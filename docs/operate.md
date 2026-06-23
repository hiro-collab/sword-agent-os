# Operate Sword Agent OS

This page is the short operator front door for the standard distribution. It is
organized by what you want to do, not by internal subsystem.

For the full first-run path from prerequisites, clone, local assets, `.env`,
launcher, and trial operations, use `docs/first-run-operator-guide.md`.

The Launcher is the standard reference control surface for local operators. It
is not the only valid ignition path for the Sword runtime stack: integrations
may start the same selected runtime surfaces from their own launch system, then
use the same readiness, demo-safe settings, action-boundary, and cleanup
contracts.

The front door defaults to no-live / no-device. It does not start Start Stack,
call a provider, operate Home Assistant, use a browser profile, open
camera/audio, or claim physical proof unless a later route explicitly says so.
`status`, `verify`, and `doctor` are no-live by default; `-NoLive` is only an
optional intent label for reports, not a stronger mode.

<!-- operate:no-live-default -->

## まず安全に見る

```powershell
.\sword.ps1 status
```

Use this when you only want the current version, selected profile, manifest
summary, and runtime route preview. This is a source/status layer check.

## 壊れていないか確認する

```powershell
.\sword.ps1 verify
```

Use this before a fresh install, review, or handoff. It validates manifests,
strict distribution pins, and no-live launch readiness. It does not prove
runtime/browser behavior, Home Assistant state, or physical devices.

## 原因を分類する

```powershell
.\sword.ps1 doctor
```

Use this when install/readiness output is unclear. Treat the result as
distribution diagnosis, not as release readiness or live-device proof.

## 起動する前に見る

```powershell
.\sword.ps1 start
```

Without `-Run`, this is a Start Stack command preview. It shows the selected
Launch Manager route and ports without starting launcher-owned children.

## 実際に起動する

```powershell
.\sword.ps1 start -Run
```

Use `-Run` only when runtime execution is in scope. The normal reference path
starts or reuses the Launcher and reports readiness/status; it does not run a demo,
submit Home Assistant/Home Control actions, or claim proof. Use
`-CompatLegacyDelegate` only for an explicit legacy-stack compatibility route.
Record this as runtime/status proof until browser, input/output, Home
Assistant, or physical observation checks are separately performed.

## Demo-safe settings

The Launcher left menu includes `Demo settings`. Tracked defaults live in
`manifests/demo-safe-settings/defaults.json` and fresh clones start with every
candidate disabled. Operator choices are stored as a local Launcher override in
the existing gitignored state directory, so they survive restarts but are not
committed.

Editable `demo_safe_settings` are separate from read-only
`demo_readiness_status`. Settings can allow a bounded demo candidate, but they
do not prove audio playback, browser-visible avatar motion, Home Assistant
state change, external observation, or physical device behavior. Appliance demo
actions must hold when disabled, when HOLD_LIVE is active or unreadable, or
when count/duration limits would be exceeded. Current-state or restore/off
unreadability is a proof limitation for command-stimulus routes unless the
reviewed route explicitly requires those gates before command submission.

## 止める前に見る

```powershell
.\sword.ps1 stop
```

Without `-Run`, this is a stop preview. It shows what would be stopped without
touching runtime children.

## 実際に止める

```powershell
.\sword.ps1 stop -Run
```

Use this only for launcher-owned runtime children in the selected profile. Use
`-Force` only when the current route explicitly allows forceful cleanup. Add
`-CompatLegacyDelegate` only when the route explicitly targets the legacy stack.

## live 家電操作を止めておく

```powershell
.\sword.ps1 hold-live
```

This writes the local hold marker `.cache\agent-os\control\hold-live.json`.
It is a safe-local control marker only. It does not execute Home Assistant,
providers, browser, camera, or device routes, and it is not an approval bypass.
See `runtime/control/README.md` for the control vocabulary.

## Home Assistant を外部環境につなぐ

```powershell
notepad .\docs\home-assistant-setup.md
```

Use the setup page before moving from mock/no-live checks to a real Home
Assistant instance. A reachable Home Assistant bridge is only connection proof.
HA-visible action proof also needs the selected clone/worktree to load a
private/live full-schema config or reviewed clone-local equivalent.

## もっと細かく確認する

| Goal | Command | Proof layer |
| --- | --- | --- |
| First-run operator path | `docs/first-run-operator-guide.md` | staged install/runtime guide |
| Version and profile summary | `pwsh -NoProfile -File .\scripts\show-version.ps1 -Profile standard` | source/static |
| Dry-run install plan | `pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard -DryRun` | install plan |
| Manifest validation | `pwsh -NoProfile -File .\scripts\validate-manifests.ps1` | source/static |
| Pin status | `pwsh -NoProfile -File .\scripts\check-distribution-pins.ps1 -Profile standard -Strict` | manifest/pin |
| Readiness without port checks | `pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1 -SkipPortChecks` | readiness/no-live |
| Local media index dry-run | `pwsh -NoProfile -File .\scripts\prepare-local-media-index.ps1 -DryRun` | local media preparation |
| Runtime launcher UI | `.\start-home-control-launcher.bat` | runtime/browser only after user action |
| Browser-visible avatar motion | `examples/starter-profiles/projection-visual/README.md` | browser-visible avatar motion |

## What The Front Door Does Not Prove

No-live front-door checks do not prove live microphone input, live camera
classification, provider response quality, Projection Visual browser behavior,
Home Assistant action execution, Home Assistant state match, external
observation, or physical device movement. Use `docs/proof-layers.md` for those
boundaries.
