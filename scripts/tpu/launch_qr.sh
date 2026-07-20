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
# Code ships as a TARBALL of the local working tree (incl. the gitignored .env,
# so WANDB_* work from the very first boot) — no git clone on the VM. The
# tarball is built + uploaded here at submit time and its URI pinned in
# metadata; set CODE_TARBALL_URI to reuse an already-uploaded tarball instead.
BUCKET="${BUCKET:-llm-architectures-eu}"
CODE_PREFIX="${CODE_PREFIX:-nanogptjax/code}"
CODE_TARBALL_URI="${CODE_TARBALL_URI:-}"
# Data: pull N FineWeb10B train shards from the PUBLIC HF dataset on the VM
# (data-source=hf), or rsync a pre-staged copy from GCS (data-source=gcs).
DATA_SOURCE="${DATA_SOURCE:-hf}"
DATA_SHARDS="${DATA_SHARDS:-2}"
GCS_DATA_URI="${GCS_DATA_URI:-gs://llm-architectures-eu/nanogptjax/data/fineweb10B}"
# Training knobs consumed by nanogpt/config.py env overrides. The default is a
# SMOKE run (50 steps); raise TOTAL_TRAIN_STEPS for the full baseline.
TOTAL_TRAIN_STEPS="${TOTAL_TRAIN_STEPS:-50}"
# v6e-8 has 31 GiB HBM/chip; the config default (32) is sized for 80 GiB GPUs and
# OOMs a v6e chip (needs ~115 GiB). 4 is verified-safe (~14 GiB, ~0.98 s/step) and
# the desired token batch is preserved via gradient accumulation. Raise carefully.
PER_DEVICE_BATCH_SIZE="${PER_DEVICE_BATCH_SIZE:-4}"
SAVE_CKPT_DIR="${SAVE_CKPT_DIR:-}"                    # empty = don't save (smoke)
# Full-run self-healing: with these in boot metadata, a spot-preemption reboot
# re-runs startup_script.sh, auto-resumes from the latest GCS checkpoint, and
# continues the SAME W&B run. resume=auto is a no-op when SAVE_CKPT_DIR is unset.
RESUME_FROM_STEP="${RESUME_FROM_STEP:-auto}"
WANDB_RUN_NAME="${WANDB_RUN_NAME:-}"
WANDB_RUN_ID="${WANDB_RUN_ID:-}"
NANOGPT_VAL_MAX_BATCHES="${NANOGPT_VAL_MAX_BATCHES:-}"
NANOGPT_DEVICE_PEAK_FLOPS="${NANOGPT_DEVICE_PEAK_FLOPS:-}"

STARTUP_SCRIPT="$SCRIPT_DIR/startup_script.sh"
[ -f "$STARTUP_SCRIPT" ] || { echo "ERROR: $STARTUP_SCRIPT not found" >&2; exit 1; }

if [ -z "$CODE_TARBALL_URI" ]; then
    STAMP="$(date +%Y%m%d-%H%M%S)"
    CODE_TARBALL_URI="gs://$BUCKET/$CODE_PREFIX/llm-arch-code-$STAMP.tar.gz"
    TARBALL_WORK="$(mktemp -d)"
    echo "==> tarring working tree (incl. .env) -> $CODE_TARBALL_URI"
    make_code_tarball "$TARBALL_WORK/code.tar.gz" "$REPO_ROOT"
    gcloud storage cp "$TARBALL_WORK/code.tar.gz" "$CODE_TARBALL_URI" \
        --project="$PROJECT_ID" >/dev/null
    gcloud storage cp "$CODE_TARBALL_URI" "gs://$BUCKET/$CODE_PREFIX/latest.tar.gz" \
        --project="$PROJECT_ID" >/dev/null
    rm -rf "$TARBALL_WORK"
fi

extra_flags=()
tier="on-demand"
if [ -n "$SPOT" ] && [ "$SPOT" != "0" ] && [ "$SPOT" != "false" ]; then
    extra_flags+=(--spot); tier="spot (preemptible)"
fi

metadata_pairs="code-tarball-uri=$CODE_TARBALL_URI"
metadata_pairs+=",data-source=$DATA_SOURCE,data-shards=$DATA_SHARDS,gcs-data-uri=$GCS_DATA_URI"
metadata_pairs+=",total-train-steps=$TOTAL_TRAIN_STEPS"
[ -n "$PER_DEVICE_BATCH_SIZE" ] && metadata_pairs+=",per-device-batch-size=$PER_DEVICE_BATCH_SIZE"
[ -n "$SAVE_CKPT_DIR" ] && metadata_pairs+=",save-ckpt-dir=$SAVE_CKPT_DIR"
metadata_pairs+=",resume-from-step=$RESUME_FROM_STEP"
[ -n "$WANDB_RUN_NAME" ] && metadata_pairs+=",wandb-run-name=$WANDB_RUN_NAME"
[ -n "$WANDB_RUN_ID" ] && metadata_pairs+=",wandb-run-id=$WANDB_RUN_ID"
[ -n "$NANOGPT_VAL_MAX_BATCHES" ] && metadata_pairs+=",val-max-batches=$NANOGPT_VAL_MAX_BATCHES"
[ -n "$NANOGPT_DEVICE_PEAK_FLOPS" ] && metadata_pairs+=",device-peak-flops=$NANOGPT_DEVICE_PEAK_FLOPS"

echo "==> creating Queued Resource"
echo "    project:      $PROJECT_ID"
echo "    zone:         $ZONE"
echo "    QR / node:    $QR_NAME / $NODE_ID"
echo "    accelerator:  $ACCEL_TYPE   runtime: $RUNTIME   tier: $tier"
echo "    code:         $CODE_TARBALL_URI"
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
