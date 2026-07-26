---
name: tpu-orchestrate
description: Run-control playbook for llm-architectures TPU runs — how orchestration is layered, where truth lives, and the recovery ladder. Load when operating, debugging, or resuming a TPU run.
---

# TPU run-control (llm-architectures)

**Design source-of-truth is `.claude/orchestration/`.** This skill is the
operational quick reference; read the folder when you need the reasoning:

| Need | File |
|---|---|
| Which surface owns a fact | `orchestration/CONTROL_PLANE.md` |
| The run loop + recovery ladder | `orchestration/SPEC.md` |
| What to do at each tier | `orchestration/playbook/tier-definitions.md` |
| Signature → classification | `.claude/agents/tpu-diagnoser.md` |
| Known-good numbers | `orchestration/playbook/baseline-v5e64.md` |
| Metric names + invariants | `orchestration/playbook/perf-metrics-schema.md` |
| ntfy event meanings | `orchestration/playbook/event-taxonomy.md` |

## Layering — who owns what

1. **VM tmux `train`** (every worker): the training process. Launched by
   `startup_script.sh` at boot and by `deploy_tarball.sh` on redeploys.
   Log: `/tmp/train.log` per worker. Deploys kill+relaunch it on all workers
   (`--worker=all` — multi-host slices need every host for the rendezvous).
2. **Workstation tmux `qrwatch`**: `scripts/tpu/qr_watch.sh` — recreates the
   QUEUED RESOURCE when spot kills it (forensics → delete → identical
   resubmit). Log: `/tmp/qr_watch.log`.
3. **Workstation tmux `sweep`**: `scripts/tpu/sweep_runner.sh` — executes a
   runs-file of sequential deploys, tag-scoped completion detection.
   Log: `/tmp/sweep_runner.log`.
4. **Boot self-heal**: QR metadata carries code-tarball URI, resume=auto,
   W&B identity → a preemption REBOOT (QR survives) recovers with zero action.
5. **Claude session**: reads logs, makes decisions. NEVER the owner of a loop
   that must outlive it — anything long-running goes into tiers 1-4.

## Where truth lives

- Metrics: https://wandb.ai/cataluna84/llm-architectures
- Push events: https://ntfy.sh/$NTFY_TOPIC (topic in `.env`)
- Logs: worker `/tmp/train.log`; workstation `/tmp/qr_watch.log`,
  `/tmp/sweep_runner.log`, `/tmp/sweep_deploy.log`
- Run defs: `scripts/tpu/runs/*.runs` (sweep payloads), `*.env` (qr_watch
  resubmit envs)
- Facts/gotchas: `.claude/memories.md`; zone/quota: `docs/tpu-trc-allocation.md`

## Recovery ladder (least → most invasive)

1. Read logs (`ops.sh tail-logs`, watchdog agent) — most "failures" are
   compiles or shard-boundary val passes.
2. Redeploy code/env to the live fleet: `deploy_tarball.sh` (kills+relaunches
   `train` everywhere; safe mid-run only if resume/checkpointing configured).
3. Recycle the QR: qr_watch does this automatically; manually = delete QR →
   `launch_spot.sh` with the same env file.
4. Zone rotation: profiles `v6e-8-eu` / `v6e-8-us` / `v5e-64-ew4b` in
   `launch_spot.sh` (quota: docs/tpu-trc-allocation.md). Keep bucket region
   in mind (EU bucket ↔ europe-west4-*).

## Invariants (do not break)

- tokens/step = 524,288 (B_ref) on every training run; per-device batch and
  accum are free parameters only within that constraint.
- Val subset = 6,400 rows: `NANOGPT_VAL_MAX_BATCHES × global_rows = 6400`.
- Deploys ship the working tree incl. `.env` as a GCS tarball — never clone.
- One resubmitter per QR (qr_watch OR a human, never both at once).
