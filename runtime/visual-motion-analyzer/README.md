# Visual Motion Analyzer / Self Mirror

The Visual Motion Analyzer is the RR003 Self Mirror proof helper for visible
duration-aware avatar motion. It measures how much named screen regions move
over time, then compares those measurements with the pretrigger, active,
release, and settle windows of a Motion Stimulus / Driver Result pair.

Self Mirror is the visual QA lane for checking whether the agent's body is
actually visible on screen. It is meant to support VRM motion, Projection
Visual, HUD, expression, pointing, dance, and gesture proof without collapsing
"invoked", "debug value changed", and "avatar visibly moved" into one claim.

This helper consumes a local-only frame source abstraction and produces bounded
summaries:

- `visual_motion_summary.json`
- `visual_motion_roi_timeseries.csv`
- optional derived chart, only after the artifact rule is accepted

Raw frames, screenshots, videos, traces, pixel crops, full logs, local paths,
provider payloads, and Home Assistant routes must not be included in shared
outputs.

## Proof Modes

Use the root wrapper:

```powershell
.\scripts\run-self-mirror-proof.ps1 -Mode Synthetic
```

`Synthetic` is the lightweight source/no-live proof. It generates an in-memory
synthetic Projection Visual-like frame sequence, runs the analyzer, and writes
summary/CSV only. It proves the Self Mirror measurement method and ROI
classification, not a live browser or real VRM.

When Projection Visual is running, use Browser mode:

```powershell
.\scripts\run-self-mirror-proof.ps1 `
  -Mode Browser `
  -Url "http://127.0.0.1:18880/projection-visual/?mode=passive&visualTest=idle-neutral" `
  -Trigger context-nod
```

`Browser` captures a short local frame sequence through Playwright, runs the
same analyzer, and deletes the raw browser frames and local config by default.
Use `-KeepRawFrames` only for local debugging; do not commit or share those
frames.

Existing local frame configs can still be run directly:

## First Cases

The first supported RR003 cases are:

- `idle/reset`
- `smile`
- `listening/lookAt`
- `thinking/expression-lookAt`

Current source/no-live Synthetic proof cannot claim true nod, wave,
sword-sign body/hand response, or rhythm/dance body motion. Browser mode can
raise the proof layer to `visible_motion` only for the exact route, viewport,
trigger, ROI, and result it measured.

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
Browser Self Mirror mode derives the default `pretrigger`/`active` boundary
from the dispatch `--trigger-at-ms` value, so pretrigger motion is not counted
as trigger-caused active motion.

The default Self Mirror ROI set is:

- expected avatar: `avatar_full`, `avatar_face_head`
- observed avatar, not required for pass unless configured: `avatar_torso`,
  `avatar_left_arm`, `avatar_right_arm`
- guard UI/background: `speech_bubble`, `left_hud`, `right_hud`, `input_bar`,
  `background_fx`

The summary carries per-ROI peak scores for pretrigger/active/release/settle.
The CSV carries the time series with `changed_pixel_ratio`,
`optical_flow_mean`, `optical_flow_p95`, `bbox_delta`, `centroid_delta`,
`ssim_to_baseline`, and `motion_score`.

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

## Review Row Shape

Use this shape in RR003 packets:

```text
Scenario | Trigger | Proof layer | Source kind | ROI pass | Active peak(s) | Guard motion | Settle | Raw retained | Claim | Non-claim
```

Claim examples:

- invocation: motion request was issued or accepted only.
- debug-probe: adapter/debug state changed; no visible avatar claim.
- browser-visible: local browser route rendered and frame sequence was captured.
- ROI: expected avatar ROI crossed active threshold and settled.
- user-observed: human reviewed the local screen/video; keep separate from ROI.
