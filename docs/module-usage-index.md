# Module Usage Index

This page is the durable entry point for using and extending Agent OS modules.
Use it when a thread needs to decide where a feature, test, adapter, or
diagnostic belongs.

## Fast Route

Use this order before opening source files:

1. Name the system responsibility: input, state, decision, action, expression,
   observation, self-observation, memory, or diagnostics.
2. Pick the authority layer:
   `manifests/` for static selection, `contracts/` for boundary shape,
   `runtime/` for OS substrate, `organs/` for concrete capability code, and
   `scripts/` for setup or verification entrypoints.
3. Check whether the work is runtime behavior or a diagnostic reader. A
   diagnostic may observe and summarize; it must not become the action
   authority.
4. Keep proof claims at the layer that was actually tested. Source/static,
   no-live/mock, runtime/browser, live device, and physical observation are not
   interchangeable.

The main loop is:

```text
input/observation -> state -> decision -> guarded action/expression
-> observation/self-observation -> feedback
```

If a proposed change does not fit one step in that loop, write down why before
adding a new module or route.

## Decision Authority Map

<!-- module-usage:decision-authority-map -->

Sword uses distributed organs intentionally. The rule is not "one controller
decides everything". The rule is **one semantic owner per decision class**.
An upstream component may request an outcome, the owning organ may accept or
reject it and choose its local execution, and downstream consumers may validate
shape, identity, ordering, freshness, replay, and their own safety boundaries.
They must not independently reinterpret the owner's decision.

Use these stable authority ids when a cross-organ setting, option, state, or
failure is being discussed:

| Authority id | Decision class and semantic owner | Owner output | Consumers may do | Must not be duplicated |
| --- | --- | --- | --- | --- |
| `AUTH-CONFIG-SELECTION` | Distribution manifests select standard components; selected owner-local config supplies organ-specific values. | Selected profile, source pin, contract version, and redacted effective config class. | Render, validate, and report drift from the selected value. | Hidden defaults or UI/env copies must not silently select a different component or policy. |
| `AUTH-RUNTIME-CONTROL` | Runtime Control owns the `HOLD_LIVE`, `STOP`, and `PAUSE` vocabulary and current operator marker intent. | A bounded control-intent state for route and service readers; current enforcement remains partial until those readers exist. | Each reader enforces the state locally and fails closed when its required control state is unreadable. | Runtime Control is not user intent, action admission, a universal interlock, permission, or proof authority. |
| `AUTH-SPEECH-ACCEPT` | The speech-input organ's canonical InputGate decides whether a private candidate is accepted as user speech. | One bounded, one-use accepted-input capability or a fail-closed class. | AEC, VAD, recognizers, and transport may condition signals and produce private evidence. | Signal presence, VAD, AEC selection, caller flags, or transport success must not grant TurnInput authority. |
| `AUTH-CONVERSATION-INTENT` | Thought Core owns conversational meaning, response choice, and contextual goal selection after accepted input. | Response events, bounded action requests, or expression/motion requests. | Organs may reject unsupported or unsafe requests and report capability/result state. | Speech, display, diagnostics, or device adapters must not infer a second conversational intent from raw text or presentation state. |
| `AUTH-REFLEX-REQUEST` | The reflex organ owns its local stimulus classification and may create a bounded request without waiting for Thought Core. | A contracted action or motion request with reflex provenance. | Action Boundary and the target organ apply their own deterministic and capability guards. | Reflex must not bypass Action Boundary or become the device driver. |
| `AUTH-ACTION-GUARD` | Action Boundary owns deterministic body-side admission: contract shape, action id, target, risk, rate, and emergency-stop state. | Admitted or rejected `action_request.v0`. | The target action organ may apply capability, current-state, and execution safety checks. | Thought Core semantic approval, a GUI click, or an organ-local fallback must not bypass the guard. |
| `AUTH-DEVICE-EXECUTION` | The selected action organ/driver owns device capability, command execution, bounded restore/stop behavior, and its configured state authority. | Submission, tracking, state-check, cleanup, and explicit non-claim classes. | Status, diagnostics, and Thought Core may consume contracted summaries. | HA-visible state, camera observation, physical state, and user confirmation must not overwrite one another or be collapsed into one proof class. |
| `AUTH-EXPRESSION-LIFECYCLE` | The expression organ owns requested and queue-accepted state; the selected player owns executed/playback state; the process observer owns externally observed evidence. | Separate requested, queued, executed, observed, released, and failure events. | Runtime controllers may correlate ids, enforce deadlines, reject replay, and clean up owned resources. | Queue acceptance must not be renamed playback; observation, AEC, or a controller must not mint user intent. |
| `AUTH-MOTION-EXECUTION` | Motion Runtime and the motion organ own asset compatibility, track composition, joint conventions, start, stop, and release. | Motion lifecycle and bounded model-state/visible-result references. | Thought Core or Reflex may request a goal and observe the returned state. | Thought Core, display code, or diagnostics must not micro-manage joint transforms or bypass motion safety. |
| `AUTH-ENVIRONMENT-OBSERVATION` | Each environment organ owns its sensor-specific observation and confidence; State/Event Ingest normalizes the event. | Source-, time-, confidence-, and ambiguity-labelled observation. | Status Store and Body Schema may project or combine observations while preserving provenance. | Camera estimates, HA state, device commands, and physical causality must not be treated as interchangeable. |
| `AUTH-CURRENT-STATE` | Status Store owns the current normalized projection; Event Journal owns append-only history. | Current state with evidence refs, plus separate historical events. | Body Schema, Thought Core, displays, and diagnostics may read contracted projections. | Event replay must not become the current-state read path, and organs must not write every consumer store directly. |
| `AUTH-BODY-SCHEMA` | Body Schema owns the current self-body model derived from Body Plan and current summarized evidence. | A provenance-preserving body snapshot. | Thought Core and display-safe projections may consume it as self-state context. | Body Schema must not become an action dispatcher, physical-proof upgrader, or substitute for organ-local control. |
| `AUTH-MEMORY-COMMIT` | Memory Core owns durable memory candidate/commit policy. | Accepted durable memory reference or rejection. | Thought Core may propose and later retrieve contracted memory. | Event history, chat logs, diagnostics, or display state must not silently become durable memory. |
| `AUTH-RUNTIME-CORRELATION` | Runtime controllers and the process registry own start order, correlation, deadlines, cancellation, ownership, and cleanup. | Run identity, timing, result linkage, and residue class. | They may stop only owned resources and report the narrowest failing edge. | A controller must not classify user intent, reinterpret an organ's semantic state, mint capability, or upgrade proof. |

The rows define functional ownership, not implementation monopolies. An organ
may contain several services or adapters, but exactly one owner-local boundary
must publish the decision that other components consume. If two components can
independently reach different semantic answers for the same authority id, the
boundary is defective even when both paths pass their local tests.

## Duplicate-Authority Audit

<!-- module-usage:authority-audit-record -->

Use the map as a development and debugging index, not as another coordination
board. For the path currently being changed, record only:

1. the authority id and exact decision;
2. the owner input, owner output, and direct consumer;
3. every copied default, fallback, cache, derived flag, or second state machine
   that can change the semantic answer;
4. the proof layer and provenance retained by each observation;
5. the smallest correction that leaves one owner and turns the other locations
   into validators, projections, or compatibility adapters;
6. a mutation test proving that a consumer-side override cannot recreate the
   retired decision path.

Prioritize findings in this order:

1. user-intent, safety, privacy, or live-device authority duplication;
2. two state machines deciding the same lifecycle transition;
3. conflicting defaults, configuration selectors, retries, or fallbacks;
4. duplicated display labels or low-impact derived presentation settings.

Fail closed and name the unresolved authority id when no owner can be named,
two owners can independently accept the same decision, an observation can
authorize an action, a fallback bypasses the selected owner, or a copied value
can outlive the version/session that produced it. Do not solve those cases by
adding a third arbitrator.

## Core Model

| Need | Use | Do not use |
| --- | --- | --- |
| Static body structure | `manifests/body-plans/` | runtime status, event history |
| Current body model | `runtime/body-schema/` | static manifests alone |
| Current state values | `runtime/status-store/` | event replay as the read path |
| Append-only history | `runtime/event-journal/` | current-state authority |
| Incoming event/status normalization | `runtime/state-event-ingest/` | direct writes from organs to every store |
| Action capability lookup | `runtime/action-catalog/` and `manifests/driver-manifests/` | hard-coded driver tables |
| Deterministic action guard | `runtime/action-boundary/` | Thought Core semantic reasoning |
| Display-safe body frames | `runtime/body-display-projection/` | raw logs, raw prompts, raw camera frames |
| Avatar/body motion indicators | `runtime/motion-runtime/` | direct appliance execution or raw driver routes |
| Hearing/audio awareness summaries | `runtime/audio-awareness/`, `organs/speech-input/audio-awareness/`, and `contracts/audio_awareness_summary/` | live capture, raw audio, full transcripts, or user-heard proof |
| Machine-readable reader/discovery surfaces | `contracts/` plus an owner-local JSON/output with `contract_ref` | README-only tables or coordination messages |

## Runtime vs Diagnostics

`runtime/` contains components that participate in ordinary operation. A
runtime component may be on a hot path, may serve current state, or may gate an
action before it reaches a driver.

`runtime/diagnostic-scheduler/`, `runtime/organ-drivers/`, and
`manifests/diagnostics/` observe and report state. Diagnostic code should prefer
read-only checks and redacted summaries. It must not execute real home actions,
mutate user data, or become the only authority for whether the system can act.

Use this split:

- If the system needs it to operate, it is runtime.
- If it inspects, summarizes, tests, or explains operation, it is diagnostics.
- If it does both, keep the write/action path in runtime and expose a separate
  diagnostic reader or projection.

## Runtime vs Organs vs Services

Use `runtime/` for Agent OS substrate responsibilities and authorities: memory,
event journal, status store, process registry, routers, action boundary, action
catalog, organ drivers, and organ test-pack execution.

Use `organs/` for concrete capability modules or external organs. An organ is a
role or module category, such as action, environment, reflex, expression,
speech-input, display, or diagnostics. Many organs are also runnable services,
but their source does not need to live under a directory named `services/`.

Use `service` for the execution/process shape: an independently launched
server, worker, UI, bridge, or adapter. Today, service code can live under
`control-plane/` or under an organ directory. Do not introduce a top-level
`services/` directory merely to make server code fit the word "service".
`manifests/services/` names selected runnable or observable services for
profiles; it does not imply that implementation code must live under a
directory named `services/`.

In short: `organ` names what capability owns the responsibility; `service`
names how it runs; `runtime` names OS substrate authority.

Use `platform profile` for the environment-level start policy: Windows demo,
Linux headless, WSL proof-of-concept, or Ubuntu sensor node. Use `substrate`
for a lower execution base shared by multiple organs, such as WSL, Ubuntu, or
ROS 2. A substrate can carry sensor or process infrastructure, but it must not
become Thought Core, Action Boundary, or proof authority. See
`docs/platform-profiles.md`.

Memory Core and Event Journal are core runtime substrate. They may eventually
run as managed processes, but their source-home and authority remain
`runtime/memory-core/` and `runtime/event-journal/` unless a later explicit
architecture decision moves them. They should not be moved under `organs/` just
because they can run like services.

## Body Plan Family

`Body Plan` names the body that exists for this Agent OS organism. It can change
over time as the system's body changes. The plan carries stable body roles such
as `thought.core`, `reflex.core`, `sense.vision.primary`, and
`display.projection`.

`Body Schema` is the current self-body model derived from Body Plan plus current
status and selected summarized evidence. It is closer to self-awareness than to
a static config file. Its snapshot contract is
`contracts/body_schema_snapshot/body_schema_snapshot.v0.schema.json`.

Current local verification uses
`scripts/build-body-schema-snapshot.ps1 -Check -NoWrite`, and the standard organ
test pack includes the same check as `body_schema.snapshot_contract`.

`Body Display Projection` is a display-safe stream for projector/background
clients. It can serve live body-state frames at up to the contract rate, but it
does not decide actions or interpret meaning.

`system-house-renderer` is a legacy source name. Use
`diagnostics.body_map_inspector` for the current organ role. If a viewer is
needed, treat it as a Body Schema / Body Display Projection consumer unless it
is only doing offline diagnostic inspection.

`cube-vault-background` is a legacy display/background route name. New code
should treat it as a display client under `display.projection`, not as a state
authority or Thought Core surface.

## Action Path

All external or actuator-facing operations should flow through
`action_request.v0`:

1. Input arrives as an input or observation event.
2. Thought Core, Reflex, GUI logic, or a system component may create an
   `action_request`.
3. Action Boundary validates structure, action id, target, risk, rate, and
   emergency-stop state.
4. The selected driver executes or rejects.
5. State/Event Ingest records the result.

Reflex can run without Thought Core, but it still uses Action Boundary before
touching a driver. Thought Core owns semantic safety and contextual judgment.
Action Boundary owns deterministic body-side guardrails.

## Motion Indicator Path

Avatar motion can be used as a visible indicator for action and attention. For
example, while a home appliance action is being previewed, executed, or checked,
Thought Core or Reflex may request a `motion_stimulus.v0` with
`kind: action_indicator` so the avatar points, gazes, or gestures toward the
display-safe target.

This path must stay separate from the action path:

1. The action itself still flows through `action_request.v0`, Action Boundary,
   and a driver.
2. Motion Runtime receives only a display-safe motion stimulus and optional
   safe target context.
3. The target context may use topology refs, safe display labels, and
   `action_request_id`.
4. It must not embed raw Home Assistant entity ids, service routes, private
   URLs, or device secrets.

## Expression Profile Requests

When Thought Core, Reflex, diagnostics, or source code needs a specific avatar
expression profile, use `motion_stimulus.v0` and set
`requirements.expression_profile_ref`. Do not scrape README prose and do not
reach into private page, module, store, browser, or driver internals to choose
expression weights.

Current contract-visible profile refs are:

- `motion.runtime.vrm_expression_weights.v0`: the standard default expression
  profile.
- `motion.runtime.vrm_expression_weights.full_relaxed.v0`: a bounded
  diagnostic profile for stronger expression-visible probing.

These refs are source/contract values. They are suitable for routing,
composition, review, and summary diagnostics, but they do not prove runtime
application, browser reachability, Self Mirror visible motion, semantic
expression correctness, physical/projector proof, release readiness, or final
RR003 pass. If a composite stimulus combines expression with gaze, posture, or
body motion, keep `track_mask`, `priority_by_track`, and later mixer/driver
results responsible for composition rather than treating a profile ref as
command authority.

## VRM Model Telemetry

Use `vrm_model_telemetry.v0` when source code, Thought Core, diagnostics, or a
review tool needs graph-ready model-state evidence for VRM expression or safe
rig-track changes. This is the right layer for questions such as "did the
runtime expression weights change over time?" or "did the selected safe track
bucket change?".

The module is intentionally separate from Self Mirror:

- `runtime/vrm-model-telemetry/` owns the runtime reader/discovery boundary.
- `organs/expression/vrm-model-telemetry/` owns the future concrete expression
  organ sampler/adapter scaffold.
- `runtime/visual-motion-analyzer/` remains the browser-visible Self Mirror
  lane.

System readers should use
`runtime/vrm-model-telemetry/vrm-model-telemetry-consumer-routes.json` instead
of scraping README prose or private runtime internals.

Bone/basis diagnostics belong in the same public VRM Model Telemetry module,
but should remain an optional internal sampler path. A future recorder must be
off by default, bounded, summary-first, and explicit about diagnostic mode
before detailed time-series artifacts are retained. The first canonical tracks
are `head`, `neck`, `spine`, and `body_root`; eyes, gaze, and mouth should stay
expression/lookAt summaries unless a selected VRM proves stable track support.

Timebase fields must be contract-visible when bone/basis telemetry is compared
with Self Mirror: relative monotonic clock kind, t0 definition, trigger offset,
baseline window, Self Mirror-style window map, stop reason, target/effective
cadence, and dropped/late sample counts. A telemetry-only sample window is not
enough to infer visible proof.

Do not use this surface to claim browser-visible Self Mirror pass, semantic
expression correctness, physical/projector proof, ROI or threshold authority,
command authority, release readiness, or final RR003 pass. For visible motion,
correlate this packet with a separate Self Mirror result authority packet.

## Audio Awareness

Use `audio_awareness_summary.v0` when source code, Thought Core, diagnostics,
review agents, or demo preflight needs a compact hearing summary that keeps PC
output and microphone input separate.

The module is tied to the existing speech-input/hearing role:

- `organs/speech-input/audio-awareness/` is the `sense.hearing.primary` organ
  scaffold.
- `runtime/audio-awareness/` owns the source/static runtime helper, tests, and
  consumer route map.
- `contracts/audio_awareness_summary/` owns the result packet shape.
- `contracts/audio_awareness_consumer_routes/` owns the route/discovery map
  shape.
- `docs/audio-awareness.md` is the operator/reviewer design note for proof
  layers and raw/private boundaries.

The current implementation is source/static only. It can validate synthetic
summary fixtures and map speech-input VAD metadata into a
`speech_input_vad_adapter` channel. It does not run PC-output loopback capture,
microphone capture, browser audio capture, provider/network STT/TTS, Home
Assistant/Home Control operations, raw audio handling, or transcript
publication.

Self-output STT/adoption-block observations belong to
`audio_self_output_observation.v0`. Do not store `tts:`, `playback:`, or
transcript-like self-output refs in `audio_awareness_summary.v0`.

Do not use this surface to claim browser audio playback, user-heard audio,
microphone content, speaker identity, physical/device proof, command authority,
release readiness, or final RR003 pass.

## Where To Add Work

| Work | Preferred location |
| --- | --- |
| New cross-organ data format | `contracts/<name>/<name>.v0.schema.json` |
| New value that Thought Core, diagnostics, or source code should read | `docs/reference-surfaces.md`, then `contracts/<name>/<name>.v0.schema.json` plus owner-local reader surface with `contract_ref` |
| New organ role or body role | `manifests/body-plans/` |
| New executable action or driver adapter | `manifests/driver-manifests/` |
| Current-state writer/normalizer | `runtime/state-event-ingest/` |
| Current-state reader/model | `runtime/status-store/` or `runtime/body-schema/` |
| Historical event/query behavior | `runtime/event-journal/` |
| Action validation behavior | `runtime/action-boundary/` |
| Side-effect-free communication fuzzing | `runtime/communication-fuzzing/` |
| Organ capability tests | `runtime/organ-test-packs/` and `manifests/tests/organ-test-packs/` |
| Launch/control-plane UI | `control-plane/` |
| Organ implementation code | nested repos under `organs/`, sourced by `manifests/organs/` |

## Adding A Reader Surface

Use `docs/reference-surfaces.md` when a developer wants to make a new value
readable by Thought Core, diagnostics, review agents, or another source module.
The short rule is: contract first, owner-local surface second, code reader
third.

1. Decide whether the value is a result packet, route/discovery map,
   current-state projection, event handoff, or static selection.
2. Add or reuse a schema in `contracts/`.
3. Put the concrete JSON/output under the owner that produces it, with
   `$schema`, `schema_version`, and `contract_ref`.
4. Add a human entrypoint only when an operator needs one.
5. Add maintenance assertions for path, contract listing, boundary booleans,
   non-claims, and the expected consumer names.

Do not teach Thought Core to scrape README prose, raw logs, generated local
config, screenshots, transcripts, or coordination messages.

## Safety Defaults

- Keep raw media, screenshots, prompts, full logs, local paths, and secrets out
  of tracked files.
- Keep raw payloads, local paths, `action_request` payloads, and driver action
  catalogs out of Body Display Projection frames.
- Use dummy drivers or dry-run paths for tests unless the user explicitly
  approves a live side effect.
- Keep compatibility names in aliases and migration docs. New runtime code
  should use canonical ids.
- Prefer small reversible slices. If a change affects a nested organ repo and
  the parent OS manifest, record both sides in the handoff.
