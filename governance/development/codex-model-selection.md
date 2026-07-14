# Codex Development Model Selection

This guide selects Codex models for developing and maintaining Sword Agent OS.
It does not configure the models used by Thought Core or any Agent OS runtime
route. Runtime model routing remains under `manifests/model-routing/`, module
task profiles, and runtime configuration.

## Default

Use `gpt-5.6-terra` with `medium` reasoning for ordinary scoped development.
Choose the model and reasoning effort independently, based on the work rather
than the thread's title or role name.

| Work profile | Model | Reasoning starting point |
| --- | --- | --- |
| Deterministic inventory, exact searches, formatting, routine test execution, and mechanical status extraction | `gpt-5.6-luna` | `low` or `medium` |
| Normal implementation, focused bug fixes, exact-diff review, and bounded runtime operation using an established harness | `gpt-5.6-terra` | `medium` or `high` |
| Cross-repository architecture, root migrations, conflicting evidence, hard diagnosis, or final integration synthesis | `gpt-5.6-sol` | `high` or `xhigh` |
| A difficult quality-first problem that remains unresolved after an adequate `xhigh` attempt | `gpt-5.6-sol` | `max` |
| A program that divides cleanly into several independent workstreams with disjoint ownership | `gpt-5.6-sol` or `gpt-5.6-terra` | Codex `ultra` mode when available |

Do not use `max` or `ultra` as a general synonym for important work. `max` is
for a single hard reasoning problem. `ultra` is for explicit multi-agent work
that benefits from parallel decomposition and synthesis.

## Escalation And De-escalation

Escalate from Luna to Terra when the task stops being mechanical and requires
code judgment. Escalate from Terra to Sol when any of these materially affect
the result:

- several modules or repositories must change together;
- current evidence conflicts across layers;
- the root cause remains ambiguous after a bounded attempt;
- an architecture, migration, or final integration decision has broad blast
  radius;
- repeated failure shows that the current route is not adequate.

De-escalate when exact scripts, schemas, tests, or deterministic results already
decide the next action. Live or external effects increase the required
verification; they do not automatically require a stronger model.

When moving an existing GPT-5.5 or GPT-5.4 workflow to GPT-5.6, keep the current
reasoning effort as the first baseline and test one lower effort on
representative work. Keep older models only for temporary availability fallback
or regression comparison unless a measured task-specific advantage is recorded.

## Role Defaults

- Manager/support and integration-management use Sol for cross-lane strategy,
  hard diagnosis, and final synthesis; use Terra for routine folds and scoped
  execution.
- Product/module owners use Terra for normal implementation and review; use Sol
  only for unresolved cross-layer design or diagnosis.
- Test-QA and security-data-safety use Terra/high for ordinary exact-diff
  review; use Sol/xhigh for systemic regression analysis, threat modeling, or
  contradictory evidence.
- Coordination administration uses Luna for table, queue, delivery, and count
  maintenance; use Terra when reconciliation needs substantive judgment.

These are defaults, not permanent model identities for a role.

## Prompt And Context Discipline

GPT-5.6 should receive the smallest complete task packet. Keep:

- the outcome;
- current authority;
- exact scope and ownership;
- constraints and side-effect boundaries;
- success criteria and required evidence;
- the expected return or concrete blocker.

Remove duplicated history, repeated acknowledgements, redundant non-claims,
and tools unrelated to the task. Link current evidence instead of replaying old
packets. A shorter prompt must still preserve every material decision,
constraint, caveat, and next action.

For an independent Test-QA or security review, omit the implementation thread's
chain of thought, persuasive narrative, desired verdict, and other reviewers'
initial conclusions. Supply the controlling request, frozen exact diff,
canonical contracts and proof boundaries, focused validation, and known limits.
The reviewer may request more context after identifying a concrete question.

## Subagent Model Budget

Use Luna or Terra for bounded exploration, exact searches, routine tests, and
supporting-document review. Reserve Sol for the parent thread when it must
resolve conflicting evidence or synthesize several independent returns. Do not
run multiple Sol/high-effort agents merely because several role threads exist.

Thread ownership, independent review context, concurrency, nesting, and
workstation backpressure are defined once in `codex-threading.md`. Model strength
or the number of available owner threads does not justify additional parallel
workers.

## Evaluation And Trace

For a new model assignment or material change in reasoning effort, compare a
small representative task set. Record only summary metadata:

- model family and reasoning effort;
- task class and selection reason;
- success and final-answer completeness;
- required evidence present or missing;
- retries or fallback used;
- latency and usage bucket when available.

The selected model is never evidence that source, runtime, device state,
publication, readiness, or final acceptance is correct. Existing proof-layer
and ownership rules continue to apply.

Official references:

- <https://developers.openai.com/api/docs/guides/latest-model>
- <https://developers.openai.com/api/docs/models>
