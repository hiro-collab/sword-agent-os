# Audio Awareness Runtime

Audio Awareness is the runtime reader surface for summary-only hearing
evidence. It separates two channels that are often confused during demos:

- `pc_output`: audio rendered by the PC or an explicitly selected output route;
- `microphone`: audio captured from the external acoustic environment.

The runtime is observation-only. It does not record audio by default, does not
submit STT, does not play TTS, does not operate Home Assistant, and does not
prove that a user heard a sound.

## Reader Surface

Start from:

- `runtime/audio-awareness/audio-awareness-consumer-routes.json`

That route map points to the result contract:

- `contracts/audio_awareness_summary/audio_awareness_summary.v0.schema.json`

The expected authority result packet is:

- `audio_awareness_summary.json`

`audio_awareness_summary.v0` is not the self-output STT/adoption gate. Its
source/static fixture keeps `self_output_event_ref`, `playback_event_ref`, and
`transcript_summary_ref` null. Use `audio_self_output_observation.v0` for
blocked system-self-output observations.

## Current Implementation

The current implementation is source/static:

- `audio-awareness.mjs` builds and validates summary packets from synthetic
  samples or speech-input VAD adapter metadata.
- `tests/audio-awareness.test.mjs` validates the contract fixture, builder,
  redaction flags, and speech-input VAD adapter boundary.
- `scripts/check-audio-awareness-readiness.ps1` is the no-live readiness
  entrypoint.

No WASAPI loopback, microphone capture, browser audio capture, STT, provider
network call, or raw audio persistence is implemented by this slice.

## Effective Processing Inventory (Phase 0)

The Windows Phase 0 prototype is:

- `runtime/audio-awareness/windows/effective-processing-inventory.ps1`

It accepts only class-level declarations for the native microphone AEC owner,
browser processing, and the prepared-sample virtual-cable route. Unknown input
is normalized to `unknown`; it is never echoed. The output distinguishes:

- `exactly_one_aec_owner` as a candidate declaration only;
- `double_aec_owner`, `no_aec_owner`, unknown, or contradictory declarations
  as observation-only;
- browser-managed processing as separate from the native microphone owner;
- the virtual cable as test-only, never product input authority.

Example class-only invocation:

```powershell
pwsh -NoProfile -File runtime/audio-awareness/windows/effective-processing-inventory.ps1
```

The default result is fail-closed `processing_unknown`. This prototype does
not inspect PCM, enumerate or publish device/process identity, prove that an
AEC is effective, select an AEC implementation, capture loopback audio, or
change Windows audio configuration. Phase 1 process-scoped loopback remains a
separate reviewed route.

Focused test:

```powershell
pwsh -NoProfile -File runtime/audio-awareness/tests/test-effective-processing-inventory.ps1
```

## Process-Scoped Loopback Observer (Phase 1)

The Windows Phase 1 source/static slice is:

- `runtime/audio-awareness/windows/ProcessLoopbackObserver.cs`
- `runtime/audio-awareness/windows/invoke-process-loopback-observer.ps1`
- `runtime/audio-awareness/tests/test-process-loopback-observer.ps1`

It uses the Windows process-loopback activation surface to include only a
leased target process and its child process tree. The observer is one-shot and
bounded. It drains every available packet, releases each acquired buffer once,
stops capture once, and disposes the backend even when cancellation or cleanup
fails. PCM is transient and is never returned or persisted; the shared result
contains only fixed classes, counts, and timing.

The safe default is a class-only capability probe:

```powershell
pwsh -NoProfile -File runtime/audio-awareness/windows/invoke-process-loopback-observer.ps1
```

Synthetic render/silence modes exist only for source/static lifecycle tests.
They set `source_class=synthetic_fixture`, `live_capture_used=false`, and cannot
be promoted to runtime evidence. Live process-tree observation requires a
separate exact process/render route and target. The wrapper acquires a private,
in-memory lease from the current OS process creation identity and expiry, then
revalidates it immediately before activation. There is no caller-supplied trust
flag or persisted lease file. No target PID,
process identity, device/endpoint identity, path, PCM, transcript, or arbitrary
payload is published.

Focused source/static test:

```powershell
pwsh -NoProfile -File runtime/audio-awareness/tests/test-process-loopback-observer.ps1
```

This phase proves only the source/static observer lifecycle and local API
capability class. It does not prove that a TTS process rendered sound, select
or validate an AEC owner, capture a microphone, classify self-output, block a
`TurnInput`, prove the user heard audio, or establish readiness.

## Existing Speech Input Integration

Existing speech-input VAD remains an adapter source. Its summary/debug
fields, such as `checked` and `speech_detected`, can be mapped into a
`speech_input_vad_adapter` channel through `buildSpeechInputVadAdapterChannel`.

Do not make Thought Core, diagnostics, or reviewers parse raw audio files,
temporary upload paths, full transcripts, or private logs to understand VAD
state. The long-term route is:

```text
speech-input VAD/STT adapter
-> audio_awareness_summary.v0 channel summary
-> status/event/memory safe refs
```

## Proof Boundary

Audio Awareness can support narrow claims such as:

- PC-output energy was observed in a bounded window;
- microphone energy or speech-presence metadata was observed;
- a speech-input VAD adapter reported speech/no-speech as summary metadata;
- a TTS/playback event and PC-output energy were correlated at a summary layer.

It cannot prove by itself:

- the user heard audio;
- browser audio actually played;
- a microphone captured a specific phrase or speaker;
- a full transcript or STT quality;
- Home Assistant action or physical device effect;
- release/readiness or final RR003 pass.

## Safety Boundary

Shared outputs must not contain:

- raw audio, generated audio, or waveform samples;
- full transcripts, prompts, responses, or provider payloads;
- private paths, private URLs, device names, Home Assistant identifiers, or
  tokens;
- screenshots, browser storage, or raw logs.

Future live adapters, such as WASAPI loopback or real microphone capture, must
enter through a separate reviewed route and keep raw persistence off by default.
