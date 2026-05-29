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
- `conscious_ready`: the OS can complete a deterministic minimum text turn
  without external AI/API access, receive response events, and project the
  result into status and event history.
- `full_conscious_ready`: the configured full turn path works with external
  AI/API access and expected integration surfaces such as expression forwarding
  or compatibility E2E probes.

The initial reflex probe is `scripts/check-runtime-reflex.ps1`. It is
deliberately cheap: read the standard profile, confirm boot-critical runtime
component skeletons exist, and return the current startup stage as JSON.

`conscious_ready` is the higher minimum ready state, but it should still be
deterministic and local-first. Secrets, network-dependent model calls, audio
devices, display targets, and home devices belong to `full_conscious_ready` or
profile-specific smoke/E2E checks unless a deployment explicitly marks them
boot-critical.

The initial `conscious_ready` probe is
`scripts/check-conscious-readiness.ps1`. It calls the Thought Core deterministic
readiness turn and requires `assistant.message` plus `turn.completed` without
using external LLM/API access.

`full_conscious_ready` may be too heavy for every routine status check, but it
is expected to be useful during initial migration, hardware bring-up, and
regression checks of the full configured stack.

Organ services such as camera, microphone, speech output, Home Assistant,
AITuber Kit, TouchDesigner, VOICEVOX, and other external-device integrations are
standard capabilities, but they can report `blocked`, `unavailable`, or
`degraded` without making the whole OS unhealthy unless a specific profile marks
one of them boot-critical.

Compatibility profiles and smoke tests may still require a stricter set of
legacy services so migration regressions are visible.

## Port Policy

Profiles distinguish the published default endpoint contract from local
validation overrides.

- `manifest_default` keeps the legacy-compatible localhost ports. This remains
  the final compatibility target and the default start/status contract.
- `isolated_override` is a first-class validation path for integration smoke
  checks, local port conflicts, and multiple active worker threads.

If a default port is already owned by another process, runtime tooling should
report the relevant service or capability as `blocked`, `unavailable`, or
`degraded`. It should not kill an unowned process automatically. A successful
isolated-port smoke run is valid operation-check evidence, while a final
standard-port pass can remain a separate compatibility checkpoint.
