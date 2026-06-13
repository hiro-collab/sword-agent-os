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
handled through later review, classification, quarantine, summarization, and
deletion paths rather than by treating broad recording as a policy violation by
itself.

Most records are ordinary and may be expired, deprecated, forgotten, or deleted
under policy. Important records should be retained through reinforcement,
refresh, importance/reference counts, and long-term promotion. Long-term memory
is not a separate protected flag: deletion requests and safety/legal deletion
rules still override retention.

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
- Thought and organs may request long-term retention, reinforcement, deletion,
  or lifecycle handling, but final durable memory and deletion decisions belong
  to memory-core, policy, or human/admin paths.
- Event journal records operational history; it is not learned memory by
  itself.
- Status store projects current memory status; it is not authority for
  remembered content.
- Secrets are not normal memory items. Secret-like material discovered in
  stores should be flagged or quarantined by security/forgetting review.

## Source Home And Service Shape

Memory Core remains runtime substrate even if a later implementation runs as a
managed process. Do not move it under `organs/`, and do not create a top-level
`services/` directory just to house a Memory Core server or worker.

If a runtime-managed process is added later, keep source authority here and
expose the process through launch/runtime management and service manifests.
`service` describes the execution shape, not the source-tree category.

## Minimal SQLite Implementation Shape

The current minimal SQLite Memory Core slice uses this package/test shape:

```text
runtime/memory-core/pyproject.toml
runtime/memory-core/uv.lock
runtime/memory-core/src/memory_core/__init__.py
runtime/memory-core/src/memory_core/schema.py
runtime/memory-core/src/memory_core/migrations.py
runtime/memory-core/src/memory_core/store.py
runtime/memory-core/src/memory_core/organize.py
runtime/memory-core/src/memory_core/reference.py
runtime/memory-core/migrations/001_initial_memory_core.sql
runtime/memory-core/tests/test_memory_core_sqlite_migrations.py
runtime/memory-core/tests/test_memory_core_record.py
runtime/memory-core/tests/test_memory_core_organize.py
runtime/memory-core/tests/test_memory_core_reference.py
```

There is intentionally no daemon/server and no top-level `services/` directory
in this slice. `pyproject.toml` exists only as local project metadata for the
module-local `uv` route; the tests still run as standard-library `unittest`
checks and use no third-party runtime dependency.

Generated databases and evidence must stay outside tracked source. Use a test
temp directory, `.cache/memory-core/`, `.cache/agent-os/...`, or
`test-runs/memory-core/`. If module-local generated output is necessary, add a
module-local ignore rule for `*.db`, `*.sqlite`, `*.sqlite3`, `*.db-wal`,
`*.db-shm`, and generated evidence directories.

## First Verification Route

A first SQLite verification should prove:

1. migrations apply to an empty temporary SQLite database;
2. schema version, tables, indexes, and constraints exist;
3. a redacted memory-candidate-compatible item can be recorded with trace and
   turn references;
4. organize logic computes freshness, staleness, familiarity, importance, and
   grouping without committing raw text or provider payloads;
5. reference logic retrieves by trace, turn, episode, candidate, or record id
   and returns reader-safe summaries;
6. `safe_to_act=false`, `durable_memory_claimed=false` for candidate-only
   evidence, and `must_revalidate_current_state=true` remain visible where
   applicable;
7. generated databases and evidence are not tracked source and do not contain
   raw prompts, transcripts, provider payloads, tokens, local private paths, or
   entity ids.

The first priority-ingest / promotion follow-up adds source-no-live module
coverage for:

- priority ingest metadata for tags such as `safety`, `user_correction`,
  `review_blocker`, `explicit_remember`, `deletion_request`,
  `deletion_requested`,
  `long_term_candidate`, and `failure_pattern`;
- unsafe-content quarantine status without persisting raw/private values;
- long-term/reinforcement metadata separated from deletion requests;
- promotion decision records for `promote`, `hold`, `reject`, `merge`,
  `quarantine`, `superseded`, and `needs_human_review` outcomes, with LLM
  output explicitly non-final;
- relation/supersession metadata for corrected or similar memories without full
  graph consolidation;
- resolved issue memory metadata as regression/history context, not current
  failure or proof that a fix still works;
- tombstone-style local delete behavior that blocks normal retrieval while
  keeping reader-safe audit metadata;
- current-state-like facts stored only as historical observations with
  `must_revalidate_current_state=true`.

This follow-up remains module-test/source-no-live only. It does not add a
daemon/server, Thought Core runtime writer, live ingestion, production durable
memory claim, Git adoption, or RR003 representative-pass proof.

The retrieval-depth follow-up adds a source-no-live `memory_context_ref.v0`
reader summary for later-turn Thought Core use. It supports `light_auto`,
`conditional_deep`, and `explicit_recall`, but all retrieval must stay bounded
by tags, trace ids, turn ids, source refs, or record ids. An unscoped
`light_auto` query returns an empty context instead of reading all memory.
Current-state-like memories remain historical observations in the returned
context and keep `current_state_revalidated=false`,
`must_revalidate_current_state=true`, and non-claims such as
`not_current_state_without_revalidation`.

The reinforcement follow-up adds source-no-live `memory_reinforcement_updates`
records for reference, re-recording, similar-record, successful-use, explicit
importance, failure-prevention, work-continuity, and correction signals. These
signals can raise reader-safe strength/importance metadata or record a
confidence-down correction, but they do not claim durable production memory,
current-state truth, issue closure, source-type authority, or safe action.
Deletion requests and unsafe quarantine take precedence and cannot be overridden
by reinforcement.

The Memory/Issue classifier safety follow-up adds a source-no-live pure helper
for deterministic route classification of reader-safe summaries. It can return
`trace_only`, `memory_candidate`, `issue_candidate`, `both`,
`needs_llm_classification`, or `needs_human_review`, but it does not write
records, create issues, call providers, authorize live actions, or publish
anything. Raw/private/unsafe keys or values stop before memory, issue, or LLM
routes. Current-state-like facts without observed/source metadata stay
trace-only or human-review and keep `must_revalidate_current_state=true`.
Resolved issue records are history/regression context unless fresh same-failure
evidence routes both memory and issue candidates. LLM classification is
summary-only advisory and never final authority for memory promotion, issue
publication, current-state truth, live/device action, Git/source adoption, or
RR003 representative pass.

Expected focused command after the exact slice exists:

```powershell
Push-Location runtime\memory-core
uv --cache-dir .uv-cache run python -m unittest discover -s tests
Pop-Location
```
