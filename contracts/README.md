# Agent OS Contracts

This directory holds language-neutral contracts for module boundaries.

Contracts are the first authority for data exchanged between organs, runtime
services, adapters, drivers, and display clients. Implementations may be
Python, TypeScript, Go, Rust, C#, or another language, but they should validate
against these shapes at the boundary.

## v2 Contracts

- `overall_test_ladder_report/overall_test_ladder_report.v2.schema.json`:
  source/static shared report shape for the overall test ladder v2 daily
  confidence smoke and related local readiness summaries. It is a report
  contract, not a broad runner implementation or readiness verdict. Each row
  carries its layer, proof ceiling, class/count/bucket-only evidence summary,
  bounded counts, opaque safe refs, next action class, non-claims, and
  `raw_private_publication_flags=false`. `pass_candidate` is explicitly not an
  RR003 pass, final readiness, release readiness, or proof upgrade. If a layer
  can only prove itself by publishing raw transcripts, raw audio/media,
  screenshots/browser frames, TouchDesigner content, provider payloads, Home
  Assistant raw payloads, entity/device ids, private paths/filenames/URLs,
  exact env values, stdout/stderr/stack traces, tokens, or secrets, the shared
  report must be blocked instead of published.
  - Examples:
    `overall_test_ladder_report/examples/daily_confidence_smoke.held.example.json`,
    `overall_test_ladder_report/examples/local_operator_readiness.blocked.example.json`,
    `overall_test_ladder_report/examples/rr003_readiness_candidate.not_claimed.example.json`

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
- `redacted_turn_input/redacted_turn_input.v0.schema.json`: compact,
  redacted voice/input handoff summary for source-static and source-no-live
  proof rows. It carries gate state, STT presence/finality metadata, handoff
  refs, Thought Core turn completion refs, safety flags, and non-claims without
  embedding raw transcripts, raw audio, provider payloads, local paths, action
  proof, motion proof, or ordinary conversation quality proof.
  - Example:
    `redacted_turn_input/examples/source_no_live.example.json`
- `audio_awareness_summary/audio_awareness_summary.v0.schema.json`:
  summary-only hearing/audio awareness packet for `pc_output`, `microphone`,
  and speech-input VAD adapter metadata. Source/static packets keep live capture,
  provider/network STT/TTS, raw audio, full transcripts, command authority,
  browser-visible audio authority, user-heard proof, and physical/device proof
  out of scope. The v0 source/static path keeps self-output, playback, and
  transcript summary refs null; self-output STT/adoption-block observations use
  `audio_self_output_observation.v0` instead.
  - Example:
    `audio_awareness_summary/examples/pc-output-voicevox-correlated.example.json`
- `audio_self_output_observation/audio_self_output_observation.v0.schema.json`:
  source/static self-output observation and adoption-gate boundary shape. It
  records that recognized system speech is held as `system_self_output`, cannot
  materialize a normal Thought Core `TurnInput`, carries no shared transcript
  refs, and keeps runtime audio capture, provider STT, raw audio/transcripts,
  user intent, command authority, source adoption, and release/readiness proof
  out of scope. Local-sample recognition summaries are class/bucket-only:
  source labels, recognized-text class, confidence/language buckets, and STT
  window class may be recorded, but raw transcript text, private paths, media
  filenames, browser storage keys, provider payloads, and command authority are
  not part of the shared shape.
  - Example:
    `audio_self_output_observation/examples/source_static_self_output_blocked.example.json`
- `local_offline_recognizer_redacted_adapter/local_offline_recognizer_redacted_adapter.v0.schema.json`:
  source/static preflight and refusal boundary for any future local/offline
  recognizer adapter. It is a mechanical filter/redaction contract, not a user
  intent, command, Thought Core adoption, or Home Control authority contract.
  It accepts opaque stable local media ids only, such as non-semantic
  `voice.local_sample_001` labels; shared `source_label` values must not encode
  transcript text, recognized text, command text, private filenames, paths,
  provider ids, browser storage keys, device ids, tokens, or secrets. The
  adapter requires redaction before shared artifacts, fails closed when a
  recognizer needs model download, provider/cloud/browser STT, playback/capture,
  transcript-oriented output, raw text exposure, private metadata exposure, or
  direct turn creation by the adapter, and limits pass-candidate output to
  class/bucket/opaque-ref summaries. It performs no recognition, publishes no
  raw transcripts/audio/paths, creates no normal Thought Core `TurnInput` by
  itself, and authorizes no Home Control, source/Git adoption, or RR003
  readiness. Later delivery of a redacted speech observation to Thought Core is
  a separate input-gate / Thought Core route, not this adapter's semantic
  decision.
  - Example:
    `local_offline_recognizer_redacted_adapter/examples/source_static_pass_candidate.example.json`
- `local_offline_recognizer_execution_wrapper/local_offline_recognizer_execution_wrapper.v0.schema.json`:
  source/static execution-wrapper boundary for a future local/offline recognizer
  runner. It exists one layer before any recognition dry-run and proves, by
  classed fixtures only, that transcript-like runner output, literal handoff
  text, private paths/filenames, provider/cloud/browser STT, model downloads,
  microphone or PC-output capture, playback, and direct Thought Core turn
  materialization are blocked before runner invocation. The wrapper may only
  hand class/bucket/opaque-ref summaries to
  `local_offline_recognizer_redacted_adapter.v0`; it performs no audio decoding,
  recognition, playback, capture, model download, provider/browser/cloud STT,
  Thought Core `TurnInput` creation, Home Control action, source/Git adoption,
  or readiness proof.
  - Example:
    `local_offline_recognizer_execution_wrapper/examples/source_static_cases.example.json`
- `audio_awareness_consumer_routes/audio_awareness_consumer_routes.v0.schema.json`:
  machine-readable route map for source/static audio-awareness consumers. It
  points readers to the hearing organ scaffold, runtime helper, result
  contract, stop conditions, and non-claims without authorizing live capture.
- `gesture_gate_summary/gesture_gate_summary.v0.schema.json`: compact,
  redacted gesture gate case summary for source-static and source-no-live proof
  rows. It keeps positive/negative gesture-gate outcomes, accepted activation
  candidate state, the `victory_false_open` known limitation, robust-gate false
  status, redaction flags, and non-claims separate from STT, Thought Core
  completion, action/Home Control, motion/expression, browser/runtime, live
  camera/audio, source adoption, Git, readiness, or RR003 pass.
  - Example:
    `gesture_gate_summary/examples/source_no_live_cases.example.json`
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
    `motion_stimulus/examples/rr003-reflex-forwarded-stimulus.example.json`,
    `motion_stimulus/examples/rr003-action-indicator-stimulus.example.json`
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
- `vrm_model_telemetry/vrm_model_telemetry.v0.schema.json`: summary-only,
  graph-ready VRM model-state telemetry for expression weights and safe
  rig/track state over time. It helps diagnose subtle expression changes that
  may be too small for image-based Self Mirror ROI checks, but it is not
  browser-visible, semantic, physical/projector, release/readiness, or final
  RR003 proof.
  - Example:
    `vrm_model_telemetry/examples/rr003-expression-full-relaxed.telemetry.example.json`
  - Bone/basis example:
    `vrm_model_telemetry/examples/rr003-bone-baseline.telemetry.example.json`
- `vrm_model_telemetry_consumer_routes/vrm_model_telemetry_consumer_routes.v0.schema.json`:
  machine-readable discovery map for the VRM Model Telemetry module. It points
  readers to the module boundary, organ scaffold, result contract, result
  authority file, proof ceiling, stop conditions, and non-claims. It is not
  execution authority or Self Mirror authority.
- `motion_trace_event/motion_trace_event.v0.schema.json`: redacted motion
  lifecycle / perception feedback event shape for State/Event Ingest, Event
  Journal summaries, Status Store source refs, and later memory candidates.
  - Example:
    `motion_trace_event/examples/rr003-motion-trace-feedback.example.json`
- `motion_memory_candidate/motion_memory_candidate.v0.schema.json`: candidate
  boundary for repeated motion mismatches, explicit corrections, stable
  mappings, and body/catalog learning. This is not a durable Memory Core
  storage row and defaults to `safe_to_act=false`.
  - Example:
    `motion_memory_candidate/examples/rr003-repeated-mismatch-candidate.example.json`
- `visual_motion_analysis/visual_motion_analysis.v0.schema.json`: visual motion
  analyzer input/result boundary for redacted ROI/time-window analysis.
  - Examples:
    `visual_motion_analysis/examples/rr003-smile-visual-motion.example.json`,
    `visual_motion_analysis/examples/rr003-idle-reset-visual-motion.example.json`
- `self_mirror_metric_summary/self_mirror_metric_summary.v0.schema.json`:
  reader-safe Self Mirror result authority packet for Thought Core,
  diagnostics, review agents, and status summaries. It keeps retry hints,
  latest state, observation queue, diagnostics, raw-media flags, and non-claims
  separate from command authority.
  - Example:
    `self_mirror_metric_summary/examples/context_nod.summary.example.json`
- `self_mirror_consumer_routes/self_mirror_consumer_routes.v0.schema.json`:
  machine-readable discovery map for Self Mirror consumer routes. It points
  readers to supported scenarios, result authority, proof ceilings, stop
  conditions, and non-claims. It is not execution authority.
- `self_mirror_reference_case/self_mirror_reference_case.v0.schema.json`:
  redacted calibration/reference case shape for Self Mirror automatic judgment.
  - Example:
    `self_mirror_reference_case/examples/dance_visible_motion.reference.example.json`
- `self_mirror_auto_judgment_profile/self_mirror_auto_judgment_profile.v0.schema.json`:
  scenario-specific automatic judgment threshold/reference profile for Self
  Mirror summaries.
  - Example:
    `self_mirror_auto_judgment_profile/examples/dance_visible_motion.profile.example.json`

## Rules

- New runtime code should depend on canonical contract names, not legacy service
  labels.
- New values that Thought Core, diagnostics, review agents, or source code read
  should follow `docs/reference-surfaces.md`: schema in `contracts/`, concrete
  owner-local surface with `schema_version` and `contract_ref`, then code
  reader.
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
- VRM model telemetry may show that runtime/model state changed, including
  expression weights or bucketed rig-track changes. It must not be used as Self
  Mirror pass, expression-visible pass, semantic expression correctness,
  physical/projector proof, ROI/threshold authority, command authority, or
  release/readiness/final RR003 approval.
- VRM bone/basis telemetry must stay opt-in, off by default, bounded,
  summary-first, and based on relative monotonic elapsed timing. Shared output
  should use normalized/shared pose or bucket classes, not raw BVH, full
  skeleton dumps, raw per-frame transforms/quaternions, raw poses, rest poses,
  raw node names, model asset names, private paths, or unbounded append
  captures.
- RR003 `action_indicator` motion exists to show what the avatar/agent is
  operating or attending to, such as pointing toward a display-safe appliance
  target during action execution or feedback checking. It may reference safe
  topology ids and action request ids, but it must not become an action
  execution path or leak raw Home Assistant entity/service details.
- Motion trace and motion memory candidate records must keep freshness,
  staleness, repetition, evidence, retention, redaction, erasure, and
  `safe_to_act` semantics explicit. Memory packets / suggestions are retrieval
  outputs for Thought Core; they are not the same object as durable storage rows.
