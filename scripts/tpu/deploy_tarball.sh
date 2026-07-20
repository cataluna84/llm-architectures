#!/bin/bash
# Deploy the LOCAL WORKING TREE to the TPU VM via a tarball staged in GCS,
# then (re)launch training in tmux on the VM.
#
# Flow:
#   1. tar czf the working tree   (INCLUDES gitignored .env — this is how
#      WANDB_API_KEY etc. reach the VM; git-clone deploys can't ship it)
#   2. gcloud storage cp -> gs://$BUCKET/$CODE_PREFIX/
#   3. VM pulls the tarball from GCS
#   4. VM extracts over $REPO_DIR (preserves .venv + staged fineweb10B data)
#   5. VM: uv sync --extra jaxtpu, stage missing FineWeb shards, relaunch
#      nanogpt/train.py inside tmux session "$TMUX_SESSION"
#
# The remote deploy script and the tmux launcher are both generated locally
# and scp'd to the VM, so there is exactly one level of shell quoting.
#
# Usage:
#   # 120-step probe at per-device batch 8:
#   TOTAL_TRAIN_STEPS=120 PER_DEVICE_BATCH_SIZE=8 bash scripts/tpu/deploy_tarball.sh
#   # full baseline:
#   TOTAL_TRAIN_STEPS=10000 PER_DEVICE_BATCH_SIZE=4 DATA_SHARDS=60 \
#   SAVE_CKPT_DIR=gs://llm-architectures-eu/nanogptjax/checkpoints/v6e8-baseline-10k \
#   WANDB_RUN_NAME=v6e8-baseline-10k WANDB_RUN_ID=v6e8-baseline-10k-r1 \
#   bash scripts/tpu/deploy_tarball.sh
#   # preemption resume: add NANOGPT_RESUME_FROM_STEP=<last saved step>
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
NODE_ID="${NODE_ID:-nanogpt-v6e8-baseline}"
BUCKET="${BUCKET:-llm-architectures-eu}"
CODE_PREFIX="${CODE_PREFIX:-nanogptjax/code}"
REPO_DIR="${REPO_DIR:-/opt/llm-architectures}"
TMUX_SESSION="${TMUX_SESSION:-train}"

# Which stage to run. Any script in the repo works: nanogpt/train.py (pretrain),
# nanogpt/train_sft.py (SFT), etc. The launcher's log markers carry this value
# so orchestrators stay stage-agnostic — see the "exited with status" marker
# below, which sweep_runner.sh matches without knowing the stage.
NANOGPT_ENTRYPOINT="${NANOGPT_ENTRYPOINT:-nanogpt/train.py}"

# ---- training knobs (exported into the tmux launcher on the VM) ----
TOTAL_TRAIN_STEPS="${TOTAL_TRAIN_STEPS:-50}"
PER_DEVICE_BATCH_SIZE="${PER_DEVICE_BATCH_SIZE:-4}"
DATA_SHARDS="${DATA_SHARDS:-2}"
SAVE_CKPT_DIR="${SAVE_CKPT_DIR:-}"
NANOGPT_VAL_MAX_BATCHES="${NANOGPT_VAL_MAX_BATCHES:-200}"
NANOGPT_RESUME_FROM_STEP="${NANOGPT_RESUME_FROM_STEP:-0}"
# LR-sweep knobs: empty = code defaults (peak 0.02, momentum warmup 300).
NANOGPT_OTHER_PEAK_LR="${NANOGPT_OTHER_PEAK_LR:-}"
NANOGPT_MUON_MOMENTUM_WARMUP_STEPS="${NANOGPT_MUON_MOMENTUM_WARMUP_STEPS:-}"
# Per-chip peak bf16 FLOPs for the MFU metric; empty = code default (v6e,
# 918e12). Set 197e12 when deploying to v5e.
NANOGPT_DEVICE_PEAK_FLOPS="${NANOGPT_DEVICE_PEAK_FLOPS:-}"
WANDB_RUN_NAME="${WANDB_RUN_NAME:-}"
WANDB_RUN_ID="${WANDB_RUN_ID:-}"

STAMP="$(date +%Y%m%d-%H%M%S)"
# Unique tag baked into the launcher's "launching train.py" log line so
# orchestrators (sweep_runner.sh) can find THIS deploy's log segment
# unambiguously — never a stale segment from an earlier run.
RUN_TAG="${RUN_TAG:-deploy-$STAMP}"
WORK="$(mktemp -d)"
TARBALL="$WORK/llm-arch-code-$STAMP.tar.gz"
GCS_URI="gs://$BUCKET/$CODE_PREFIX/llm-arch-code-$STAMP.tar.gz"

echo "==> [1/5] tarring working tree (incl. .env; excl. .git/.venv/data/wandb)"
make_code_tarball "$TARBALL" "$REPO_ROOT"
ls -lh "$TARBALL"

echo "==> [2/5] uploading tarball to $GCS_URI (+ latest.tar.gz alias)"
gcloud storage cp "$TARBALL" "$GCS_URI" --project="$PROJECT_ID" >/dev/null
# Stable alias: startup_script.sh boots from this when no pinned URI is set,
# so preemption reboots pick up the most recently deployed code.
gcloud storage cp "$GCS_URI" "gs://$BUCKET/$CODE_PREFIX/latest.tar.gz" \
    --project="$PROJECT_ID" >/dev/null

echo "==> [3/5] generating remote scripts"
LAUNCHER="$WORK/nanogpt_train_launch.sh"
REMOTE="$WORK/nanogpt_remote_deploy.sh"

# Export WANDB_* only when set: the wandb library reads these raw from the
# environment, and an exported empty string breaks wandb.init ("Run ID cannot
# be empty") where our config's empty-means-unset convention would not.
WANDB_ENV_LINES=""
[ -n "$WANDB_RUN_NAME" ] && WANDB_ENV_LINES+="export WANDB_RUN_NAME=\"$WANDB_RUN_NAME\""$'\n'
[ -n "$WANDB_RUN_ID" ] && WANDB_ENV_LINES+="export WANDB_RUN_ID=\"$WANDB_RUN_ID\""$'\n'
[ -n "$NANOGPT_DEVICE_PEAK_FLOPS" ] && WANDB_ENV_LINES+="export NANOGPT_DEVICE_PEAK_FLOPS=\"$NANOGPT_DEVICE_PEAK_FLOPS\""$'\n'

# Runs INSIDE tmux on the VM. Local values are baked in at generation time;
# escaped \$ are evaluated on the VM at runtime.
cat > "$LAUNCHER" <<EOF
#!/bin/bash
set -uo pipefail
ulimit -n 1048576
cd "$REPO_DIR"
export PATH="/root/.local/bin:/usr/local/bin:\$PATH"
export NANOGPT_TPU=1
export NANOGPT_DATA_DIR="$REPO_DIR/nanogpt/fineweb10B"
export NANOGPT_TOTAL_TRAIN_STEPS="$TOTAL_TRAIN_STEPS"
export NANOGPT_PER_DEVICE_BATCH_SIZE="$PER_DEVICE_BATCH_SIZE"
export NANOGPT_SAVE_CKPT_DIR="$SAVE_CKPT_DIR"
export NANOGPT_VAL_MAX_BATCHES="$NANOGPT_VAL_MAX_BATCHES"
export NANOGPT_RESUME_FROM_STEP="$NANOGPT_RESUME_FROM_STEP"
export NANOGPT_OTHER_PEAK_LR="$NANOGPT_OTHER_PEAK_LR"
export NANOGPT_MUON_MOMENTUM_WARMUP_STEPS="$NANOGPT_MUON_MOMENTUM_WARMUP_STEPS"
${WANDB_ENV_LINES}export PYTHONUNBUFFERED=1
UV="\$(command -v uv || echo /root/.local/bin/uv)"
echo "[\$(date -Is)] launching $NANOGPT_ENTRYPOINT tag=$RUN_TAG steps=$TOTAL_TRAIN_STEPS bsz=$PER_DEVICE_BATCH_SIZE resume=$NANOGPT_RESUME_FROM_STEP peak_lr=${NANOGPT_OTHER_PEAK_LR:-default} mom_warmup=${NANOGPT_MUON_MOMENTUM_WARMUP_STEPS:-default}" | tee -a /tmp/train.log
"\$UV" run python -u "$NANOGPT_ENTRYPOINT" 2>&1 | tee -a /tmp/train.log
echo "[\$(date -Is)] $NANOGPT_ENTRYPOINT exited with status \$?" | tee -a /tmp/train.log
EOF

# Runs once via `sudo bash` on the VM: pull, extract, sync, stage data, tmux.
cat > "$REMOTE" <<EOF
#!/bin/bash
set -euo pipefail
export HOME=/root
export PATH="/root/.local/bin:/usr/local/bin:\$PATH"
echo "=== [\$(date -Is)] remote deploy $STAMP begin ==="

mkdir -p "$REPO_DIR"
gcloud storage cp "$GCS_URI" /tmp/llm-arch-code.tar.gz
# Extract OVER the existing tree: .venv and nanogpt/fineweb10B are not in the
# tarball, so the synced env and staged data survive redeploys.
tar xzf /tmp/llm-arch-code.tar.gz -C "$REPO_DIR"
cd "$REPO_DIR"

UV="\$(command -v uv || echo /root/.local/bin/uv)"
"\$UV" sync --extra jaxtpu

DATA_DIR="$REPO_DIR/nanogpt/fineweb10B"
mkdir -p "\$DATA_DIR"
have=\$(ls "\$DATA_DIR"/fineweb_train_*.bin 2>/dev/null | wc -l)
if [ "\$have" -lt "$DATA_SHARDS" ]; then
    echo "[deploy] FineWeb: have \$have train shards, staging up to $DATA_SHARDS"
    "\$UV" run python nanogpt/download_fineweb_tokens.py "$DATA_SHARDS"
else
    echo "[deploy] FineWeb: \$have train shards already staged (need $DATA_SHARDS)"
fi

cp /tmp/nanogpt_train_launch.sh /tmp/nanogpt_train_launch.active.sh
chmod +x /tmp/nanogpt_train_launch.active.sh
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
tmux new-session -d -s "$TMUX_SESSION" "bash /tmp/nanogpt_train_launch.active.sh"
chmod 0644 /tmp/train.log 2>/dev/null || true
echo "=== [\$(date -Is)] remote deploy complete; training launched in tmux '$TMUX_SESSION' ==="
EOF

# --worker=all: single-host slices have one worker; multi-host slices
# (v5e-64 = 8 workers) need the code + launcher on every host, and every
# host must relaunch train.py for the jax.distributed rendezvous.
echo "==> [4/5] scp remote scripts to $NODE_ID (all workers)"
gcloud compute tpus tpu-vm scp "$LAUNCHER" "$REMOTE" "$NODE_ID":/tmp/ \
    --project="$PROJECT_ID" --zone="$ZONE" --worker=all --quiet

echo "==> [5/5] executing remote deploy on all workers (sudo)"
gcloud compute tpus tpu-vm ssh "$NODE_ID" \
    --project="$PROJECT_ID" --zone="$ZONE" --worker=all --quiet \
    --command="sudo bash /tmp/nanogpt_remote_deploy.sh"

echo
echo "==> deployed. follow with:  bash scripts/tpu/ops.sh tail-logs"
[ -n "$WANDB_RUN_NAME" ] && echo "    wandb run: $WANDB_RUN_NAME (project ${WANDB_PROJECT:-llm-architectures})"
rm -rf "$WORK"
