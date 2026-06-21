# Visual Motion Analyzer / Self Mirror

The Visual Motion Analyzer is the RR003 Self Mirror proof helper for visible
duration-aware avatar motion. It measures how much named screen regions move
over time, then compares those measurements with the pretrigger, active,
release, and settle windows of a Motion Stimulus / Driver Result pair.

For normal operator use, start from
`examples/starter-profiles/projection-visual/README.md`. This README remains
the implementation reference. System readers such as Thought Core, diagnostics,
and review agents should discover supported routes through
`runtime/visual-motion-analyzer/self-mirror-consumer-routes.json`.

Self Mirror is the visual QA lane for checking whether the agent's body is
actually visible on screen. It is meant to support VRM motion, Projection
Visual, HUD, expression, pointing, dance, and gesture proof without collapsing
"invoked", "debug value changed", and "avatar visibly moved" into one claim.

This helper consumes a local-only frame source abstraction and produces bounded
summaries:

- `self_mirror_metric_summary.json`
- `visual_motion_summary.json`
- `visual_motion_roi_timeseries.csv`
- `visual_motion_chart.html`
- `result.md`
- `manifest.json`

`self_mirror_metric_summary.json` is the reader-safe authority product for
Self Mirror consumers. It uses the `self_mirror_metric_summary.v0` shape. The
CSV timeline, HTML graph, and any future JSONL export are supporting inspection
views only; they are not the proof authority by themselves.
The authority summary also carries `latest_state` plus a short bounded
`observation_queue` / ring buffer. Queue entries are current/recent observation
data only: no raw frames, screenshots, videos, local paths, durable memory
promotion, or direct correction dispatch.
When a consumer such as Thought Core decides whether to retry a safe
internal/self-display output, it should reference the observation id and the
`consumer_retry_policy` hint. Self Mirror itself is not a retry authority or
command channel. The hint exposes `retry_limit_default=2`,
`retry_limit_configurable=true`, and the expected Thought Core/profile/status
policy sources; the active retry limit and any retry execution belong to the
consumer/output owner, not Self Mirror.

## Reference-To-Automatic Judgment

Manual/user-visible observation is calibration support, not the steady-state
Self Mirror authority product. Redacted reference cases may be stored with the
`self_mirror_reference_case.v0` shape when they contain safe run refs,
aggregate ROI/window metrics, controlled observation labels, expected result,
confidence, redaction flags, and non-claims.

Scenario-specific automatic judgment uses
`self_mirror_auto_judgment_profile.v0`. The profile stores reference coverage,
ROI thresholds, quiet-pretrigger rules, active-window rules, guard/UI
false-positive behavior, and confidence thresholds. The pure helper
`judge_metric_summary(summary, profile, reference_cases)` returns
`pass`, `fail`, or `unclear` from redacted metrics only. Missing or stale
profiles, insufficient reference coverage, mismatched run refs, pretrigger
motion, low confidence, or guard/layout false-positive suspicion must return
`unclear` with `needs_human_review=true`, not a silent pass.

`attach_auto_judgment(summary, judgment)` can add `reference_profile_id`,
`threshold_profile_id`, `reference_case_refs`, `auto_judgment_result`,
`auto_judgment`, `confidence`, and `needs_human_review` to a compatible
`self_mirror_metric_summary.v0` packet. This is still observation/evaluation
only: it cannot execute correction, close issues, approve Git/publication,
claim live/device proof, or claim RR003 representative pass.

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
the standard result package. It proves the Self Mirror measurement method and
ROI classification, not a live browser or real VRM.

When Projection Visual is running, use Browser mode:

```powershell
.\scripts\run-self-mirror-proof.ps1 `
  -Mode Browser `
  -Url "http://127.0.0.1:18880/projection-visual/?mode=passive&visualTest=self-mirror-baseline" `
  -Scenario context_nod
```

`Browser` captures a short local frame sequence through Playwright, runs the
same analyzer, and deletes the raw browser frames and local config by default.
Use `-KeepRawFrames` only for local debugging; do not commit or share those
frames.
Direct `node scripts/capture-self-mirror-frames.mjs` execution is a local
capture primitive, not a review-safe cleanup wrapper: it leaves
`raw-browser-frames` and `self_mirror_browser_config.json` in the output
directory so the analyzer can consume them. Treat those as local-only temporary
inputs; do not share, commit, or publish them, and clean them up after direct
runs.

Controlled Chrome routes must not be silently downgraded to Browser helper
routes. For controlled Chrome review, the analyzer can consume a
`controlled_chrome_observation` config object containing summary-only
Projection Visual / Chrome-extension-readable ROI window metrics. That source
uses `source_ref.kind=controlled_chrome_metric_summary`, preserves safe target
identity such as `capture_surface_kind=controlled_chrome_extension_tab` and a
safe tab/target id, and still emits the normal
`self_mirror_metric_summary.v0` authority packet. This adapter is source-no-live
plumbing: it does not attach to Chrome by itself and does not prove controlled
Chrome visibility until a coordinated controlled Chrome run supplies matching
summary metrics. If raw screenshots, frame sequences, video, crops, storage, or
logs are required to compute those metrics, stop and route a security/user
artifact-retention subgate before runtime proof.

For trigger-caused visible-motion review, use the
`visualTest=self-mirror-baseline` route. The capture helper waits for the VRM
debug/ready state before the first frame and records both `self_mirror_ready`
and `runtime_join` summary objects in the Browser capture manifest. The runtime
join pairs the ROI run with the planned safe result id echoed by the Motion
Stimulus receiver; it is not an independently generated live runtime id. If the
analyzer still reports `visual-pretrigger-motion`, keep the run classified as
pretrigger contamination instead of a trigger-caused pass.

Existing local frame configs can still be run directly:

```powershell
.\scripts\run-visual-motion-analyzer.ps1 `
  -ConfigPath .cache\agent-os\self-mirror\some-run\self_mirror_browser_config.json
```

The analyzer implementation is owned by Self Mirror under this runtime package.
The old Environment VSP import path is a deprecated compatibility shim during
the migration window.

## First Cases

The first supported Self Mirror kit scenarios are defined in
`runtime/visual-motion-analyzer/self-mirror-scenarios.json`:

- `context_nod`: expected `avatar_full` motion only.
- `idle_baseline`: no expected motion; confirms the same ROI set stays quiet.
- `dance_visible_motion`: expected broad avatar/body motion across
  `avatar_full`, `avatar_torso`, `avatar_left_arm`, and `avatar_right_arm`.
- `expression_visible_change`: expected visible face/head ROI change in
  `avatar_face_head`.

Current source/no-live Synthetic proof cannot claim true nod, wave,
sword-sign body/hand response, pointing, semantic expression correctness,
rhythm, choreography, or semantic dance quality. Browser mode can raise the proof layer to
`visible_motion` only for the exact route, viewport, trigger, ROI, and result it
measured. The `dance_visible_motion` ROI claim is broad avatar/body movement in
the configured ROIs, not physical-display proof or semantic dance quality.

## ROI Rule

Each ROI must declare whether it counts as avatar motion:

- avatar ROIs: `avatar_full`, `avatar_face_head`, `avatar_eyes_gaze`,
  `avatar_torso`, `avatar_left_arm`, `avatar_right_arm`, `avatar_lower_body`
- guard ROIs: `speech_bubble`, `left_hud`, `right_hud`, `bottom_controls`,
  `input_bar`, `render_controls`, `background_fx`

Only expected avatar ROIs may satisfy an avatar motion pass. HUD, speech bubble,
render controls, input bar, and background motion are reported as guard signals.

Expected avatar motion must meet the active threshold for
`min_consecutive_samples` in the active window. Motion that crosses the active
threshold in a `pretrigger` window is reported as `visual-pretrigger-motion`
instead of a pass.
For `expected_motion=none`, quiet input can pass as a stability baseline, but
motion above the settle threshold in the `settle` window is still reported as
`did-not-settle` instead of `visual-pass`.
Browser Self Mirror mode derives the default `pretrigger`/`active` boundary
from the dispatch `--trigger-at-ms` value, so pretrigger motion is not counted
as trigger-caused active motion.

The analyzer also emits `motion_diagnostics` in the
`self_mirror_metric_summary.v0` packet. This diagnostic layer keeps the primary
pass rule narrow while explaining common failure modes:

- `event-correlated-motion`: expected ROIs moved in the normal active window.
- `late-visible-motion`: expected ROIs moved only in a `late_watch` window.
- `motion-outside-expected-roi`: diagnostic wide ROIs moved, but expected ROIs
  did not.
- `idle-only-motion`: post-trigger motion did not exceed the pretrigger/idle
  baseline by the configured delta.
- `runtime-started-no-visible-motion`: runtime start was observed, but no
  event-correlated visible motion was found.

Diagnostic ROIs such as `avatar_wide` are never pass authority. They are only
used to distinguish a real lack of visible motion from a likely narrow or
misaligned expected ROI.

The v0 Self Mirror ROI set is intentionally coarse:

- expected avatar for `context_nod`: `avatar_full`
- observed avatar for `idle_baseline`: `avatar_full`, not required for motion
  pass
- guard UI: `speech_bubble`, `left_hud`, `right_hud`, `bottom_controls`,
  `input_bar`

The ROI coordinates are normalized to the captured page viewport, not to the
Chrome window including address bars or tabs. For stable checks, keep the
capture viewport explicit (`-ViewportWidth`, `-ViewportHeight`) and treat
coordinate changes across display sizes as ROI calibration work.

Pointing, semantic expression correctness, and semantic dance-quality ROIs are
future review layers. Do not claim arm/torso/dance behavior from the v0
`avatar_full` packet alone. Use `dance_visible_motion` for broad body/arm ROI
evidence, use `expression_visible_change` only for visible face/head ROI
change, and keep semantic dance quality and semantic smile/frown/emotion
correctness as separate future review layers.

The summary carries per-ROI peak scores for pretrigger/active/release/settle.
The CSV carries the time series with `changed_pixel_ratio`,
`optical_flow_mean`, `optical_flow_p95`, `bbox_delta`, `centroid_delta`,
`ssim_to_baseline`, and `motion_score`.

## Expression Boundary

Self Mirror can include face/head/eye ROIs in a scenario and report whether
those visible regions changed over time while motion is running. That supports
automatic inspection of visible display/avatar output.

Self Mirror does not identify which facial expression was requested, whether
the expression runtime accepted it, or whether the avatar semantically smiled,
blinked, looked surprised, or matched a requested emotion. Those facts need a
separate expression request/result or expression-state proof product from the
expression/runtime owner, which Test-QA or an integration proof can correlate
with `self_mirror_metric_summary.v0` and the shared request/result refs.

## Local CLI

The root wrapper keeps raw source paths local:

```powershell
.\scripts\run-visual-motion-analyzer.ps1 `
  -ConfigPath .cache\agent-os\visual-motion-analyzer\rr003-smile.config.json
```

The config may contain local frame paths, but the output summary records only
redacted source refs. Shared review packets should include the standard result
package only after no-leak review. Machine-readable CLI stdout reports artifact
basenames, not local output paths.

## Result Classifications

The analyzer emits one primary result classification:

- `visual-pass`
- `visual-pretrigger-motion`
- `visual-missing-motion`
- `guard-only-motion`
- `did-not-settle`
- `runtime-not-joined`
- `capture-not-ready`
- `roi-out-of-frame`
- `threshold-too-strict`

Read `result.md` first for the short guide: what passed, what failed or remains
a known gap, which ROI to inspect, whether raw frames were retained, and the
next action. The local chart is for ROI/time-series inspection; it is not a
claim by itself.

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
