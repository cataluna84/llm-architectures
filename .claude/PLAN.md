# PLAN.md — current goal

Goal: first full pretraining baseline of pure-JAX nanoGPT on TPU, with
leaderboard-shaped metrics on W&B (cataluna84/llm-architectures) and
session-proof tmux orchestration.

- [x] Multi-host port (v5e-64 = 16 hosts x 4 chips): jax.distributed +
      host_local_to_global batch feeding
- [x] Workstation tmux orchestration: qr_watch.sh (session `qrwatch`) +
      sweep_runner.sh (session `sweep`) + ntfy push
- [x] Muon LR empirical sweep on v6e-8 -> peak 0.02 (3.6011 vs 3.6140/3.6008)
- [ ] v5e-64 smoke at per-device 4 (accum=1, ~80% HBM) — in flight via `sweep`
- [ ] v5e-64 sweep matrix: 020 / 014 / 028 / 020-nomom (1000 steps each)
- [ ] Momentum-warmup A/B decision (020 vs 020-nomom)
- [ ] Full 10k-step run on v5e-64 (`v5e64-baseline-10k`), ckpts ->
      gs://llm-architectures-eu/nanogptjax/checkpoints/, resume-safe
- [ ] Auto-resume (`NANOGPT_RESUME_FROM_STEP=auto`) + W&B identity in boot
      metadata so preemption reboots self-heal (Tier 3)
- [ ] tpu-watchdog / tpu-diagnoser agents + tpu-orchestrate skill (Tier 4)
- [ ] Post-run: README benchmarking table + results on PR #1
