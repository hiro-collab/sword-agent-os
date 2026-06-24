# Organ Manifests

Organ manifests record implementation sources for organ checkouts. The Agent OS
repository owns the manifest, target placement, contracts, authorities, and
runtime integration rules. The organ implementation code stays in its own Git
repository.

`standard-sources.json` is the standard distribution source manifest.

Use `scripts/bootstrap-organs.ps1 -DryRun` before cloning or checking organ
sources into the local workspace.
