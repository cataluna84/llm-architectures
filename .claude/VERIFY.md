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
