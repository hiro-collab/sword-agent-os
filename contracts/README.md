# Agent OS Contracts

This directory holds language-neutral contracts for module boundaries.

Contracts are the first authority for data exchanged between organs, runtime
services, adapters, drivers, and display clients. Implementations may be
Python, TypeScript, Go, Rust, C#, or another language, but they should validate
against these shapes at the boundary.

## v0 Contracts

- `action_request/action_request.v0.schema.json`: unified request shape for
  thought, reflex, GUI-derived, system, and test-origin actions.
- `event_ingest/event_ingest.v0.schema.json`: state/event ingest envelope used
  before writing to event journal or status store.
- `status_patch/status_patch.v0.schema.json`: normalized current-state patch.
- `body_plan/body_plan.v0.schema.json`: static body plan and organism identity.
- `driver_manifest/driver_manifest.v0.schema.json`: driver capabilities,
  action declarations, risk class defaults, and dummy/real separation.
- `body_schema_snapshot/body_schema_snapshot.v0.schema.json`: current self-body
  snapshot derived from Body Plan and current state.
- `body_display_projection/body_display_projection.v0.schema.json`: display-safe
  projection frames for projector/background/display clients.

## Rules

- New runtime code should depend on canonical contract names, not legacy service
  labels.
- Legacy names belong in compatibility aliases, not in primary ids.
- Contracts should avoid local paths, secrets, raw logs, raw prompts, raw media,
  or unredacted user content.
- v0 uses full frames for display projection; delta frames are reserved by the
  schema for future use.
