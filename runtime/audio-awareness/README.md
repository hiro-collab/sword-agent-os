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
