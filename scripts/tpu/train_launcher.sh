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

# Reap orphaned entrypoint processes from a previous crashed run. A libtpu
# SLICE_FAILURE kills the controller but leaves the python workers alive holding
# the TPU, so the NEXT launch cannot acquire it and libtpu reports
# SLICE_FAILURE_FLAPPING_TASK_ERROR ~8s in, with no program ever loaded
# ("Program fingerprint: n/a"). Observed on 14 of 16 v5e-64 hosts after three
# crashed SFT attempts (2026-07-26); clearing them made the slice usable again
# without a reboot.
#
# The bracketed regex is load-bearing: `pkill -f` matches full command lines, so
# an unbracketed pattern also matches THIS script and the shell running it, and
# the cleanup kills itself before reaping anything.
_stale='nanogpt/train_sf[t].py|nanogpt/run_eva[l].py|nanogpt/trai[n].py'
if pgrep -f "$_stale" >/dev/null 2>&1; then
    echo "[$(date -Is)] reaping orphaned entrypoint procs from a prior run" | tee -a "$TRAIN_LOG"
    pkill -f "$_stale" 2>/dev/null || true
    sleep 3
    pkill -9 -f "$_stale" 2>/dev/null || true
    sleep 2
fi

# Clear a stale libtpu lock a hard-killed prior process may have left behind: a
# dead pid's lock makes jax fail init with "TPU already in use" / SliceBuilder
# DEADLINE_EXCEEDED. Safe to remove — no live TPU process holds it at launch.
rm -f /tmp/libtpu_lockfile 2>/dev/null || true

echo "[$(date -Is)] launching $NANOGPT_ENTRYPOINT tag=$RUN_TAG steps=${NANOGPT_TOTAL_TRAIN_STEPS:-default} bsz=${NANOGPT_PER_DEVICE_BATCH_SIZE:-default} resume=${NANOGPT_RESUME_FROM_STEP:-0} seed=${NANOGPT_SEED:-0} peak_lr=${NANOGPT_OTHER_PEAK_LR:-default} mom_warmup=${NANOGPT_MUON_MOMENTUM_WARMUP_STEPS:-default}" | tee -a "$TRAIN_LOG"
"$UV" run python -u "$NANOGPT_ENTRYPOINT" 2>&1 | tee -a "$TRAIN_LOG"
rc=$?
echo "[$(date -Is)] $NANOGPT_ENTRYPOINT exited with status $rc" | tee -a "$TRAIN_LOG"
exit "$rc"
