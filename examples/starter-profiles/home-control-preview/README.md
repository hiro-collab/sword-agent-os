# home-control-preview Starter Profile

<!-- starter-profile:home-control-preview -->

This starter profile is the safe Home Control route for a new environment. It
helps an operator prove that Home Assistant connection, selected config,
catalog, tracking metadata, and read-only state surfaces are understandable
before any Home Assistant action is previewed, dry-run, or executed.

It is an example profile, not a new front-door command and not live
authorization.

## Goal

<!-- starter-profile:home-control-preview-goal -->

Reach a redacted, no-live Home Control checkpoint:

- Home Assistant / Home Control local inputs are selected.
- The selected config context is not demo/default/template.
- A full-schema private/live config or reviewed clone-local equivalent is
  selected when HA-visible state proof is the goal.
- The bridge can report health/catalog classes.
- `CheckTracking` can say whether the action is tracked and testable.
- Optional read-only `CheckState` can classify current state readability, but
  it is not live-effect proof.

## Safe Route

<!-- starter-profile:home-control-preview-route -->

Start with front-door checks:

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 hold-live
```

Then read the setup docs:

- `docs/home-assistant-setup.md`
- `docs/add-home-device.md`
- `docs/home-control-action-authoring.md`
- `docs/proof-layers.md`

Before touching a real environment, preview the rendered config handoff:

```powershell
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard -DryRun
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -DryRun -ExpectedActionId <allowed-action-id>
```

When the local/private Home Assistant inputs are intentionally available, use
read-only helper modes only:

```powershell
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckOnly -ExpectedActionId <allowed-action-id>
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckTracking -ActionId <allowed-action-id>
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckState -ActionId <allowed-action-id>
```

The last command is a current-state readability/classification check for this
starter profile. It must not be reported as proof that a command changed the
device.

## Result Fields

<!-- starter-profile:home-control-preview-result-fields -->

Keep these fields separate in notes and reports:

| Field | Meaning | Does not prove |
| --- | --- | --- |
| bridge health | The local bridge can answer a redacted health check | action execution |
| catalog binding | The expected action appears in the bridge catalog | target moved |
| config context | The selected config is non-demo and full-schema when state proof is needed | live permission |
| `CheckTracking` | The action row carries proof metadata and readiness/blockers | current or post-action state |
| read-only `CheckState` | Current state surface is readable/matched/unavailable at that moment | live effect, transition, dock/path/floor proof |
| preview/dry-run/live | Not part of this starter profile | external or physical proof |
| external observation | Not part of this starter profile | camera/media proof unless separately routed |

## Stop Conditions

Stop before any preview/dry-run/live route if:

- `HOLD_LIVE` is active and no exact live route supersedes it.
- The selected config is demo/default/template.
- The selected config is short/minimal action-only but the goal is HA-visible
  `CheckState` proof.
- `CheckTracking` returns `ack_only`, `external_required`, unavailable, or any
  safety/restore blocker.
- `CheckState` is unavailable and the next route requires HA-visible state.
- You would need to publish raw HA entity IDs, script IDs, URLs, private config,
  tokens, screenshots, logs, or media to explain the result.

## Does Not Prove

- preview acceptance;
- dry-run acceptance;
- live Home Assistant execution;
- command submission;
- post-action HA-visible terminal state;
- external/user observation;
- physical/device proof;
- release/readiness.
