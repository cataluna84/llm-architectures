# Event taxonomy (ntfy push)

Replaces tinyaya's blocking `AskUser` check-in protocol at T+15/30/45/60/90 min.
Nothing here blocks: events are pushed to `https://ntfy.sh/$NTFY_TOPIC` (topic in
the gitignored `.env`) and read whenever the human gets to them.

Emitted via `notify()` in `scripts/tpu/_lib.sh`, which is a no-op when
`NTFY_TOPIC` is unset — so call sites stay unconditional.

## Events

| Source | Event | When | Why it matters |
|---|---|---|---|
| `qr_watch` | `QR state changed` | QR leaves `ACTIVE` | First warning that capacity was lost |
| `qr_watch` | `resubmitted (n/20)` | after a recycle | Confirms self-heal fired; the counter is the flap signal |
| `qr_watch` | `quota abort` | quota-class failure | Resubmitting cannot help — needs a human |
| `qr_watch` | `budget exhausted` | 20 resubmits spent | Run is stopped, capacity is gone |
| `qr_watch` | heartbeat | every 2h | Proves the watcher itself is alive |
| `sweep_runner` | `starting (N runs)` | runner boot | Sweep accepted the runs file |
| `sweep_runner` | `fleet ready` | all workers report startup complete | Rendezvous prerequisites met |
| `sweep_runner` | `run #N OK — Best loss …` | clean exit | The result, without opening W&B |
| `sweep_runner` | `run #N failed` | dirty exit | Sweep aborted; fleet needs a look |
| `sweep_runner` | `SWEEP COMPLETE` | last run done | Slice is now idle — schedule the next thing |

## Design rules

1. **Every event carries its outcome, not just its occurrence.** `run #3 OK —
   Best loss 3.5952 at step 905` is actionable on a phone screen; `run #3
   finished` forces a laptop.
2. **A silent watcher is indistinguishable from a dead one**, hence the 2h
   heartbeat. Absence of failure events is not evidence of health.
3. **Never push per-step or per-interval progress.** Metrics belong on W&B; ntfy
   is for state transitions only. A noisy topic gets muted, and a muted topic is
   worse than no topic.
4. **Terminal events say what is now idle.** The expensive mistake is a 64-chip
   slice sitting unused because nobody knew a sweep ended.

## Where to look when an event arrives

| Event | First thing to open |
|---|---|
| any `qr_watch` failure | `/tmp/qr_watch.log` |
| `run #N failed` | worker 0 `/tmp/train.log`, then `tpu-diagnoser` |
| `SWEEP COMPLETE` | https://wandb.ai/cataluna84/llm-architectures |
| heartbeat gap > 2h | `tmux ls` on the workstation, then `df -h` |
