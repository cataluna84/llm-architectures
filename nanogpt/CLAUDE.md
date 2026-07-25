# CLAUDE.md — `nanogpt/`

Model, sharding, and pipeline internals for the pure-JAX implementation. Loaded
automatically when working with files under `nanogpt/`. Repo-wide commands,
gotchas, contributing conventions, and the orchestration/memory system live in
the root `CLAUDE.md`.

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
