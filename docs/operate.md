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

Some launcher implementation paths still live under `home-control-stack`
because the reference Launcher grew out of the Home Control stack scripts. In
the standard profile, that path name is a package/history detail: it can start
or supervise selected standard runtime surfaces, not only Home Control, and it
does not by itself imply live Home Assistant action proof.

The front door defaults to no-live / no-device. It does not start the runtime stack,
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

Without `-Run`, this is a Launcher command preview. It shows the selected
Launcher route and ports without starting launcher-owned children.

## 実際に起動する

```powershell
.\sword.ps1 start -Run
```

Use `-Run` only when runtime execution is in scope. The normal reference path
starts or reuses the Launcher and reports readiness/status; it does not run a demo,
submit Home Assistant/Home Control actions, or claim proof.
Record this as runtime/status proof until browser, input/output, Home
Assistant, or physical observation checks are separately performed.

## Demo-safe settings

The Launcher left menu includes `Demo settings`. Tracked defaults live in
`manifests/demo-safe-settings/defaults.json` and fresh clones start with every
candidate disabled. Operator choices are stored as a local Launcher override in
the existing gitignored state directory, so they survive restarts but are not
committed.

Editable `demo_safe_settings` are separate from read-only
`demo_preflight_status`. Settings can allow a candidate for a later bounded
route, but they do not prove audio playback, browser-visible avatar motion,
Home Assistant state change, external observation, or physical device behavior.
Appliance command stimuli must hold when disabled, when HOLD_LIVE is active or
unreadable, or when count/duration limits would be exceeded. Current-state or
restore/off unreadability is a proof limitation for command-stimulus routes
unless the reviewed route explicitly requires those gates before command
submission.

## Camera input selection

Use the Launcher's connected-camera list as the normal camera-input selector.
`Refresh` enumerates local video inputs without starting Camera Hub or opening a
capture device. The UI shows friendly labels, while Launcher resolves and stores
an opaque local selection key in the existing gitignored state. Same-name
cameras remain separate candidates. Raw local device identity stays on the
Launcher server boundary and is not published in the API, command preview, or
routine logs. The resolved selection is passed to Camera Hub only on an
explicit stack start.

If the selected camera is absent, Launcher keeps that selection and marks it
missing; it must not silently substitute another camera. Refresh after reconnect
and select the same device when it is available again. The advanced manual field
is only a compatibility path for virtual or late-attached inputs that the local
enumerator cannot report; its removal gate is complete enumeration coverage for
those named consumers.

## Microphone input selection

Ordinary conversation uses the browser-managed speech path. Chrome's
`SpeechRecognition` and microphone permission preflight use the current
Chrome/Windows default input; the central `.env` does not select a microphone
device for this path. After replacing a microphone, confirm the Windows default
input and Chrome's site microphone permission. Do not add a DirectShow name to
the central env as a substitute for that browser setting.

The ai-talk-core `--mic` and `--mic-loop` commands are a separate
compatibility/maintainer route. On Windows their `ffmpeg-dshow` backend excludes
the prepared-sample virtual cable from automatic physical-device selection. One
physical candidate is selected automatically; zero or multiple candidates fail
closed and require an explicit `--mic-device`. This CLI selection does not
change the browser's ordinary conversation input.

## Projection calibration and speech bubble

Open the canonical Projection Visual operator page and select `投影調整`. This
single operator-only panel owns the local presentation settings. Passive and
stage outputs render the selected result but do not show the adjustment button
or controls. The values persist in this browser's local settings; they are not
written to tracked defaults, `.env`, or VRM files.

`Camera / Framing` provides a horizontal-FOV slider and exact numeric entry in
the validated 20–90 degree range, plus 30 / 35 / 45 degree presets. The UI uses
30 degrees as the distant-projection reference, 35 as the default, and 45 as
the near-display reference. `現在の構図を固定` keeps the current camera distance;
`モデル全体へ自動フィット` may change camera distance to fit the model, so use
the same framing mode when comparing FOV values. `Layer / Light` contains the
VRM lighting and Projection Effect controls.

`Speech Bubble` has short and long Japanese previews. Adjust font size, line
height, automatic or fixed width/height, normalized stage X/Y, tail side, and
tail target X/Y. The safe-area clamp may change the realized placement without
rewriting the selected values. Choose one timing policy:

- `音声終了＋保持`: keep the bubble through speech and the configured hold.
- `文字量から算出`: derive reading time up to the configured maximum.
- `固定時間`: use the configured duration.
- `次の発話まで`: keep it until another message replaces it.

The minimum-visible-time guard applies independently so a short event cannot
clear readable text immediately. `画角・外観を開いた時へ戻す` restores the
snapshot taken when the panel opened; `画角・外観を既定値へ戻す` restores the
product defaults. These controls are the current manual presentation authority.
Future AI-selected bubble presentation must use the same bounded settings seam
and remains a separate requirement.

## 投影用の別ウィンドウを出す

The Display Runtime GUI's `Separate projector output` controls the canonical
public browser-output route. Start the selected runtime, then open the Display
Runtime GUI from the Launcher. The route creates its own Projection Visual
source with `mode=stage-output` and `hud=0`; do not substitute an arbitrary page
or screen capture. The output window's actual title is `Projection Output`.

1. Select `SELECT WINDOW` in the Display Runtime GUI.
2. In the browser share picker, choose the newly opened Projection Visual stage
   window. Do not choose the operator GUI, the entire screen, or an unrelated or
   private window. The route accepts no audio, permits only a browser or window
   surface, and verifies the selected stage identity before streaming.
3. Wait until the GUI reports `Projector output active`, then move the
   `Projection Output` window to the intended display and use the browser or OS
   full-screen control as needed.
4. Select `STOP OUTPUT` before stopping the runtime. Closing the output window
   or ending browser sharing also terminates the owned capture; confirm
   `Output ended` or `Idle`.

If pop-ups or screen sharing are denied, treat the route as unavailable instead
of bypassing its source checks. A successful browser output is runtime evidence
only. Real-projector brightness, color, readability, and U1 acceptance remain a
separate physical and human check.

## Primary System Cell を人に見せる前の確認

```powershell
.\scripts\run-primary-system-cell-preflight.ps1
```

The user-visible route preflight separates allowed local display/audio/action
stimulus surfaces from holds for a later bounded route. By default it does not
call provider/network STT/TTS, microphone, camera, Home Assistant/Home Control
command submission, or `/actions` catalog routes. It returns local reachability
and preflight rows as summary/classes, not a route-ready claim.

Fold operator-observed screen, audio, and AC-control surface checks only with
explicit switches:

```powershell
.\scripts\run-primary-system-cell-preflight.ps1 `
  -OperatorConfirmedAvatarForeground `
  -OperatorConfirmedChromeWindowHygiene `
  -OperatorConfirmedAudioHeard `
  -OperatorConfirmedAcControlSurfaceReadable `
  -OperatorConfirmedRestoreOffReadable
```

Those switches are operator assertions for the Primary System Cell preflight. They are not
Home Control `/actions` proof, physical device proof, user-heard audio proof
for another route, or release/readiness claim.

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
`-Force` only when the current route explicitly allows forceful cleanup.

## live 家電操作を止めておく

```powershell
.\sword.ps1 hold-live
```

This writes the local hold marker `.cache\agent-os\control\hold-live.json`.
It is a safe-local control marker only. It does not execute Home Assistant,
providers, browser, camera, or device routes, and it is not a live-authority bypass.
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
