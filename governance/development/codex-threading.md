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

## Owner Threads And Subagents

Persistent owner threads and subagents serve different purposes.

- An owner thread keeps durable responsibility, current decisions, unresolved
  blockers, and the proof boundary for one area.
- A subagent is a short-lived worker for one bounded question, exact path set,
  test slice, or read-heavy investigation. It does not become a second owner.
- The parent thread defines the scope, decides whether writes are allowed,
  validates the returned evidence, and owns the final synthesis.
- Close completed or failed subagents after their result is folded. Do not keep
  idle subagents as standing roles.
- Do not let subagents spawn further subagents. Recursive fan-out makes resource
  use and review provenance harder to predict.

Use subagents when work is independent and disjoint, especially for source
inventory, focused tests, documentation lookup, or separate review dimensions.
Keep write-heavy implementation sequential. A verified disjoint checkout and
integration order is still required for any handoff between write owners, but
does not raise the one-write-heavy-worker limit.

## Independent Review Context

Thread separation is also a bias-control boundary. A reviewer should be able to
reach an initial conclusion without inheriting the implementation thread's
assumptions or desired result.

The first Test-QA or security review packet should contain only the smallest
complete evidence set:

- the controlling user or manager request;
- the exact path set and current diff;
- canonical contracts, policies, proof vocabulary, and publication boundaries;
- focused validation results and known environmental limitations;
- the requested review classification and proof ceiling.

Do not preload the implementation conversation, speculative diagnosis, desired
verdict, or another reviewer's conclusion. After each reviewer records an
independent first assessment, integration may compare findings, resolve
disagreements, and route a same-scope repair or rerun. A review performed by the
authoring thread is useful self-review, but it must not be labeled independent.

Context intake is role-specific:

- implementation owners read the current task, directly relevant source,
  contracts, tests, and collision state;
- Test-QA and security read the frozen review packet and canonical authorities,
  then expand only when a concrete finding requires it;
- integration-management reads the current-state table, owner results, and
  independent review returns, using raw history only to resolve a named conflict;
- coordination administration reads the current-state table and direct delivery
  gaps, not the full implementation history.

Historical messages and handoffs remain evidence. They are not routine startup
context and must not silently override current authority.

## Concurrency And Workstation Load

Within one Codex root session, the project-local configuration caps that
session's concurrently open agent threads at two and keeps spawned nesting depth
at one. It does not globally cap separately opened persistent owner sessions;
the cooperative operational limits below apply across those sessions:

- normal mode: one write-heavy worker plus at most one read-only reviewer;
- high-load mode: one active Codex worker in total;
- build, test, browser, sandbox setup, Git maintenance, and generated-file scans:
  one heavy local operation at a time;
- review workstation load at worker completion or about every five minutes, not
  with a high-frequency polling loop.

Enter high-load mode when workstation interaction becomes visibly delayed or
CPU-intensive local tools remain saturated. Return to normal mode only after two
consecutive observations show that the heavy local operation has settled.
Do not stop unrelated user applications as an automatic load-control action.

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
