# Memory Core

Memory Core is the Agent OS runtime component for durable memory semantics and
forgetting.

It is not an organ. Thought, environment, action, expression, diagnostics, and
other organs may use memory, but they do not own durable memory commit or
forgetting semantics.

## Responsibilities

- Accept memory candidates from allowed sources.
- Provide scoped retrieval for thought, expression, runtime, and other allowed
  clients.
- Own durable semantic and episodic memory commit semantics.
- Build or help build episodes from events, turns, observations, actions,
  results, corrections, and feedback.
- Run forgetting cycles over stored data.
- Decide or prepare decisions about what is remembered, summarized,
  de-indexed, quarantined, archived, or deleted.
- Preserve source traceability for remembered and forgotten items.
- Expose memory and forgetting status as projections for status store and
  diagnostics.

## Forgetting

Forgetting is a core memory function, not a cleanup organ and not a diagnostics
responsibility.

Agent OS may record broadly, including raw or high-sensitivity data. Safety is
handled through later review, classification, quarantine, summarization,
deletion, and protected-memory approval paths rather than by treating broad
recording as a policy violation by itself.

Most records are ordinary and may be forgotten autonomously under policy.
Protected records require the approval path before destructive deletion.

## Experience Units

Memory Core uses linked experience units:

- `event`: a fine-grained observation, action, tool result, log, or state
  change
- `turn`: one user/system interaction flow
- `episode`: a larger experience that may include conversation, observation,
  action, result checking, correction, feedback, and follow-up

Events are raw material. Turns are short-range correlation units. Episodes are
the main long-term memory candidate shape when an experience has enough
structure to summarize.

## Correlation

Initial correlation IDs:

- `event_id`
- `turn_id`
- `episode_id`
- `trace_id`
- `action_id`
- `observation_id`

`event_id`, `turn_id`, `episode_id`, and `trace_id` are core OS-level IDs.
`action_id` and `observation_id` are expected for home-control and environment
flows.

## Classification

Memory and behavior classification is demand-driven. The system keeps baseline
vocabulary for behavior and data, but unclassified or partially classified
records are allowed until policy, security, implementation, memory, or
debugging needs more detail.

Classification may become nested, graph-like, multi-indexed, or otherwise more
complex than a simple table. Memory schemas should keep explicit versioning and
leave room for migration.

## Boundaries

- Thought may retrieve memory and submit candidates, but it does not directly
  commit durable memory.
- Thought and organs may request protected memory status, but final protected
  status is approved by memory-core, policy, or human/admin paths.
- Event journal records operational history; it is not learned memory by
  itself.
- Status store projects current memory status; it is not authority for
  remembered content.
- Secrets are not normal memory items. Secret-like material discovered in
  stores should be flagged or quarantined by security/forgetting review.
