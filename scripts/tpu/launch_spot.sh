#!/usr/bin/env bash
# Submit a SPOT (preemptible) Queued Resource against the TRC grant.
#
# TRC v6e is SPOT-only, so this is the normal entrypoint. TRC_PROFILE picks the
# slice; all other knobs (TOTAL_TRAIN_STEPS, DATA_SHARDS, QR_NAME, ...) are
# forwarded to launch_qr.sh unchanged. SPOT is pinned to 1.
#
# Usage:
#   TRC_PROFILE=v6e-8-eu  bash scripts/tpu/launch_spot.sh   # smoke / eval (default)
#   TRC_PROFILE=v6e-8-us  bash scripts/tpu/launch_spot.sh   # US fallback when EU spot churns
#   TRC_PROFILE=v6e-16-eu bash scripts/tpu/launch_spot.sh   # future scale-up
#
# Zones/quota: europe-west4-a, us-east1-d (TRC v6e; override the us zone with
# ZONE=us-east5-b etc. if quota rejects). See docs/tpu-runbook.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TRC_PROFILE="${TRC_PROFILE:-v6e-8-eu}"

case "$TRC_PROFILE" in
    v6e-8-eu)
        ACCEL_TYPE="${ACCEL_TYPE:-v6e-8}"
        ZONE="${ZONE:-europe-west4-a}"
        RUNTIME="${RUNTIME:-v2-alpha-tpuv6e}"
        DEFAULT_QR="nanogpt-v6e8-baseline-qr"
        DEFAULT_NODE="nanogpt-v6e8-baseline"
        ;;
    v6e-8-us)
        ACCEL_TYPE="${ACCEL_TYPE:-v6e-8}"
        ZONE="${ZONE:-us-east1-d}"
        RUNTIME="${RUNTIME:-v2-alpha-tpuv6e}"
        DEFAULT_QR="nanogpt-v6e8-baseline-qr"
        DEFAULT_NODE="nanogpt-v6e8-baseline"
        ;;
    v6e-16-eu)
        ACCEL_TYPE="${ACCEL_TYPE:-v6e-16}"
        ZONE="${ZONE:-europe-west4-a}"
        RUNTIME="${RUNTIME:-v2-alpha-tpuv6e}"
        DEFAULT_QR="nanogpt-v6e16-qr"
        DEFAULT_NODE="nanogpt-v6e16"
        ;;
    v5e-64-ew4b)
        # MULTI-HOST: 8 hosts x 8 chips. train.py must be multi-host-ready
        # (jax.distributed + per-host data feeding) before this can train.
        ACCEL_TYPE="${ACCEL_TYPE:-v5litepod-64}"
        ZONE="${ZONE:-europe-west4-b}"
        RUNTIME="${RUNTIME:-v2-alpha-tpuv5-lite}"
        DEFAULT_QR="nanogpt-v5e64-qr"
        DEFAULT_NODE="nanogpt-v5e64"
        ;;
    v5e-64-uc1a)
        # Same v5litepod-64 chip family as v5e-64-ew4b, in the US zone
        # us-central1-a (the second v5e-64 TRC grant row). Drought-escape
        # fallback when europe-west4-b has no capacity. Reuses the QR/node
        # names (zone-scoped, so no conflict) to keep docs/scripts consistent.
        ACCEL_TYPE="${ACCEL_TYPE:-v5litepod-64}"
        ZONE="${ZONE:-us-central1-a}"
        RUNTIME="${RUNTIME:-v2-alpha-tpuv5-lite}"
        DEFAULT_QR="nanogpt-v5e64-qr"
        DEFAULT_NODE="nanogpt-v5e64"
        ;;
    v5e-32-ew4b)
        # Half-size v5e slice (v5litepod-32 = 8 hosts x 4 chips = 32 chips) from
        # the same 64-chip europe-west4-b grant. Easier to land during a v5e-64
        # drought. Runs the baseline with auto-derived accum=2 (same 524288
        # tok/step); commit needs EXPECT_WORKERS=8 + NANOGPT_VAL_MAX_BATCHES=50.
        ACCEL_TYPE="${ACCEL_TYPE:-v5litepod-32}"
        ZONE="${ZONE:-europe-west4-b}"
        RUNTIME="${RUNTIME:-v2-alpha-tpuv5-lite}"
        DEFAULT_QR="nanogpt-v5e32-qr"
        DEFAULT_NODE="nanogpt-v5e32"
        ;;
    v5e-32-uc1a)
        # Half-size v5e slice in us-central1-a (second v5e grant row). See
        # v5e-32-ew4b for the accum/worker/val notes.
        ACCEL_TYPE="${ACCEL_TYPE:-v5litepod-32}"
        ZONE="${ZONE:-us-central1-a}"
        RUNTIME="${RUNTIME:-v2-alpha-tpuv5-lite}"
        DEFAULT_QR="nanogpt-v5e32-qr"
        DEFAULT_NODE="nanogpt-v5e32"
        ;;
    v6e-64-ew4a)
        # Newest-gen 64-chip v6e (Trillium) = 8 hosts x 8 chips, europe-west4-a.
        # Needs the v6e runtime. CLOSEST match to the intended v5e-64 baseline:
        # per-device 4 x 64 chips = 524288 tok/step at accum=1, VAL_MAX_BATCHES=25;
        # only EXPECT_WORKERS=8 (8 hosts) and DEVICE_PEAK_FLOPS differ.
        ACCEL_TYPE="${ACCEL_TYPE:-v6e-64}"
        ZONE="${ZONE:-europe-west4-a}"
        RUNTIME="${RUNTIME:-v2-alpha-tpuv6e}"
        DEFAULT_QR="nanogpt-v6e64-qr"
        DEFAULT_NODE="nanogpt-v6e64"
        ;;
    v6e-64-ue1d)
        # Same v6e-64 as v6e-64-ew4a, US zone us-east1-d.
        ACCEL_TYPE="${ACCEL_TYPE:-v6e-64}"
        ZONE="${ZONE:-us-east1-d}"
        RUNTIME="${RUNTIME:-v2-alpha-tpuv6e}"
        DEFAULT_QR="nanogpt-v6e64-qr"
        DEFAULT_NODE="nanogpt-v6e64"
        ;;
    *)
        echo "ERROR: unknown TRC_PROFILE '$TRC_PROFILE' (valid: v6e-8-eu, v6e-8-us, v6e-16-eu, v5e-64-ew4b, v5e-64-uc1a, v5e-32-ew4b, v5e-32-uc1a, v6e-64-ew4a, v6e-64-ue1d)" >&2
        exit 2
        ;;
esac

QR_NAME="${QR_NAME:-$DEFAULT_QR}"
NODE_ID="${NODE_ID:-$DEFAULT_NODE}"

echo "==> launch_spot: TRC_PROFILE=$TRC_PROFILE"
echo "    ACCEL_TYPE=$ACCEL_TYPE  ZONE=$ZONE  RUNTIME=$RUNTIME"
echo "    QR_NAME=$QR_NAME  NODE_ID=$NODE_ID"
echo "    forwarding to launch_qr.sh with SPOT=1"
echo

exec env \
    SPOT=1 \
    ACCEL_TYPE="$ACCEL_TYPE" \
    ZONE="$ZONE" \
    RUNTIME="$RUNTIME" \
    QR_NAME="$QR_NAME" \
    NODE_ID="$NODE_ID" \
    bash "$SCRIPT_DIR/launch_qr.sh" "$@"
