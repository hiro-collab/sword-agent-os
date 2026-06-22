# Audio Awareness Hearing Organ

This directory is the concrete hearing-organ scaffold for `sense.hearing.primary`.

It exists because Sword Agent OS needs to distinguish:

- PC output audio;
- microphone input audio;
- TTS generation;
- playback calls;
- browser-visible or user-heard audio;
- speech-input VAD/STT metadata.

Those are separate proof layers. A TTS request does not prove audio played, and
PC output energy does not prove a user heard it.

## Responsibility

The organ should eventually provide adapters for:

- PC-output observation, such as a reviewed Windows loopback worker;
- microphone observation, only under explicit route permission;
- browser audio or media events when a browser route supplies them;
- local TTS/VOICEVOX generation and playback event summaries;
- legacy speech-input VAD/STT metadata.

The organ emits `audio_awareness_summary.json` packets that validate against:

- `contracts/audio_awareness_summary/audio_awareness_summary.v0.schema.json`

The runtime reader surface is:

- `runtime/audio-awareness/audio-awareness-consumer-routes.json`

## Current Status

This is a source/static scaffold. The current adopted code lives in
`runtime/audio-awareness/` and supports synthetic sample summaries plus a legacy
VAD compatibility mapper.

No live PC-output capture, microphone capture, browser audio capture, STT,
provider network call, generated audio sharing, or raw audio persistence is
implemented by this scaffold.

## Integration With Existing Speech Input

Existing `organs/speech-input/ai-talk-core` VAD and STT behavior should be
migrated through adapters rather than forced into this scaffold all at once.

Suggested order:

1. Keep legacy endpoints and events working.
2. Map legacy VAD debug metadata into `legacy_speech_input` channel summaries.
3. Add a compatibility reader that emits `audio_awareness_summary.v0`.
4. Move live capture adapters only after a reviewed route authorizes them.
5. Keep STT optional and outside the default audio-awareness core.

## Non-Goals

This organ is not:

- a Home Assistant action route;
- proof that a physical device changed state;
- proof that a browser played audio;
- proof that a user heard audio;
- a raw audio recorder;
- a transcript archive;
- a release/readiness authority.
