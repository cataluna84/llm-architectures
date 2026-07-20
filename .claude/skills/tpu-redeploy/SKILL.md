---
name: tpu-redeploy
description: Push the local working tree to a live TPU slice and relaunch training, without recreating the queued resource. Use when applying a code or config patch to an already-ACTIVE node, or when a run must be restarted with different env. Covers the multi-host fan-out and the mid-run safety rules.
---

# Redeploy to a live TPU slice

Encodes `scripts/tpu/deploy_tarball.sh`. This is the **T2** action in
`.claude/orchestration/playbook/tier-definitions.md` — code/config fix on
hardware that is still healthy. It never touches the queued resource; if the
node itself is gone, that is T3 and `qr_watch.sh` owns it.

## What it does

1. Tars the local working tree — **including the gitignored `.env`**, which is
   how `WANDB_API_KEY` and `NTFY_TOPIC` reach the VM. A git-clone deploy cannot
   ship it, which is why this repo never clones.
2. Uploads to `gs://$BUCKET/$CODE_PREFIX/` (stamped plus a `latest.tar.gz`).
3. Pulls and extracts over `$REPO_DIR` on the VM, preserving `.venv` and the
   staged `fineweb10B/` shards.
4. `uv sync --extra jaxtpu`, stages any missing FineWeb shards.
5. Kills and relaunches tmux session `train`, logging to `/tmp/train.log`,
   with a unique `RUN_TAG` baked into the launch line.

## Invocation

```bash
TOTAL_TRAIN_STEPS=1000 PER_DEVICE_BATCH_SIZE=4 DATA_SHARDS=60 \
NANOGPT_VAL_MAX_BATCHES=25 NANOGPT_DEVICE_PEAK_FLOPS=197e12 \
WANDB_RUN_NAME=my-run ZONE=europe-west4-b NODE_ID=nanogpt-v5e64 \
bash scripts/tpu/deploy_tarball.sh
```

Configuration precedence is shell env > repo-root `.env` > script defaults.
Defaults target v6e-8; **v5e-64 requires `ZONE`, `NODE_ID`, and
`NANOGPT_DEVICE_PEAK_FLOPS=197e12`** or the MFU metric silently uses the v6e
peak and reads ~4.7× too low.

## Multi-host rules (v5e-64 = 16 hosts × 4 chips)

- The deploy fans out with `--worker=all`. **Every** host must relaunch, because
  `jax.distributed` performs a rendezvous across all 16 — a partial relaunch
  hangs the survivors until they time out with `DEADLINE_EXCEEDED`.
- Deploying before the fleet is ready produces the same rendezvous failure.
  Gate on all workers reporting `startup_script.sh complete` in
  `/tmp/startup.log`; `sweep_runner.sh` already does this.
- If a worker is missing that marker, re-run its startup **detached**
  (`nohup … &` or tmux) — never as a foreground ssh with a timeout.

## Mid-run safety

A redeploy kills `train` on every worker. That is only safe if the run can pick
up where it left off:

- `SAVE_CKPT_DIR` set (otherwise nothing was ever written)
- `NANOGPT_RESUME_FROM_STEP=auto` (scans for the latest saved step)
- `WANDB_RUN_ID` fixed (otherwise the resumed run forks a second W&B entry)

Without all three, redeploying mid-run discards progress. Check before acting.

## Gotchas

- **A killed `gcloud ssh` does not kill the remote command.** A local `timeout`
  on ssh orphans the process on the VM. Long remote operations go in detached
  tmux with a liveness check.
- **Never pipe a critical deploy step through `head`** — SIGPIPE kills it
  mid-work.
- `which uv` is empty under sudo; use `/root/.local/bin/uv`.
- Empty `WANDB_*` exports break `wandb.init` outright ("Run ID cannot be
  empty"), so the launcher exports them only when non-empty.

## After deploying

Watch the tag-scoped segment of `/tmp/train.log` on worker 0 — not the whole
file, which still holds every previous run. Scope with the `RUN_TAG` from the
launch line, and read status markers from the **tail**; a `head -N` on output
that also contains repeating `Best loss` lines will hide the exit marker
behind them.
