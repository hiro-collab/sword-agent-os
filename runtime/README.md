# Runtime

Runtime contains Agent OS orchestration pieces for the running AI-agent loop:
routers, status store, process registry, event journal, communication
governance, memory core, and review-state queues.

The runtime path is distinct from human operator setup and maintainer/Codex
inspection. It carries accepted input, state, response content, action requests,
feedback, and memory through contracted boundaries. It should not depend on
private coordination messages, and it should not treat maintainer review
language as normal runtime permission logic.

## Standard Components

- `routers/turn-router/`: coordinates user-response flow.
- `status-store/`: holds current runtime projections.
- `process-registry/`: tracks managed runtime processes for lifecycle control.
- `event-journal/`: stores append-only runtime history after redaction.
- `state-event-ingest/`: validates incoming events and status patches, attaches
  current organism identity, then distributes to event journal and status store.
- `action-catalog/`: aggregates executable action declarations from driver
  manifests.
- `action-boundary/`: validates action requests with deterministic body-side
  guard rules before driver execution.
- `body-schema/`: builds the current self-body model from body plan and current
  status.
- `body-display-projection/`: emits display-safe body-state frames for
  projector/background/display clients.
- `audio-awareness/`: exposes source/static, summary-only hearing awareness
  helpers and consumer routes for PC-output, microphone, and speech-input VAD
  adapter metadata under `sense.hearing.primary`.
- `diagnostic-scheduler/`: owns read-only observation pulse timing.
- `organ-drivers/`: translates organ-specific evidence into common status,
  event, topology, and capability observations.
- `organ-test-packs/`: defines how organ capability tests are declared and
  executed without embedding organ internals into the OS core.
- `communication-governance/`: observes and controls organ-to-organ
  communication boundaries.
- `memory-core/`: owns durable memory semantics and forgetting.
- `approval-queue/`: owns review-required approval state where a selected
  route or policy really requires review; it is not a routine permission loop
  for ordinary Home Assistant actions that already have an exact technical
  route.

Initial runtime work is documentation-first. Implementations should grow from
these boundaries and from the standard profile.
