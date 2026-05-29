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
.\scripts\system.ps1 start -Profile thought-core-v0 -LegacyDelegate -DryRun -SkipVoicevoxCheck
.\scripts\system.ps1 stop -Profile thought-core-v0 -DryRun -Force
.\scripts\check-launch-readiness.ps1
.\scripts\prepare-compat-launch.ps1 -ImportLocalConfig
.\scripts\run-compat-smoke.ps1 -UseIsolatedPorts
.\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -RunManualTurn
.\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -RunManualTurn -RunSafeIntegrationProbes
.\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -RunManualTurn -RunSafeIntegrationProbes -RunWatcherProbe
.\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc -RunManualTurn -RunSafeIntegrationProbes -RunWatcherProbe
.\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -RunWatcherProbe -RequireWatcherAituberForward
```

`status` is native to this repository and reads Agent OS manifests. `start` and
`stop` are compatibility delegates to the bootstrapped control-plane checkout
until the runtime becomes fully native; non-dry-run delegation requires
`-LegacyDelegate`. `check-launch-readiness.ps1` reports clone, tool, secret,
asset, endpoint, and legacy-layout gaps before attempting a real launch.
`prepare-compat-launch.ps1` creates ignored compatibility layout aliases and
can import local-only config/env files from the legacy workspace without
printing secret values. It also imports the local MediaPipe gesture model into
the ignored organ checkout when present. `run-compat-smoke.ps1` defaults to the
legacy `thought-core-v0` ports; pass `-UseIsolatedPorts` to temporarily move the
stack to the `188xx` range for local port conflicts or side-by-side legacy
testing. Its MediaPipe readiness wait is adjustable with
`-MediapipeReadyTimeoutSeconds` for slow camera initialization. Pass
`-MediapipeVideoSource testsrc` when the real camera is unavailable but the
MediaPipe/RTSP/Camera Hub service path still needs to be smoke-tested. Pass
`-RunManualTurn` to add a non-action Thought Core turn after the service probes.
Pass `-RunSafeIntegrationProbes` to add token-protected
environment state, AITuber direct_send, and Home Assistant `dry_run` checks
without executing a real home action. Environment state liveness uses
`/health`; `/environment/current` remains the token-protected state API.
`-RunWatcherProbe` writes a temporary safe ai-talk-core handoff, waits for the
watcher to complete a Thought Core turn, reports whether AITuber Kit forwarding
was observed, then restores the previous handoff cache. The smoke runner passes
a longer watcher-to-AITuber HTTP timeout by default; override it with
`-WatcherAituberHttpTimeoutSeconds` when needed. Add
`-RequireWatcherAituberForward` when the AITuber forwarding path should be a hard
smoke-test requirement.
