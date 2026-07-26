# Diagnosis table — pointer

**The canonical failure-signature table lives in
`.claude/agents/tpu-diagnoser.md`.**

It is deliberately not duplicated here. tinyaya carried the table in both its
playbook and its diagnoser agent, and the two drifted. One copy, in the file the
agent actually reads at runtime.

- **Detection** (signature → classification) → `.claude/agents/tpu-diagnoser.md`
- **Policy** (classification → what to do) → `tier-definitions.md`
- **Recovery mechanics** (how each action is performed) → `../SPEC.md` §4-5

## Adding a signature

1. Add the row to `.claude/agents/tpu-diagnoser.md`: signature, root cause,
   action, tier.
2. If it needs a tier that doesn't exist, update `tier-definitions.md` first.
3. If the fix is structural rather than operational, record the decision in
   `.claude/memories.md` so the next session doesn't rediscover it.
4. Prefer a signature that matches the *cause* over one that matches a
   downstream symptom. The multi-host `DEADLINE_EXCEEDED` rendezvous failure was
   really an apt/dpkg lock race on two workers; matching the rendezvous error
   alone sent us looking at JAX for an hour.
