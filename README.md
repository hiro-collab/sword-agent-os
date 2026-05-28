# Sword Agent OS

Sword Agent OS is the new standard Agent OS workspace for coordinating organs,
runtime services, policies, manifests, and development governance.

This repository is the source of truth for the Agent OS itself. Legacy
`sword-voice-agent` / `sword-agent-system` repositories are reference sources,
not active edit targets.

## Start Here

- [Remote workstation setup](docs/remote-workstation-setup.md)
- [Thread startup guide](docs/thread-startup-guide.md)
- [Legacy reference index](docs/legacy-reference-index.md)

## Initial Runtime Facade

The first compatibility profile is `thought-core-v0-compat`, which also accepts
the legacy profile name `thought-core-v0`:

```powershell
.\scripts\system.ps1 status -Profile thought-core-v0 -ManifestOnly
.\scripts\system.ps1 status -Profile thought-core-v0
.\scripts\system.ps1 start -Profile thought-core-v0 -DryRun
.\scripts\system.ps1 stop -Profile thought-core-v0 -DryRun -Force
```

`status` is native to this repository and reads Agent OS manifests. `start` and
`stop` are compatibility delegates to the bootstrapped control-plane checkout
until the runtime becomes fully native; non-dry-run delegation requires
`-LegacyDelegate`.
