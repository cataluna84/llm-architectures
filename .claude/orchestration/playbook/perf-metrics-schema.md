# Performance metrics schema

Field names emitted to W&B (`cataluna84/llm-architectures`) and the invariants
that make runs comparable across slices and architectures.

## Identity

| Field | Source | Notes |
|---|---|---|
| `WANDB_RUN_NAME` | runs-file env | Human-readable, e.g. `v5e64-lrsweep-020` |
| `WANDB_RUN_ID` | runs-file env | **Fixed** for resumable runs — a preemption must rejoin the same run, not fork a new one |
| `RUN_TAG` | `deploy_tarball.sh` | Unique per deploy; baked into the launch log line so log segments can be scoped |

Empty `WANDB_*` exports break `wandb.init` ("Run ID cannot be empty"), so
launchers export only when set and `init_wandb` scrubs empties. Both halves are
needed; either alone has been observed to fail.

## Training

| Field | Unit | Meaning |
|---|---|---|
| `train/loss` | nats | Per-step training loss |
| `train/lr` | — | Current LR of the Muon (hidden-matrix) group; should peak at the configured value |
| `train/muon_beta` | — | Momentum, ramping 0.85 → 0.95 over the warmup window; flat when warmup is disabled |
| `train/grad_norm` | — | Pre-clip gradient norm (clip at 1.0) |
| `val/loss` | nats | Validation, on the fixed 6,400-row subset |

## Throughput

| Field | Unit | Formula |
|---|---|---|
| `perf/step_time` | s | Measured wall time per optimizer step |
| `perf/tokens_per_sec` | tok/s | `tokens_per_step / step_time` |
| `perf/mfu` | fraction | achieved FLOP/s ÷ (`NANOGPT_DEVICE_PEAK_FLOPS` × chips) |

Percentiles (`p50`/`p90`/`p99` step time) come from tinyaya's schema and are
**not yet emitted here**. Worth adding before any throughput-optimization work:
a mean step time hides exactly the tail stalls that optimization targets.

## Invariants that make numbers comparable

1. **tokens/step = 524,288** on every training run. Per-device batch and
   accumulation may vary freely as long as their product with chip count and
   sequence length is unchanged.
2. **Val subset = 6,400 rows**: `NANOGPT_VAL_MAX_BATCHES × global_rows = 6400`.
   v6e-8 at 32 global rows → 200; v5e-64 at 256 → 25. **Recompute on every
   batch or topology change** — this was silently wrong once and produced a val
   curve that couldn't be compared to anything.
3. **`NANOGPT_DEVICE_PEAK_FLOPS` matches the silicon** (v5e: 197e12). MFU is
   meaningless across slices otherwise.
4. **Identical data pipeline per host** — same files, same seed, each host
   contributing only its row block. This is what makes multi-host batch
   composition match a single-host run exactly.

## Leaderboard fields

For run comparison, `run.summary` should carry final/best `val/loss`, total
tokens, wall-clock, MFU, and the slice name. Verify these are populated before
adding a row to the README benchmarking table.
