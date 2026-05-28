# Codex Threading

Sword Agent OS development uses multiple Codex threads with separated
worktrees.

## Default Shape

- One thread normally owns one area.
- A central implementation thread may integrate cross-area changes.
- Cross-area edits are allowed when practical, but they must be visible in the
  coordination repository.
- Changes to standard profiles, manifests, policies, runtime structure, and
  repository boundaries should usually go through the central implementation
  thread.

## Thread Start

Each thread should:

1. Read its role prompt.
2. Check active messages and blockers in the coordination repository.
3. Check reservations for files or areas it plans to edit.
4. Record its current worktree and area in the registry if needed.

## Thread Finish

Each thread should leave a handoff when work is incomplete or relevant to other
threads. Include changed areas, verification performed, open questions, and any
out-of-area edits.

