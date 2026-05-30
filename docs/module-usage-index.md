# Module Usage Index

This page is the durable entry point for using and extending Agent OS modules.
Use it when a thread needs to decide where a feature, test, adapter, or
diagnostic belongs.

## Core Model

| Need | Use | Do not use |
| --- | --- | --- |
| Static body structure | `manifests/body-plans/` | runtime status, event history |
| Current body model | `runtime/body-schema/` | static manifests alone |
| Current state values | `runtime/status-store/` | event replay as the read path |
| Append-only history | `runtime/event-journal/` | current-state authority |
| Incoming event/status normalization | `runtime/state-event-ingest/` | direct writes from organs to every store |
| Action capability lookup | `runtime/action-catalog/` and `manifests/driver-manifests/` | hard-coded driver tables |
| Deterministic action guard | `runtime/action-boundary/` | Thought Core semantic reasoning |
| Display-safe body frames | `runtime/body-display-projection/` | raw logs, raw prompts, raw camera frames |

## Runtime vs Diagnostics

`runtime/` contains components that participate in ordinary operation. A
runtime component may be on a hot path, may serve current state, or may gate an
action before it reaches a driver.

`runtime/diagnostic-scheduler/`, `runtime/organ-drivers/`, and
`manifests/diagnostics/` observe and report state. Diagnostic code should prefer
read-only checks and redacted summaries. It must not execute real home actions,
mutate user data, or become the only authority for whether the system can act.

Use this split:

- If the system needs it to operate, it is runtime.
- If it inspects, summarizes, tests, or explains operation, it is diagnostics.
- If it does both, keep the write/action path in runtime and expose a separate
  diagnostic reader or projection.

## Body Plan Family

`Body Plan` names the body that exists for this Agent OS organism. It can change
over time as the system's body changes. The plan carries stable body roles such
as `thought.core`, `reflex.core`, `sense.vision.primary`, and
`display.projection`.

`Body Schema` is the current self-body model derived from Body Plan plus current
status and selected summarized evidence. It is closer to self-awareness than to
a static config file. Its snapshot contract is
`contracts/body_schema_snapshot/body_schema_snapshot.v0.schema.json`.

Current local verification uses
`scripts/build-body-schema-snapshot.ps1 -Check -NoWrite`, and the standard organ
test pack includes the same check as `body_schema.snapshot_contract`.

`Body Display Projection` is a display-safe stream for projector/background
clients. It can serve live body-state frames at up to the contract rate, but it
does not decide actions or interpret meaning.

`system-house-renderer` is a legacy source name. Use
`diagnostics.body_map_inspector` for the current organ role. If a viewer is
needed, treat it as a Body Schema / Body Display Projection consumer unless it
is only doing offline diagnostic inspection.

`cube-vault-background` is a legacy display/background route name. New code
should treat it as a display client under `display.projection`, not as a state
authority or Thought Core surface.

## Action Path

All external or actuator-facing operations should flow through
`action_request.v0`:

1. Input arrives as an input or observation event.
2. Thought Core, Reflex, GUI logic, or a system component may create an
   `action_request`.
3. Action Boundary validates structure, action id, target, risk, rate, and
   emergency-stop state.
4. The selected driver executes or rejects.
5. State/Event Ingest records the result.

Reflex can run without Thought Core, but it still uses Action Boundary before
touching a driver. Thought Core owns semantic safety and contextual judgment.
Action Boundary owns deterministic body-side guardrails.

## Where To Add Work

| Work | Preferred location |
| --- | --- |
| New cross-organ data format | `contracts/<name>/<name>.v0.schema.json` |
| New organ role or body role | `manifests/body-plans/` |
| New executable action or driver adapter | `manifests/driver-manifests/` |
| Legacy name compatibility | `manifests/compat-aliases/` |
| Current-state writer/normalizer | `runtime/state-event-ingest/` |
| Current-state reader/model | `runtime/status-store/` or `runtime/body-schema/` |
| Historical event/query behavior | `runtime/event-journal/` |
| Action validation behavior | `runtime/action-boundary/` |
| Side-effect-free communication fuzzing | `runtime/communication-fuzzing/` |
| Organ capability tests | `runtime/organ-test-packs/` and `manifests/tests/organ-test-packs/` |
| Launch/control-plane UI | `control-plane/` |
| Organ implementation code | nested repos under `organs/`, sourced by `manifests/organs/` |

## Safety Defaults

- Keep raw media, screenshots, prompts, full logs, local paths, and secrets out
  of tracked files.
- Keep raw payloads, local paths, `action_request` payloads, and driver action
  catalogs out of Body Display Projection frames.
- Use dummy drivers or dry-run paths for tests unless the user explicitly
  approves a live side effect.
- Keep compatibility names in aliases and migration docs. New runtime code
  should use canonical ids.
- Prefer small reversible slices. If a change affects a nested organ repo and
  the parent OS manifest, record both sides in the handoff.
