# VERIFY.md — done-criteria (fenced bash blocks are runnable checks)

Fast, side-effect-free checks only (the Stop hook may run these).

Lint clean:

```bash
cd "$CLAUDE_PROJECT_DIR" && uv run ruff check nanogpt/*.py
```

Orchestration scripts parse:

```bash
cd "$CLAUDE_PROJECT_DIR" && for f in scripts/tpu/*.sh; do bash -n "$f" || exit 1; done && echo scripts-ok
```

Hooks import:

```bash
cd "$CLAUDE_PROJECT_DIR" && python3 -c "
import sys; sys.path.insert(0, '.claude/hooks')
import _lib, session_start, session_end, user_prompt_submit, post_tool_use, pre_compact, stop
print('hooks-ok')"
```

tmux orchestration alive (informational — passes even when sessions are
intentionally down):

```bash
tmux ls 2>/dev/null | grep -E 'qrwatch|sweep' || echo "no orchestration sessions (ok if no run active)"
```

Orchestration docs present and cross-references resolve (the diagnosis table is
canonical in the agent; the playbook must only point at it):

```bash
cd "$CLAUDE_PROJECT_DIR" && \
for f in .claude/orchestration/{README,CONTROL_PLANE,SPEC}.md \
         .claude/orchestration/playbook/{tier-definitions,diagnosis-table,event-taxonomy,perf-metrics-schema,baseline-v5e64}.md \
         .claude/agents/tpu-diagnoser.md .claude/skills/tpu-redeploy/SKILL.md; do
    [ -f "$f" ] || { echo "MISSING: $f"; exit 1; }
done && echo orchestration-docs-ok
```

Completion probe reads status markers from the tail, never `head` (the
2026-07-20 watcher-blindness bug — a repeating `Best loss` line pushed the exit
marker out of a bounded `head`):

```bash
cd "$CLAUDE_PROJECT_DIR" && \
if grep -nE "grep -E '.*(Best loss|exited).*' \| head" scripts/tpu/sweep_runner.sh; then
    echo "REGRESSION: probe truncates with head"; exit 1
fi && echo probe-ok
```

Run invariants stated in the runs files (tokens/step and the val subset must
stay comparable across slices):

```bash
cd "$CLAUDE_PROJECT_DIR" && python3 - <<'PY'
import glob, re, sys
bad = []
for path in glob.glob("scripts/tpu/runs/*.runs"):
    for n, line in enumerate(open(path), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        env = dict(re.findall(r"(\w+)=(\S+)", line))
        bsz = int(env.get("PER_DEVICE_BATCH_SIZE", 0))
        vmb = int(env.get("NANOGPT_VAL_MAX_BATCHES", 0))
        if not bsz:
            continue
        chips = 64  # v5e-64 runs files
        rows = bsz * chips
        if rows * 2048 != 524288:
            bad.append(f"{path}:{n} tokens/step={rows*2048} != 524288")
        if vmb and vmb * rows != 6400:
            bad.append(f"{path}:{n} val rows={vmb*rows} != 6400")
print("\n".join(bad) if bad else "run-invariants-ok")
sys.exit(1 if bad else 0)
PY
```
