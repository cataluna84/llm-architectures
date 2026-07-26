#!/usr/bin/env bash
# Sequential driver for a LIST of runs files. Runs on the always-on supervisor
# VM (not the workstation, not the TPU) so a sweep program survives a
# workstation shutdown and a TPU preemption.
#
# Each entry of RUNS_FILES is handed to sweep_runner.sh in order. A stage that
# aborts stops the program (loudly): later stages usually depend on earlier
# verdicts, so plowing on would burn capacity on runs whose premise just died.
#
# Progress is journalled to $STATE_DIR/completed so a systemd restart resumes
# at the next unfinished stage instead of re-running everything.
#
# Env: RUNS_FILES (space/newline separated paths, relative to repo root),
#      ZONE, NODE_ID, PROJECT_ID, STATE_DIR.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"
load_env_file "$REPO_ROOT/.env"

ZONE="${ZONE:?set ZONE}"
NODE_ID="${NODE_ID:?set NODE_ID}"
PROJECT_ID="${PROJECT_ID:-ml-pipelines-315702}"
RUNS_FILES="${RUNS_FILES:?set RUNS_FILES (space-separated runs files)}"
STATE_DIR="${STATE_DIR:-/var/lib/nanogpt-supervisor}"
DONE_FILE="$STATE_DIR/completed"

mkdir -p "$STATE_DIR"
touch "$DONE_FILE"

_ts() { date -Is; }

echo "[driver $(_ts)] start: node=$NODE_ID zone=$ZONE"
echo "[driver $(_ts)] program: $RUNS_FILES"
echo "[driver $(_ts)] already completed: $(tr '\n' ' ' < "$DONE_FILE")"

for rf in $RUNS_FILES; do
    if grep -Fxq "$rf" "$DONE_FILE"; then
        echo "[driver $(_ts)] SKIP $rf (already completed)"
        continue
    fi
    if [ ! -f "$REPO_ROOT/$rf" ]; then
        echo "[driver $(_ts)] FATAL: missing runs file $rf"
        notify "supervisor: FATAL missing runs file $rf"
        exit 2
    fi

    echo "[driver $(_ts)] === stage $rf ==="
    notify "supervisor: starting stage $(basename "$rf")"

    if ZONE="$ZONE" NODE_ID="$NODE_ID" PROJECT_ID="$PROJECT_ID" \
       RUNS_FILE="$REPO_ROOT/$rf" \
       bash "$SCRIPT_DIR/sweep_runner.sh" </dev/null; then
        echo "$rf" >> "$DONE_FILE"
        echo "[driver $(_ts)] stage $rf COMPLETE"
        notify "supervisor: stage $(basename "$rf") complete"
    else
        echo "[driver $(_ts)] stage $rf FAILED — stopping program"
        notify "supervisor: stage $(basename "$rf") FAILED — program stopped, needs a human"
        exit 1
    fi
done

echo "[driver $(_ts)] PROGRAM COMPLETE — all stages finished"
notify "supervisor: PROGRAM COMPLETE — all stages finished. TPU is idle; results on W&B."
