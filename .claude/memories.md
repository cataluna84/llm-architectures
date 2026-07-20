# memories.md — decisions and gotchas

Append via `/remember` or `#decision …`. Newest entries at the top of each section.

## Operational gotchas (transferred from tinyaya-stage2-scale, battle-tested)

- **Killed `gcloud ssh` ≠ killed remote command.** A local `timeout` on ssh
  orphans the remote process (two orphaned stagers once filled a root disk).
  Long host operations go in detached tmux (or `nohup … &`) with a liveness
  check; never foreground-ssh a critical command with a timeout.
- **Never pipe a critical command through `head`** — SIGPIPE kills it mid-work.
- **When detached sessions vanish, check `df -h` first** — full disk is the
  classic silent killer signature.
- **`pkill -f` matches itself**; use the bracket trick: `pkill -f '[s]cripts/...'`.
- **`which uv` is empty under sudo** — use `/root/.local/bin/uv` explicitly.
- **Spot preemption is a *when*, not an *if*.** Never launch a long run without
  the QR babysitter (`scripts/tpu/qr_watch.sh` in workstation tmux) and
  checkpoint+resume wired end to end.
- **apt/dpkg lock races at VM boot kill startup scripts** (`set -e` + lock =
  dead worker). The apt step must retry in a loop (fixed in startup_script.sh
  after it killed 2/16 v5e-64 workers and broke the multi-host rendezvous).

## Project decisions (llm-architectures / nanoGPT-JAX)

- **2026-07-20: v5e-64 throughput baseline (bsz 4/chip, accum 1):**
  0.23 s/step, 2.32M tokens/s, 25.5% MFU — 4.3× the v6e-8 (0.98 s/step,
  536k tok/s, 10.1% MFU). 1000-step run ≈ 4 min; 10k run ≈ 40 min train time.

- **2026-07-20: orchestration lives in workstation tmux, not agent sessions.**
  Sessions `qrwatch` (qr_watch.sh) + `sweep` (sweep_runner.sh), logs at
  `/tmp/qr_watch.log` / `/tmp/sweep_runner.log`, push events to
  https://ntfy.sh/$NTFY_TOPIC (topic in `.env`). Background monitors inside an
  agent session died twice mid-orchestration before this.
- **2026-07-20: v5e-64 topology is 16 hosts × 4 chips** (not 8×8). Multi-host
  port: `jax.distributed.initialize()` before model.py import;
  `host_local_to_global()` ships each host's row block; every host runs the
  identical data pipeline (same files/seed) so batch composition matches
  single-host runs exactly.
- **2026-07-20: per-device batch targets ~80% HBM** (leave 20% headroom —
  user directive). v5e-64: per-device 4, accum 1 (single micro-batch =
  B_ref); v6e-8: per-device 4, accum 8 (bsz 8 fits but is no faster —
  bandwidth-bound). B_ref = 524,288 tokens/step, always.
- **2026-07-19: Muon peak LR = 0.02** (empirical 3-point sweep on v6e-8, best
  val @902: 0.02→3.6011, 0.028→3.6008 tie, 0.014→3.6140; tie resolves to the
  nanochat-validated value). Momentum warmup 0.85→0.95/300 steps (nanochat)
  implemented via optax inject_hyperparams (`hyperparam_dtype=float32`,
  `static_args=("ns_steps","mu_dtype")`).
- **2026-07-19: code reaches TPU VMs ONLY as a GCS tarball incl. `.env`**
  (launch_qr.sh tars+uploads at submit; startup_script.sh extracts; no git
  clone anywhere). This is how WANDB_* credentials reach the VM.
- **Cross-topology comparability rule:** keep tokens/step = 524,288 and pick
  `NANOGPT_VAL_MAX_BATCHES` so batches × global rows = 6,400 val rows
  (v6e-8/bsz32: 200; v5e-64/bsz256: 25 at per-device 4 — recompute when bsz
  changes!).
- **Empty env-var exports break wandb** (`WANDB_RUN_ID=""` → "Run ID cannot
  be empty"); init_wandb scrubs empties, launchers export only when set.
- **Zone facts:** TRC grant zones in docs/tpu-trc-allocation.md; v6e
  (europe-west4-a, us-east1-d) had all-day insta-preemption churn 2026-07-19/20;
  v5e-64 (europe-west4-b) held. W&B: cataluna84/llm-architectures.
