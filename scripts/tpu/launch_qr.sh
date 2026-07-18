#!/bin/bash
# Create the Queued Resource that provisions the TPU slice and runs
# startup_script.sh (pure-JAX nanoGPT deploy + train) on the host.
#
# Run from your local workstation after setup_gcp.sh has succeeded. TRC v6e is
# SPOT-only, so the usual entrypoint is launch_spot.sh (a TRC_PROFILE wrapper
# around this script with SPOT=1); call this directly only for a custom slice.
#
# Configuration precedence (highest first):
#   1. shell env vars (e.g. `TOTAL_TRAIN_STEPS=50 bash launch_qr.sh`)
#   2. <repo-root>/.env  (auto-sourced)
#   3. defaults below

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
ACCEL_TYPE="${ACCEL_TYPE:-v6e-8}"
RUNTIME="${RUNTIME:-v2-alpha-tpuv6e}"
# SPOT=1 -> preemptible (required for TRC v6e). Empty = on-demand.
SPOT="${SPOT:-}"

# ---- what the VM deploys + runs (passed via VM metadata to startup_script.sh) ----
REPO_URL="${REPO_URL:-https://github.com/cataluna84/llm-architectures.git}"
REPO_BRANCH="${REPO_BRANCH:-feat/nanoGPTJAX}"
# Data: pull N FineWeb10B train shards from the PUBLIC HF dataset on the VM
# (data-source=hf), or rsync a pre-staged copy from GCS (data-source=gcs).
DATA_SOURCE="${DATA_SOURCE:-hf}"
DATA_SHARDS="${DATA_SHARDS:-2}"
GCS_DATA_URI="${GCS_DATA_URI:-gs://llm-architectures-eu/nanogptjax/data/fineweb10B}"
# Training knobs consumed by nanogpt/config.py env overrides. The default is a
# SMOKE run (50 steps); raise TOTAL_TRAIN_STEPS for the full baseline.
TOTAL_TRAIN_STEPS="${TOTAL_TRAIN_STEPS:-50}"
PER_DEVICE_BATCH_SIZE="${PER_DEVICE_BATCH_SIZE:-}"   # empty = config default (32)
SAVE_CKPT_DIR="${SAVE_CKPT_DIR:-}"                    # empty = don't save (smoke)

STARTUP_SCRIPT="$SCRIPT_DIR/startup_script.sh"
[ -f "$STARTUP_SCRIPT" ] || { echo "ERROR: $STARTUP_SCRIPT not found" >&2; exit 1; }

extra_flags=()
tier="on-demand"
if [ -n "$SPOT" ] && [ "$SPOT" != "0" ] && [ "$SPOT" != "false" ]; then
    extra_flags+=(--spot); tier="spot (preemptible)"
fi

metadata_pairs="repo-url=$REPO_URL,repo-branch=$REPO_BRANCH"
metadata_pairs+=",data-source=$DATA_SOURCE,data-shards=$DATA_SHARDS,gcs-data-uri=$GCS_DATA_URI"
metadata_pairs+=",total-train-steps=$TOTAL_TRAIN_STEPS"
[ -n "$PER_DEVICE_BATCH_SIZE" ] && metadata_pairs+=",per-device-batch-size=$PER_DEVICE_BATCH_SIZE"
[ -n "$SAVE_CKPT_DIR" ] && metadata_pairs+=",save-ckpt-dir=$SAVE_CKPT_DIR"

echo "==> creating Queued Resource"
echo "    project:      $PROJECT_ID"
echo "    zone:         $ZONE"
echo "    QR / node:    $QR_NAME / $NODE_ID"
echo "    accelerator:  $ACCEL_TYPE   runtime: $RUNTIME   tier: $tier"
echo "    repo:         $REPO_URL @ $REPO_BRANCH"
echo "    data:         source=$DATA_SOURCE shards=$DATA_SHARDS"
echo "    train steps:  $TOTAL_TRAIN_STEPS   per-device-bsz: ${PER_DEVICE_BATCH_SIZE:-<config default>}"
echo "    save ckpt:    ${SAVE_CKPT_DIR:-<none — smoke>}"
echo

gcloud compute tpus queued-resources create "$QR_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --node-id="$NODE_ID" \
    --accelerator-type="$ACCEL_TYPE" \
    --runtime-version="$RUNTIME" \
    --metadata-from-file=startup-script="$STARTUP_SCRIPT" \
    --metadata="$metadata_pairs" \
    "${extra_flags[@]}"

echo
echo "==> QR submitted. Watch with:  QR_NAME=$QR_NAME NODE_ID=$NODE_ID bash scripts/tpu/ops.sh status"
