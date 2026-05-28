# Control Plane Checkouts

This directory is for local control-plane implementation checkouts used by
compatibility profiles.

The Agent OS repository owns manifests, runtime boundaries, and integration
rules. The legacy control-plane implementation remains its own Git repository
and is bootstrapped from `manifests/legacy/control-plane-reference.json`.

Do not commit nested control-plane implementation files into this repository.

