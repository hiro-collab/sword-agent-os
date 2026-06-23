# OS Display Diagnostics

This directory defines source/static route maps for future OS foreground,
permission prompt, warning, and desktop/window diagnostic summaries.

The authority artifact is `os_display_diagnostic_summary.json`, validated by
`contracts/os_display_diagnostic_summary/os_display_diagnostic_summary.v0.schema.json`.

Default route posture:

- no browser, OS, screenshot, screen-recording, microphone, camera, browser-audio,
  PC-output, or system-audio capture is authorized by this source/static map;
- raw screenshot and raw screen-recording retention defaults remain false;
- shared evidence is class/count/bucket/safe-ref summary only;
- full desktop capture requires a later exact live-capture route with Test-QA and
  security review.

OS display diagnostics are separate from Self Mirror, VRM telemetry, Projection
Visual display/TTS, and audio-awareness. A foreground window or prompt summary
does not prove browser-visible avatar motion, user-heard audio, appliance
operation, Home Assistant state, or physical device behavior.
