# voice-avatar Starter Profile

<!-- starter-profile:voice-avatar -->

This starter profile is the safe voice/avatar route for a new environment. It
helps an operator understand voice readiness, local-media voice-gate preview
shape, and avatar/display configuration boundaries before any provider call,
TTS playback, browser runtime proof, camera/mic route, or physical observation
is claimed.

It is an example profile, not a new front-door command and not live
authorization. Completion of this profile is source/docs/no-live readiness only.

## Goal

<!-- starter-profile:voice-avatar-goal -->

Reach a redacted no-live checkpoint for the Voice Pack and Avatar / Projection
Pack:

- front-door status and verify checks run without opening live routes;
- voice/TTS readiness is classified without installing or updating tools;
- provider/TTS readiness stays separate from audio playback and avatar
  rendering;
- local-media voice-gate proof is kept at source/static command-preview layer;
- avatar configuration is located without claiming browser rendering or motion;
- provider calls, raw prompts, raw transcripts, audio/media, screenshots,
  camera/mic input, and physical observation stay out of scope.

Proof ceiling: `source_docs_no_live_voice_avatar_readiness`.

## Safe Route

<!-- starter-profile:voice-avatar-route -->

Start with front-door checks:

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 start
```

`start` is a command preview by default. Do not add `-Run` for this starter
profile.

Then read the setup docs:

- `docs/customize.md`
- `docs/local-configuration.md`
- `docs/operate.md`
- `docs/proof-layers.md`

Check VOICEVOX endpoint readiness without starting or installing anything:

```powershell
pwsh -NoProfile -File .\scripts\check-voicevox-readiness.ps1
```

This command may classify the endpoint as ready, skipped, or blocked. It does
not play audio, change global audio devices, install or update VOICEVOX, or
prove TTS output. `-StartIfNeeded` is outside this starter profile unless a
separate exact route says otherwise.

If a reviewed local media index and asset id are available, inspect the
voice-gate helper shape in preview mode:

```powershell
pwsh -NoProfile -File .\scripts\test-local-media-voice-gate.ps1 -Mode preview -AssetId <local-media-asset-id>
```

This is a source/static command preview. It must not be reported as STT
execution, audio playback, browser runtime proof, Thought Core turn proof,
avatar motion, or user-facing voice proof.

## Report Shape

<!-- starter-profile:voice-avatar-result-fields -->

Report only redacted readiness classes, selected config refs, and blockers.
Use `docs/proof-layers.md` for proof boundaries instead of copying another
result-field ledger into this starter profile.

## Stop Conditions

<!-- starter-profile:voice-avatar-stop-conditions -->

Stop before claiming the next proof layer if:

- `status`, `verify`, or `start` command preview reports a blocker.
- The route needs `.\sword.ps1 start -Run` to continue.
- VOICEVOX is not ready and continuing would require `-StartIfNeeded`.
- The local media index or requested asset id is missing.
- The next step would read from a real microphone, camera, browser session, or
  provider service.
- The next step would play audio, generate TTS, dispatch avatar motion, or
  observe a rendered avatar.
- The explanation would require raw prompts, provider payloads, audio/media,
  screenshots, transcripts, private local paths, tokens, or private model/asset
  details.

## Boundary

<!-- starter-profile:voice-avatar-does-not-prove -->

This profile remains source/docs/no-live readiness. It does not claim provider
quality, audio playback, real microphone or camera input, browser runtime reachability, rendered avatar visibility, avatar motion dispatch, external/user observation, physical proof, or release readiness.

## Optional Next Paths

<!-- starter-profile:voice-avatar-next-paths -->

- For voice or avatar configuration, use `docs/customize.md` and
  `docs/local-configuration.md`.
- For runtime/browser proof, open a separate exact runtime route.
- For real mic/camera, provider, TTS playback, or avatar observation, open a
  separate exact route with evidence fields and raw/private handling.
