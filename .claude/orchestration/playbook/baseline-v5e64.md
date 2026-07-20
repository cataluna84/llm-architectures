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
| 0.014 | 3.6140 | 3.6186 |
| **0.020** | 3.6011 | **3.5952** |
| 0.028 | 3.6008 | 3.5983 |

**Selected: peak LR 0.02, momentum warmup ON.**

Read the LR result honestly: 0.020 and 0.028 are a *plateau*, not a ranking.
They differ by 0.0031 on v5e-64 (<0.1%, single seed) and the two slices order
them oppositely — v6e-8 put 0.028 ahead by 0.0003. What the sweep actually
establishes is that **0.014 is clearly worse** on both slices. The tie breaks to
0.020 as the nanochat-validated value. Do not read the 0.020 win as evidence
that 0.028 is harmful.

Momentum warmup A/B at LR 0.020 (v5e-64, 1000 steps):

| Muon momentum | Best val @905 |
|---|---|
| **warmup 0.85 -> 0.95 over 300 steps** | **3.5952** |
| constant 0.95 (`WARMUP_STEPS=0`) | 3.6322 |

**Momentum warmup stays ON.** The 0.0370 gap is ~12x the entire spread between
the two best learning rates, making it the most consequential single knob the
sweep tested — and the only one whose result is well outside single-seed noise.

v5e-64 at LR 0.020 also beat its v6e-8 twin (3.5952 vs 3.6011), consistent with
accum=1 versus accum=8 numerics at identical tokens/step.

Caveat: `v6e8-lrsweep-020` predates the empty-`WANDB_RUN_ID` fix and exists only
in console logs, so the v6e-8 column is not fully reproducible from W&B.

## Regression triggers

- Step time > ~0.46 s (2× baseline) sustained — but rule out a recompile marker,
  a shard-boundary validation pass, and a sick host first.
- MFU below ~20% at this configuration.
- Best val at step ~900 materially above 3.60 for a 1000-step run at LR 0.02.
- Any change in tokens/step — that invalidates comparison against everything
  above, which is the whole point of the invariant.
