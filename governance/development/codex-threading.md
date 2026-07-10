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

## Model And Reasoning Selection

Choose the model from the task profile, not from the role name. The current
development defaults and escalation rules are defined in
`governance/development/codex-model-selection.md`.

- Ordinary scoped work starts with `gpt-5.6-terra` and `medium` reasoning.
- Mechanical inventory, exact searches, routine test execution, and summary
  extraction use `gpt-5.6-luna` with `low` or `medium` reasoning.
- Cross-repository architecture, conflicting evidence, hard diagnosis, and
  final integration synthesis use `gpt-5.6-sol` with `high` or `xhigh`
  reasoning.
- Use `max` only for a difficult quality-first problem that needs more work than
  `xhigh`. Use Codex `ultra` only when the work divides into independent,
  non-overlapping scopes that benefit from subagents.

When a task changes model or reasoning tier, record the short reason in the
task request or handoff. The model choice is execution metadata, not proof or
approval authority.

## Thread Start

Each thread should:

1. Read its role prompt.
2. Check active messages and blockers in the coordination repository.
3. Check reservations for files or areas it plans to edit.
4. Record its current worktree and area in the registry if needed.
5. Confirm that its model and reasoning tier fit the current task, and reduce
   or escalate them only for a concrete task reason.

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
