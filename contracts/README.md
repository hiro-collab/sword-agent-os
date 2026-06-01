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
- `environment_evidence_packet/environment_evidence_packet.v0.schema.json`:
  compact, redacted current-environment evidence packet for Thought Core,
  diagnostics, Action Boundary, and tests. It preserves source layers,
  conflicts, policy-switch operation references, and confirmation-loop limits
  without embedding raw Home Assistant payloads, camera frames, prompts, or
  local paths.
  - Example:
    `environment_evidence_packet/examples/rr001-home-assistant-camera-conflict.example.json`
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
- Environment evidence packet `subject` values must be stable redacted labels
  using lowercase letters, digits, `_`, `.`, or `-`. Do not put drive-letter
  paths, UNC paths, home-directory paths, URLs, raw room/device names, or slash /
  backslash separators in `subject` or `scope.subjects`.
- Thought Core should consume compact environment evidence packets instead of
  raw Home Assistant/camera dumps when reasoning about current state.
- Policy switches that choose between conflicting source layers must be explicit
  and traceable through an operation/event reference.
- Confirmation loops for home actions must not silently re-operate. The RR-001
  v0 limit is one appliance operation, at most two post-operation state checks,
  and zero automatic re-operation attempts.
- v0 uses full frames for display projection; delta frames are reserved by the
  schema for future use.
