# projection-visual Starter Profile

<!-- starter-profile:projection-visual -->

This starter profile is the user-facing route for checking browser-visible
avatar/display motion with Self Mirror. It is for operators who need to know
whether Projection Visual / AITuber can show a visible nod, expression change,
or dance-like body motion after the runtime is actually opened.

It is an example profile, not a new `sword.ps1` front-door command, not Home
Assistant live authorization, and not physical projector proof. It may enter a
runtime/browser proof layer only after the operator intentionally starts the
selected runtime. Keep raw frames, screenshots, provider payloads, transcripts,
and private paths out of shared results.

## Goal

<!-- starter-profile:projection-visual-goal -->

Reach a redacted browser/display checkpoint for the Avatar / Projection Pack:

- front-door status and verify checks run first;
- runtime start is explicit, not implied by no-live checks;
- Projection Visual / AITuber reaches a local browser route;
- Self Mirror records visible avatar motion for a named scenario;
- dance, expression, and nod evidence stays separate from semantic quality,
  voice intent, provider response, Home Assistant action, and physical display
  proof.

Proof ceiling: `browser_visible_avatar_motion_self_mirror`.

## Safe Route

<!-- starter-profile:projection-visual-route -->

Start with safe front-door checks:

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 start
```

`start` without `-Run` is a command preview. Continue only when runtime/browser
execution is in scope for the current install test.

Start the selected runtime explicitly:

```powershell
.\sword.ps1 start -Run
```

Wait for Launch Manager, AITuber Kit, Projection Visual, and Thought Core to be
ready or clearly degraded/blocked. Open the local Projection Visual route:

```text
http://127.0.0.1:3000/projection-visual/?mode=passive&visualTest=self-mirror-baseline
```

If the active runtime is using an isolated or delegated AITuber port, use the
selected workspace route shown by Launch Manager instead of guessing another
workspace.

Run a Self Mirror method check first:

```powershell
pwsh -NoProfile -File .\scripts\run-self-mirror-proof.ps1 `
  -Mode Synthetic `
  -Scenario dance_visible_motion
```

This proves the local Self Mirror measurement method and ROI classification
only. It does not prove a live browser, real VRM, or real runtime.

Run browser Self Mirror for visible avatar motion:

```powershell
pwsh -NoProfile -File .\scripts\run-self-mirror-proof.ps1 `
  -Mode Browser `
  -Scenario dance_visible_motion `
  -Trigger dance `
  -Url "http://127.0.0.1:3000/projection-visual/?mode=passive&visualTest=self-mirror-baseline"
```

For face/head expression visibility, use:

```powershell
pwsh -NoProfile -File .\scripts\run-self-mirror-proof.ps1 `
  -Mode Browser `
  -Scenario expression_visible_change `
  -Trigger expression-visible `
  -Url "http://127.0.0.1:3000/projection-visual/?mode=passive&visualTest=self-mirror-baseline"
```

For context nod visibility, use:

```powershell
pwsh -NoProfile -File .\scripts\run-self-mirror-proof.ps1 `
  -Mode Browser `
  -Scenario context_nod `
  -Trigger context-nod `
  -Url "http://127.0.0.1:3000/projection-visual/?mode=passive&visualTest=self-mirror-baseline"
```

Self Mirror writes a local result package under `.cache\agent-os\self-mirror\`.
The reader-safe authority file is `self_mirror_metric_summary.json`; supporting
inspection files include `visual_motion_summary.json`, `result.md`,
`visual_motion_roi_timeseries.csv`, `visual_motion_chart.html`, and
`manifest.json`. Do not share or commit raw browser frames.
Shared reports must not include raw screenshots, raw browser frames, provider payloads, transcripts, private URLs, local absolute paths, tokens, or private asset names.

System readers such as Thought Core, diagnostics, and review agents should use
`runtime/visual-motion-analyzer/self-mirror-consumer-routes.json` to discover
the supported routes, expected scenarios, result authority file, proof ceiling,
and non-claims.

## Result Fields

<!-- starter-profile:projection-visual-result-fields -->

Keep these fields separate in notes and reports:

| Field | Meaning | Does not prove |
| --- | --- | --- |
| front-door status | `sword.ps1 status` can inspect the selected workspace | runtime/browser proof, avatar motion |
| front-door verify | no-live install/readiness checks pass or classify blockers | browser rendering, provider response, physical display |
| start command preview | launch plan is visible without starting runtime | running stack or visible avatar |
| runtime start | selected launcher/runtime was intentionally started | browser-visible motion or input/output loop quality |
| browser route reachability | Projection Visual / AITuber page can be opened | avatar motion, dance, expression correctness |
| Self Mirror synthetic method | analyzer method and ROI classification work on synthetic frames | real browser, real VRM, live runtime |
| Self Mirror browser dance | expected avatar body/arm ROIs moved during `dance_visible_motion` | semantic dance quality, rhythm, choreography, physical projector proof |
| Self Mirror expression | expected face/head ROI changed during `expression_visible_change` | semantic smile/frown/emotion correctness |
| Self Mirror context nod | expected avatar ROI moved during `context_nod` | natural-language correctness or general gesture proof |
| raw/private/media boundary | raw frames are cleaned or kept local-only | shareability of screenshots, transcripts, provider payloads |

## Stop Conditions

<!-- starter-profile:projection-visual-stop-conditions -->

Stop before claiming the next proof layer if:

- `status`, `verify`, or `start` command preview reports a blocker.
- Runtime/browser execution is not in scope for the current test.
- Launch Manager, AITuber Kit, Projection Visual, or Thought Core is not ready
  enough to open the selected workspace route.
- The route would require switching to another workspace or stale browser tab
  just to get a green result.
- Self Mirror reports `visual-pretrigger-motion`, `visual-missing-motion`,
  `guard-or-ui-only-motion`, `idle-only-motion`, `runtime-started-no-visible-motion`,
  `did-not-settle`, `capture-not-ready`, or `roi-out-of-frame`.
- The explanation would require raw screenshots, raw browser frames, raw logs,
  transcripts, provider payloads, private URLs, private asset names, local
  absolute paths, tokens, or Home Assistant identifiers.
- The next step would claim microphone/camera input, provider response quality,
  Home Assistant action, physical projector output, or physical-device proof.

## Does Not Prove

<!-- starter-profile:projection-visual-does-not-prove -->

- voice intent parsing;
- provider response quality;
- TTS synthesis or audio playback;
- real microphone or camera input;
- Home Assistant preview, dry-run, live execute, or HA-visible CheckState;
- semantic dance quality, rhythm, or choreography;
- semantic smile/frown/emotion correctness;
- TouchDesigner or physical projector output;
- external/user observation unless separately recorded;
- physical/device proof;
- release/readiness.

## Optional Next Paths

<!-- starter-profile:projection-visual-next-paths -->

- For the Self Mirror implementation and proof modes, use
  `runtime/visual-motion-analyzer/README.md`.
- For route discovery by Thought Core or diagnostics, use
  `runtime/visual-motion-analyzer/self-mirror-consumer-routes.json`.
- For voice/avatar no-live setup, use
  `examples/starter-profiles/voice-avatar/README.md`.
- For physical projector or TouchDesigner verification, open a separate exact
  route when that hardware is available.
