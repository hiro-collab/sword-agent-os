# Visual Motion Analyzer

The Visual Motion Analyzer is the RR003 no-live proof helper for visible
duration-aware avatar motion. It measures how much named screen regions move
over time, then compares those measurements with the active, release, and
settle windows of a Motion Stimulus / Driver Result pair.

This helper is not a browser/live proof by itself. It consumes a local-only
frame source abstraction and produces bounded summaries:

- `visual_motion_summary.json`
- `visual_motion_roi_timeseries.csv`
- optional derived chart, only after the artifact rule is accepted

Raw frames, screenshots, videos, traces, pixel crops, full logs, local paths,
provider payloads, and Home Assistant routes must not be included in shared
outputs.

## First Cases

The first supported RR003 cases are:

- `idle/reset`
- `smile`
- `listening/lookAt`
- `thinking/expression-lookAt`

Current Slice 2A cannot use this helper to claim true nod, wave, sword-sign
body/hand response, or rhythm/dance body motion.

## ROI Rule

Each ROI must declare whether it counts as avatar motion:

- avatar ROIs: `avatar_full`, `avatar_face_head`, `avatar_eyes_gaze`,
  `avatar_torso`, `avatar_left_arm`, `avatar_right_arm`, `avatar_lower_body`
- guard ROIs: `speech_bubble`, `left_hud`, `right_hud`, `render_controls`,
  `input_bar`, `background_fx`

Only expected avatar ROIs may satisfy an avatar motion pass. HUD, speech bubble,
render controls, input bar, and background motion are reported as guard signals.

Expected avatar motion must meet the active threshold for
`min_consecutive_samples` in the active window. Motion that crosses the active
threshold in a `pretrigger` window is reported as `visual-pretrigger-motion`
instead of a pass.

## Local CLI

The root wrapper keeps raw source paths local:

```powershell
.\scripts\run-visual-motion-analyzer.ps1 `
  -ConfigPath .cache\agent-os\visual-motion-analyzer\rr003-smile.config.json
```

The config may contain local frame paths, but the output summary records only
redacted source refs. Shared review packets should include summary JSON and CSV
only after no-leak review. Machine-readable CLI stdout reports artifact
basenames, not local output paths.
