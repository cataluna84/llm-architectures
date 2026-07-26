# Tier definitions

The escalation ladder. Lower tiers are less disruptive and preferred when the
failure mode is well understood.

**This table diverges from the tinyaya original at T3.** There, T3 was locked to
"always escalate — never auto-recreate the QR". Here T3 is automatic, because
spot preemption on TRC capacity is routine rather than exceptional, the quota is
free, and runs must survive unattended. See `../SPEC.md` §5.

| Tier | Action | Trigger | Auto? | Disruption |
|------|--------|---------|-------|------------|
| **T0** | Continue | All signals nominal; step lines advancing | yes | none |
| **T1** | Wait it out | Known-benign stall: XLA compile, shard-boundary validation pass, checkpoint write | yes | none |
| **T2** | Redeploy with patch | Classified, fixable error from the diagnosis table (config/env/code) | yes | ~1 min: tarball + relaunch `train` on all workers |
| **T3** | Recycle the queued resource | Node preempted, `SUSPENDED`/`FAILED`, or hosts unreachable | **yes — `qr_watch.sh`** | ~10-30 min: new spot acquisition, then boot self-heal resumes |
| **T4** | Stop and notify | Resubmit budget spent, quota-class abort, repeat classification, or unknown signature | n/a | indefinite — needs a human |

## Auto-escalation to T4

Stop and push a notification regardless of tier when:

1. The same classification fires twice consecutively (circuit breaker — the
   patch is not working and redeploying again just burns capacity).
2. `MAX_RESUBMITS` (20) is exhausted.
3. The QR failure is quota-class — resubmitting into a wall cannot succeed.
4. The failure signature is not in the diagnosis table.
5. A second resubmitter is detected for the same QR (see invariant below).

## Locked invariants

- **One resubmitter per QR, ever.** `qr_watch.sh` exits if the QR is absent
  rather than racing a human who is mid-recreate. Two resubmitters produce
  duplicate nodes and split-brain rendezvous.
- **T3 auto-recycle is bounded**, never unbounded. Budget plus cooldown is what
  separates self-healing from a flapping loop that burns a day of capacity.
- **T2 redeploys are only safe mid-run when checkpointing and resume are
  configured.** A redeploy kills `train` on every worker; without
  `SAVE_CKPT_DIR` + `NANOGPT_RESUME_FROM_STEP=auto` that discards progress.
- **T1 is a real tier, not a stalling tactic.** Most apparent hangs are a
  compile or a validation pass. Capture three step lines as evidence before
  escalating a throughput regression.

## Classification source

The signature → classification table is canonical in
`.claude/agents/tpu-diagnoser.md`. This file owns *policy* (what to do at each
tier); that file owns *detection* (which tier a log belongs to).
