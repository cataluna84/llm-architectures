#!/bin/bash
# Daily ops helper for the nanoGPT TPU run.
#
# Usage:
#   bash scripts/tpu/ops.sh status
#   bash scripts/tpu/ops.sh tail-logs
#   bash scripts/tpu/ops.sh attach
#   bash scripts/tpu/ops.sh ssh
#   bash scripts/tpu/ops.sh pull-ckpt [LOCAL_DIR]
#   bash scripts/tpu/ops.sh delete
#
# Configuration precedence: shell env > <repo-root>/.env > defaults below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"
load_env_file "$ENV_FILE"

PROJECT_ID="${PROJECT_ID:-ml-pipelines-315702}"
ZONE="${ZONE:-europe-west4-a}"
QR_NAME="${QR_NAME:-nanogpt-v6e8-baseline-qr}"
NODE_ID="${NODE_ID:-nanogpt-v6e8-baseline}"
BUCKET="${BUCKET:-llm-architectures-eu}"
CKPT_PREFIX="${CKPT_PREFIX:-nanogptjax/checkpoints}"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 11; exit 1; }

cmd="${1:-}"; shift || true

case "$cmd" in
    status)
        echo "==> Queued Resource"
        gcloud compute tpus queued-resources describe "$QR_NAME" \
            --project="$PROJECT_ID" --zone="$ZONE" || true
        echo
        echo "==> TPU node (if provisioned)"
        gcloud compute tpus tpu-vm describe "$NODE_ID" \
            --project="$PROJECT_ID" --zone="$ZONE" 2>/dev/null || echo "    (not yet provisioned)"
        ;;
    tail-logs)
        gcloud compute tpus tpu-vm ssh "$NODE_ID" \
            --project="$PROJECT_ID" --zone="$ZONE" --worker=0 \
            --command="tail -n 80 -f /tmp/train.log"
        ;;
    attach)
        echo "==> attaching tmux 'train' (root-owned; Ctrl-b d to detach)"
        gcloud compute tpus tpu-vm ssh "$NODE_ID" \
            --project="$PROJECT_ID" --zone="$ZONE" --worker=0 \
            -- -t "sudo tmux attach -t train"
        ;;
    ssh)
        gcloud compute tpus tpu-vm ssh "$NODE_ID" \
            --project="$PROJECT_ID" --zone="$ZONE" --worker=0
        ;;
    pull-ckpt)
        dst="${1:-./_artifacts}"; mkdir -p "$dst"
        echo "==> pulling gs://$BUCKET/$CKPT_PREFIX -> $dst"
        gcloud storage rsync -r "gs://$BUCKET/$CKPT_PREFIX/" "$dst/"
        ls -lh "$dst"
        ;;
    delete)
        echo "==> deleting Queued Resource $QR_NAME (stops billing for the slice)"
        gcloud compute tpus queued-resources delete "$QR_NAME" \
            --project="$PROJECT_ID" --zone="$ZONE" --force --quiet
        ;;
    *)
        usage
        ;;
esac
