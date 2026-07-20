# Protected baseline — v5e-64 (nanoGPT-JAX)

Numbers a regression is measured against. Update only when a new configuration
is deliberately promoted, and say why.

Architecture-specific by design: a new model implementation in this repo adds
`baseline-<slice>-<arch>.md` rather than editing this file.

## Slice

`nanogpt-v5e64` — `v5litepod-64`, `europe-west4-b`, spot/queued-resource.
**16 hosts × 4 chips = 64 devices**, one Python process per host, 1-D `x` mesh
(DDP). Assumed peak `NANOGPT_DEVICE_PEAK_FLOPS=197e12` per chip.

## Model

~181M params (~104M non-embedding): `d_emb=768`, `num_layers=16`, GQA
`q_heads=8` / `kv_heads=4` (`head_dim=96`), `seqlen=2048`, `vocab_size=50304`,
ReLU² MLP at 4× width, parameter-free RMSNorm, QK-norm, RoPE, logit
soft-capping, all-global attention (`window_pattern="L"`). bfloat16, `xla`
attention backend.

## Batch configuration

| Quantity | Value |
|---|---|
| `PER_DEVICE_BATCH_SIZE` | 4 (~80% HBM at 16 GiB/chip) |
| Global rows/step | 256 |
| Tokens/step | **524,288** (B_ref) |
| `grad_accum_steps` | **1** (single micro-batch) |
| `NANOGPT_VAL_MAX_BATCHES` | 25 → the 6,400-row val subset |

## Throughput (measured 2026-07-20)

| Metric | v5e-64 | v6e-8 (prior) |
|---|---|---|
| Step time | **0.23 s** | 0.98 s |
| Tokens/s | **2.32M** | 536k |
| MFU | **25.5%** | 10.1% |
| 1000 steps | ~4 min | ~16 min |
| 10k steps | ~40 min | ~2.7 h |

v6e-8 reached the same B_ref with per-device 4 × 8 chips × accum 8. Equal
tokens/step is what makes the two slices' losses directly comparable.

## Loss references

Muon peak-LR sweep, best val loss at ~step 902-905, 1000-step runs:

| Peak LR | v6e-8 | v5e-64 |
|---|---|---|
| 0.014 | 3.6140 | pending |
| **0.020** | 3.6011 | **3.5952** |
| 0.028 | 3.6008 | pending |

Selected: **0.02** (v6e-8 tie between 0.02 and 0.028 resolved to the
nanochat-validated value). v5e-64 at the same LR came in slightly better, as
expected from accum=1 versus accum=8 numerics.

Momentum warmup A/B (`020` vs `020-nomom`) is still outstanding.

## Regression triggers

- Step time > ~0.46 s (2× baseline) sustained — but rule out a recompile marker,
  a shard-boundary validation pass, and a sick host first.
- MFU below ~20% at this configuration.
- Best val at step ~900 materially above 3.60 for a 1000-step run at LR 0.02.
- Any change in tokens/step — that invalidates comparison against everything
  above, which is the whole point of the invariant.
