#!/usr/bin/env bash
# Sequential sweep executor. Run on the LOCAL workstation in a detached tmux —
# it survives the Claude session, the IDE, and anything short of the
# workstation itself dying (tinyaya-stage2-scale orchestration pattern).
#
# Reads RUNS_FILE: one run per line, each line a space-separated list of
# KEY=VALUE envs passed to deploy_tarball.sh (blank lines / #-comments
# skipped). Runs execute strictly in order; each is deployed, then watched to
# completion via the exit-count ledger on worker 0's /tmp/train.log. A run
# that finishes without "Reached maximum training steps" aborts the sweep
# (loudly, with ntfy) rather than plowing on with a broken fleet.
#
# Usage:
#   tmux new -d -s sweep \
#     "ZONE=europe-west4-b NODE_ID=nanogpt-v5e64 RUNS_FILE=sweeps/v5e64-lr.runs \
#      bash scripts/tpu/sweep_runner.sh 2>&1 | tee -a /tmp/sweep_runner.log"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"
load_env_file "$REPO_ROOT/.env"   # NTFY_TOPIC etc.

ZONE="${ZONE:?set ZONE}"
NODE_ID="${NODE_ID:?set NODE_ID}"
PROJECT_ID="${PROJECT_ID:-ml-pipelines-315702}"
RUNS_FILE="${RUNS_FILE:?set RUNS_FILE (one run per line: KEY=VALUE ...)}"
# Per-run completion budget (seconds). Sweep runs on v5e-64 should take
# ~6-12 min; leave slack for compile + deploy.
RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-3600}"
# All-workers readiness gate before the first deploy (startup marker present).
EXPECT_WORKERS="${EXPECT_WORKERS:-16}"

[ -f "$RUNS_FILE" ] || { echo "[sweep] FATAL: no runs file $RUNS_FILE"; exit 2; }

_ts() { date -Is; }

vmssh() { # worker cmd
    timeout 120 gcloud compute tpus tpu-vm ssh "$NODE_ID" \
        --project="$PROJECT_ID" --zone="$ZONE" --worker="$1" --quiet \
        --command="$2" 2>/dev/null
}

exit_count() {
    vmssh 0 "grep -c 'train.py exited' /tmp/train.log" | tr -dc '0-9'
}

ready_workers() {
    timeout 240 gcloud compute tpus tpu-vm ssh "$NODE_ID" \
        --project="$PROJECT_ID" --zone="$ZONE" --worker=all --quiet \
        --command="sudo grep -c 'startup_script.sh complete' /tmp/startup.log 2>/dev/null" \
        2>/dev/null | grep -c '^1$'
}

echo "[sweep $(_ts)] runner start: node=$NODE_ID zone=$ZONE runs_file=$RUNS_FILE"
notify "sweep_runner: starting (runs: $(grep -cvE '^\s*(#|$)' "$RUNS_FILE"))"

# ---- readiness gate: all workers must have completed startup ----
for _i in $(seq 1 60); do
    n=$(ready_workers); n=${n:-0}
    echo "[sweep $(_ts)] readiness: $n/$EXPECT_WORKERS workers have startup complete"
    [ "$n" -ge "$EXPECT_WORKERS" ] && break
    if [ "$_i" -eq 60 ]; then
        echo "[sweep $(_ts)] ABORT: fleet never became ready"
        notify "sweep_runner ABORT: only $n/$EXPECT_WORKERS workers ready"
        exit 1
    fi
    sleep 60
done
echo "[sweep $(_ts)] fleet ready"
notify "sweep_runner: fleet ready ($EXPECT_WORKERS workers)"

run_no=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    run_no=$(( run_no + 1 ))
    echo ""
    echo "[sweep $(_ts)] === run #$run_no: $line ==="

    n0=$(exit_count); n0=${n0:-0}
    if ! env $line ZONE="$ZONE" NODE_ID="$NODE_ID" \
         bash "$SCRIPT_DIR/deploy_tarball.sh" >>/tmp/sweep_deploy.log 2>&1; then
        echo "[sweep $(_ts)] ABORT: deploy failed for run #$run_no (see /tmp/sweep_deploy.log)"
        notify "sweep_runner ABORT: deploy failed on run #$run_no"
        exit 1
    fi
    echo "[sweep $(_ts)] run #$run_no deployed; waiting for completion (ledger n0=$n0)"

    deadline=$(( $(date +%s) + RUN_TIMEOUT_SECONDS ))
    while true; do
        sleep 60
        n=$(exit_count); n=${n:-$n0}
        if [ "$n" -gt "$n0" ]; then
            seg=$(vmssh 0 "awk '/launching train.py/{m=NR} m && NR>=m' /tmp/train.log | grep -E 'Reached maximum training steps|Best loss|Traceback|DEADLINE_EXCEEDED' | head -4")
            echo "[sweep $(_ts)] run #$run_no finished:"
            echo "$seg"
            if echo "$seg" | grep -q "Reached maximum training steps"; then
                notify "sweep_runner: run #$run_no OK — $(echo "$seg" | grep 'Best loss' | head -1)"
            else
                echo "[sweep $(_ts)] ABORT: run #$run_no did not complete cleanly"
                notify "sweep_runner ABORT: run #$run_no failed — check /tmp/train.log on $NODE_ID"
                exit 1
            fi
            break
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "[sweep $(_ts)] ABORT: run #$run_no exceeded ${RUN_TIMEOUT_SECONDS}s (preemption? check qr_watch)"
            notify "sweep_runner ABORT: run #$run_no timed out"
            exit 1
        fi
    done
done < "$RUNS_FILE"

echo "[sweep $(_ts)] SWEEP COMPLETE — all $run_no runs finished"
notify "sweep_runner: SWEEP COMPLETE ($run_no runs)"
