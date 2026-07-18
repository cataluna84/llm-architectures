# TPU Runbook — nanoGPT (pure JAX) on Cloud TPU v6e

Operational guide for training the baseline nanoGPT on Google Cloud TPU via the Queued
Resource API. Single-host, pure-JAX (no torch_xla / wandb / multi-host rendezvous). Companion:
[`../scripts/tpu/README.md`](../scripts/tpu/README.md) (script/env reference).

## Hardware & zones (TRC)

| Slice | Topology | Use | Zone | Runtime |
|---|---|---|---|---|
| **v6e-8** | 1 host × 8 chips | baseline smoke / eval | `europe-west4-a` | `v2-alpha-tpuv6e` |
| **v6e-16** | 4 hosts × 4 chips | future scale-up | `europe-west4-a` | `v2-alpha-tpuv6e` |

- TRC v6e is **spot-only**; free zones are `europe-west4-a` and `us-east1-d`. 32 GiB HBM/chip.
- Keep the GCS bucket **`gs://llm-architectures-eu` (europe-west4)** co-located with the TPUs —
  a cross-region bucket makes every checkpoint write pay egress.
- **This project shares the TRC quota with other slices in the project.** A v6e-8 (8 chips)
  fits alongside a running v6e-16 (16 chips) at 24/64 chips in the zone. Preempted/SUSPENDED QR
  husks still book quota — delete dead QRs (`ops.sh delete`) with intent.

## Provisioning + launch

One-time GCP bootstrap, then a single spot launch:

```bash
bash scripts/tpu/setup_gcp.sh                          # APIs + gs://llm-architectures-eu + IAM
TRC_PROFILE=v6e-8-eu bash scripts/tpu/launch_spot.sh   # smoke: 50 steps, 2 FineWeb shards
```

`launch_spot.sh` → `launch_qr.sh` creates the QR with `startup_script.sh` as metadata. On boot
the host: installs uv → clones `cataluna84/llm-architectures @ feat/nanoGPTJAX` → `uv sync
--extra jaxtpu` (JAX 0.11.0 + libtpu) → stages FineWeb10B shards → runs `nanogpt/train.py` in a
`tmux` session teed to `/tmp/train.log`. Knobs (steps, batch, data source, checkpoint dir) are
passed as VM metadata and consumed by `nanogpt/config.py`'s `NANOGPT_*` env overrides.

## Observe / control

```bash
bash scripts/tpu/ops.sh status       # QR + node state
bash scripts/tpu/ops.sh tail-logs    # follow /tmp/train.log
bash scripts/tpu/ops.sh attach       # sudo tmux attach -t train (root-owned session)
bash scripts/tpu/ops.sh delete       # tear down the QR (stops billing)
```

## Full baseline vs smoke

The smoke defaults to `TOTAL_TRAIN_STEPS=50` and 2 shards. For the README baseline
(10k steps) raise the knobs and point checkpoints at GCS:

```bash
TOTAL_TRAIN_STEPS=10000 DATA_SHARDS=30 \
SAVE_CKPT_DIR=gs://llm-architectures-eu/nanogptjax/checkpoints/pretrain \
TRC_PROFILE=v6e-8-eu bash scripts/tpu/launch_spot.sh
```

## Gotchas

- **JAX 0.11.0 / libtpu on v6e**: installed via the `jaxtpu` extra (`jax[tpu]==0.11.0`). If a
  build lacks a matching v6e libtpu, relax to the nearest v6e-supporting 0.11.x.
- **GPU flags**: `nanogpt/train.py` sets `--xla_gpu_*`/NCCL env at import; the startup script
  exports `NANOGPT_TPU=1`, which skips that block on TPU.
- **Flat imports**: `train.py` uses `from model import ...`; run it as `python nanogpt/train.py`
  (the script's dir goes on `sys.path`). `NANOGPT_DATA_DIR` is set to an absolute path so CWD
  doesn't matter for data globbing.
- **Spot preemption**: a preempt reboots the host; `startup_script.sh` re-runs idempotently and
  relaunches (the `.staged` marker avoids re-downloading data). No auto-resume of training state
  yet — checkpoints exist via Orbax but resume-on-preempt is a follow-up before long runs.
- **HBM / OOM**: if `train.py` OOMs, lower `PER_DEVICE_BATCH_SIZE` (default 32).
- **TRC is a free grant** — never stop/delete/reprovision a slice without explicit intent.

## TRC allocation facts (reference)

Project `ml-pipelines-315702`. v6e spot in `europe-west4-a` / `us-east1-d` (64 chips/zone).
v4/v5e rows in the grant are legacy. Bucket `gs://llm-architectures-eu` (europe-west4).
