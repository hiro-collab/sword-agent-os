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

This command starts or reuses **Launch Manager**; it does not by itself start
every selected service. Open `http://127.0.0.1:8799`, choose the intended
services, and press **Start Stack / 起動する**. For the smallest text
conversation plus avatar route, keep Provider Broker (fixed), Thought Core,
and AITuber / Expression; Camera, Home, Environment, GUI, and voice are
separate capabilities and should be enabled only when that scenario needs
them.

Wait for Launch Manager, AITuber Kit, Projection Visual, and Thought Core to be
ready or clearly degraded/blocked. Open the local Projection Visual route:

```text
http://127.0.0.1:3000/projection-visual/?mode=passive&visualTest=self-mirror-baseline
```

Use `http://127.0.0.1:3000/` for ordinary conversation plus avatar display,
and `http://127.0.0.1:3000/projection-visual/?mode=operator` when the projected
surface itself must submit the turn and show its strict response bubble. The
`mode=passive&visualTest=self-mirror-baseline` route above is an observation
surface for display state and Self Mirror; it is not a mirror of arbitrary
chat history from `/`.

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

Run browser Self Mirror with one scenario/trigger pair:

| Scenario | Trigger | Use when |
| --- | --- | --- |
| `dance_visible_motion` | `dance` | broad body/arm motion |
| `expression_visible_change` | `expression-visible` | face/head visible change |
| `context_nod` | `context-nod` | nod-style motion |

```powershell
pwsh -NoProfile -File .\scripts\run-self-mirror-proof.ps1 `
  -Mode Browser `
  -Scenario dance_visible_motion `
  -Trigger dance `
  -Url "http://127.0.0.1:3000/projection-visual/?mode=passive&visualTest=self-mirror-baseline"
```

Substitute the scenario and trigger from the table when checking expression or
context nod visibility.

Self Mirror writes a local result package under `.cache\agent-os\self-mirror\`.
The reader-safe authority file is `self_mirror_metric_summary.json`; supporting
inspection files include `visual_motion_summary.json`, `result.md`,
`visual_motion_roi_timeseries.csv`, `visual_motion_chart.html`, and
`manifest.json`. Do not share or commit raw browser frames.
Shared reports must not include raw screenshots, raw browser frames, provider payloads, transcripts, private URLs, local absolute paths, tokens, or private asset names.

When the check is finished, stop the selected stack through Launch Manager or
the normal front door:

```powershell
.\sword.ps1 stop -Run
```

System readers such as Thought Core, diagnostics, and review agents should use
`runtime/visual-motion-analyzer/self-mirror-consumer-routes.json` to discover
the supported routes, expected scenarios, result authority file, proof ceiling,
and non-claims.

## Report Shape

<!-- starter-profile:projection-visual-report-shape -->

Keep notes compact: command preview status, runtime route, scenario/trigger,
browser route reachability, Self Mirror classification, raw-retention state,
claim, and non-claim.

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

## Next Paths

<!-- starter-profile:projection-visual-next-paths -->

Use `runtime/visual-motion-analyzer/README.md` for implementation details,
`runtime/visual-motion-analyzer/self-mirror-consumer-routes.json` for route
discovery, and `examples/starter-profiles/voice-avatar/README.md` for no-live
voice/avatar setup. Physical projector or TouchDesigner checks need a separate
exact route.
