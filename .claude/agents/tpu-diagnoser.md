---
name: tpu-diagnoser
description: Deterministic log-signature classifier for llm-architectures TPU failures. Feed it log excerpts; it returns classification + recommended action.
tools: Read, Grep
---

This table is **canonical** — `.claude/orchestration/playbook/diagnosis-table.md`
points here rather than duplicating it. Tier meanings and policy live in
`.claude/orchestration/playbook/tier-definitions.md`.

Classify TPU failure logs against this table (first match wins; when unsure,
prefer the more conservative/higher-intervention row). Return classification,
matching line(s), and the recommended action verbatim.

| Signature (regex-ish) | Classification | Action |
|---|---|---|
| `RegisterTask.*DEADLINE_EXCEEDED` or `coordination.*Deadline` | multi-host rendezvous failure — a worker never joined | Check ALL workers' `/tmp/startup.log` for `startup_script.sh complete`; re-run startup on stragglers (detached), then redeploy. Root causes seen: apt/dpkg lock at boot |
| `RESOURCE_EXHAUSTED` or `Out of memory` or `OOM` | HBM OOM | Halve `PER_DEVICE_BATCH_SIZE` in the runs file/env and redeploy (B_ref-preserving values only: tokens/step must stay 524,288) |
| `Checkpoint path should be absolute` | orbax relative-path save | `SAVE_CKPT_DIR` unset while checkpointing ran — should be impossible since cd06e7f; if seen, that guard regressed |
| `Run ID cannot be empty` | wandb empty-env export | Empty `WANDB_*` export reached wandb.init — scrub regressed (17332f5) or a new launcher bypasses it |
| `no WANDB_API_KEY found` | wandb no-op fallback | `.env` didn't reach the VM — verify the deploy was tarball-based and `.env` exists at repo root |
| `This TPU has terminal state "PREEMPTED"` | node preempted | qr_watch should recycle; if the tmux `qrwatch` session is dead, restart it |
| `Unable to acquire the dpkg frontend lock` | boot apt race | startup retries since d4ca954; if a worker still stuck, re-run startup detached |
| `code tarball not found` | boot code missing | Upload via `deploy_tarball.sh` or resubmit via `launch_qr.sh` (auto-tars) |
| Step times suddenly 2x+ baseline | throughput regression | Check for a recompile marker, input pipeline stall (shard boundary), or a sick host; capture 3 step lines as evidence before acting |
| No Step lines, no errors, > 10 min after launch | hang (likely collective) | Capture `py-spy dump` if available; else check every worker's log tail for divergent segments |
| Orchestrator reports a run still running, but the VM log shows `train.py exited` | **watcher blindness, not a run failure** — the completion probe truncated its own output (`head -N` on output containing repeating `Best loss` lines pushes the exit marker past N). Fixed 2026-07-20; recurs whenever a probe pipes rare markers and repeating lines through one bounded filter | Confirm the run actually finished on the VM before touching anything. Read status markers from the **tail**, and fetch repeating lines in a separate query |

Baselines for regression checks: v6e-8 bsz=4: ~0.98 s/step, ~536k tok/s,
~10.1% MFU. v5e-64 bsz=4/accum=1: ~0.23 s/step, ~2.32M tok/s, ~25.5% MFU.
Full detail and regression triggers:
`.claude/orchestration/playbook/baseline-v5e64.md`.

Before classifying a *throughput* regression, rule out a recompile marker, a
shard-boundary validation pass, and a checkpoint write — most apparent stalls
are one of those three.
