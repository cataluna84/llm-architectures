#!/usr/bin/env bash
# Boot-complete detector + committer for the v5e-64 two-zone race.
#
# While race_provision.sh keeps resubmitting nanogpt-v5e64-qr on BOTH zones and
# ACTIVE_PROGRAM stays DISARMED (done:baseline-10k) so any landing idle-boots,
# this watches for the FIRST slice that is durably up (state READY + health
# HEALTHY + 16/16 host endpoints) and then, atomically:
#   1. tears down the OTHER zone's QR (the loser) so it can never collide,
#   2. stops the race loop (no more resubmits),
#   3. runs launch_vm_program.sh on the winner -> arms baseline-10k + starts the
#      coordinator, which resumes from the latest GCS checkpoint (step 0 now).
# Then exits. One commit, ever.
#
# Preference order = europe-west4-b first (the user's stated zone), then
# us-central1-a. Usage (workstation tmux):
#   tmux new -d -s race-commit "bash scripts/tpu/race_commit.sh 2>&1 | tee -a /tmp/race_commit.log"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"
load_env_file "$REPO_ROOT/.env"   # NTFY_TOPIC

PROJECT_ID="${PROJECT_ID:-ml-pipelines-315702}"
QR_NAME="${QR_NAME:-nanogpt-v5e64-qr}"
NODE_ID="${NODE_ID:-nanogpt-v5e64}"
POLL="${POLL:-60}"
ZONES=(europe-west4-b us-central1-a)
RUNS_FILE="scripts/tpu/runs/v5e64-baseline-10k.runs"

_ts() { date -Is; }
_durable() {  # zone -> 0 if node is READY+HEALTHY with 16 endpoints
    local z="$1" sh state health n
    sh="$(gcloud compute tpus tpu-vm describe "$NODE_ID" --zone="$z" \
        --project="$PROJECT_ID" --format='value(state,health)' 2>/dev/null)"
    state="$(awk '{print $1}' <<< "$sh")"
    health="$(awk '{print $2}' <<< "$sh")"
    [ "$state" = "READY" ] && [ "$health" = "HEALTHY" ] || return 1
    n="$(gcloud compute tpus tpu-vm describe "$NODE_ID" --zone="$z" \
        --project="$PROJECT_ID" --format='value(networkEndpoints)' 2>/dev/null \
        | tr ';' '\n' | grep -c ipAddress)"
    [ "$n" = "16" ]
}

echo "[commit $(_ts)] watching ${ZONES[*]} for the first durable 16/16 boot (poll ${POLL}s)"
notify "race-commit: watching ${ZONES[*]} for first durable v5e-64 boot"

while true; do
    for z in "${ZONES[@]}"; do
        if _durable "$z"; then
            loser=""
            for o in "${ZONES[@]}"; do [ "$o" != "$z" ] && loser="$o"; done
            echo "[commit $(_ts)] WINNER: $NODE_ID @ $z is durable (16/16 HEALTHY)"
            notify "race-commit: WINNER $z durable — committing baseline-10k, tearing down $loser"

            if [ -n "$loser" ]; then
                echo "[commit $(_ts)] tearing down loser QR @ $loser"
                gcloud compute tpus queued-resources delete "$QR_NAME" --zone="$loser" \
                    --project="$PROJECT_ID" --quiet --force 2>/dev/null || true
            fi

            echo "[commit $(_ts)] stopping race loop"
            tmux kill-session -t race-prov 2>/dev/null || true

            echo "[commit $(_ts)] committing baseline-10k to $z"
            cd "$REPO_ROOT"
            if PROGRAM=baseline-10k RUNS_FILES="$RUNS_FILE" EXPECT_WORKERS=16 \
               ZONE="$z" NODE_ID="$NODE_ID" FRESH=0 \
               bash "$SCRIPT_DIR/launch_vm_program.sh"; then
                echo "[commit $(_ts)] committed. baseline-10k armed on $z."
                notify "race-commit: baseline-10k committed + running on $z"
            else
                echo "[commit $(_ts)] ERROR: launch_vm_program failed — re-run by hand for $z"
                notify "race-commit: FAILED to commit on $z — needs a hand"
            fi
            exit 0
        fi
    done
    sleep "$POLL"
done
