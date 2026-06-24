# Control Plane Checkouts

This directory is for local control-plane implementation checkouts used by
the standard distribution.

The Agent OS repository owns manifests, runtime boundaries, and integration
rules. The control-plane implementation remains its own Git repository and is
bootstrapped from `manifests/control-plane/standard.json`.

The standard checkout is the Thought Core control-plane implementation. Its
launcher diagnostics, timing summaries, and world-model projections do not by
themselves prove browser foreground behavior, Home Control operation,
HA-visible state, external observation, physical device effects, release
readiness, or final RR003 completion.

Do not commit nested control-plane implementation files into this repository.
