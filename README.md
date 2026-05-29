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
.\scripts\check-runtime-reflex.ps1
.\scripts\check-conscious-readiness.ps1
.\scripts\check-organ-readiness.ps1
.\scripts\check-launch-readiness.ps1
.\scripts\run-organ-test-packs.ps1
.\scripts\start-launcher.ps1 -OpenBrowser
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
`-LegacyDelegate`. `check-runtime-reflex.ps1` is the lowest-level liveness
probe: it reads the standard profile, checks that boot-critical runtime
component skeletons exist, and returns `reflex_alive` when the OS substrate can
answer a simple status reflex. `check-conscious-readiness.ps1` calls the
Thought Core deterministic no-external-API readiness turn and returns
`conscious_ready` only when `assistant.message` and `turn.completed` are
observed without using the LLM/API path. `check-launch-readiness.ps1` reports
clone, tool, secret, asset, endpoint, and legacy-layout gaps before attempting
a real launch. `check-organ-readiness.ps1` projects per-organ validation and
availability from the selected organ manifest; pass `-CheckEndpoints` to add
live HTTP/TCP health checks and `-UseIsolatedPorts` when checking a smoke stack
started on the temporary `188xx` port range.
It keeps source/manifest validation separate from functional availability:
local checkouts that are ahead of the manifest remain validation warnings, but
do not make a live organ unavailable when its required paths and endpoint checks
are otherwise healthy.
`run-organ-test-packs.ps1` reads the standard organ test pack manifest and
runs the safe `auto` checks by default. Add `-Modes auto,replay`, `-Modes
auto,live -PortMode isolated_override`, or `-Modes auto,manual,deep` to include
fixture, live-service, manual, or deeper checks; side-effecting live actions
remain gated behind `-AllowSideEffects`.
`prepare-compat-launch.ps1` creates ignored compatibility layout aliases and
can import local-only config/env files from the legacy workspace without
printing secret values. It also imports the local MediaPipe gesture model into
the ignored organ checkout when present. `run-compat-smoke.ps1` defaults to the
legacy `thought-core-v0` ports; pass `-UseIsolatedPorts` to temporarily move the
stack to the `188xx` range for local port conflicts or side-by-side legacy
testing. The default and isolated port sets are declared in
`manifests/services/thought-core-v0-compat.json` under `port_modes`, so launch
and readiness checks share the same source of truth. Its MediaPipe readiness wait is adjustable with
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
smoke-test requirement. These compatibility smoke checks belong to
`full_conscious_ready`; the lower `conscious_ready` stage should be testable
without external AI/API access or optional organ service integrations.

## Launch GUI

The first launch GUI is the inherited Home Control Launcher, started through an
Agent OS wrapper so the workspace root is correct:

```powershell
.\scripts\start-launcher.ps1 -OpenBrowser
```

For the temporary isolated validation stack, run:

```powershell
.\scripts\start-launcher.ps1 -PortMode isolated_override -StackStateDir .cache\home-control-stack-live -OpenBrowser
```

or:

```bat
start-home-control-launcher.bat
```

The launcher now defaults to the `thought-core-v0` profile. Legacy Dify profiles
remain available under compatibility options, but normal startup should use the
Thought Core profile. Routine launcher status uses process evidence for
WebSocket services so refreshing the GUI does not create MediaPipe monitor
connection churn; use explicit smoke/deep checks for strict WebSocket
handshake truth.
