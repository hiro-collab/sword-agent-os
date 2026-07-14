# State/Event Ingest

State/Event Ingest is the single runtime entry for normalized event and current
state reports.

Drivers and adapters should not write SQLite files or status snapshots
directly. They send an ingest envelope. The ingest layer validates the envelope,
adds the currently active `organism_id`, appends history to Event Journal, and
applies current-state updates to Status Store.

## Responsibilities

- Validate `contracts/event_ingest/event_ingest.v0.schema.json`.
- Validate embedded `status_patch.v0` payloads.
- Attach the active `organism_id`; organs and drivers do not remember their
  owner.
- Append durable history to `runtime/event-journal/`.
- Apply current values to `runtime/status-store/`.
- Preserve causal ids such as `episode_id`, `turn_id`, `issue_ticket_id`, and
  `action_request_id` when present.
- Reject or redact payloads that include raw media, raw prompts, secrets, local
  paths, or unbounded logs.

## RR003 Motion Trace Ingest

RR003 motion feedback enters through the same ingest layer. Runtime adapters
should submit an `event_ingest.v0` envelope whose payload references a
`motion_trace_event.v0` summary and, when current state changed, an embedded
`status_patch.v0`.

Important boundaries:

- Driver/adapter code may carry a supplied `turn_id`, `episode_id`, or
  `issue_ticket_id`, but it must not infer semantic issue tickets from raw
  input.
- Motion trace payloads use ids, hashes, or redacted evidence refs only.
- Status updates should include `observed_at`, `recorded_at`, `stale_after`, and
  a projection catch-up marker such as `source_offset` when available.
- Home Assistant service, entity, or action routes must not be retained in
  avatar-motion trace payloads.

## Degraded Behavior

Reflex and safety-gated actions must not depend on the ingest service being
healthy. When ingest is down, each adapter/driver buffers only its own
unsubmitted events for short-term replay. Buffer size and retention policy are a
separate contract.

## Hearing Organ Current State

`StateEventIngest.psm1` validates the bounded
`sense.hearing.primary.input_gate.body_state` update before it is merged into
Status Store. The value is owned and classified by ai-talk-core InputGate. The
ingest module checks only exact fields, canonical organ/driver provenance,
freshness, confidence, and privacy.

The accepted owner projection contains only these classes:

- `self-speaking`, `input-receivable`, or `ambiguity-held`;
- input availability and system-speech intent class;
- matching-current or missing self-output observation;
- zero/nonzero pending private authority;
- current or missing owner-read freshness;
- `raw_private_publication_flags=false`.

The ingest module does not combine AIT lifecycle and process-observation
evidence, run AEC/VAD, accept speech, mint capability or TurnInput, or retain
candidate history. Extra fields, mismatched authority, stale current-owner
reads, and private-bearing data fail closed. A missing bounded owner read is
stored only as `ambiguity-held` with missing freshness and zero confidence.
