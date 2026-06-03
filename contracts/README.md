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
- `motion_stimulus/motion_stimulus.v0.schema.json`: source-static avatar/body
  motion stimulus shape for user/GUI, Thought Core contextual, and
  Reflex-forwarded movement requests.
  - Examples:
    `motion_stimulus/examples/rr003-user-command-stimulus.example.json`,
    `motion_stimulus/examples/rr003-thought-context-stimulus.example.json`,
    `motion_stimulus/examples/rr003-reflex-forwarded-stimulus.example.json`
- `motion_mixer_snapshot/motion_mixer_snapshot.v0.schema.json`: safe current
  Motion Mixer snapshot, track ownership, abstract body-state summary, and
  Status Store projection keys.
  - Example:
    `motion_mixer_snapshot/examples/rr003-mixer-playing.example.json`
- `motion_driver_result/motion_driver_result.v0.schema.json`: safe driver
  feedback/result shape for applied, degraded, unavailable, incompatible,
  fallback, stopped, and failed-safe avatar motion outcomes.
  - Example:
    `motion_driver_result/examples/rr003-driver-degraded.example.json`

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
- RR003 motion contracts use safe ids, safe display labels, bounded telemetry,
  redaction/shareability fields, and status references. They must not expose raw
  media, prompts, transcripts, provider payloads, local paths, raw filenames,
  private endpoints, secrets, full debug logs, or Home Assistant/appliance
  action routes for avatar motion.
