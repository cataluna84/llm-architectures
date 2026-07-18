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

## Core abstraction (utils.py)

State and computation are strictly separated:

- **`ParamSpec`**: abstract description of one array — shape, dtype, initializer, and `logical_axes` (logical sharding names).
- **`ParamInitializer`**: base class for layers. Subclasses implement `param_specs(cfg)` returning a pytree whose leaves are `ParamSpec`s; the base class derives `shardings(mesh, rules, ...)` and materializes sharded arrays in `_init_fn` via a single jitted init.
- **`@jax_pytree_struct`**: dataclass decorator registering the class as a JAX pytree. Fields with `metadata=dict(static=True)` become meta (non-trainable/static) fields; everything else is a data leaf. All layers (`layers.py`), the `GPT` model, `KVCache`, and `QArray` follow this pattern.

Forward passes are free pure functions (`forward`, `attn_forward`, `mlp_forward`, ... in `model.py`) that take the param pytree as their first argument — never methods on the layer classes.

## Sharding model

Params carry logical axis names (e.g. `("qkv_embed", "q_heads", "head_dim")`); `ShardingRules` in `config.py` maps each logical name to a physical mesh axis (`x` = batch, `y`/`z` = tensor), and `logical_to_sharding` produces `NamedSharding`s. Changing the parallelism strategy means editing `ShardingRules`, not layer code. The train/inference scripts currently build a 1-D mesh over `x` (DDP).

Attention weights are intentionally 3D — `wq/wk/wv: (d_emb, heads, head_dim)`, `wo: (heads, head_dim, d_emb)` — to make head sharding trivial. Anything that assumes 2D matrices (notably Muon's `muon_weight_dimension_numbers` in `optim.py`) must be told which axes to treat as batch/reduction/output; see `docs/training.md` for the throughput implications.

## Pipeline structure

- **`config.py`** — nested dataclass configs (`ModelConfig` → attention/MLP/embedding sub-configs built in `__post_init__`) composed into `Config`. GQA requires `q_heads != kv_heads` (raises otherwise). `window_pattern` ("L", "S", "SSSL", ...) selects per-layer local/global attention; global layers use NoPE when mixed (see `compute_layer_configs` in `model.py`).
- **`model.py`** — GPT-2-style transformer: GQA, RoPE, QK-norm, logits soft-capping, ReLU² MLP, parameter-free RMSNorm. Two forward paths: `forward` (training, causal+segment masks) and `forward_infer` (KV cache). Its `einsum` wrapper accepts a dense or `QArray` RHS, so quantized and dense params flow through the same code.
- **`optim.py`** — `build_optimizer` builds per-group optimizers via `optax.multi_transform`-style partitioning: separate LRs for embedding / unembedding / everything else, Muon or AdamW, plus cautious weight decay (decay only where update and param signs align). Gradient accumulation uses `optax.MultiSteps`; `grad_accum_steps` is derived from `desired_batch_size // (bsz * seqlen)` in `train.py`.
- **`fineweb_dataloader.py`** — grain loader over cached FineWeb10B `.bin` token shards (uint16), finds BOS boundaries on the fly, multithreaded prefetch (multiprocessing avoided: grain workers eat ~512MB GPU memory each).
- **`sft_dataloader.py`** — tokenizes role-based conversations (GPT-2 tokenizer extended with `<|pad|>`, `<|user_start|>` etc. special tokens), writes parquet, then BestFit-packs sequences with `segment_ids` and completion masks for completion-only loss. RoPE frequencies must be computed from segment positions, not absolute positions, because of packing.
- **`kvcache.py`** — `KVCache` pytree plus mask/position helpers. Inference uses left-padded prompts with right-aligned generation (`inference.py`: `prefill` → `decode` → `generate`). Known numerics: exact greedy equivalence with the no-cache path only holds on a compact active-KV slice, not the full masked buffer (bf16 flash-attention tiling noise breaks ties).
- **`quantization.py`** — weight-only int8 PTQ. `QArray` (quantized ints + scale + static placement metadata) replaces param leaves via `quantize_params` and path-pattern `QuantizationRule`s; dequant placement is handled by the `einsum` wrapper in `model.py`.
- **`checkpoint_utils.py`** — Orbax checkpoints with three items: `params`, `optim_state`, `ds` (grain iterator state, so data order survives resumes). Use `load_weights_from_checkpoint_with_validation` for params-only loads.
- **`tasks/`** — eval/SFT task definitions (smoltalk, MMLU, GSM8K, ARC, HumanEval) taken from nanochat; `Task`/`TaskMixture` in `tasks/common.py`.

## Gotchas

- `train.py` sets NCCL/XLA env flags at the very top **before** `import jax` — this ordering is load-bearing (and why ruff E402 is ignored under `nanogpt/`).
- Everything defaults to bfloat16; attention backend is `cudnn` on GPU, `xla` on TPU (chosen at import in `model.py`).
- The README has a couple of stale names: the SFT prep script is `nanogpt/sft_dataloader.py` (not `sft_downloader.py`) and the config lives at `nanogpt/config.py` (not `nanochat/config.py`).

## Contributing conventions (from README)

Open an issue before significant changes; branch as `feat/<name>` or `fix/<name>` off `main`; include a minimal repro/validation script with functional changes.
