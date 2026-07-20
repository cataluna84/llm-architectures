#!/usr/bin/env bash
# One-shot handover: give the TPU VM a PROGRAM (ordered list of runs files)
# and make it self-driving. After this returns, the workstation can shut
# down — agents + coordinator live on the TPU, state lives in GCS, and a
# preemption reboot resumes via startup_script.sh.
#
# Usage:
#   PROGRAM=sweep2-final \
#   RUNS_FILES="scripts/tpu/runs/v5e64-sweep2-stage3.runs scripts/tpu/runs/v5e64-sweep2-stage4.runs" \
#   bash scripts/tpu/launch_vm_program.sh
#
#   FRESH=1 wipes a previous journal for PROGRAM (default: resume).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"
load_env_file "$REPO_ROOT/.env"

PROJECT_ID="${PROJECT_ID:-ml-pipelines-315702}"
ZONE="${ZONE:-europe-west4-b}"
NODE_ID="${NODE_ID:-nanogpt-v5e64}"
BUCKET="${BUCKET:-llm-architectures-eu}"
CODE_PREFIX="${CODE_PREFIX:-nanogptjax/code}"
CONTROL="gs://$BUCKET/nanogptjax/control"
REPO_DIR="${REPO_DIR:-/opt/llm-architectures}"
PROGRAM="${PROGRAM:?set PROGRAM (name for this program)}"
RUNS_FILES="${RUNS_FILES:?set RUNS_FILES (space-separated, repo-relative)}"
FRESH="${FRESH:-0}"

for rf in $RUNS_FILES; do
    [ -f "$REPO_ROOT/$rf" ] || { echo "FATAL: missing $rf"; exit 2; }
done

STAMP="$(date +%Y%m%d-%H%M%S)"
echo "==> [1/4] shipping working tree (incl. .env + runs files) to GCS"
TB="$(mktemp -d)/code-$STAMP.tar.gz"
make_code_tarball "$TB" "$REPO_ROOT"
gcloud storage cp "$TB" "gs://$BUCKET/$CODE_PREFIX/llm-arch-code-$STAMP.tar.gz" --project="$PROJECT_ID" >/dev/null
gcloud storage cp "gs://$BUCKET/$CODE_PREFIX/llm-arch-code-$STAMP.tar.gz" \
    "gs://$BUCKET/$CODE_PREFIX/latest.tar.gz" --project="$PROJECT_ID" >/dev/null

echo "==> [2/4] writing control plane: $CONTROL/$PROGRAM"
if [ "$FRESH" = "1" ]; then
    gcloud storage rm -r "$CONTROL/$PROGRAM" 2>/dev/null || true
fi
printf '%s\n' $RUNS_FILES | gcloud storage cp - "$CONTROL/$PROGRAM/program.list"
printf '%s' "$PROGRAM" | gcloud storage cp - "$CONTROL/ACTIVE_PROGRAM"

echo "==> [3/4] refreshing code + starting agents on all workers"
gcloud compute tpus tpu-vm ssh "$NODE_ID" --project="$PROJECT_ID" --zone="$ZONE" \
    --worker=all --quiet --command="
set -e
sudo mkdir -p '$REPO_DIR'
sudo gcloud storage cp 'gs://$BUCKET/$CODE_PREFIX/latest.tar.gz' /tmp/code.tar.gz
sudo tar -xzf /tmp/code.tar.gz -C '$REPO_DIR'
sudo tmux kill-session -t agent 2>/dev/null || true
sudo tmux kill-session -t sweep 2>/dev/null || true
sudo tmux kill-session -t train 2>/dev/null || true
sudo tmux new-session -d -s agent \"REPO_DIR='$REPO_DIR' CONTROL='$CONTROL' bash '$REPO_DIR/scripts/tpu/vm_worker_agent.sh'\"
" </dev/null

echo "==> [4/4] starting coordinator on worker 0"
gcloud compute tpus tpu-vm ssh "$NODE_ID" --project="$PROJECT_ID" --zone="$ZONE" \
    --worker=0 --quiet --command="
sudo tmux new-session -d -s sweep \"REPO_DIR='$REPO_DIR' CONTROL='$CONTROL' bash '$REPO_DIR/scripts/tpu/vm_coordinator.sh'\"
sleep 3; sudo tmux ls
" </dev/null

echo
echo "Handover complete. The workstation is no longer required."
echo "  events:  https://ntfy.sh/\$NTFY_TOPIC"
echo "  metrics: https://wandb.ai/cataluna84/llm-architectures"
echo "  state:   $CONTROL/$PROGRAM/{journal,heartbeat,logs/coordinator.log}"
