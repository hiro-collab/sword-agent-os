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

