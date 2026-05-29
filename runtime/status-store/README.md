# Status Store

Status store holds current runtime projections. It is for latest state, not
historical truth.

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

A standard profile can be healthy while camera, speech, display, Home
Assistant, TouchDesigner, VOICEVOX, or another external integration is
unavailable. Those states should appear as capability details, not as whole-OS
failure unless a profile explicitly marks the capability boot-critical.
