#!/usr/bin/env bash
# Submit a SPOT (preemptible) Queued Resource against the TRC grant.
#
# TRC v6e is SPOT-only, so this is the normal entrypoint. TRC_PROFILE picks the
# slice; all other knobs (TOTAL_TRAIN_STEPS, DATA_SHARDS, QR_NAME, ...) are
# forwarded to launch_qr.sh unchanged. SPOT is pinned to 1.
#
# Usage:
#   TRC_PROFILE=v6e-8-eu  bash scripts/tpu/launch_spot.sh   # smoke / eval (default)
#   TRC_PROFILE=v6e-16-eu bash scripts/tpu/launch_spot.sh   # future scale-up
#
# Zones/quota: europe-west4-a (TRC v6e). See docs/tpu-runbook.md.

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
    v6e-16-eu)
        ACCEL_TYPE="${ACCEL_TYPE:-v6e-16}"
        ZONE="${ZONE:-europe-west4-a}"
        RUNTIME="${RUNTIME:-v2-alpha-tpuv6e}"
        DEFAULT_QR="nanogpt-v6e16-qr"
        DEFAULT_NODE="nanogpt-v6e16"
        ;;
    *)
        echo "ERROR: unknown TRC_PROFILE '$TRC_PROFILE' (valid: v6e-8-eu, v6e-16-eu)" >&2
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
