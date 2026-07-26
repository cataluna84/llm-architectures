# Shared bash helpers for the TPU launch scripts.
# Sourced (not executed) by setup_gcp.sh, launch_qr.sh, launch_spot.sh, ops.sh,
# deploy_tarball.sh.

# Load KEY=VALUE pairs from a dotenv-style file WITHOUT overwriting variables
# that are already set in the environment. Skips blank / comment lines.
# Strips optional single or double quotes around the value.
#
# Precedence: shell env  >  .env  >  script defaults.
load_env_file() {
    local file=$1
    [ -f "$file" ] || return 0
    local line key value
    while IFS='' read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"
            if [ -z "${!key:-}" ]; then
                export "$key=$value"
            fi
        fi
    done < "$file"
}

# Push a short event line to ntfy.sh (subscribe at https://ntfy.sh/$NTFY_TOPIC
# in any browser/phone). No-op when NTFY_TOPIC is unset; never fails the caller.
notify() {
    [ -n "${NTFY_TOPIC:-}" ] || return 0
    curl -fsS -m 10 -d "$*" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

# Tar the working tree (INCLUDING the gitignored .env — that is how WANDB_*
# credentials reach the VM; git clones can never ship it), excluding VCS,
# venvs, staged data, and caches. $1 = output tarball path, $2 = repo root.
make_code_tarball() {
    local out=$1 root=$2
    tar czf "$out" -C "$root" \
        --exclude='.git' \
        --exclude='.venv' \
        --exclude='wandb' \
        --exclude='_artifacts' \
        --exclude='nanogpt/fineweb10B' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.ruff_cache' \
        --exclude='profile-data' \
        .
}
