# Control Plane Checkouts

This directory is for local control-plane implementation checkouts used by
compatibility profiles.

The Agent OS repository owns manifests, runtime boundaries, and integration
rules. The control-plane implementation remains its own Git repository and is
bootstrapped from `manifests/control-plane/standard.json`. The older
`manifests/legacy/control-plane-reference.json` path is retained as a
compatibility alias for legacy tooling.

Do not commit nested control-plane implementation files into this repository.
