# Action Boundary

Action Boundary is the deterministic body-side guard for action execution.

It is not the thought core and does not perform rich meaning interpretation.
Thought Core decides whether an operation is appropriate in context. Reflex may
issue a limited immediate request without waiting for Thought Core. Action
Boundary validates that the resulting `action_request` is structurally safe and
allowed before a driver can touch a device, external API, display runtime, or
internal actuator.

## Responsibilities

- Validate `contracts/action_request/action_request.v0.schema.json`.
- Reject unknown `action_id` values.
- Resolve action defaults through Action Catalog.
- Enforce driver-declared `risk_class` minimums.
- Block malformed targets, unregistered devices, unsafe values, rate-limit
  violations, and emergency-stop state.
- Keep dummy and real execution clearly separated.
- Report decisions through State/Event Ingest.

## Non-Responsibilities

- No natural-language interpretation.
- No conversation context reasoning.
- No long-term memory lookup.
- No direct Home Assistant, TouchDesigner, file, or network side effects without
  an approved driver boundary.

## v0 Result Classes

- `accepted`: request passed guard checks and was handed to a driver.
- `rejected_schema`: contract validation failed.
- `rejected_unknown_action`: action id is not in Action Catalog.
- `rejected_policy`: risk, permission, emergency-stop, or rate policy blocked it.
- `driver_error`: guard accepted the request, but driver execution failed.
