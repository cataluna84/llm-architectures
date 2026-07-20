#!/bin/bash
# Per-worker agent for the VM-resident orchestration loop. Runs on EVERY host
# of the slice inside tmux session "agent" (started by startup_script.sh when
# an ACTIVE_PROGRAM exists, or bootstrapped once by launch_vm_program.sh).
#
# GCS blackboard protocol (no ssh anywhere):
#   - poll  <control>/<program>/spec-<gen+1>.env   every POLL_S seconds
#   - found -> source it -> run train_launcher.sh (blocking, all 16 workers
#     pick the spec up within ~POLL_S so the jax.distributed rendezvous holds)
#   - write <control>/<program>/done/<gen>.w<K> containing the rc
#   - repeat. Generation state is LOCAL (/tmp) — after a reboot the agent
#     re-derives it from the highest published spec so it never replays an
#     old run (a fresh boot must wait for the NEXT spec, not rerun the last).
set -uo pipefail

REPO_DIR="${REPO_DIR:-/opt/llm-architectures}"
CONTROL="${CONTROL:-gs://llm-architectures-eu/nanogptjax/control}"
POLL_S="${POLL_S:-10}"
AGENT_LOG="/tmp/agent.log"

_ts() { date -Is; }
log() { echo "[agent $(_ts)] $*" | tee -a "$AGENT_LOG"; }

WORKER="$(curl -fsS -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/agent-worker-number \
    2>/dev/null)"
[ -n "$WORKER" ] || WORKER="${HOSTNAME##*-w-}"

PROGRAM="$(gcloud storage cat "$CONTROL/ACTIVE_PROGRAM" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$PROGRAM" ]; then
    log "no ACTIVE_PROGRAM at $CONTROL — nothing to do, exiting"
    exit 0
fi
PREFIX="$CONTROL/$PROGRAM"

# Never replay: start from the highest spec generation already published.
gen=0
for u in $(gcloud storage ls "$PREFIX/spec-*.env" 2>/dev/null); do
    n="${u##*/spec-}"; n="${n%.env}"
    [ "$n" -gt "$gen" ] 2>/dev/null && gen="$n"
done

log "start: worker=$WORKER program=$PROGRAM from generation=$gen"
# Boot marker doubles as the coordinator's readiness gate.
echo "$(_ts) gen=$gen" | gcloud storage cp - "$PREFIX/boot/w$WORKER" 2>/dev/null

while true; do
    next=$(( gen + 1 ))
    if spec="$(gcloud storage cat "$PREFIX/spec-$next.env" 2>/dev/null)" \
       && [ -n "$spec" ]; then
        log "picked up spec-$next"
        # A previous launcher should have exited; kill any straggler so two
        # trainings never share the chips (bracket trick: pkill won't match
        # its own command line).
        pkill -f '[t]rain_launcher.sh' 2>/dev/null && sleep 2

        # Fresh env per run: only the spec's values + a clean base survive.
        rc=99
        if env -i HOME="$HOME" PATH="$PATH" REPO_DIR="$REPO_DIR" \
             bash -c "set -a; $spec; set +a; bash '$REPO_DIR/scripts/tpu/train_launcher.sh'" \
             </dev/null >>"$AGENT_LOG" 2>&1; then
            rc=0
        else
            rc=$?
        fi
        log "spec-$next finished rc=$rc"
        echo "rc=$rc $(_ts)" | gcloud storage cp - "$PREFIX/done/$next.w$WORKER" 2>/dev/null
        gen=$next
    else
        # Program over?
        if [ "$(gcloud storage cat "$CONTROL/ACTIVE_PROGRAM" 2>/dev/null | tr -d '[:space:]')" != "$PROGRAM" ]; then
            log "ACTIVE_PROGRAM changed/cleared — agent exiting"
            exit 0
        fi
        sleep "$POLL_S"
    fi
done
