#!/bin/bash
# GCE startup script for the nanogpt-driver e2-micro (us-central1-a).
#
# Runs on EVERY boot (so a VM reboot re-launches everything — reboot-durable):
#   1. deploy the latest code + .env from GCS (tarball ships gitignored .env)
#   2. (re)start the v5e-64 provisioning race + committer in tmux, idempotently
#
# The driver exists because the workstation is not a reliable 24/7 host (it
# reboots, wiping tmux + /tmp). The VM's default compute SA (cloud-platform
# scope) does the QR create/delete + GCS ops. race_commit's launch_vm_program
# SSH into the TPU may or may not work from here; if it fails it ntfy's
# "needs a hand" and the commit is finished by hand.
set -uo pipefail
exec >>/var/log/nanogpt-driver-startup.log 2>&1
echo "===== [driver-startup $(date -Is)] boot ====="

REPO_DIR=/opt/llm-architectures
BUCKET=llm-architectures-eu
CODE="gs://$BUCKET/nanogptjax/code/latest.tar.gz"

command -v gcloud >/dev/null || { echo "FATAL: gcloud missing on image"; exit 1; }
command -v tmux   >/dev/null || { apt-get update -y && apt-get install -y tmux; }

mkdir -p "$REPO_DIR"
gcloud storage cp "$CODE" /tmp/code.tar.gz
tar -xzf /tmp/code.tar.gz -C "$REPO_DIR"
echo "[driver-startup $(date -Is)] code deployed to $REPO_DIR"

cd "$REPO_DIR"
# v5e-32 @ eu is single-zone + ARMED, so only the provisioning cycle is needed
# (each landing auto-runs baseline-10k via startup_script). No committer.
tmux kill-session -t race-prov   2>/dev/null || true
tmux kill-session -t race-commit 2>/dev/null || true
tmux new-session -d -s race-prov "TICK=1800 bash scripts/tpu/race_provision.sh 2>&1 | tee -a /var/log/race_provision.log"
sleep 2
echo "[driver-startup $(date -Is)] tmux sessions:"; tmux ls
echo "===== [driver-startup $(date -Is)] done ====="
