# Service Manifests

Service manifests describe runnable or observable services in an Agent OS
profile. They do not vendor implementation code. They name the service,
selected organ source, contracts, start/status expectations, runtime outputs,
authority touched, and migration notes.

Legacy compatibility manifests may point at old launch scripts and old service
names while the native Agent OS runtime is still being built.

## Terms

Use `organ` for the capability or responsibility boundary. Use `organ service`
for a runtime-managed process, server, UI, or adapter that provides part of an
organ capability. OS substrate processes such as memory, approval, status, or
launch supervision are `runtime services`.

## Status And Availability

Lifecycle state and capability availability are separate.

Lifecycle state should stay small and mechanical:

- `stopped`
- `starting`
- `running`
- `stopping`
- `failed`

Capability availability explains what the system can actually do through a
running or expected organ service. External hardware, local devices, privacy
policy, and projection targets may make a capability unavailable without making
the whole OS failed.

Initial availability states:

- `available`: the capability is usable.
- `blocked`: the capability is intentionally held by policy, approval, or a
  missing prerequisite that must be resolved before use.
- `unavailable`: the capability cannot currently be used because hardware,
  drivers, external apps, devices, or local environment are absent or offline.
- `degraded`: the capability is usable with a known limitation, stale source,
  synthetic source, fallback route, or partial target.

System-manager status should report both layers when it can. For example, a
camera organ service can be `running` while gesture observation is
`unavailable` because no camera is connected, or `degraded` because a synthetic
video source is being used. The OS profile may still be healthy when a
non-critical capability is `blocked` or `unavailable`.
