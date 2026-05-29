# Status Store

Status store holds current runtime projections. It is for latest state, not
historical truth.

## Latest-State Policy

Status store is the hot path for diagnostics viewers and other local readers.
Routine diagnostic pulses should overwrite the latest projection rather than
append history here.

Every projected observation should keep state separate from freshness:

- `state`: `available`, `degraded`, `unavailable`, `blocked`, or `unknown`.
- `freshness`: `fresh`, `stale`, `missing`, or `unknown`.

A stale `available` observation must not be displayed as currently available.
Readers should use `observed_at`, `received_at`, and `stale_after_seconds` to
decide whether a status is fresh enough for the current view.

The first target size for `status-store/current.json` is under 1 MB. Heavier
details should be represented as evidence references, not embedded payloads.

The first writer is `scripts/update-diagnostics-status.ps1`. It writes
`.cache/agent-os/status/current.json` and treats it as generated local runtime
state.

## Health Projection

Status projections should keep OS boot health separate from body capability
availability.

- Boot health reports whether boot-critical runtime services, the basic runtime
  reflex, and the minimum turn-processing path are usable.
- Startup stage reports `nonresponsive`, `reflex_alive`, `conscious_ready`, or
  `full_conscious_ready`.
- Capability availability reports whether a specific organ service ability is
  `available`, `blocked`, `unavailable`, or `degraded`.

The first `reflex_alive` implementation is `scripts/check-runtime-reflex.ps1`.
It returns JSON suitable for status projection before full Thought Core startup
is required.

`conscious_ready` should project a deterministic no-external-API minimum turn
path. `full_conscious_ready` can project configured external model/API access
and broader integration checks.

The first `conscious_ready` implementation is
`scripts/check-conscious-readiness.ps1`, which delegates to the Thought Core
readiness turn and validates the required event stream without external LLM/API
access.

The first organ availability projection is
`scripts/check-organ-readiness.ps1`. It reports per-organ source state, local
gaps, safe check commands, and optional live service health as `pass`,
`degraded`, `unavailable`, `blocked`, or `not_yet_checked`-compatible
projection data. These organ results feed `full_conscious_ready` and capability
details, not the lower boot-health stages by themselves.

A standard profile can be healthy while camera, speech, display, Home
Assistant, TouchDesigner, VOICEVOX, or another external integration is
unavailable. Those states should appear as capability details, not as whole-OS
failure unless a profile explicitly marks the capability boot-critical.
