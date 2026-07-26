# llm-architectures TPU Run Control — SPEC

**Version:** v1 (2026-07-20)
**Scope:** repo-level. This spec governs TPU run control for **any** model
implementation in `llm-architectures`; nanoGPT-JAX is simply the first one
through it. Nothing below is architecture-specific except the named
invariants in §7, which each architecture restates with its own numbers.
**Status:** adapted from tinyaya-stage2-scale v4; validated on v5e-64
**Topology:** v5litepod-64 = **16 hosts × 4 chips**, one Python process per
host, 64 devices in a 1-D `x` mesh (DDP). Legacy: v6e-8 = 1 host × 8 chips.

Read `CONTROL_PLANE.md` first for surface ownership.

## 1. Goal

Drive a TPU stage (pretrain / SFT / eval) to completion with **bounded
autonomous recovery**, on spot capacity that will be preempted mid-run, without
a human in the loop and without a Claude session being load-bearing.

## 2. Decisions locked

| Decision | Value | Why |
|---|---|---|
| Orchestration home | workstation tmux | Claude sessions die; three did |
| Training home | VM tmux `train`, all workers | Multi-host rendezvous needs every host |
| Code delivery | GCS tarball incl. `.env` | Private repo, and credentials must reach the VM |
| T3 (node lost) | **auto-recycle** via `qr_watch.sh` | Diverges from tinyaya — see §5 |
| Check-ins | **push-only** (ntfy) | Diverges from tinyaya — see §6 |
| Resume | `NANOGPT_RESUME_FROM_STEP=auto` | Preemption reboot self-heals |
| Iteration cap | resubmit budget 20, then stop | Anti-flap without a hard wall-clock cap |

## 3. Architecture (5 layers)

See `diagrams/01-architecture.mmd`.

```
Claude session      reads logs, decides, edits code      (disposable)
      |
Workstation tmux    qrwatch  (QR lifecycle)              (survives Claude)
                    sweep    (runs-file execution)
      |
QR metadata         tarball URI, resume=auto, W&B id     (survives reboot)
      |
VM tmux `train`     the actual training process x16      (survives workstation)
      |
GCS + W&B           checkpoints, metrics                 (survives everything)
```

## 4. The run loop

See `diagrams/02-state-machine.mmd`.

```
DEPLOY -> WATCH -> [ok] -> WATCH
                -> [exit clean]   -> NEXT RUN / DONE
                -> [exit dirty]   -> CLASSIFY -> RECOVER -> DEPLOY
                -> [node gone]    -> qr_watch recycles -> boot self-heal
                -> [budget spent] -> STOP + notify
```

**DEPLOY** — `deploy_tarball.sh` tars the working tree, uploads to GCS, pulls it
on `--worker=all`, and relaunches VM tmux `train` everywhere. Each deploy bakes
a unique `RUN_TAG` into the launch line.

**WATCH** — poll worker 0's `/tmp/train.log`, scoped to the segment *after* this
run's `RUN_TAG`. Never match a stale segment from an earlier deploy or boot; a
7-hour-old segment once triggered a spurious abort.

Completion detection has two independent queries, and this is load-bearing:

- rare status markers (`exited`, `Reached maximum training steps`, `Traceback`,
  `DEADLINE_EXCEEDED`, `RESOURCE_EXHAUSTED`) — take the **tail**
- the repeating `Best loss` line — fetched separately, **tail -1**

Piping both through one `head -N` truncates the status marker behind N repeats
of the noisy line and the run looks hung forever. That exact bug hid a
successfully completed 1000-step run for an hour on 2026-07-20.

**CLASSIFY** — match the log against the canonical table in
`.claude/agents/tpu-diagnoser.md`; it returns a tier.

**RECOVER** — act per `playbook/tier-definitions.md`.

## 5. Preemption and T3 (divergence from tinyaya)

tinyaya locked T3 to "always escalate, never auto-recreate the QR", reasoning
that a new spot acquisition costs 10-30 minutes and may fail on capacity.

**This project inverts that.** `qr_watch.sh` polls the queued resource every
300s and, on `SUSPENDING` / `SUSPENDED` / `FAILED`:

1. captures `describe` JSON forensics,
2. checks for a quota-class abort (no point resubmitting into a wall),
3. deletes the QR,
4. resubmits the identical `launch_spot.sh` env file,
5. pushes an ntfy event.

Bounded by `MAX_RESUBMITS=20` plus a cooldown. If the QR is absent entirely it
exits rather than competing with a human — **one resubmitter per QR, ever.**

Justification: on TRC capacity preemption is routine rather than exceptional
(~25 in a single day on v6e), the quota is free, and a 40-minute pretraining run
must survive unattended overnight. The cost asymmetry tinyaya worried about
points the other way here.

Boot self-heal closes the loop: QR metadata carries the code tarball URI,
`NANOGPT_RESUME_FROM_STEP=auto`, and the W&B run identity — so a recycled node
re-fetches code, resumes from the latest GCS checkpoint, and continues logging
to the *same* W&B run with no human action.

## 6. Notifications (divergence from tinyaya)

tinyaya required a blocking `AskUser` snapshot at T+15/30/45/60/90 min.
**Nothing blocks on a human here.** Events push to `https://ntfy.sh/$NTFY_TOPIC`
and a 2-hour heartbeat proves the watcher is alive. See
`playbook/event-taxonomy.md`.

Rationale: the check-in protocol assumes a human is watching a single
foreground run. This project runs unattended sweeps and overnight training; a
blocking prompt would stall the sweep at the first milestone.

## 7. Invariants (do not break)

- **tokens/step = 524,288** (B_ref) on every training run. Per-device batch and
  accumulation are free only within that product.
- **Val subset = 6,400 rows**: `NANOGPT_VAL_MAX_BATCHES × global_rows = 6400`.
  Recompute whenever per-device batch or chip count changes.
- **Deploys ship the working tree as a GCS tarball** including `.env`. Never
  clone.
- **One resubmitter per QR** — `qr_watch` or a human, never both.
- **Long loops live in tmux**, never in a Claude session.
- Multi-host: `jax.distributed.initialize()` must run **before** `model.py` is
  imported (it queries `jax.default_backend()` at import time).

## 8. Known-good numbers

See `playbook/baseline-v5e64.md`. A step time more than ~2× baseline, or a
missing step line for >10 min after launch, is a regression worth diagnosing —
but check for a recompile marker or a shard-boundary validation pass first.
Most "hangs" are neither.
