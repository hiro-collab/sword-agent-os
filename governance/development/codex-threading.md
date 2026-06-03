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

## Distribution Pin Reporting

When a thread changes a nested checkout under `control-plane/` or `organs/`,
its handoff must state both:

- the nested checkout commit that was tested; and
- whether the parent `sword-agent-os` manifest pin was updated.

Use these labels in handoffs and coordination messages:

- `source-only`: nested repo work exists, but no parent manifest adoption was
  attempted.
- `ahead_of_manifest`: the local nested checkout is newer than the parent
  manifest pin; an adoption decision is still required.
- `manifest-adopted`: the parent manifest pin has been updated and
  `validate-manifests.ps1` passed.
- `distribution-proven`: strict pin check and the relevant install/readiness or
  smoke proof passed after adoption.

Do not use "done", "integrated", or "review-ready" by themselves for nested
repo work. Include the label, exact commit, and verification command output
summary so the manager and integration thread can tell whether the work is only
available in the active checkout or actually installable from the standard
distribution.
