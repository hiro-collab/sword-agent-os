# Event Correlation Spine v0

This contract links Agent OS runtime events without flattening body layers into
one vague "user command" stream.

It is append-only. If an interpretation, classification, decision, or result is
wrong, write a new correction/superseding event. Do not edit prior journal
events in place.

## Layers

The first diagnostics-readable flow is:

1. `reflex.observation`: a body/reflex signal was observed.
2. `reflex.readiness`: the reflex route became ready or not ready to act.
3. `reflex.action`: a system reflex/autonomic action happened, such as opening
   the microphone after a gesture.
4. `input.recognized`: an input channel produced recognized text or another
   normalized input.
5. `conscious.interpretation`: Thought Core interpreted the input.
6. `intent.structured`: a structured intent was emitted.
7. `action_boundary.decision`: policy/action boundary accepted, denied,
   blocked, or requested approval for the intent.
8. `execution.result`: an organ reported execution result or failure.

Gesture judgement belongs to the Reflex domain. A browser microphone button is
a GUI input source, but opening the mic can still be a system reflex action.
Recognized text is input until conscious interpretation emits structured
intent.

## Required Envelope

Every correlated event should include:

- `schema_version`: `event.correlation.v0`
- `event_id`: stable unique event id
- `event_type`: one of the layer event types, or a namespaced extension
- `observed_at`: when the source observed the event
- `received_at`: when Agent OS received or wrote the event
- `agency_mode`: `reflex`, `autonomic`, `voluntary`, `mixed`, or `unknown`
- `source_component`: runtime component, organ driver, or bridge that emitted
  the event
- `summary`: redacted one-line event summary for diagnostics

## Link Fields

Use link fields to build the chain:

- `causal_parent_id`: immediate event that caused or triggered this event
- `episode_id`: longer experience unit for diagnostics and memory candidates
- `turn_id`: one user/system interaction flow, when available
- `issue_id`: durable semantic issue across turns, retries, and feedback loops,
  when known
- `trace_id`: technical trace across services/processes, when available
- `observation_id`: source observation id, when available
- `interpretation_id`: conscious interpretation id, when available
- `intent_id`: structured intent id, when available
- `action_id`: action request/execution id, when available
- `approval_id`: approval queue id, when review is required
- `correction_of_event_id`: prior event corrected by this event
- `supersedes_event_id`: prior event replaced by this event

`causal_parent_id` is local and immediate. `episode_id` groups a short runtime
chain such as reflex input or action execution. `turn_id` marks one Thought Core
conscious processing turn.

`issue_id` identifies a continuing semantic problem, request, or unresolved
matter across multiple turns, retries, and feedback loops. Thought Core owns
creation, preservation, split, merge, and retag decisions because issue
continuity depends on interpretation. Lower-level modules may carry a supplied
`issue_id`, but must not infer it from raw gesture, button, speech, sensor, or
status input.

Do not overload `turn_id` for reflex-only observations that have not yet become
a turn. Do not overload `episode_id` or `turn_id` for long-lived issue
continuity.

## Source Fields

Use these to preserve semantics without leaking payload:

- `input_channel`: `gesture`, `browser_button`, `microphone`, `text`, `timer`,
  `system_status`, or another stable channel
- `trigger_source`: `reflex_core`, `display_runtime_gui`, `aituber_ui`,
  `thought_core`, `home_assistant_bridge`, or another component id
- `authority_domain`: `reflex`, `input`, `thought`, `action_boundary`,
  `execution`, `display`, `diagnostics`, or `memory`
- `payload_ref`: optional reference to quarantined/snapshot/deep evidence
- `redaction_level`: `summary_only`, `redacted_fields`, `payload_ref_only`, or
  `none`

Routine diagnostics should prefer `summary_only` or `redacted_fields`. Raw
conversation text, raw camera frames/images, generated media, local private
paths, tokens, and full logs must not be copied into routine event summaries.

## Example Chain

Example: gesture-opened microphone leading to a Home Assistant light action.

```json
[
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_reflex_obs_001",
    "event_type": "reflex.observation",
    "observed_at": "2026-05-29T18:00:00.000+09:00",
    "received_at": "2026-05-29T18:00:00.050+09:00",
    "agency_mode": "reflex",
    "source_component": "mediapipe_camera_hub_stack",
    "episode_id": "ep_living_room_20260529_1800",
    "input_channel": "gesture",
    "trigger_source": "reflex_core",
    "authority_domain": "reflex",
    "summary": "Reflex observed Sword gesture",
    "redaction_level": "summary_only"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_reflex_action_001",
    "event_type": "reflex.action",
    "causal_parent_id": "evt_reflex_obs_001",
    "observed_at": "2026-05-29T18:00:00.100+09:00",
    "received_at": "2026-05-29T18:00:00.120+09:00",
    "agency_mode": "autonomic",
    "source_component": "reflex_core",
    "episode_id": "ep_living_room_20260529_1800",
    "input_channel": "gesture",
    "trigger_source": "reflex_core",
    "authority_domain": "input",
    "summary": "Reflex opened microphone",
    "redaction_level": "summary_only"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_input_recognized_001",
    "event_type": "input.recognized",
    "causal_parent_id": "evt_reflex_action_001",
    "observed_at": "2026-05-29T18:00:02.000+09:00",
    "received_at": "2026-05-29T18:00:02.100+09:00",
    "agency_mode": "autonomic",
    "source_component": "speech_input",
    "episode_id": "ep_living_room_20260529_1800",
    "turn_id": "turn_living_room_001",
    "input_channel": "microphone",
    "trigger_source": "reflex_core",
    "authority_domain": "input",
    "summary": "Speech input recognized a light-control request",
    "payload_ref": "evidence://speech/redacted/turn_living_room_001",
    "redaction_level": "payload_ref_only"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_interpretation_001",
    "event_type": "conscious.interpretation",
    "causal_parent_id": "evt_input_recognized_001",
    "observed_at": "2026-05-29T18:00:02.300+09:00",
    "received_at": "2026-05-29T18:00:02.350+09:00",
    "agency_mode": "voluntary",
    "source_component": "thought_core_api",
    "episode_id": "ep_living_room_20260529_1800",
    "turn_id": "turn_living_room_001",
    "issue_id": "issue_living_room_light_001",
    "interpretation_id": "interp_living_room_001",
    "authority_domain": "thought",
    "summary": "Thought Core interpreted input as a request to turn on the light",
    "redaction_level": "summary_only"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_intent_001",
    "event_type": "intent.structured",
    "causal_parent_id": "evt_interpretation_001",
    "observed_at": "2026-05-29T18:00:02.360+09:00",
    "received_at": "2026-05-29T18:00:02.370+09:00",
    "agency_mode": "voluntary",
    "source_component": "thought_core_api",
    "episode_id": "ep_living_room_20260529_1800",
    "turn_id": "turn_living_room_001",
    "issue_id": "issue_living_room_light_001",
    "interpretation_id": "interp_living_room_001",
    "intent_id": "intent_light_on_001",
    "authority_domain": "thought",
    "summary": "Structured intent: home light on",
    "redaction_level": "summary_only"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_boundary_001",
    "event_type": "action_boundary.decision",
    "causal_parent_id": "evt_intent_001",
    "observed_at": "2026-05-29T18:00:02.400+09:00",
    "received_at": "2026-05-29T18:00:02.420+09:00",
    "agency_mode": "voluntary",
    "source_component": "action_boundary",
    "episode_id": "ep_living_room_20260529_1800",
    "turn_id": "turn_living_room_001",
    "issue_id": "issue_living_room_light_001",
    "intent_id": "intent_light_on_001",
    "action_id": "action_light_on_001",
    "authority_domain": "action_boundary",
    "summary": "Action boundary accepted allowlisted light action",
    "redaction_level": "summary_only"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_execution_001",
    "event_type": "execution.result",
    "causal_parent_id": "evt_boundary_001",
    "observed_at": "2026-05-29T18:00:02.800+09:00",
    "received_at": "2026-05-29T18:00:02.900+09:00",
    "agency_mode": "voluntary",
    "source_component": "home_assistant_bridge",
    "episode_id": "ep_living_room_20260529_1800",
    "turn_id": "turn_living_room_001",
    "issue_id": "issue_living_room_light_001",
    "action_id": "action_light_on_001",
    "authority_domain": "execution",
    "summary": "Home Assistant light action executed",
    "redaction_level": "summary_only"
  }
]
```

## Multiple Turns, One Issue

If the result is unsatisfactory and a later turn retries the same unresolved
problem, create a new `turn_id` and new append-only events while preserving the
same `issue_id`. This trimmed example shows the identity boundary:

```json
[
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_interpretation_001",
    "event_type": "conscious.interpretation",
    "turn_id": "turn_living_room_001",
    "issue_id": "issue_living_room_light_001",
    "interpretation_id": "interp_living_room_001",
    "summary": "Thought Core interpreted the request as living room light on"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_execution_001",
    "event_type": "execution.result",
    "causal_parent_id": "evt_boundary_001",
    "turn_id": "turn_living_room_001",
    "issue_id": "issue_living_room_light_001",
    "action_id": "action_light_on_001",
    "summary": "Home Assistant reported success, but the issue remains open"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_input_recognized_002",
    "event_type": "input.recognized",
    "turn_id": "turn_living_room_002",
    "summary": "Follow-up input says the living room is still dark"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_interpretation_002",
    "event_type": "conscious.interpretation",
    "causal_parent_id": "evt_input_recognized_002",
    "turn_id": "turn_living_room_002",
    "issue_id": "issue_living_room_light_001",
    "interpretation_id": "interp_living_room_002",
    "summary": "Thought Core attached the follow-up to the same light issue"
  }
]
```

## Memory Issue Tags

The append-only event journal remains separate from learned memory. `issue_id`
on events tracks semantic continuity when known. `issue_id` on memories is a
memory index/tag controlled by Thought Core.

Retagging memory should be recorded as a new memory-index event or metadata
revision, not by rewriting old journal events. Future split and merge workflows
should preserve provenance with fields such as:

- `memory_id`: memory record being indexed
- `memory_revision_id`: metadata revision or memory-index event revision
- `previous_issue_id`: issue tag before this change, or `null`
- `new_issue_id`: issue tag after this change, or `null`
- `split_from_issue_id`: original issue when the memory is split out
- `merged_from_issue_ids`: issues merged into the new tag
- `retag_reason`: redacted reason for diagnostics
- `retagged_by`: component or actor that made the decision
- `retagged_at`: when the memory tag decision was made
- `causal_parent_id`: event that caused or justified the retag, when available

Example: a memory first stored without an issue tag, then tagged by Thought
Core:

```json
[
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_memory_index_001",
    "event_type": "memory.issue_tagged",
    "memory_id": "mem_living_room_dark_001",
    "memory_revision_id": "memrev_living_room_dark_001",
    "previous_issue_id": null,
    "new_issue_id": "issue_living_room_light_001",
    "retag_reason": "Thought Core linked an untagged memory to the active light issue",
    "retagged_by": "thought_core_api",
    "causal_parent_id": "evt_interpretation_002",
    "summary": "Memory tagged with active light issue"
  }
]
```

Example: a memory moved from one issue tag to another:

```json
[
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_memory_index_002",
    "event_type": "memory.issue_retagged",
    "memory_id": "mem_living_room_dark_001",
    "memory_revision_id": "memrev_living_room_dark_002",
    "previous_issue_id": "issue_living_room_light_001",
    "new_issue_id": "issue_lamp_hardware_001",
    "split_from_issue_id": "issue_living_room_light_001",
    "merged_from_issue_ids": [],
    "retag_reason": "Thought Core narrowed the memory to a lamp hardware issue",
    "retagged_by": "thought_core_api",
    "causal_parent_id": "evt_interpretation_003",
    "summary": "Memory issue tag moved with provenance"
  }
]
```

## First Implementation Notes

- Event journal writers should add these fields opportunistically; readers must
  tolerate missing optional links.
- Diagnostics viewers should render both timeline order and causal-parent
  links.
- Action Boundary validates structured intent. It should not reinterpret raw
  natural language.
- Memory Core may later build episode candidates from these links, but event
  journal remains operational history, not learned memory authority.
- Security/data-safety should review payload references and redaction before
  richer native readers persist routine event projections.
