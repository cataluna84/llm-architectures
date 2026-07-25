#!/usr/bin/env bash
# Race-provision the baseline-10k slice across multiple TRC targets (zone +
# TPU type) on a fixed cadence until ONE slice DURABLY lands. Handles the
# mixed fleet: v5e-32 (v5litepod-32, us-central1-a + europe-west4-b) and
# v6e-64 (Trillium, europe-west4-a + us-east1-d).
#
# This is a PURE PROVISIONING loop — it does NOT decide the winner. QR=ACTIVE
# is not a durable signal (a spot slice can be reclaimed in <60s, before it
# ever boots), so the commit is driven by a separate boot-complete detector.
#
# Per TICK (default 30 min), per target:
#   FAILED / SUSPENDED / missing        -> delete + resubmit via launch_spot
#   ACTIVE / PROVISIONING / WAITING / … -> leave it (up, or holding its queue
#                                          place; churning it loses the place)
#
# Auto-launch must stay DISARMED (ACTIVE_PROGRAM=done:*) while this runs so any
# landing idle-boots instead of colliding; commit to the winner by hand.
#
# Usage (workstation tmux):
#   tmux new -d -s race-prov "bash scripts/tpu/race_provision.sh 2>&1 | tee -a /tmp/race_provision.log"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"
load_env_file "$REPO_ROOT/.env"   # NTFY_TOPIC

PROJECT_ID="${PROJECT_ID:-ml-pipelines-315702}"
TICK="${TICK:-1800}"   # 30 min provisioning cadence

# target = "zone:qr_name:env_file"  (env file sets TRC_PROFILE + DATA_SHARDS)
# v5e-32 @ europe-west4-b (eu) — single zone, so ACTIVE_PROGRAM stays ARMED
# (baseline-10k) and each landing auto-runs the baseline via startup_script (no
# committer needed). This loop just resubmits the QR when it goes SUSPENDED/FAILED
# so a preemption self-heals (re-land -> armed auto-resume from the eu checkpoint).
TARGETS=(
    "europe-west4-b:nanogpt-v5e32-qr:$REPO_ROOT/scripts/tpu/runs/launch-v5e32-ew4b.env"
)

_ts() { date -Is; }
_state() {  # zone qr_name
    gcloud compute tpus queued-resources describe "$2" \
        --zone="$1" --project="$PROJECT_ID" --format='value(state.state)' 2>/dev/null
}
_resubmit() {  # zone qr_name envfile
    local zone="$1" qr="$2" env="$3"
    echo "[race $(_ts)] resubmitting $qr @ $zone (env $(basename "$env"))"
    gcloud compute tpus queued-resources delete "$qr" \
        --zone="$zone" --project="$PROJECT_ID" --quiet --force 2>/dev/null || true
    for _i in $(seq 1 30); do [ -z "$(_state "$zone" "$qr")" ] && break; sleep 10; done
    ( set -a; # shellcheck disable=SC1090
      source "$env"; set +a
      QR_NAME="$qr" ZONE="$zone" bash "$SCRIPT_DIR/launch_spot.sh" ) \
        && notify "race-provision: resubmitted $qr @ $zone" \
        || echo "[race $(_ts)] WARNING: $qr @ $zone resubmit failed; retry next tick"
}

echo "[race $(_ts)] provisioning race across ${#TARGETS[@]} targets, tick=${TICK}s (winner decided by boot-complete detector)"
notify "race-provision: cycling ${#TARGETS[@]} v5e-32/v6e-64 targets every $((TICK/60))min; commit on boot-complete"

while true; do
    for t in "${TARGETS[@]}"; do
        IFS=: read -r zone qr env <<< "$t"
        st="$(_state "$zone" "$qr")"
        echo "[race $(_ts)] $qr @ $zone = ${st:-<missing>}"
        case "$st" in
            FAILED|SUSPENDED|SUSPENDING|"") _resubmit "$zone" "$qr" "$env" ;;
            *) : ;;  # ACTIVE/PROVISIONING/WAITING_FOR_RESOURCES/ACCEPTED/CREATING — leave
        esac
    done
    echo "[race $(_ts)] tick complete; sleeping ${TICK}s"
    sleep "$TICK"
done
