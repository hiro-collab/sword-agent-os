# Status Store

Status store holds current runtime projections. It is for latest state, not
historical truth.

## Health Projection

Status projections should keep OS boot health separate from body capability
availability.

- Boot health reports whether boot-critical runtime services and the minimum
  turn-processing path are usable.
- Capability availability reports whether a specific organ service ability is
  `available`, `blocked`, `unavailable`, or `degraded`.

A standard profile can be healthy while camera, speech, display, Home
Assistant, TouchDesigner, VOICEVOX, or another external integration is
unavailable. Those states should appear as capability details, not as whole-OS
failure unless a profile explicitly marks the capability boot-critical.
