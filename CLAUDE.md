# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

nanoGPT/nanochat rebuilt in **pure JAX** — no Flax/Equinox/Keras. Every layer, the training loop, sharding, KV-cache inference, and int8 quantization are written from scratch on top of a deliberately minimal two-class abstraction. Read `docs/design.md` (the abstraction philosophy) and `docs/training.md` (optimizer/throughput/KV-cache findings) before making non-trivial changes.

## Commands

```bash
# Environment (uv, Python 3.12)
uv sync                # CPU/TPU
uv sync --all-extras   # GPU (adds jax-cuda12 plugin)

# Lint / format (line length 88, double quotes)
ruff check nanogpt/*.py
ruff format nanogpt/*.py
# pre-commit runs the same hooks on ^nanogpt/, excluding nanogpt/dev/

# Data → pretrain → SFT → inference
python nanogpt/download_fineweb_tokens.py [num_chunks]  # → nanogpt/fineweb10B/, 103 chunks default
python nanogpt/train.py
python nanogpt/sft_dataloader.py    # tokenize + pack SFT data to parquet
python nanogpt/train_sft.py
python nanogpt/inference.py
```

There is no test suite and no CLI arg parsing: **all configuration lives in `nanogpt/config.py`** (`data_dir`, hparams, model size, checkpoint paths). Set `CheckpointConfig.load_params_ckpt_path` (absolute path to a checkpoint's `params/` subdir) before running inference or SFT.

**Experiment tracking:** `train.py`/`train_sft.py` log to Weights & Biases via `nanogpt/wandb_logger.py` (the only module importing `wandb`). Credentials are read from a gitignored `.env` at the repo root (`WANDB_API_KEY`, `WANDB_PROJECT`, `WANDB_ENTITY`) by a dependency-free `load_dotenv()` (no `python-dotenv`), called before `Config()` is built so `WandbConfig` picks the values up. `init_wandb(...)` returns a no-op run when disabled/keyless/non-primary-host, so call sites are unconditional. Toggle with `WANDB_ENABLED=0`, `WANDB_MODE=offline|disabled`; see `WandbConfig` in `config.py` for all env knobs.

Imports are flat (`from utils import ...`, `from model import ...`) — there is no installed package and no `__init__.py`. Scripts work because Python puts the script's own directory on `sys.path`, so run them as `python nanogpt/<script>.py` and keep new modules' imports flat.

`nanogpt/dev/` is experimental scratch space, excluded from lint hooks.

## Model internals

Layer abstraction, sharding rules, and the per-module pipeline tour live in
`nanogpt/CLAUDE.md`, loaded automatically when working under `nanogpt/`. Design
philosophy: `docs/design.md`. Optimizer/throughput/KV-cache findings:
`docs/training.md`.

## Gotchas

- `train.py` sets NCCL/XLA env flags at the very top **before** `import jax` — this ordering is load-bearing (and why ruff E402 is ignored under `nanogpt/`).
- Everything defaults to bfloat16; attention backend is `cudnn` on GPU, `xla` on TPU (chosen at import in `model.py`).
- The README has a couple of stale names: the SFT prep script is `nanogpt/sft_dataloader.py` (not `sft_downloader.py`) and the config lives at `nanogpt/config.py` (not `nanochat/config.py`).

## Contributing conventions (from README)

Open an issue before significant changes; branch as `feat/<name>` or `fix/<name>` off `main`; include a minimal repro/validation script with functional changes.

## Memory system + orchestration (imported from tinyaya-stage2-scale)

Before any non-trivial task read, in order: `.claude/PLAN.md` → `.claude/PROGRESS.md`
(top) → `.claude/VERIFY.md` → `.claude/memories.md`. Lifecycle hooks in
`.claude/settings.json` inject these at SessionStart, log edits to PROGRESS.md,
run VERIFY.md checks on Stop, and snapshot state before compaction. Quick capture
from the prompt: `#progress …`, `#decision …`, `#plan …`; slash commands:
`/recall /progress /remember /plan /verify /curate`.

**Where to log:** decisions & gotchas → `memories.md` (`/remember`); work done →
`PROGRESS.md` (automatic via hook, or `/progress`); goal changes → `PLAN.md`
(`/plan`); done-criteria → `VERIFY.md`.

**Long runs live in tmux, never in an agent session.** Workstation: `qrwatch`
(`scripts/tpu/qr_watch.sh` — QR babysitter, log `/tmp/qr_watch.log`) and `sweep`
(`scripts/tpu/sweep_runner.sh` — ordered runs-file executor, log
`/tmp/sweep_runner.log`). TPU VMs: session `train` (`ops.sh attach|tail-logs`).
Push events: `https://ntfy.sh/$NTFY_TOPIC` (topic in `.env`). Live metrics:
https://wandb.ai/cataluna84/llm-architectures.

**Run-control design lives in `.claude/orchestration/`** (repo-level, not
nanoGPT-specific): `CONTROL_PLANE.md` for which surface owns which fact,
`SPEC.md` for the run loop and recovery ladder, `playbook/` for tier policy,
baselines, metric schema, and the ntfy event taxonomy, `diagrams/*.mmd` for the
layering. Load the `tpu-orchestrate` skill when operating a run; the canonical
failure-signature table is `.claude/agents/tpu-diagnoser.md`.

Two invariants govern every training run: **tokens/step = 524,288** and
**val subset = 6,400 rows** (`NANOGPT_VAL_MAX_BATCHES × global_rows`,
recomputed whenever batch or topology changes). Breaking either makes results
incomparable to every run recorded so far.
