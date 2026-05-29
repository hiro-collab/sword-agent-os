# Organ Test Pack Manifests

This directory contains Agent OS test-pack manifests. Test packs declare how to
verify organ capabilities from outside the organ implementation.

- `standard.json`: first standard-cell pack for the selected thought-core-v0
  compatibility organs.

The manifest is data. The execution rules live in
`runtime/organ-test-packs/README.md`, and the first runner is
`scripts/run-organ-test-packs.ps1`.
