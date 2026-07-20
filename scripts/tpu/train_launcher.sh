#!/bin/bash
# THE canonical training launcher. Runs ON a TPU worker with all NANOGPT_*/
# WANDB_* env already exported by the caller (deploy_tarball's generated env
# file, or vm_worker_agent's sourced run spec).
#
# Emits the exact log markers every orchestrator matches on:
#   [ts] launching <entrypoint> tag=<RUN_TAG> ...
#   [ts] <entrypoint> exited with status <rc>
#
# rc is captured on its own line BEFORE the echo: a $(date) substitution on
# the same line as $? resets $? to date's status, which made every historic
# exit status read 0 — including fatal tracebacks (fixed 2026-07-20).
set -uo pipefail

REPO_DIR="${REPO_DIR:-/opt/llm-architectures}"
RUN_TAG="${RUN_TAG:?train_launcher: RUN_TAG must be set}"
NANOGPT_ENTRYPOINT="${NANOGPT_ENTRYPOINT:-nanogpt/train.py}"
TRAIN_LOG="${TRAIN_LOG:-/tmp/train.log}"

ulimit -n 1048576
cd "$REPO_DIR"
export PATH="/root/.local/bin:/usr/local/bin:$PATH"
export NANOGPT_TPU=1
export NANOGPT_DATA_DIR="${NANOGPT_DATA_DIR:-$REPO_DIR/nanogpt/fineweb10B}"
export PYTHONUNBUFFERED=1

UV="$(command -v uv || echo /root/.local/bin/uv)"

echo "[$(date -Is)] launching $NANOGPT_ENTRYPOINT tag=$RUN_TAG steps=${NANOGPT_TOTAL_TRAIN_STEPS:-default} bsz=${NANOGPT_PER_DEVICE_BATCH_SIZE:-default} resume=${NANOGPT_RESUME_FROM_STEP:-0} seed=${NANOGPT_SEED:-0} peak_lr=${NANOGPT_OTHER_PEAK_LR:-default} mom_warmup=${NANOGPT_MUON_MOMENTUM_WARMUP_STEPS:-default}" | tee -a "$TRAIN_LOG"
"$UV" run python -u "$NANOGPT_ENTRYPOINT" 2>&1 | tee -a "$TRAIN_LOG"
rc=$?
echo "[$(date -Is)] $NANOGPT_ENTRYPOINT exited with status $rc" | tee -a "$TRAIN_LOG"
exit "$rc"
