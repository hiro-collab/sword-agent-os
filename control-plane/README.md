# Control Plane Checkouts

This directory is for local control-plane implementation checkouts used by
the standard distribution and compatibility profiles.

The Agent OS repository owns manifests, runtime boundaries, and integration
rules. The control-plane implementation remains its own Git repository and is
bootstrapped from `manifests/control-plane/standard.json`. The older
`manifests/legacy/control-plane-reference.json` path is retained as a
compatibility alias for legacy tooling.

The standard checkout is a Thought Core / compatibility control-plane
implementation. It may expose launcher diagnostics, timing summaries, and
world-model projections, but those surfaces are source/static or runtime
summary layers. They do not by themselves prove browser foreground behavior,
Home Control operation, HA-visible state, external observation, physical device
effects, release readiness, or final RR003 completion.

Do not commit nested control-plane implementation files into this repository.
