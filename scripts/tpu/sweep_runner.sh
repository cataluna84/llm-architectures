#!/usr/bin/env bash
# Sequential sweep executor. Run on the LOCAL workstation in a detached tmux —
# it survives the Claude session, the IDE, and anything short of the
# workstation itself dying (tinyaya-stage2-scale orchestration pattern).
#
# Reads RUNS_FILE: one run per line, each line a space-separated list of
# KEY=VALUE envs passed to deploy_tarball.sh (blank lines / #-comments
# skipped). Runs execute strictly in order; each is deployed, then watched to
# completion via this run's tag-scoped segment of worker 0's /tmp/train.log. A
# run that finishes without "Reached maximum training steps" aborts the sweep
# (loudly, with ntfy) rather than plowing on with a broken fleet.
#
# Stage-agnostic: a runs-file line may set NANOGPT_ENTRYPOINT to run SFT or any
# other stage, and RUN_TIMEOUT_SECONDS to override the completion budget for
# that one run (a 10k pretrain needs far longer than a 1000-step sweep run).
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
# Default per-run completion budget (seconds); a runs-file line may override it
# with its own RUN_TIMEOUT_SECONDS=. Sweep runs on v5e-64 take ~6-12 min;
# leave slack for compile + deploy.
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

ready_workers() {
    timeout 240 gcloud compute tpus tpu-vm ssh "$NODE_ID" \
        --project="$PROJECT_ID" --zone="$ZONE" --worker=all --quiet \
        --command="sudo grep -c 'startup_script.sh complete' /tmp/startup.log 2>/dev/null" \
        2>/dev/null | grep -c '^1$'
}

# Print the tag-scoped segment of worker 0's train.log, i.e. everything from
# this deploy's launch line onward. Never matches a stale segment from an
# earlier deploy or boot (a 7h-old segment once triggered a spurious abort).
seg_cmd() { # tag
    printf "awk -v t='tag=%s' 'index(\$0, t){m=NR} m && NR>=m' /tmp/train.log" "$1"
}

# Rare status markers, read from the TAIL.
#
# These MUST NOT share a filter with the repeating "Best loss" line. The
# original probe piped both through a single `head -6`; a 1000-step run emits
# one "Best loss" per shard boundary, so the six lines of head budget were
# consumed before the exit marker and the run looked hung forever. A finished
# 1000-step run went undetected for an hour on 2026-07-20 this way.
#
# "exited with status" is deliberately stage-agnostic — it matches
# "nanogpt/train.py exited with status 0", "nanogpt/train_sft.py exited ...",
# and every line the pre-2026-07-20 launcher wrote.
run_status() { # tag
    vmssh 0 "$(seg_cmd "$1") | grep -E 'exited with status|Reached maximum training steps|Traceback|DEADLINE_EXCEEDED|RESOURCE_EXHAUSTED' | tail -6"
}

run_best_loss() { # tag
    vmssh 0 "$(seg_cmd "$1") | grep 'Best loss' | tail -1"
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

# Runs file on fd 3: the loop body runs ssh/gcloud, which read stdin and
# would silently swallow the remaining lines of a stdin-fed while-read
# (observed: a 5-run file "completed" after run 1).
run_no=0
while IFS= read -r -u3 line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    run_no=$(( run_no + 1 ))
    tag="sweeprun${run_no}-$(date +%s)"

    # Per-run timeout override, if this line carries one.
    run_timeout="$RUN_TIMEOUT_SECONDS"
    case "$line" in
        *RUN_TIMEOUT_SECONDS=*)
            run_timeout="$(printf '%s\n' "$line" \
                | sed -n 's/.*RUN_TIMEOUT_SECONDS=\([0-9]\{1,\}\).*/\1/p')"
            run_timeout="${run_timeout:-$RUN_TIMEOUT_SECONDS}"
            ;;
    esac

    echo ""
    echo "[sweep $(_ts)] === run #$run_no tag=$tag (timeout ${run_timeout}s): $line ==="

    if ! env $line ZONE="$ZONE" NODE_ID="$NODE_ID" RUN_TAG="$tag" \
         bash "$SCRIPT_DIR/deploy_tarball.sh" </dev/null >>/tmp/sweep_deploy.log 2>&1; then
        echo "[sweep $(_ts)] ABORT: deploy failed for run #$run_no (see /tmp/sweep_deploy.log)"
        notify "sweep_runner ABORT: deploy failed on run #$run_no"
        exit 1
    fi
    echo "[sweep $(_ts)] run #$run_no deployed; waiting on log segment tag=$tag"

    deadline=$(( $(date +%s) + run_timeout ))
    while true; do
        sleep 60
        status="$(run_status "$tag")"
        if echo "$status" | grep -q 'exited with status'; then
            best="$(run_best_loss "$tag")"
            echo "[sweep $(_ts)] run #$run_no finished:"
            echo "$status"
            [ -n "$best" ] && echo "$best"
            if echo "$status" | grep -q "Reached maximum training steps"; then
                notify "sweep_runner: run #$run_no OK — ${best:-no val loss recorded}"
            else
                echo "[sweep $(_ts)] ABORT: run #$run_no did not complete cleanly"
                notify "sweep_runner ABORT: run #$run_no failed — check /tmp/train.log on $NODE_ID"
                exit 1
            fi
            break
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "[sweep $(_ts)] ABORT: run #$run_no exceeded ${run_timeout}s (preemption? check qr_watch)"
            notify "sweep_runner ABORT: run #$run_no timed out"
            exit 1
        fi
    done
done 3< "$RUNS_FILE"

echo "[sweep $(_ts)] SWEEP COMPLETE — all $run_no runs finished"
notify "sweep_runner: SWEEP COMPLETE ($run_no runs)"
