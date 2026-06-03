# Agent OS Codex Instructions

This repository is the source of truth for Sword Agent OS.

## Scope

- Treat legacy `sword-agent-system` and `sword-voice-agent` repositories as
  reference sources only unless the user explicitly asks to edit them.
- Keep runtime safety policies separate from development governance.
- Keep development coordination state outside this repository, under the
  workspace-level coordination repository.

## Development Rules

- Prefer small, scoped changes.
- Do not add secrets, local paths, raw logs, screenshots, audio captures, or
  unredacted user content to tracked files.
- Put durable design decisions in `governance/`, `manifests/`, or `policies/`.
- Put temporary coordination, handoffs, reservations, and thread messages in
  the private coordination repository, not in this repository.
- When working in a secondary worktree, check coordination messages and
  reservations before editing shared manifests, policies, runtime structure, or
  standard profiles.
- Treat nested checkout commits and parent manifest pins as separate adoption
  states. A nested repo can be correct and still be only "ahead of manifest"
  until the parent manifest pin is updated and verified.
- Before claiming a standard distribution change is review-ready or
  push-ready, run the relevant focused tests and include distribution pin
  evidence. Use `scripts/doctor-distribution.ps1 -Profile standard` for the
  broad local diagnosis, and use
  `scripts/check-distribution-pins.ps1 -Profile standard -Strict` before
  release, fresh-install, or review gates.
- Do not classify Git `dubious ownership`, sandbox access failures, or uv cache
  access failures as source mismatches. Re-run the same diagnosis as the normal
  workspace user or with an exact per-command override, then report the real
  source-pin state.
