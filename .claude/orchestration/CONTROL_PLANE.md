# Orchestration Control Plane

**Version:** v1 (2026-07-20, adapted from tinyaya-stage2-scale v2)
**Scope:** repo-level — covers TPU work for any model implementation in
`llm-architectures`, of which nanoGPT-JAX is the first.
**Purpose:** one map of skills, agents, hooks, memory files, scripts, and
external surfaces — so every fact is written once.

## 1. Entry points

| Intent | Entry point | Supporting files |
|---|---|---|
| Load state before non-trivial work | SessionStart hook (automatic) or `/recall` | `PLAN.md`, `PROGRESS.md`, `VERIFY.md`, `memories.md`, this file |
| Run or supervise a TPU stage | `tpu-orchestrate` skill | `SPEC.md`, `playbook/*`, `tpu-watchdog`, `tpu-diagnoser` |
| Push code to a live slice | `tpu-redeploy` skill | `scripts/tpu/deploy_tarball.sh` |
| Classify a failure | `tpu-diagnoser` agent | `playbook/tier-definitions.md` |
| Record goal / phase changes | `/plan` | `.claude/PLAN.md` |
| Record events | PostToolUse hook (automatic) or `/progress` | `.claude/PROGRESS.md` |
| Record a durable decision | `/remember` or `#decision …` | `.claude/memories.md` |
| Prove done | `/verify` or Stop hook | `.claude/VERIFY.md` |

`tpu-orchestrate` is the master run-control skill. Everything else is
subordinate to it during a run.

## 2. Source-of-truth boundaries

| Surface | Owns | Does NOT own |
|---|---|---|
| `CLAUDE.md` | Repo architecture, commands, conventions | Run state, operational history |
| `.claude/PLAN.md` | Current goal + phase checklist | Run history, raw logs |
| `.claude/PROGRESS.md` | Append-only event log | Durable rationale |
| `.claude/memories.md` | Durable decisions + gotchas | Step-by-step task lists |
| `.claude/VERIFY.md` | Commands that prove the repo is sane | Experiment hypotheses |
| `.claude/orchestration/*` | Operational spec, playbook, invariants | Raw runtime data |
| `.claude/agents/tpu-diagnoser.md` | **The diagnosis table** (canonical) | Recovery policy (that's `SPEC.md`) |
| `scripts/tpu/runs/*` | Run payloads (envs per run) | Results |
| `docs/tpu-trc-allocation.md` | TRC quota + zone grants | Live capacity |
| `docs/training.md` | Optimizer/throughput findings | Operational procedure |
| W&B / GCS | Metrics, checkpoints | Repo-local truth |
| `/tmp/*.log` | Ephemeral runtime detail | Anything durable |

Rule: write a fact once, at the most specific durable layer, then link to it.
The diagnosis table lives in `tpu-diagnoser.md` **only** — `playbook/
diagnosis-table.md` is a pointer, not a second copy, because two copies drift.

## 3. Pipeline stages (nanoGPT-JAX)

Architectures in this repo are multi-stage, unlike the tinyaya original. Every
stage runs through the same deploy/supervise machinery, selected by an
entrypoint env var — so a new architecture plugs in by adding rows here, not by
touching `scripts/tpu/`. The current nanoGPT-JAX pipeline:

| Stage | Entrypoint | Inputs | Produces |
|---|---|---|---|
| Data prep | `nanogpt/download_fineweb_tokens.py` | shard count | `fineweb10B/*.bin` on the VM |
| Pretrain | `nanogpt/train.py` (default) | FineWeb shards | params + optim + ds checkpoints |
| SFT prep | `nanogpt/sft_dataloader.py` | task mixture | packed parquet |
| SFT | `nanogpt/train_sft.py` | pretrain `params/` via `load_params_ckpt_path` | SFT checkpoints |
| Inference | `nanogpt/inference.py` | a `params/` dir | samples |

A runs-file line is stage-agnostic: it is just `KEY=VALUE` env passed to
`deploy_tarball.sh`. Stage selection is one more env var.

## 4. Layers (who survives what)

| Layer | Dies when | Survives |
|---|---|---|
| VM tmux `train` (per worker) | node preempted/rebooted | workstation off, Claude session ends |
| Workstation tmux `qrwatch` / `sweep` | workstation off | Claude session ends, node preemption |
| Boot self-heal (QR metadata) | QR deleted | node reboot, preemption |
| Claude session | anything | nothing — **never** owns a long loop |

The rule this encodes: **a loop that must outlive the conversation never runs
inside the conversation.** Session-bound monitors died three times on
2026-07-19/20 before this was enforced.

## 5. Agents

| Agent | Mode | Responsibility |
|---|---|---|
| `tpu-watchdog` | read-only | Report live run state across all 16 workers |
| `tpu-diagnoser` | read-only | Classify a failure signature → tier + action |

Agents never edit files, restart processes, or touch queued resources. They
report; the orchestrator acts.

## 6. External surfaces

- Metrics: https://wandb.ai/cataluna84/llm-architectures
- Push events: `https://ntfy.sh/$NTFY_TOPIC` (topic in gitignored `.env`)
- Checkpoints: `gs://llm-architectures-eu/nanogptjax/checkpoints/`
  (EU bucket pairs with `europe-west4-*`; `gs://llm-architectures-us` for
  `us-east1-d`)
- Code delivery: GCS tarball only — **never** a git clone. The tarball
  includes the gitignored `.env`, which is how W&B credentials reach the VM.
