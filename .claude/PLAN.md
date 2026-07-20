# PLAN.md — current goal

Goal: first full pretraining baseline of pure-JAX nanoGPT on TPU, with
leaderboard-shaped metrics on W&B (cataluna84/llm-architectures), driven
end-to-end by session-proof orchestration that also carries SFT and later reps.

Order is deliberate: **finish and harden the orchestration first, then run every
stage through it** (user directive 2026-07-20).

## Orchestration (must be complete before the long runs)

- [x] Multi-host port (v5e-64 = 16 hosts x 4 chips): jax.distributed +
      host_local_to_global batch feeding
- [x] Workstation tmux: qr_watch.sh (`qrwatch`) + sweep_runner.sh (`sweep`) + ntfy
- [x] Memory/hook system imported (6 lifecycle hooks, skills, commands, agents)
- [x] `.claude/orchestration/` imported + adapted — repo-level, not
      nanoGPT-specific; T3 auto-recycle, push-only check-ins
- [x] session_start.py injects the control plane again; tpu-redeploy skill added
- [x] Stage entrypoint parameterized (`NANOGPT_ENTRYPOINT`) for SFT + reps
- [ ] sweep_runner completion probe fixed (rare markers via tail, `Best loss`
      fetched separately) — staged, blocked on the live runner exiting
- [ ] Auto-resume + W&B identity in boot metadata verified across a real
      preemption

## Runs (after the above)

- [x] Muon LR sweep on v6e-8 -> peak 0.02 (3.6011 vs 3.6140 / 3.6008)
- [x] v5e-64 smoke at per-device 4, accum=1: 0.23 s/step, 2.32M tok/s, 25.5% MFU
- [x] v5e64-lrsweep-020 (1000 steps): best val **3.5952 @ step 905**
- [ ] v5e64-lrsweep-014 / -028 / -020-nomom
- [ ] Momentum-warmup A/B decision (020 vs 020-nomom)
- [ ] Full 10k-step run (`v5e64-baseline-10k`), ckpts ->
      gs://llm-architectures-eu/nanogptjax/checkpoints/, resume-safe
- [ ] SFT: sft_dataloader.py -> train_sft.py via NANOGPT_ENTRYPOINT, params from
      the 10k checkpoint
- [ ] Post-run: docs/training.md, README benchmarking table, results on PR #1

## Invariants

tokens/step = 524,288; val subset = 6,400 rows
(`NANOGPT_VAL_MAX_BATCHES x global_rows`); code reaches VMs only as a GCS
tarball including `.env`; long loops never live in a Claude session.
