# Event Journal

Event journal stores append-only runtime history after redaction. It is not
learned memory and not the authority for live service state.

## Routine Append Policy

Routine diagnostic success should normally update `status-store`, not append a
new event for every pulse. Append only:

- state changes
- warnings
- recoveries
- stale or missing evidence transitions
- blocked/unblocked transitions
- sampled healthy heartbeats
- deep-check summaries with evidence references

The first sampled healthy heartbeat interval is 15 minutes. This keeps the
journal useful for timeline reconstruction without turning every one-second
diagnostic pulse into long-term storage.

## Initial Retention

- Keep event journal files for 30 days.
- Rotate event files daily.
- Compress rotated files.
- Target at most 300 MB of uncompressed routine journal data per day.
- Do not copy raw camera frames, images, generated media, full module logs, or
  secret-bearing payloads into the routine journal.

The first writer is `scripts/update-diagnostics-status.ps1`. It appends to
`.cache/agent-os/events/events-YYYY-MM-DD.jsonl` only when status meaning
changes, when a new service/capability is observed, or when the status is first
initialized.

## Correlation Spine

Event journal links runtime history with explicit causal fields instead of
treating every input as an immediate user command.

The first correlation contract is
`runtime/event-journal/correlation-spine.v0.md`. It keeps reflex observation,
reflex/autonomic action, recognized input, conscious interpretation, structured
intent, action-boundary decision, and execution result as separate append-only
events connected by ids such as `causal_parent_id`, `episode_id`, `turn_id`,
`issue_ticket_id`, `interpretation_id`, and `action_id`.
