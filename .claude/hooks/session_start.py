#!/usr/bin/env python3
"""SessionStart hook: inject the four memory files, the right AGENTS.md
tier(s), and the orchestration control plane into Claude's context.

Line caps are deliberately tight: this payload is prepended to every session,
so each file gets only enough to orient, not its full contents.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from _lib import (  # noqa: E402
    PROJECT_DIR,
    PROGRESS_FILE,
    PLAN_FILE,
    VERIFY_FILE,
    MEMORIES_FILE,
    ORCHESTRATION_DIR,
    emit,
    find_relevant_subproject_agents,
    read_file_safe,
    read_input,
    git_branch,
    git_rev,
)


def main() -> None:
    data = read_input()
    cwd = data.get("cwd") or str(PROJECT_DIR)

    parts: list[str] = []
    parts.append(
        f"# Memory System Context\n"
        f"\nbranch: `{git_branch()}@{git_rev()}`  cwd: `{cwd}`\n"
    )

    root_agents = PROJECT_DIR / "AGENTS.md"
    if root_agents.exists():
        parts.append("## AGENTS.md (root)\n")
        parts.append(read_file_safe(root_agents, max_lines=200))

    sub = find_relevant_subproject_agents(cwd)
    if sub is not None:
        parts.append(f"\n## AGENTS.md ({sub.relative_to(PROJECT_DIR)})\n")
        parts.append(read_file_safe(sub, max_lines=200))

    parts.append("\n## PLAN.md (current goal)\n")
    parts.append(read_file_safe(PLAN_FILE, max_lines=120))

    parts.append("\n## PROGRESS.md (most recent)\n")
    parts.append(read_file_safe(PROGRESS_FILE, max_lines=80))

    parts.append("\n## VERIFY.md (done-criteria)\n")
    parts.append(read_file_safe(VERIFY_FILE, max_lines=80))

    parts.append("\n## memories.md (decisions and gotchas)\n")
    parts.append(read_file_safe(MEMORIES_FILE, max_lines=120))

    # Orchestration: surface ownership first, then the run-control invariants.
    # The full spec, playbook, and diagrams are read on demand via the
    # tpu-orchestrate skill rather than injected here.
    control_plane = ORCHESTRATION_DIR / "CONTROL_PLANE.md"
    if control_plane.exists():
        parts.append("\n## orchestration control plane\n")
        parts.append(read_file_safe(control_plane, max_lines=100))

    spec = ORCHESTRATION_DIR / "SPEC.md"
    if spec.exists():
        parts.append("\n## orchestration SPEC (run-control summary)\n")
        parts.append(read_file_safe(spec, max_lines=60))

    additional_context = "\n".join(parts).strip()

    emit({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": additional_context,
        },
        "suppressOutput": True,
    })


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
