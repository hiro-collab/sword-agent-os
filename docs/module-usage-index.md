# Module Usage Index

This page is the durable entry point for using and extending Agent OS modules.
Use it when a thread needs to decide where a feature, test, adapter, or
diagnostic belongs.

## Fast Route

Use this order before opening source files:

1. Name the system responsibility: input, state, decision, action, expression,
   observation, self-observation, memory, or diagnostics.
2. Pick the authority layer:
   `manifests/` for static selection, `contracts/` for boundary shape,
   `runtime/` for OS substrate, `organs/` for concrete capability code, and
   `scripts/` for setup or verification entrypoints.
3. Check whether the work is runtime behavior or a diagnostic reader. A
   diagnostic may observe and summarize; it must not become the action
   authority.
4. Keep proof claims at the layer that was actually tested. Source/static,
   no-live/mock, runtime/browser, live device, and physical observation are not
   interchangeable.

The main loop is:

```text
input/observation -> state -> decision -> guarded action/expression
-> observation/self-observation -> feedback
```

If a proposed change does not fit one step in that loop, write down why before
adding a new module or route.

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
| Avatar/body motion indicators | `runtime/motion-runtime/` | direct appliance execution or raw driver routes |
| Machine-readable reader/discovery surfaces | `contracts/` plus an owner-local JSON/output with `contract_ref` | README-only tables or coordination messages |

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

## Runtime vs Organs vs Services

Use `runtime/` for Agent OS substrate responsibilities and authorities: memory,
event journal, status store, process registry, routers, action boundary, action
catalog, organ drivers, and organ test-pack execution.

Use `organs/` for concrete capability modules or external organs. An organ is a
role or module category, such as action, environment, reflex, expression,
speech-input, display, or diagnostics. Many organs are also runnable services,
but their source does not need to live under a directory named `services/`.

Use `service` for the execution/process shape: an independently launched
server, worker, UI, bridge, or adapter. Today, service code can live under
`control-plane/` or under an organ directory. Do not introduce a top-level
`services/` directory merely to make server code fit the word "service".
`manifests/services/` names selected runnable or observable services for
profiles; it does not imply that implementation code must live under a
directory named `services/`.

In short: `organ` names what capability owns the responsibility; `service`
names how it runs; `runtime` names OS substrate authority.

Memory Core and Event Journal are core runtime substrate. They may eventually
run as managed processes, but their source-home and authority remain
`runtime/memory-core/` and `runtime/event-journal/` unless a later explicit
architecture decision moves them. They should not be moved under `organs/` just
because they can run like services.

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

## Motion Indicator Path

Avatar motion can be used as a visible indicator for action and attention. For
example, while a home appliance action is being previewed, executed, or checked,
Thought Core or Reflex may request a `motion_stimulus.v0` with
`kind: action_indicator` so the avatar points, gazes, or gestures toward the
display-safe target.

This path must stay separate from the action path:

1. The action itself still flows through `action_request.v0`, Action Boundary,
   and a driver.
2. Motion Runtime receives only a display-safe motion stimulus and optional
   safe target context.
3. The target context may use topology refs, safe display labels, and
   `action_request_id`.
4. It must not embed raw Home Assistant entity ids, service routes, private
   URLs, or device secrets.

## Where To Add Work

| Work | Preferred location |
| --- | --- |
| New cross-organ data format | `contracts/<name>/<name>.v0.schema.json` |
| New value that Thought Core, diagnostics, or source code should read | `docs/reference-surfaces.md`, then `contracts/<name>/<name>.v0.schema.json` plus owner-local reader surface with `contract_ref` |
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

## Adding A Reader Surface

Use `docs/reference-surfaces.md` when a developer wants to make a new value
readable by Thought Core, diagnostics, review agents, or another source module.
The short rule is: contract first, owner-local surface second, code reader
third.

1. Decide whether the value is a result packet, route/discovery map,
   current-state projection, event handoff, or static selection.
2. Add or reuse a schema in `contracts/`.
3. Put the concrete JSON/output under the owner that produces it, with
   `$schema`, `schema_version`, and `contract_ref`.
4. Add a human entrypoint only when an operator needs one.
5. Add maintenance assertions for path, contract listing, boundary booleans,
   non-claims, and the expected consumer names.

Do not teach Thought Core to scrape README prose, raw logs, generated local
config, screenshots, transcripts, or coordination messages.

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
