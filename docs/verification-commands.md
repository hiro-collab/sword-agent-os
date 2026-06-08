# Verification Commands

This is the command reference for Sword Agent OS verification lanes.

For the conceptual map of the standard distribution, read
`docs/standard-distribution-map.md`. This document is narrower: it lists the
commands to run and the proof layer each command can support. Do not treat a
lower proof layer as proof for live hardware, real camera, real microphone, or
physical appliance behavior.

## Required / Source-Static

Use these commands before or after startup when you want a quick check of
manifest health, source pins, runtime contracts, organ readiness, and launch
readiness. These commands are not a substitute for live review.

```powershell
pwsh -NoProfile -File .\scripts\doctor-distribution.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\check-distribution-pins.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\system.ps1 status -Profile thought-core-v0 -ManifestOnly
pwsh -NoProfile -File .\scripts\check-runtime-reflex.ps1
pwsh -NoProfile -File .\scripts\check-conscious-readiness.ps1
pwsh -NoProfile -File .\scripts\check-organ-readiness.ps1
pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1
pwsh -NoProfile -File .\scripts\run-organ-test-packs.ps1
```

## No-Camera / No-Live Compatibility Smoke

```powershell
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc -RunManualTurn
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc -RunManualTurn -RunSafeIntegrationProbes
```

This smoke uses a test source. It is not proof of real camera video, real
microphone input, or physical appliance behavior. `-RunSafeIntegrationProbes`
includes mock/no-live safe probes, but when `THOUGHT_CORE_TOOLS_ADAPTER=mock`
is still set, the probe does not send actions to live Home Assistant.

## Optional / Local-Media Replay Preview

When local `local/media/README.md` and `local/media/media-index.json` exist,
you can preview replay commands by asset id. The helper output is
`source/static-command-preview`; the next proof layer is
`bounded local-media replay`.

It is not real camera, real microphone, browser runtime, virtual audio, live
Home Assistant, or long-run/stress proof.

```powershell
pwsh -NoProfile -File .\scripts\run-local-media-replay.ps1 -Mode camera-hub -AssetId gesture.sword.20260603
pwsh -NoProfile -File .\scripts\run-local-media-replay.ps1 -Mode camera-hub -AssetId gesture.victory.20260603
pwsh -NoProfile -File .\scripts\run-local-media-replay.ps1 -Mode camera-hub -AssetId gesture.open_hand.20260603
pwsh -NoProfile -File .\scripts\run-local-media-replay.ps1 -Mode room-light -AssetId vision.room_light.on.20260603
pwsh -NoProfile -File .\scripts\run-local-media-replay.ps1 -Mode room-light -AssetId vision.room_light.off.20260603
```

Use this report shape when sharing results:

```text
asset_id=<id>
proof_layer=source/static-command-preview
next_proof_layer=bounded local-media replay
result=<pass|fail|blocked|preview-only>
summary=<redacted counts/status labels only>
raw_media_shared=false
raw_transcript_shared=false
generated_output_written=false
live_action_executed=false
```

When replaying local media, do not share raw media, frames, audio, transcripts,
or private absolute paths. Gesture positive replay, gesture contrast
false-positive checks, and room-light on/off replay are local-media replay
proof. Gesture-to-voice gate, STT/input, Thought Core turn, real camera, real
mic, browser runtime, and ticketed live appliance action are separate proof
layers and should be reported separately.

## Optional / Full Install Verification Helper

Use this helper when several lane states should be summarized in one redacted
report:

```powershell
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1
```

The default is `default_safety=no-live/no-device`. It summarizes `show-version`,
`install-distribution -DryRun`, manifest validation, pin check, local-media
preview, and voice-gate preview as source/static. Real camera, real microphone,
virtual audio, browser runtime, gesture gate, and Home Assistant live action
remain separate layers shown as `held` or `blocked`.

Open only the proof layers you need:

```powershell
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1 -RunNoLiveSmoke
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1 -RunRuntimeHttpChecks
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1 -RequestRealCamera
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1 -RequestVoicevoxStartup
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1 -RequestVirtualAudio
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1 -RequestGestureGate
```

`-RequestLiveHomeAssistant` is not permission for physical action. Physical
action requires explicit ticket confirmation such as
`-ConfirmHomeAssistantTicket`, plus action id, restore id, expected state, max
count, and stop conditions. If those inputs are missing, the helper holds the
lane. Even when they are present, this helper does not directly execute physical
appliance action. It reports Home Assistant preflight and state-check readiness,
then points to the separate live-owner ladder for actual execution.

`git_unreadable` is not the same as a true source pin mismatch. Recheck in the
normal user context before treating it as source drift.

## Optional / Runtime-Browser

Launch Manager, Start Stack, Projection Visual, AITuber Kit browser display,
microphone, real camera, and VRM display are runtime/browser checks. Completing
README install-readiness does not prove browser UI behavior.

You can prove sword-sign positive gesture detection with the Camera Hub /
gesture topic positive event, timestamp, and status label. Gesture-to-voice
input transition can be shown with speech gate status and turn trace. Raw
camera images, screenshots, and audio are local-only.

## Live Caution

For any live action that can affect real appliances, define the target, number
of executions, interval, stop condition, and restore path before executing. Do
not start with broad appliance fuzzing or long-running appliance operation.
