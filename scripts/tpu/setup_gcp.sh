#!/bin/bash
# One-time GCP bootstrap for llm-architectures TPU training (pure-JAX nanoGPT).
# Run from your local workstation (not from a TPU VM) after `gcloud auth login`.
#
# What this does:
#   1. Enables required APIs (tpu, storage, compute).
#   2. Creates the GCS experiment bucket (europe-west4, co-located with the TPUs).
#   3. Grants the TPU service identity + the VM's default Compute Engine SA
#      objectAdmin on the bucket (so the startup script can stage data and
#      write checkpoints).
#
# No Secret Manager / HF token / wandb: FineWeb10B is a PUBLIC HF dataset and
# this pure-JAX stack has no wandb. Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"
load_env_file "$ENV_FILE"

PROJECT_ID="${PROJECT_ID:-ml-pipelines-315702}"
REGION="${REGION:-europe-west4}"   # bucket location — MUST match the TPUs' region (co-located = no egress)
BUCKET="${BUCKET:-llm-architectures-eu}"

echo "==> using project: $PROJECT_ID  region: $REGION  bucket: gs://$BUCKET"
gcloud config set project "$PROJECT_ID" >/dev/null

# ---- 1. APIs ----
echo "==> enabling APIs"
gcloud services enable \
    tpu.googleapis.com \
    storage.googleapis.com \
    compute.googleapis.com

# ---- 2. bucket ----
echo "==> creating bucket gs://$BUCKET (no-op if exists)"
if ! gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://$BUCKET" \
        --location="$REGION" \
        --uniform-bucket-level-access
else
    echo "    bucket already exists"
fi

# ---- 3. IAM ----
# On a fresh project the TPU service agent is not auto-created just by enabling
# the API; ask for it explicitly (idempotent).
echo "==> ensuring TPU service identity exists (best-effort)"
# `services identity create` lives under `gcloud beta`; on a fresh SDK that
# component may be absent. It only needs to run once per project to materialize
# the agent, so tolerate failure (already-exists / beta-unavailable) and proceed.
gcloud beta services identity create --service=tpu.googleapis.com \
    --project="$PROJECT_ID" --quiet >/dev/null 2>&1 \
    || echo "    (skipped — TPU service agent already exists or beta unavailable)"

PROJECT_NUM="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
TPU_SA="service-${PROJECT_NUM}@cloud-tpu.iam.gserviceaccount.com"
# The TPU VM runs as the project's default Compute Engine service account; that
# is the identity the startup script uses for `gcloud storage ...` calls.
VM_SA="${PROJECT_NUM}-compute@developer.gserviceaccount.com"

for sa in "$TPU_SA" "$VM_SA"; do
    echo "==> granting objectAdmin on gs://$BUCKET to $sa"
    gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
        --member="serviceAccount:$sa" \
        --role="roles/storage.objectAdmin" >/dev/null
done

echo "==> done. Next: TRC_PROFILE=v6e-8-eu bash scripts/tpu/launch_spot.sh"
