# PROGRESS.md — append-only log (newest first)

<!-- progress:marker -->

## 2026-07-20 — orchestration import + v5e-64 bring-up
- Imported tinyaya memory/hook system (6 lifecycle hooks, memory
  skills/commands/agents) into `.claude/`; seeded PLAN/PROGRESS/VERIFY/memories.
- Launched workstation tmux: `qrwatch` (QR babysitter, /tmp/qr_watch.log) and
  `sweep` (runs-file executor, /tmp/sweep_runner.log); ntfy topic in .env
  (https://ntfy.sh/$NTFY_TOPIC).
- v5e-64: apt-lock race killed startup on w2/w6 -> re-ran startup detached;
  hardened startup_script.sh with an apt retry loop. Fleet 16/16 ready.
- Per-device batch -> 4 (accum=1, single 524,288-token micro-batch, ~80% HBM
  target); removed the max(2,...) accum floor; VAL_MAX_BATCHES=25 keeps the
  6,400-row val subset at 256-row batches.
- v6e-8 LR sweep concluded (peak 0.02); multi-host port committed (0bd2763);
  first v5e-64 rendezvous failure diagnosed (stragglers) and fixed.

## 2026-07-20T05:24:27Z | feat/nanoGPTJAX@4208e18 | done | edit
created `/home/cataluna84/Workspace/llm-architectures/.claude/PROGRESS.md`


## 2026-07-20T05:24:34Z | feat/nanoGPTJAX@4208e18 | done | edit
created `/home/cataluna84/Workspace/llm-architectures/.claude/VERIFY.md`

