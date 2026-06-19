# Operate Sword Agent OS

This page is the short operator front door for the standard distribution. It
keeps no-live setup checks separate from runtime, browser, Home Assistant, and
physical-device proof.

## Front Door

From the repository root:

```powershell
.\sword.ps1 status -NoLive
.\sword.ps1 verify -NoLive
.\sword.ps1 doctor -NoLive
```

These commands are safe local checks. They do not start Start Stack, call a
provider, operate Home Assistant, use a browser profile, open camera/audio, or
claim physical proof.

`.\sword.ps1 start` and `.\sword.ps1 stop` are command previews by default.
They show the selected Launch Manager route without starting or stopping
runtime children. Use `-Run` only under an explicit runtime execution lease.

`.\sword.ps1 hold-live` writes a local hold marker under `.cache/agent-os/`.
It is a safe-local control marker only; it is not an approval bypass and it
does not execute Home Assistant, providers, browser, camera, or device routes.

## Common Commands

| Goal | Command | Proof layer |
| --- | --- | --- |
| Version and profile summary | `pwsh -NoProfile -File .\scripts\show-version.ps1 -Profile standard` | source/static |
| Dry-run install plan | `pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard -DryRun` | install plan |
| Manifest validation | `pwsh -NoProfile -File .\scripts\validate-manifests.ps1` | source/static |
| Pin status | `pwsh -NoProfile -File .\scripts\check-distribution-pins.ps1 -Profile standard -Strict` | manifest/pin |
| Readiness without port checks | `pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1 -SkipPortChecks` | readiness/no-live |
| Local media index dry-run | `pwsh -NoProfile -File .\scripts\prepare-local-media-index.ps1 -DryRun` | local media preparation |
| Runtime launcher UI | `.\start-home-control-launcher.bat` | runtime/browser only after user action |

## What The Front Door Does Not Prove

No-live front-door checks do not prove live microphone input, live camera
classification, provider response quality, Projection Visual browser behavior,
Home Assistant action execution, Home Assistant state match, external
observation, or physical device movement. Use `docs/proof-layers.md` for those
boundaries.
