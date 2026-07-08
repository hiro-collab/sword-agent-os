# Audio Awareness Design Note

Audio Awareness is the source/static foundation for hearing-awareness summaries
under the existing body role `sense.hearing.primary`.

The concrete scaffold is:

- `organs/speech-input/audio-awareness/`
- `runtime/audio-awareness/`
- `contracts/audio_awareness_summary/`
- `contracts/audio_awareness_consumer_routes/`

Do not start this module as a disconnected top-level
`organs/auditory-awareness/` implementation. Existing
`organs/speech-input/ai-talk-core` VAD/STT behavior remains an adapter boundary:
the current slice maps speech-input VAD metadata into summary fields and does not
refactor nested `ai-talk-core`.

## MVP Boundary

The MVP is contract-first and no-live:

- define `audio_awareness_summary.v0`;
- expose `runtime/audio-awareness/audio-awareness-consumer-routes.json`;
- provide deterministic source/static tests and
  `scripts/check-audio-awareness-readiness.ps1`;
- keep PC-output and microphone channels separate;
- keep STT optional and outside the audio-awareness core.

This slice does not add WASAPI loopback workers, microphone workers, browser
audio capture, provider/network STT/TTS, Home Assistant/Home Control calls, or
raw media handling.

Self-output STT and turn-adoption blocking do not live in
`audio_awareness_summary.v0` refs. Use
`audio_self_output_observation.v0` for those observations; Audio Awareness keeps
source/static `self_output_event_ref`, `playback_event_ref`, and
`transcript_summary_ref` null unless a later reviewed route changes that
contract.

## User Speech Handoff

When speech is classified as user speech, Audio Awareness must not block it
before Thought Core because of what the user said. Command-like, appliance-like,
emotional, offensive, risky, or otherwise meaningful content belongs to Thought
Core / Soft Core for meaning and response handling.

Valid pre-Thought-Core holds are source/provenance and contract boundaries:
system self-output, not-user source, ambiguous source, recognizer failure or
unusable confidence, missing required candidate/session fields, and shared
publication risks. Shared artifacts may still redact live/private text while a
private Thought Core handoff carries accepted user speech.

## Proof Layers

Keep these layers separate in reports and preflight output:

| Layer | Meaning | Not Proof Of |
| --- | --- | --- |
| TTS request | A component requested speech generation. | Generated audio or playback. |
| TTS generated | A TTS engine produced an output summary. | Playback or user-heard audio. |
| Playback call | A local player was asked to play audio. | PC-output loopback or user-heard audio. |
| PC-output loopback summary | Future reviewed adapter summary of output energy. | Which app played audio or user hearing it. |
| Mic input summary | Future reviewed adapter summary of microphone energy or VAD. | Transcript content, speaker identity, or intent. |
| Bleed/echo likely | Summary correlation between output and mic input. | Ground-truth acoustic causality. |
| Operator-heard | Human/operator observation. | Device/runtime capture by itself. |

The current proof ceiling is:

```text
audio_awareness_source_static_summary_only
```

## Raw/Private Boundary

Tracked source, shared packets, and reviewer artifacts must not include raw
audio, transcript bodies, private paths, Home Assistant identifiers, logs,
screenshots/media, provider payloads, tokens, or device secrets.

Use `audio_awareness_summary.json` only as a compact summary authority packet.
It is observation context, not command authority, action authority,
browser-visible playback proof, user-heard proof, physical/device proof,
release readiness, or final RR003 claim.
