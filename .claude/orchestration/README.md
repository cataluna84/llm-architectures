# `.claude/orchestration/`

Design source-of-truth for **`llm-architectures` TPU run control**. This folder
holds the spec, playbook, and diagrams that describe how runs are supervised.
The implementations live in their natural homes (`scripts/tpu/*.sh`,
`.claude/agents/`, `.claude/skills/`) and are listed below.

Scope is **repo-level, not per-architecture**. nanoGPT-JAX is the first model
implementation driven through this machinery; the layering, recovery ladder,
and event taxonomy are meant to carry over to every architecture added to this
repo. Only the numbers in `playbook/baseline-*.md` and the run invariants are
architecture-specific — each new architecture adds its own baseline file rather
than editing these.

Adapted from `tinyaya-stage2-scale` on 2026-07-20. Two policies were
deliberately inverted during the import; see "Divergences" below.

## Status (2026-07-20)

Active slice: **v5e-64 `nanogpt-v5e64` in `europe-west4-b`** — 16 hosts × 4
chips, one Python process per host, 64 devices in a 1-D `x` mesh (DDP).

Baseline measured on this slice at per-device batch 4 / accum 1:
**0.23 s/step, 2.32M tokens/s, 25.5% MFU**. First 1000-step sweep run
(`v5e64-lrsweep-020`) reached **best val 3.5952 at step 905**.

Prior slice: v6e-8 (`europe-west4-a` / `us-east1-d`) — 0.98 s/step, 536k tok/s,
10.1% MFU. Held the 3-point Muon LR sweep that selected peak LR 0.02. Both
v6e zones saw all-day insta-preemption churn on 2026-07-19/20; v5e-64 held.

## Layout

```
.claude/orchestration/
|-- README.md                      # this file
|-- CONTROL_PLANE.md               # who owns which surface; entry points
|-- SPEC.md                        # the supervised run loop + recovery ladder
|-- playbook/
|   |-- tier-definitions.md        # T0-T4 escalation ladder (T3 = auto here)
|   |-- diagnosis-table.md         # pointer to the canonical table
|   |-- perf-metrics-schema.md     # metric names + the run invariants
|   |-- baseline-v5e64.md          # protected throughput/loss baselines
|   `-- event-taxonomy.md          # ntfy push events (replaces check-ins)
`-- diagrams/
    |-- 01-architecture.mmd        # the 5 layers
    |-- 02-state-machine.mmd       # DEPLOY -> WATCH -> CLASSIFY -> RECOVER
    |-- 03-memory-lifecycle.mmd    # logs -> progress -> memories
    `-- render.sh                  # mmdc helper (svg/ + png/)
```

## Implementation files (NOT here)

| Artifact | Location | Purpose |
|---|---|---|
| QR babysitter | `scripts/tpu/qr_watch.sh` | tmux `qrwatch`: recycle the queued resource on preemption |
| Sweep executor | `scripts/tpu/sweep_runner.sh` | tmux `sweep`: run an ordered runs-file to completion |
| Deploy | `scripts/tpu/deploy_tarball.sh` | tar → GCS → all workers → relaunch VM tmux `train` |
| QR submit | `scripts/tpu/launch_qr.sh`, `launch_spot.sh` | tar+upload at submit; zone/profile selection |
| Boot | `scripts/tpu/startup_script.sh` | fetch tarball, install deps, launch `train` |
| Shared helpers | `scripts/tpu/_lib.sh` | `make_code_tarball()`, `notify()` |
| Skill | `.claude/skills/tpu-orchestrate/SKILL.md` | run-control playbook entry point |
| Skill | `.claude/skills/tpu-redeploy/SKILL.md` | the redeploy procedure |
| Agent | `.claude/agents/tpu-watchdog.md` | read-only live state |
| Agent | `.claude/agents/tpu-diagnoser.md` | **canonical diagnosis table** |
| Run defs | `scripts/tpu/runs/*.runs`, `*.env` | sweep payloads / resubmit envs |

## Divergences from the tinyaya original

1. **Tier 3 is automatic here.** tinyaya locked "never auto-recreate the QR;
   always escalate". This project runs `qr_watch.sh`, which deletes and
   resubmits the QR automatically (budget 20, cooldown, quota-abort). Spot
   preemption is routine on TRC capacity (~25 in one day), TRC quota is free,
   and long runs must survive unattended overnight. See
   `playbook/tier-definitions.md`.
2. **No blocking check-ins.** tinyaya mandated an `AskUser` snapshot at
   T+15/30/45/60/90 min. Here nothing blocks on a human: events push to
   ntfy.sh and a 2h heartbeat confirms liveness. See
   `playbook/event-taxonomy.md`.
3. **Optimization spec dropped.** tinyaya's `TPU_OPTIMIZATION_SPEC.md` and
   `optimization-experiment-matrix.md` encode a torch_xla/FSDPv2 phase program
   (scan_layers, depth chunking, MPDeviceLoader) with no analogue in this pure
   JAX codebase. Throughput findings belong in `docs/training.md`.

## Read order

1. `CONTROL_PLANE.md` — surface ownership, so facts get written once
2. `SPEC.md` — the run loop and recovery ladder
3. `playbook/baseline-v5e64.md` — the numbers a regression is measured against
4. `.claude/agents/tpu-diagnoser.md` — failure signature → action
5. `diagrams/01-architecture.mmd` — the layering, visually

## Rendering diagrams

```bash
bash .claude/orchestration/diagrams/render.sh          # all
bash .claude/orchestration/diagrams/render.sh 01-architecture.mmd
```

Requires `mmdc` (`npm i -g @mermaid-js/mermaid-cli`), falls back to `npx`.
The `.mmd` sources are the checked-in artifact; `svg/` and `png/` are
generated and gitignored.

## Versioning

Edits bump the version banner at the top of `SPEC.md` and update affected
diagrams in the same commit.
