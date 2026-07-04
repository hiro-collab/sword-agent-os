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
pwsh -NoProfile -File .\scripts\check-runtime-reflex.ps1
pwsh -NoProfile -File .\scripts\check-conscious-readiness.ps1
pwsh -NoProfile -File .\scripts\check-organ-readiness.ps1
pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1
pwsh -NoProfile -File .\scripts\run-organ-test-packs.ps1
```

`check-distribution-pins.ps1` can report `local_artifact_hold_at_manifest_pin`
when source pins match but a local runtime artifact still blocks strict release
or fresh-install readiness.

### Overall Test Ladder V2 Report Shape

The overall test ladder v2 daily confidence smoke should publish only the
`contracts/overall_test_ladder_report/overall_test_ladder_report.v2.schema.json`
shape until a later front-door runner route is selected. Treat this as a
classed report contract: every row must carry `proof_ceiling`, `non_claims`,
and `raw_private_publication_flags=false`; `evidence_summary` must be
class/count/bucket-only; `pass_candidate` must not mean RR003 pass, final
readiness, release readiness, or a proof upgrade.

Do not use this schema route to start runtime/browser/audio/Home Control or
TouchDesigner work. Those layers remain separate exact routes with their own
stop conditions and proof ceilings. If a layer can only be explained by sharing
raw transcripts, audio/media, screenshots/browser frames, TouchDesigner
content, provider payloads, Home Assistant raw payloads, entity/device ids,
private paths/filenames/URLs, exact env values, stdout/stderr, stack traces,
tokens, or secrets, block the shared report publication instead.

## Optional / Local-Media Replay Preview

When local `local/media/README.md` and `local/media/media-index.json` exist,
you can preview replay commands by asset id. The helper output is
`source/static-command-preview`; the next proof layer is
`bounded local-media replay`.

It is not real camera, real microphone, browser runtime, virtual audio, live
Home Assistant, or long-run/stress proof.

After a reset, `_secret_inputs` alone is not enough. Prepare the workspace-local
index first from a private seed file:

```powershell
pwsh -NoProfile -File .\scripts\prepare-local-media-index.ps1 -DryRun
pwsh -NoProfile -File .\scripts\prepare-local-media-index.ps1
```

If the secret input bundle is outside the fresh clone root, pass both roots
explicitly. The output and JSON still use placeholders rather than private paths:

```powershell
pwsh -NoProfile -File .\scripts\prepare-local-media-index.ps1 -WorkspaceRoot <fresh-clone-root> -SecretInputsRoot <private-secret-inputs-root> -DryRun
```

The seed file lives under `_secret_inputs\local-media-index.seed.json` and is
not tracked. The preparation helper copies private media into ignored
`local/media/assets/`, writes `local/media/media-index.json`, and prints only
redacted counts and asset ids.

Because asset ids are visible in proof output, keep them non-personal and
non-secret. Do not encode names, places, accounts, device locations, or private
labels in an asset id. Duplicate ids are blocked.

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
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1 -WorkspaceRoot <fresh-clone-root> -SecretInputsRoot <private-secret-inputs-root>
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

## First-Run Operator Acceptance

`README.md` and `docs/first-run-operator-guide.md` are user-facing promises.
Every operation listed there should have one of these outcomes in a first-run
verification report:

- works in the stated scope;
- not prepared because a required local file, secret, device, or route is
  absent;
- failed with an actionable problem.

Do not leave a documented first-run operation as untested while also claiming
the current install path is complete.

Minimum post-install checks:

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 start
```

When runtime/browser behavior is in scope, include start/stop safety:

```powershell
.\sword.ps1 start -Run
.\sword.ps1 stop
.\sword.ps1 stop -Run
```

or use the launcher wrappers:

```powershell
.\start-home-control-launcher.bat
.\stop-home-control-launcher.bat
```

Report startup/shutdown separately. These field names are for test reports; the
plain-language operator guide describes the same checks as start, stop, and
cleanup safety.

```text
launcher_start=<pass|blocked|held>
selected_workspace=<current|stale|unknown>
ui_links=<reachable|degraded|blocked|not-tested>
stop_preview=<pass|blocked|not-tested>
stop_run=<pass|blocked|not-tested>
selected_ports_clear_after_stop=<true|false|not-tested>
cleanup_blocker=<none|exact blocker>
```

Voice, gesture, avatar, Home Control, Environment State, external observation,
and physical proof remain separate rows. If the required microphone, camera,
`gesture_model.pkl`, Home Assistant config, device, or observation source is
missing, keep that row `held` instead of weakening the test.

## Optional / Home Control Live Proof

Do not keep live or physical proof recipes in this general command reference.
Use `docs/live-home-control-proof.md` for the ticketed ladder, and keep command
submission, HA-visible state, external observation, and physical proof as
separate rows.

## Optional / SwitchBot Surface Read-Only Inspection

Use this helper when a review needs to know whether Home Assistant exposes
readable SwitchBot-style `cover` / `vacuum` surfaces before opening a live route
or changing Home Control action metadata. It performs read-only Home Assistant
GET requests only; it does not call services, execute scripts, preview actions,
or mutate appliances.

```powershell
pwsh -NoProfile -File .\scripts\inspect-home-control-switchbot-surfaces.ps1
pwsh -NoProfile -File .\scripts\inspect-home-control-switchbot-surfaces.ps1 -Json
```

Default output hides raw entity ids and current state values. Use it to classify
whether a SwitchBot curtain-style door can be mapped to
`verification.position.current_position`, and whether a SwitchBot vacuum can be
mapped to HA-visible start/pause/return states. The helper also reports the
configured `live_test_readiness`, restore/stop classes, safety blockers, and
proof ceiling for each target row. Do not treat these read-only surface checks
as physical obstruction, floor/path safety, or physical device success proof.

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
