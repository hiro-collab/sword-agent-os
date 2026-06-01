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
- `issue_ticket_id`: durable ticket identity across turns, retries, feedback
  loops, and memory entries, when known
- `issue_ticket_ids`: plural/list form for memories or events that legitimately
  belong to multiple tickets
- `ticket_status`: latest status assertion for an issue ticket at this event or
  metadata revision: `open`, `in_progress`, `blocked`, `resolved`, or `closed`
- `tags`: structured `namespace:value` labels for known dimensions, when useful
- `keywords`: free terms for concepts not yet standardized
- `keyphrases`: free phrases for fuzzy descriptions
- `work_notes`: optional operational notes for the active ticket or memory
  ticket revision
- `tag_source_refs`: optional references to topology snapshots/summaries or
  other evidence used to choose tags
- `topology_snapshot_id`: optional id of the topology provider snapshot used
  when interpreting or labeling the ticket
- `topology_freshness_state`: optional freshness state from the snapshot, such
  as `fresh`, `stale`, `partial`, `missing`, or `unknown`
- `topology_source_layers`: optional source layers that support this tag or
  topology reference, such as `home_assistant`, `environment_state`,
  `camera_vision`, or `agent_os`
- `topology_ref`: optional stable topology reference for the primary topology
  object related to this event, ticket, or memory-ticket revision
- `topology_ref_kind`: optional kind for the topology reference, such as
  `room`, `zone`, `device`, `camera_view`, `object_instance`, or
  `spatial_relation`
- `topology_confidence`: optional confidence for observed or inferred topology
  references
- `topology_observed_at`: optional timestamp for observed spatial/topology
  evidence
- `topology_conflict_state`: optional disagreement state such as `none`,
  `conflict`, `degraded`, `needs_confirmation`, or `sources_disagree`
- `topology_evidence_refs`: optional references to the observations or source
  records that support a topology ref, tag, or conflict
- `state_confidence`: optional confidence estimate for the current inferred
  state, usually stored or derived by Thought Core rather than copied directly
  from a driver observation
- `source_confidence`: optional confidence estimate for the source or source
  layer used; drivers may report local observation confidence here or in their
  own source records
- `freshness`: optional freshness estimate when a record uses a non-topology
  source or combines multiple source ages; drivers may report local freshness,
  while Thought Core may derive cross-source freshness judgments
- `reality_divergence`: optional estimate of how far internal state may be from
  real-world state, usually a Thought Core/system-level judgment
- `expected_effect`: optional redacted expected outcome for an action or retry
- `observed_effect`: optional redacted observed outcome after action/feedback
- `feedback_match`: optional estimate such as `matched`, `mismatch`,
  `partial`, `unknown`, or a bounded confidence score
- `retry_or_confirmation_need`: optional derived judgment that a retry,
  confirmation, approval, or no extra action is needed
- `environment_evidence_packet_id`: optional compact Environment State packet
  reference, using the `eep_...` id from
  `contracts/environment_evidence_packet/environment_evidence_packet.v0.schema.json`
- `policy_switch_operation`: optional redacted operation record when Thought
  Core or policy logic selects a conflict policy for the turn
- `confirmation_loop`: optional bounded feedback-loop summary with operation
  count, post-operation check count, and auto re-operation count
- `metrics`: optional array of lightweight metric records when confidence,
  divergence, staleness, or feedback estimates should be kept with provenance
- `trace_id`: technical trace across services/processes, when available
- `observation_id`: source observation id, when available
- `interpretation_id`: conscious interpretation id, when available
- `intent_id`: structured intent id, when available
- `action_id`: action request/execution id, when available
- `approval_id`: approval queue id, when review is required
- `correction_of_event_id`: prior event corrected by this event
- `supersedes_event_id`: prior event replaced by this event

Metric records follow the source-of-truth contract in
`runtime/status-store/metric-records.v0.md`. Event journal, memory, and ticket
records should reuse that shape only when the metric affects behavior or has
long-lived meaning. Initial metric records stay lightweight: use a numeric
`value` plus `metric`, `subject`, `recorded_at`, `stale_after`, `source`,
`provenance`, `basis`, and `evidence_refs` when those fields are available.
`stale_after` is driver-defined metadata carried into the record. `subject` is
a readable tag-like identifier such as `room:living_room`,
`entity:light.living_room`, `capability:lighting.living_room`, or
`action:turn_on_light`; it does not need strict URI semantics in v0, but should
remain compatible with later topology node mapping. `evidence_refs` start as
lightweight typed references such as `event:...`, `snapshot:...`, `turn:...`,
and `action:...`; a heavy evidence registry is deferred.

Metric labels are policy/config-derived at read time for the initial contract.
Do not require `recorded_label`, `current_label`, or relabel history in v0, and
do not silently redefine thresholds in Thought Core. If thresholds are
unsuitable, Thought Core can emit a proposal for an Agent OS policy/config
change. Historical label storage and relabel history are a separate future
design slice if audit needs require them.

`causal_parent_id` is local and immediate. `episode_id` groups a short runtime
chain such as reflex input or action execution. `turn_id` marks one Thought Core
conscious processing turn.

`issue_ticket_id` identifies a continuing semantic problem, request, or
unresolved matter across multiple turns, retries, feedback loops, diagnostics,
and memory entries. Thought Core owns creation, preservation, split, merge,
status, and retag decisions because ticket continuity depends on
interpretation. Lower-level modules may carry a supplied `issue_ticket_id`, but
must not infer it from raw gesture, button, speech, sensor, or status input.

Do not overload `turn_id` for reflex-only observations that have not yet become
a turn. Do not overload `episode_id` or `turn_id` for long-lived issue ticket
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
For local replay media, event summaries may use filename-only labels or stable
observation ids; absolute video paths, extracted frame paths, and frame payloads
belong in local-only evidence or ledgers, not routine retained events.

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
    "issue_ticket_id": "ticket_living_room_light_001",
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
    "issue_ticket_id": "ticket_living_room_light_001",
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
    "issue_ticket_id": "ticket_living_room_light_001",
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
    "issue_ticket_id": "ticket_living_room_light_001",
    "action_id": "action_light_on_001",
    "authority_domain": "execution",
    "summary": "Home Assistant light action executed",
    "redaction_level": "summary_only"
  }
]
```

## Multiple Turns, One Ticket

If the result is unsatisfactory and a later turn retries the same unresolved
problem, create a new `turn_id` and new append-only events while preserving the
same `issue_ticket_id`. This trimmed example shows the identity boundary:

```json
[
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_interpretation_001",
    "event_type": "conscious.interpretation",
    "turn_id": "turn_living_room_001",
    "issue_ticket_id": "ticket_living_room_light_001",
    "interpretation_id": "interp_living_room_001",
    "summary": "Thought Core interpreted the request as living room light on"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_execution_001",
    "event_type": "execution.result",
    "causal_parent_id": "evt_boundary_001",
    "turn_id": "turn_living_room_001",
    "issue_ticket_id": "ticket_living_room_light_001",
    "action_id": "action_light_on_001",
    "summary": "Home Assistant reported success, but the ticket remains open"
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
    "issue_ticket_id": "ticket_living_room_light_001",
    "interpretation_id": "interp_living_room_002",
    "summary": "Thought Core attached the follow-up to the same light ticket"
  }
]
```

## Ticket Status

Issue tickets use append-only status transitions. Initial vocabulary:

- `open`
- `in_progress`
- `blocked`
- `resolved`
- `closed`

Do not rewrite old journal events to change status. Write a new
`ticket.status_changed` event, or a new memory-ticket metadata revision, with
the previous and new status.

Example: one ticket starts `open`, moves to `in_progress`, and resolves after a
second turn:

```json
[
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_ticket_status_001",
    "event_type": "ticket.status_changed",
    "turn_id": "turn_living_room_001",
    "issue_ticket_id": "ticket_living_room_light_001",
    "previous_ticket_status": null,
    "new_ticket_status": "open",
    "summary": "Thought Core opened a light-control ticket"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_ticket_status_002",
    "event_type": "ticket.status_changed",
    "causal_parent_id": "evt_intent_001",
    "turn_id": "turn_living_room_001",
    "issue_ticket_id": "ticket_living_room_light_001",
    "previous_ticket_status": "open",
    "new_ticket_status": "in_progress",
    "summary": "Action execution started for the light-control ticket"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_interpretation_002",
    "event_type": "conscious.interpretation",
    "turn_id": "turn_living_room_002",
    "issue_ticket_id": "ticket_living_room_light_001",
    "interpretation_id": "interp_living_room_002",
    "summary": "Thought Core interpreted feedback for the same ticket"
  },
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_ticket_status_003",
    "event_type": "ticket.status_changed",
    "causal_parent_id": "evt_execution_002",
    "turn_id": "turn_living_room_002",
    "issue_ticket_id": "ticket_living_room_light_001",
    "previous_ticket_status": "in_progress",
    "new_ticket_status": "resolved",
    "summary": "Thought Core marked the light-control ticket resolved"
  }
]
```

Diagnostics should show the latest append-only status per `issue_ticket_id`.
Tickets with `open`, `in_progress`, or `blocked` are unresolved; tickets with
`resolved` or `closed` are resolved/closed. Timeline views should still expose
the status history so a resolved ticket can be audited without rewriting older
events.

## Ticket Labels

Issue-ticket records should start with lightweight semantic labels, not
mandatory polished titles or summaries. `title` and richer display summaries can
be generated later for UI/readability; they are not source-of-truth fields in
v0.

Use these fields when Thought Core has enough semantic context:

- `tags`: structured entries in `namespace:value` form, such as
  `room:living_room`, `capability:lighting`, `modality:voice`, `organ:reflex`,
  or `symptom:no_expected_reflection`
- `keywords`: free terms for concepts not yet standardized
- `keyphrases`: free phrases for fuzzy descriptions
- `work_notes`: optional operational notes, kept concise and redacted for
  routine diagnostics
- `label_revision_id`: optional metadata revision id for append-only label
  changes

Validate tag shape only: each tag should be a stable `namespace:value` string.
Do not reject a tag only because the namespace or value is missing from a
standard dictionary. Standard tag registry/promotion is future work; common
tags can be standardized later based on actual use.

Topology snapshots and summaries are sources of tag candidates, not a closed
dictionary. Thought Core should consume topology through a read-only topology
context provider rather than scraping organs directly. The provider may expose
internal topology such as organs, services, drivers, capabilities, event routes,
and action boundaries, plus environment topology such as rooms, devices,
sensors, physical areas, external systems, and people/actors when those systems
exist. Prefer stable topology ids when available, but Thought Core must still
be able to create tags when topology is incomplete.

The first topology provider output is expected to be a snapshot file:
`.cache/agent-os/status/topology.json`. Consumers must not introduce a hard
startup dependency on a topology service or snapshot in v0. They should tolerate
missing snapshots, stale snapshots, partial topology, unknown tags, and unknown
`topology_ref` values. When present, consumers may reference the snapshot with
`topology_snapshot_id`, record whether that topology was fresh/stale/advisory
with `topology_freshness_state`, reference specific topology objects with
`topology_ref`, and record tag candidate provenance with `tag_source_refs`.
Fresh topology is never required to create tags; missing, stale, or partial
topology is degraded context, not a hard failure.

One snapshot may combine source layers such as Home Assistant, Environment
State, camera/vision observations, and Agent OS topology. Consumers should
preserve layer/source provenance when it matters, because the layers have
different authority, freshness, confidence, and failure modes. For example,
`room:living_room` may be supported by both Home Assistant area data and vision
observations, while `symptom:no_expected_reflection` may come from environment
or vision feedback. Do not assume every topology ref has the same authority, and
do not treat environment/vision observations as overwriting Home Assistant
device topology unless an explicit fusion rule says so.

Future topology refs and tags may point at object instances, camera views,
rooms, zones, coordinate/location reference systems, and spatial relations.
These are references to topology evidence, not unqualified truth. Preserve
source layer, freshness, observation time, and confidence when available,
especially for camera/vision-derived spatial tags.

When topology sources disagree, preserve the conflict rather than silently
fusing sources into one truth. For example, if Home Assistant reports a light on
while camera/vision says the room appears dark, Thought Core may create tags
such as `source_conflict`, `needs_confirmation`, `vision:room_dark`, and
`home_assistant:light_on`; the ticket/event should keep `topology_conflict_state`
and `topology_evidence_refs` so diagnostics can see that the tags came from a
disagreement.

Thought Core may also use confidence and divergence estimates for ticket tags,
retries, confirmation decisions, and memory retagging. Keep these estimates
optional and evolvable. Useful concepts include source confidence, state
confidence, freshness, internal-state versus real-world divergence, expected
effect, observed effect, and whether feedback matched the expected effect.
Drivers should report local observation confidence and freshness when available;
Thought Core may store or derive system-level judgments such as state
confidence, reality divergence, feedback match, and retry or confirmation need.
Those derived judgments are not raw driver observations and should keep evidence
references when available.
Place metric records by use, not as a single universal log. Routine current
values belong in topology snapshots. Event journal entries should keep metric
records when a metric affects behavior, such as degraded execution,
block/approval routing, or feedback mismatch. Promote only repeated or
meaningful issues into Thought Core memory or issue tickets; routine current
values should not become long-term memory by default.
Conflicting or stale evidence is a risk signal, not automatically a hard stop:
ordinary low-risk capabilities may proceed in degraded mode with stronger
post-action feedback checks, while high-risk operations can escalate to
confirmation, approval, or blocked status by policy.

When a conflict policy is selected, store it as an explicit operation rather
than as hidden prompt drift. The operation record should name the conflict id,
selected policy, selected authority, reason, preserved evidence refs, and
redaction state. It should not contain raw Home Assistant payloads, raw camera
frames, raw prompts, local paths, secrets, or provider logs.

Home-control confirmation loops must remain bounded in the event stream: one
appliance operation, at most two post-operation state checks, and zero
automatic re-operation attempts. If feedback still conflicts after those checks,
record `needs_confirmation`, `held`, `mismatch`, or `unknown` instead of
emitting a second appliance operation.

Retagging or label edits should be represented as append-only ticket or
memory-ticket metadata revisions.

Example ticket label record:

```json
{
  "schema_version": "event.correlation.v0",
  "event_id": "evt_ticket_labels_001",
  "event_type": "ticket.labels_updated",
  "issue_ticket_id": "ticket_living_room_light_001",
  "label_revision_id": "ticket_label_rev_living_room_light_001",
  "ticket_status": "open",
  "tags": [
    "room:living_room",
    "capability:lighting",
    "modality:voice",
    "organ:home_assistant"
  ],
  "keywords": ["light", "living-room", "voice-control"],
  "keyphrases": ["living room still dark", "voice request did not reflect"],
  "work_notes": "Check whether the Home Assistant entity accepted the command but the physical light state did not update.",
  "tag_source_refs": [
    "topology://environment/rooms/living_room",
    "topology://agent-os/organs/home_assistant"
  ],
  "topology_snapshot_id": "topology_snapshot_20260529_1840",
  "topology_freshness_state": "fresh",
  "topology_source_layers": ["home_assistant", "camera_vision"],
  "topology_ref": "topology://environment/rooms/living_room",
  "topology_ref_kind": "room",
  "topology_confidence": 0.86,
  "topology_observed_at": "2026-05-29T18:40:00+09:00",
  "topology_conflict_state": "sources_disagree",
  "topology_evidence_refs": [
    "topology://home_assistant/entities/light.living_room",
    "topology://camera_vision/observations/living_room_dark_001"
  ],
  "metrics": [
    {
      "metric": "state_confidence",
      "subject": "room:living_room",
      "value": 0.62,
      "recorded_at": "2026-05-29T18:40:02+09:00",
      "stale_after": "2026-05-29T18:45:02+09:00",
      "source": "thought_core",
      "provenance": ["home_assistant", "camera_vision"],
      "basis": "home_assistant_on_camera_dark_conflict",
      "evidence_refs": [
        "snapshot:topology_snapshot_20260529_1840",
        "event:evt_ticket_labels_001"
      ]
    },
    {
      "metric": "reality_divergence",
      "subject": "capability:lighting.living_room",
      "value": 0.71,
      "recorded_at": "2026-05-29T18:40:02+09:00",
      "stale_after": "2026-05-29T18:45:02+09:00",
      "source": "thought_core",
      "provenance": ["home_assistant", "camera_vision"],
      "basis": "possible_light_state_mismatch",
      "evidence_refs": [
        "snapshot:topology_snapshot_20260529_1840",
        "action:turn_on_light_001"
      ]
    },
    {
      "metric": "feedback_match",
      "subject": "action:turn_on_light",
      "value": 0.2,
      "recorded_at": "2026-05-29T18:40:02+09:00",
      "stale_after": "2026-05-29T18:45:02+09:00",
      "source": "thought_core",
      "provenance": ["camera_vision", "action_feedback"],
      "basis": "vision_still_reports_room_dark",
      "evidence_refs": [
        "event:evt_ticket_labels_001",
        "action:turn_on_light_001"
      ]
    }
  ],
  "expected_effect": "Living room light becomes visibly on",
  "observed_effect": "Vision still reports room dark",
  "retry_or_confirmation_need": "hold_for_confirmation_or_manual_followup",
  "confirmation_loop": {
    "operation_count": 1,
    "post_operation_check_count": 2,
    "auto_reoperation_count": 0
  },
  "summary": "Ticket labels updated with structured tags and fallback terms"
}
```

## Memory Issue Ticket Tags

The append-only event journal remains separate from learned memory.
`issue_ticket_id` on events tracks semantic continuity when known.
`issue_ticket_id` or `issue_ticket_ids` on memories are memory index tags
controlled by Thought Core. A memory may belong to multiple issue tickets when
that is semantically useful.

Retagging memory should be recorded as a new memory-index event or metadata
revision, not by rewriting old journal events. Future split and merge workflows
should preserve provenance with fields such as:

- `memory_id`: memory record being indexed
- `memory_revision_id`: metadata revision or memory-index event revision
- `previous_issue_ticket_ids`: issue ticket tags before this change, or `[]`
- `new_issue_ticket_ids`: issue ticket tags after this change, or `[]`
- `split_from_issue_ticket_id`: original ticket when the memory is split out
- `merged_from_issue_ticket_ids`: tickets merged into the new tag set
- `previous_ticket_status`: status before this metadata revision, when changed
- `new_ticket_status`: status after this metadata revision, when changed
- `retag_reason`: redacted reason for diagnostics
- `retagged_by`: component or actor that made the decision
- `retagged_at`: when the memory tag decision was made
- `causal_parent_id`: event that caused or justified the retag, when available

Ordinary ticket/memory tag cleanup is autonomous by default. Thought Core and
memory maintenance may add, remove, replace, merge, or split tags, and may
attach or detach `issue_ticket_id` / `issue_ticket_ids` without requiring human
approval for routine cleanup. The requirement is append-only provenance, not
manual approval. Security/data-safety may later define audit emphasis for
policy-sensitive tags, but that should not block ordinary retagging.

Example: a memory first stored without an issue ticket tag, then tagged by Thought
Core:

```json
[
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_memory_index_001",
    "event_type": "memory.issue_ticket_tagged",
    "memory_id": "mem_living_room_dark_001",
    "memory_revision_id": "memrev_living_room_dark_001",
    "previous_issue_ticket_ids": [],
    "new_issue_ticket_ids": ["ticket_living_room_light_001"],
    "retag_reason": "Thought Core linked an untagged memory to the active light ticket",
    "retagged_by": "thought_core_api",
    "causal_parent_id": "evt_interpretation_002",
    "summary": "Memory tagged with active light ticket"
  }
]
```

Example: a memory moved from one issue ticket to another:

```json
[
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_memory_index_002",
    "event_type": "memory.issue_ticket_retagged",
    "memory_id": "mem_living_room_dark_001",
    "memory_revision_id": "memrev_living_room_dark_002",
    "previous_issue_ticket_ids": ["ticket_living_room_light_001"],
    "new_issue_ticket_ids": ["ticket_lamp_hardware_001"],
    "split_from_issue_ticket_id": "ticket_living_room_light_001",
    "merged_from_issue_ticket_ids": [],
    "retag_reason": "Thought Core narrowed the memory to a lamp hardware ticket",
    "retagged_by": "thought_core_api",
    "causal_parent_id": "evt_interpretation_003",
    "summary": "Memory issue ticket tag moved with provenance"
  }
]
```

Example: one memory belongs to two issue tickets:

```json
[
  {
    "schema_version": "event.correlation.v0",
    "event_id": "evt_memory_index_003",
    "event_type": "memory.issue_ticket_tagged",
    "memory_id": "mem_replay_light_failure_001",
    "memory_revision_id": "memrev_replay_light_failure_001",
    "previous_issue_ticket_ids": ["ticket_gesture_instability_001"],
    "new_issue_ticket_ids": [
      "ticket_gesture_instability_001",
      "ticket_living_room_light_001"
    ],
    "retag_reason": "Thought Core linked the replay observation to both gesture instability and light action failure",
    "retagged_by": "thought_core_api",
    "causal_parent_id": "evt_interpretation_004",
    "summary": "Memory indexed under gesture instability and light failure tickets"
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
