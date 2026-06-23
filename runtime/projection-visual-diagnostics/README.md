# Projection Visual Diagnostics

This directory defines source/static route maps for Projection Visual display,
receiver binding, speech/TTS summary, and display/TTS parity diagnostics.

The authority artifact is `projection_visual_display_audio_summary.json`,
validated by
`contracts/projection_visual_display_audio_summary/projection_visual_display_audio_summary.v0.schema.json`.

Default route posture:

- no browser runtime operation is authorized by this source/static map;
- no microphone, camera, provider STT/TTS, browser-audio, PC-output, or
  system-audio capture is authorized;
- raw prompt text, assistant text, transcripts, and raw audio are never included
  in shared summaries;
- display/TTS parity remains a summary/hash/class layer and is not user-heard
  audio proof.

Projection Visual display/TTS is separate from Self Mirror, VRM model telemetry,
audio-awareness, OS display diagnostics, and Home Assistant/Home Control. A
rendered assistant bubble or TTS summary does not prove browser-visible avatar
motion, Self Mirror pass, physical audio playback, user-heard audio, appliance
operation, or physical device behavior.
