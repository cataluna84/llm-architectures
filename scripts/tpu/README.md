# TPU launch scripts (pure-JAX nanoGPT)

Operator-side scripts for training on Google Cloud TPU (TRC) via the Queued Resource API.
Current path: **v6e-8 spot in `europe-west4-a`** for the baseline smoke/eval. See
[`../../docs/tpu-runbook.md`](../../docs/tpu-runbook.md) for the launch flow and gotchas.

## Files

| File | Where it runs | Purpose |
|---|---|---|
| `setup_gcp.sh` | workstation, once | enable APIs, create the GCS bucket, grant bucket IAM to the TPU + VM service accounts |
| `launch_qr.sh` | workstation | submit a Queued Resource (accel/zone/metadata) that boots `startup_script.sh` |
| `launch_spot.sh` | workstation | `TRC_PROFILE` wrapper around `launch_qr.sh` with `SPOT=1` (`v6e-8-eu`, `v6e-16-eu`) |
| `startup_script.sh` | TPU host at boot | install uv, clone the repo branch, `uv sync --extra jaxtpu`, stage FineWeb, run `nanogpt/train.py` in tmux |
| `ops.sh` | workstation | `status`, `tail-logs`, `attach`, `ssh`, `pull-ckpt`, `delete` |
| `_lib.sh` | sourced | dotenv loader (`shell env > .env > defaults`) |

## Configuration

Scripts auto-source `<repo-root>/.env` (gitignored; see `.env.example`). Override per-invocation
with `VAR=value bash ...`.

| Var | Default | Used by |
|---|---|---|
| `PROJECT_ID` | `ml-pipelines-315702` | all |
| `REGION` | `europe-west4` | `setup_gcp.sh` (bucket location) |
| `ZONE` | `europe-west4-a` | `launch_*`, `ops.sh` |
| `BUCKET` | `llm-architectures-eu` | `setup_gcp.sh`, `ops.sh pull-ckpt` |
| `TRC_PROFILE` | `v6e-8-eu` | `launch_spot.sh` |
| `REPO_URL` / `REPO_BRANCH` | `cataluna84/llm-architectures` / `feat/nanoGPTJAX` | startup (clone) |
| `DATA_SOURCE` / `DATA_SHARDS` | `hf` / `2` | startup (FineWeb staging) |
| `TOTAL_TRAIN_STEPS` | `50` (smoke) | startup → `NANOGPT_TOTAL_TRAIN_STEPS` |
| `PER_DEVICE_BATCH_SIZE` | config default (32) | startup → `NANOGPT_PER_DEVICE_BATCH_SIZE` (OOM fallback) |
| `SAVE_CKPT_DIR` | unset (no save) | startup → `NANOGPT_SAVE_CKPT_DIR` (may be `gs://...`) |

## Typical flow

```bash
bash scripts/tpu/setup_gcp.sh                          # once: bucket + IAM
TRC_PROFILE=v6e-8-eu bash scripts/tpu/launch_spot.sh   # smoke (50 steps)
bash scripts/tpu/ops.sh status                         # watch QR -> ACTIVE
bash scripts/tpu/ops.sh tail-logs                      # follow /tmp/train.log
bash scripts/tpu/ops.sh delete                         # tear down (stops billing)
```

## What this does NOT do

- Multi-host (single-slice v6e-8/16 only) · no wandb · no Secret Manager (FineWeb is public).
- No auto-resume wired for the full run yet — checkpoints exist via Orbax but resume-on-preempt
  is a follow-up before long-horizon training.
