# Profiles

Profiles describe the runtime components and organ capabilities expected for an
Agent OS shape.

## Boot Health

Profile health is not the same as full body capability.

The standard profile keeps boot-critical requirements small:

- core runtime services for routing, status, process registry, event journal,
  communication governance, memory, and approvals
- a basic runtime reflex response
- a minimum turn-processing path for the higher ready state

Startup is staged:

- `nonresponsive`: no basic runtime reflex can answer; the OS is not alive
  enough to operate.
- `reflex_alive`: the OS substrate can answer a simple liveness or status
  reflex without full thought.
- `conscious_ready`: the OS can complete a minimum text turn, receive Thought
  Core response events, and project the result into status and event history.

Organ services such as camera, microphone, speech output, Home Assistant,
AITuber Kit, TouchDesigner, VOICEVOX, and other external-device integrations are
standard capabilities, but they can report `blocked`, `unavailable`, or
`degraded` without making the whole OS unhealthy unless a specific profile marks
one of them boot-critical.

Compatibility profiles and smoke tests may still require a stricter set of
legacy services so migration regressions are visible.
