# Runtime

Runtime contains Agent OS orchestration pieces such as routers, status store,
event journal, communication governance, memory core, and approval queue.

## Standard Components

- `routers/turn-router/`: coordinates user-response flow.
- `status-store/`: holds current runtime projections.
- `event-journal/`: stores append-only runtime history after redaction.
- `communication-governance/`: observes and controls organ-to-organ
  communication boundaries.
- `memory-core/`: owns durable memory semantics and forgetting.
- `approval-queue/`: owns review-required approval state.

Initial runtime work is documentation-first. Implementations should grow from
these boundaries and from the standard profile.
