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

## Degraded Behavior

Reflex and safety-gated actions must not depend on the ingest service being
healthy. When ingest is down, each adapter/driver buffers only its own
unsubmitted events for short-term replay. Buffer size and retention policy are a
separate contract.
