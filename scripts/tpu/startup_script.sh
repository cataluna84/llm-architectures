#!/bin/bash
# TPU VM startup script — pure-JAX nanoGPT (single host, v6e-8).
# Runs as root on the QR host at boot. Idempotent: safe to re-run after a
# spot-preemption reboot (GCP re-runs this script; it re-deploys + relaunches).
#
# Code arrives as a TARBALL from GCS (uploaded by launch_qr.sh /
# deploy_tarball.sh; includes the gitignored .env, so W&B works from the first
# boot) — no git clone. No multi-host rendezvous, no Secret Manager, no
# libpython/torch_xla shim — one Python process drives all 8 chips via JAX SPMD.

set -euo pipefail
exec > >(tee -a /tmp/startup.log) 2>&1
export HOME="${HOME:-/root}"
export USER="${USER:-$(id -un)}"

echo "=== [$(date -Is)] startup_script.sh begin on $(hostname) ==="

read_meta() {
    local key=$1 default=$2
    curl -fsS -H 'Metadata-Flavor: Google' \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" \
        2>/dev/null || echo "$default"
}

CODE_TARBALL_URI="$(read_meta code-tarball-uri gs://llm-architectures-eu/nanogptjax/code/latest.tar.gz)"
REPO_DIR="${REPO_DIR:-/opt/llm-architectures}"
DATA_SOURCE="$(read_meta data-source hf)"
DATA_SHARDS="$(read_meta data-shards 2)"
GCS_DATA_URI="$(read_meta gcs-data-uri '')"
TOTAL_TRAIN_STEPS="$(read_meta total-train-steps 50)"
PER_DEVICE_BATCH_SIZE="$(read_meta per-device-batch-size '')"
SAVE_CKPT_DIR="$(read_meta save-ckpt-dir '')"
# Self-healing/full-run identity (empty values are harmless: config env
# helpers and init_wandb treat empty as unset).
RESUME_FROM_STEP="$(read_meta resume-from-step auto)"
WANDB_RUN_NAME_META="$(read_meta wandb-run-name '')"
WANDB_RUN_ID_META="$(read_meta wandb-run-id '')"
VAL_MAX_BATCHES_META="$(read_meta val-max-batches '')"
DEVICE_PEAK_FLOPS_META="$(read_meta device-peak-flops '')"
TMUX_SESSION="${TMUX_SESSION:-train}"

echo "[startup] code=$CODE_TARBALL_URI  data-source=$DATA_SOURCE shards=$DATA_SHARDS"
echo "[startup] total-train-steps=$TOTAL_TRAIN_STEPS per-device-bsz=${PER_DEVICE_BATCH_SIZE:-<default>} save-ckpt-dir=${SAVE_CKPT_DIR:-<none>}"

# ----- 1. system deps -----
# Retry loop: at boot, unattended-upgrades often holds the dpkg lock and the
# Dpkg::Lock::Timeout option alone has been observed to lose the race (killed
# startup on 2/16 v5e-64 workers via set -e). Never let apt be the reason a
# worker misses the multi-host rendezvous.
APT_OPTS=(-o Dpkg::Lock::Timeout=600)
for _apt_try in $(seq 1 30); do
    if sudo DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" update -qq &&
       sudo DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -y -qq \
           tmux git curl ca-certificates build-essential; then
        break
    fi
    echo "[startup] apt busy/failed (attempt $_apt_try/30); retrying in 30s"
    sleep 30
    [ "$_apt_try" -eq 30 ] && { echo "[startup] FATAL: apt never succeeded"; exit 1; }
done

# ----- 2. uv (pip fallback if astral.sh is unreachable) -----
if ! command -v uv >/dev/null 2>&1; then
    if ! curl -fLsS https://astral.sh/uv/install.sh -o /tmp/uv-install.sh; then
        python3 -m pip install --user uv
    else
        sh /tmp/uv-install.sh
    fi
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
"$UV" --version

# ----- 3. fetch code tarball from GCS (working tree incl. .env) -----
echo "[startup] fetching code tarball $CODE_TARBALL_URI"
sudo mkdir -p "$REPO_DIR"
if ! gcloud storage cp "$CODE_TARBALL_URI" /tmp/llm-arch-code.tar.gz; then
    echo "[startup] ERROR: code tarball not found at $CODE_TARBALL_URI" >&2
    echo "[startup]        upload one via scripts/tpu/launch_qr.sh (automatic)" >&2
    echo "[startup]        or scripts/tpu/deploy_tarball.sh" >&2
    exit 1
fi
# Extract OVER the existing tree on reboots: .venv and nanogpt/fineweb10B are
# not in the tarball, so the synced env and staged data survive.
sudo tar xzf /tmp/llm-arch-code.tar.gz -C "$REPO_DIR"
sudo chown -R "$USER:$USER" "$REPO_DIR" 2>/dev/null || true
cd "$REPO_DIR"

# ----- 4. python + deps via uv (TPU extra: jax[tpu]==0.11.0 + libtpu) -----
"$UV" python install 3.12
"$UV" sync --extra jaxtpu

# ----- 5. stage FineWeb10B token shards -----
DATA_DIR="$REPO_DIR/nanogpt/fineweb10B"
mkdir -p "$DATA_DIR"
if [ ! -f "$DATA_DIR/.staged" ]; then
    if [ "$DATA_SOURCE" = "gcs" ] && [ -n "$GCS_DATA_URI" ]; then
        echo "[startup] staging data from $GCS_DATA_URI"
        gcloud storage rsync -r "$GCS_DATA_URI" "$DATA_DIR"
    else
        echo "[startup] downloading $DATA_SHARDS FineWeb10B train shards from HF (public)"
        "$UV" run python nanogpt/download_fineweb_tokens.py "$DATA_SHARDS"
    fi
    touch "$DATA_DIR/.staged"
else
    echo "[startup] data already staged (marker present)"
fi

# ----- 6. launch training in tmux -----
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
tmux new-session -d -s "$TMUX_SESSION" "
    set -uo pipefail
    ulimit -n 1048576
    cd '$REPO_DIR'
    export PATH='$PATH'
    export NANOGPT_TPU=1
    export NANOGPT_DATA_DIR='$DATA_DIR'
    export NANOGPT_TOTAL_TRAIN_STEPS='$TOTAL_TRAIN_STEPS'
    export NANOGPT_PER_DEVICE_BATCH_SIZE='${PER_DEVICE_BATCH_SIZE}'
    export NANOGPT_SAVE_CKPT_DIR='${SAVE_CKPT_DIR}'
    export NANOGPT_RESUME_FROM_STEP='${RESUME_FROM_STEP}'
    export WANDB_RUN_NAME='${WANDB_RUN_NAME_META}'
    export WANDB_RUN_ID='${WANDB_RUN_ID_META}'
    export NANOGPT_VAL_MAX_BATCHES='${VAL_MAX_BATCHES_META}'
    export NANOGPT_DEVICE_PEAK_FLOPS='${DEVICE_PEAK_FLOPS_META}'
    export PYTHONUNBUFFERED=1
    echo \"[\$(date -Is)] launching nanogpt/train.py on \$(python -c 'import jax;print(jax.devices())' 2>/dev/null)\" | tee -a /tmp/train.log
    '$UV' run python -u nanogpt/train.py 2>&1 | tee -a /tmp/train.log
    echo \"[\$(date -Is)] train.py exited with status \$?\" | tee -a /tmp/train.log
"
chmod 0644 /tmp/train.log 2>/dev/null || true

echo "=== [$(date -Is)] startup_script.sh complete on $(hostname) ==="
echo "Logs: tail -f /tmp/train.log   |   attach: sudo tmux attach -t $TMUX_SESSION"
