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

## Development Restart Baseline

- Before resuming work from the clean rebuild, read `HANDOVER.md` and
  `docs/development-restart.md`. Revalidate the current manifests and pins;
  the recorded commit IDs are a reconstruction snapshot, not permission to
  ignore newer repository authority.
- Do not automatically adopt the unselected Control candidate, the deferred
  avatar service, legacy local assets, secrets, caches, or runtime evidence.
- Keep source inspection, focused tests, runtime reachability, browser-visible
  behavior, external observation, physical effects, and user acceptance as
  separate proof layers.
- Do not turn placeholder or mock responses into claims about provider-backed
  AI behavior.

## Codex Model Selection

- Follow `governance/development/codex-model-selection.md` for development and
  maintenance model selection. This is separate from Agent OS runtime model
  routing under `manifests/model-routing/`.
- Use `gpt-5.6-terra` with `medium` reasoning as the ordinary default. Use
  `gpt-5.6-luna` for deterministic high-volume work and `gpt-5.6-sol` for
  difficult cross-repository reasoning, architecture, diagnosis, or final
  synthesis.
- Choose reasoning effort independently. Reserve `max` for unresolved
  quality-first work and Codex `ultra` for work that divides cleanly into
  independent subagent scopes.
- A stronger model does not raise proof or decision authority. Source, runtime,
  device, publication, readiness, and final-acceptance evidence remain separate.
- If GPT-5.6 is unavailable, record the fallback and use the closest available
  capability tier without silently changing the task's proof ceiling.
- Keep persistent owner threads for durable responsibility and independent
  review context. Use subagents only for bounded temporary work; the parent
  thread remains responsible for scope, writes, evidence, and final synthesis.
- Preserve reviewer independence. Give Test-QA and security the controlling
  request, exact diff, canonical contracts and proof boundaries, and focused
  validation. Do not preload the author's reasoning, desired verdict, or another
  reviewer's conclusion before their first assessment.
- Run at most one write-heavy worker at a time across persistent owner sessions.
  Within one Codex root session, the project configuration caps that session's
  concurrently open agent threads at two and spawned nesting depth at one; it
  does not globally cap separately opened owner sessions. Reduce total active
  Codex work to one while the workstation is under sustained load.
