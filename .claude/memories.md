# memories.md — decisions and gotchas

Append via `/remember` or `#decision …`. Newest entries at the top of each section.

## Operational gotchas (transferred from tinyaya-stage2-scale, battle-tested)

- **`echo X >> file` corrupts the last line when the file lacks a trailing
  newline.** This silently glued `NTFY_TOPIC=` onto the `HF_TOKEN` line of
  `.env` — the variable never existed, `notify()` no-opped *by design*, and
  every push event on 2026-07-20 was dropped until the user asked where their
  notifications were. Append with `printf '\n%s\n'` or verify the tail first.
  Same lesson as the exit-status bug: an alerting channel that can fail
  silently WILL, so send a test event through any new pipe end to end before
  trusting it.
- **`$(...)` in the same line as `$?` destroys the exit status.** In
  `echo "[$(date -Is)] exited with status $?"` bash runs the substitution while
  expanding the line, resetting `$?` to `date`'s status — so the launcher
  reported `status 0` for *every* run, including fatal tracebacks, until
  2026-07-20. Capture `rc=$?` on its own line immediately after the command.
  Generalization: any status/marker a watcher trusts must be proven to change
  when the thing it describes fails. An indicator that is always green is worse
  than no indicator.
- **Never filter rare status markers and repeating lines through one bounded
  pipe.** `sweep_runner.sh` matched `grep -E 'exited|Best loss|...' | head -6`;
  a 1000-step run emits one `Best loss` per shard boundary, so six of them ate
  the entire head budget and the exit marker never appeared. A finished run went
  undetected for an hour (2026-07-20) while a 64-chip slice sat idle. Read rare
  markers from the **tail**, and fetch repeating lines in a *separate* query.
  General form: **the watcher was wrong, not the run** — always confirm against
  the source of truth on the VM before concluding a run is stuck.
- **Editing a shell script while bash is executing it is unsafe.** Bash reads a
  script incrementally by byte offset; rewriting it under a running process can
  make it resume mid-line and execute garbage. Stage the new version elsewhere
  and install it once the process exits.
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

- **2026-07-20: orchestration design lives in `.claude/orchestration/`** and is
  **repo-level, not nanoGPT-specific** (user directive — `llm-architectures` is
  the repo; nanoGPT-JAX is its first architecture). New architectures add a
  `playbook/baseline-*.md` rather than editing the spec. Two policies were
  deliberately inverted from the tinyaya original: **T3 auto-recycles** (qr_watch
  resubmits, bounded) and **check-ins are push-only** (ntfy, nothing blocks).
- **2026-07-20: the stage entrypoint is `NANOGPT_ENTRYPOINT`** (default
  `nanogpt/train.py`), carried in launcher log markers and QR metadata, so the
  same deploy/supervise/self-heal machinery drives pretraining, SFT, and later
  reps. Orchestrators match the stage-agnostic substring `exited with status`,
  which also matches every log line the pre-2026-07-20 launcher wrote.
- **Duplicate reference tables drift.** tinyaya kept its diagnosis table in both
  the playbook and the diagnoser agent; they diverged. Here the table is
  canonical in `.claude/agents/tpu-diagnoser.md` and the playbook only points
  at it.

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
- **2026-07-20: sweep concluded on v5e-64 — LR 0.02, momentum warmup ON.**
  Best val @905 over 1000 steps: 0.014→3.6186, **0.020→3.5952**, 0.028→3.5983,
  0.020-without-warmup→3.6322.
  - **Momentum warmup is the real finding**: 0.0370 better than constant beta,
    ~12x the spread between the two best LRs and well outside single-seed noise.
  - **LR 0.020 vs 0.028 is a plateau, not a ranking** (0.0031 apart, <0.1%, and
    the two slices order them oppositely — v6e-8 had 0.028 ahead by 0.0003).
    Only 0.014 is clearly worse. The tie breaks to 0.02 as the nanochat value.
    Do not cite the sweep as evidence that 0.028 is harmful.
  Momentum warmup 0.85→0.95/300 steps implemented via optax inject_hyperparams
  (`hyperparam_dtype=float32`, `static_args=("ns_steps","mu_dtype")`).
- **2026-07-20: checkpointing had NEVER run** — the GCS checkpoint prefix was
  empty after every run to date, because each sweep run left `SAVE_CKPT_DIR`
  unset. Always exercise checkpoint+resume in a ~120-step smoke
  (`runs/v5e64-ckpt-smoke.runs`, `checkpoint_save_steps=100`) before committing
  to a long run: orbax saves are collective across all 16 hosts, so a
  multi-host save bug *hangs* rather than erroring, and the whole T3
  auto-recycle policy assumes resume works.
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
