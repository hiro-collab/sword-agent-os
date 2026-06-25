# Reference Surfaces

<!-- reference-surfaces:overview -->

A reference surface is a small, contracted reader-facing object that product
code, Thought Core, diagnostics, or review tools can use to understand what a
feature can read, run, or interpret. It is not a chat note, README-only table,
private coordination packet, raw log, or hidden generated file.

Use this page when a developer wants to add a new value that source code or
system readers can reference later.

## What Counts

| Need | Preferred shape | Example |
| --- | --- | --- |
| Result authority packet | `contracts/<name>/<name>.v0.schema.json` plus generated/read output | `self_mirror_metric_summary.v0` |
| Route or discovery map | owner-local JSON with `$schema`, `schema_version`, and `contract_ref` | `runtime/visual-motion-analyzer/self-mirror-consumer-routes.json` |
| Current-state projection | `runtime/status-store/` projection with event/evidence refs | body/current environment status |
| Historical/event handoff | `event_ingest.v0` or event-journal summary | normalized observation event |
| Static selection | `manifests/` or template/config source with redacted examples | standard distribution organ pin |

If another component will read it, give it a contract or point it to an
existing contract. If only humans read it, keep it in docs or a starter profile.

## Add A New Reference Surface

<!-- reference-surfaces:add-new-reference -->

Use this checklist before adding source code that reads a new value:

1. Name the owner plane in `docs/architecture.md`: front door, configuration,
   runtime control, proof/verification, module/organ, or coordination.
2. Name the consumers: Thought Core, Action Boundary, diagnostics, status
   store, event journal, review agents, human operators, or a specific organ.
3. Create or reuse a contract under `contracts/<name>/<name>.v0.schema.json`.
   The contract must define `schema_version`, reader intent, required fields,
   redaction flags, non-claims, and whether it is command authority.
4. Put the actual reader surface under the owning implementation area, not in
   coordination. For JSON maps, include `$schema`, `schema_version`, and
   `contract_ref`.
5. Link a human entrypoint when operators need one, such as a starter profile or
   how-to doc. The human doc explains the journey; the contract defines what
   code can rely on.
6. Add the smallest maintenance assertion that prevents drift: path present,
   contract listed, `contract_ref` present, critical boundary booleans, and key
   non-claims.
7. Validate the exact path set with `git diff --check` and
   `scripts/test-distribution-maintenance.ps1 -SkipFreshClone`.

Do not make a new reference value by copying raw local paths, raw logs, private
Home Assistant ids, raw screenshots, transcripts, provider payloads, or
generated local config into tracked files.

## Thought Core Consumption

<!-- reference-surfaces:thought-core-consumption -->

Thought Core may consume contracted reference surfaces as compact context. It
must not treat them as execution authority unless the contract explicitly routes
through `action_request.v0`, Action Boundary, and the selected driver.

Rules for Thought Core and similar system readers:

- read contracted packets, route maps, or status projections;
- prefer `contract_ref` and `schema_version` over path-name guessing;
- use result authority packets for proof claims, not supporting charts or logs;
- keep retry, correction, issue closure, and release/readiness authority outside
  observation-only surfaces;
- stop if the only way to explain a value is to expose raw media, raw prompts,
  private paths, secrets, provider payloads, or raw Home Assistant identifiers.

## Self Mirror Example

<!-- reference-surfaces:self-mirror-example -->

Self Mirror now uses two related reference surfaces:

- `contracts/self_mirror_consumer_routes/self_mirror_consumer_routes.v0.schema.json`
  defines the route/discovery map that Thought Core, diagnostics, review agents,
  and operators may read.
- `runtime/visual-motion-analyzer/self-mirror-consumer-routes.json` is the
  owner-local route map. It carries `$schema`, `schema_version`, and
  `contract_ref`, points to the starter profile, names supported scenarios,
  names `self_mirror_metric_summary.json` as the result authority, and keeps
  observation-only boundaries explicit.
- `contracts/self_mirror_metric_summary/self_mirror_metric_summary.v0.schema.json`
  defines the result authority packet. This is the packet to use for proof
  wording after a Self Mirror run.

The route map helps a reader choose and interpret Self Mirror checks. It does
not dispatch correction, run another route, close an issue, claim release
readiness, or prove physical projector output.

## VRM Model Telemetry Example

<!-- reference-surfaces:vrm-model-telemetry-example -->

VRM model telemetry is a model-state reference surface for subtle expression
and rig-track diagnostics:

- `contracts/vrm_model_telemetry_consumer_routes/vrm_model_telemetry_consumer_routes.v0.schema.json`
  defines the discovery map for the VRM Model Telemetry module.
- `runtime/vrm-model-telemetry/vrm-model-telemetry-consumer-routes.json` is the
  owner-local route map. It carries `$schema`, `schema_version`, and
  `contract_ref`, points to the module README, names the expression organ
  scaffold, and keeps model-state-only boundaries explicit.
- `contracts/vrm_model_telemetry/vrm_model_telemetry.v0.schema.json` defines
  the result packet.
- Example output lives under
  `contracts/vrm_model_telemetry/examples/rr003-expression-full-relaxed.telemetry.example.json`.
- The proof ceiling is `runtime_model_state_telemetry_summary_only`.

This surface is useful when Self Mirror image detection is too weak for a small
facial change. It can say that expression weights or safe rig-track buckets
changed over time. It cannot say that the browser visibly changed, that the
expression was semantically correct, that the physical display/projector showed
the effect, or that ROI/thresholds should be changed.

Bone/basis telemetry stays inside this same VRM Model Telemetry surface. A
future recorder should be opt-in and should publish a summary packet with
relative monotonic timing, `t0_event`, trigger offset, baseline/window map,
stop reason, cadence/cap fields, normalized/shared pose class, allow-listed
tracks, and redaction/non-claim flags. Detailed per-frame transforms,
quaternions, raw poses, BVH/full-skeleton dumps, rest poses, raw node names,
and model asset names are not public reference surfaces.

When `vrm_model_telemetry_summary.json` says model-state changed but
`self_mirror_metric_summary.json` says the browser-visible authority ROI stayed
static, keep the result split:

```text
model-state diagnostic only / Self Mirror no-pass hold
```

## Audio Awareness Example

<!-- reference-surfaces:audio-awareness-example -->

Audio Awareness is a hearing reference surface for summary-only PC-output and
microphone awareness:

- `contracts/audio_awareness_consumer_routes/audio_awareness_consumer_routes.v0.schema.json`
  defines the route/discovery map for source/static audio-awareness readers.
- `runtime/audio-awareness/audio-awareness-consumer-routes.json` is the
  owner-local route map. It carries `$schema`, `schema_version`, and
  `contract_ref`, points to the speech-input hearing organ scaffold, names
  `audio_awareness_summary.json` as the result authority file, and keeps live
  capture off by default.
- `contracts/audio_awareness_summary/audio_awareness_summary.v0.schema.json`
  defines the result packet for `pc_output`, `microphone`, and
  `speech_input_vad_adapter` channel summaries.
- `organs/speech-input/audio-awareness/README.md` is the organ scaffold tied to
  `sense.hearing.primary`.
- `docs/audio-awareness.md` is the concise operator/reviewer design note for
  proof-layer separation and raw/private boundaries.

The current proof ceiling is:

```text
audio_awareness_source_static_summary_only
```

This surface can describe source/static contract readiness, synthetic fixture
summaries, and speech-input VAD adapter metadata mapping. It cannot prove live PC-output
capture, microphone capture, browser audio playback, user-heard audio,
transcript content, Home Assistant action, physical device effect, or
release/readiness/final RR003 pass.

## Smells

- A runtime reader parses prose from README instead of a contracted file.
- A value exists only in private coordination messages.
- A JSON map has `schema_version` but no contract under `contracts/`.
- A discovery map becomes command authority.
- A result packet and a how-to guide duplicate the same data without a single
  contract authority.
- A proof layer is inferred from a helper command name instead of an authority
  packet.
