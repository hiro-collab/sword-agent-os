# home-control-preview Starter Profile

<!-- starter-profile:home-control-preview -->

This starter profile is the safe Home Control route for a new environment. It
helps an operator prove that Home Assistant connection, selected config,
catalog, tracking metadata, and read-only state surfaces are understandable
before any Home Assistant action is previewed, dry-run, or executed.

It is an example profile, not a new front-door command and not live
authorization.

This profile is a read-only readiness route. It is not Home Assistant preview
proof and does not exercise a Home Assistant preview endpoint.

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

`HOLD_LIVE` stays active during this profile. Read-only helper modes require an
already-running selected-workspace bridge, or an exact route-owned read-only
bridge-health scope that can be started and stopped without bridge action
execute. If neither is available under `HOLD_LIVE`, stop and report bridge
unavailable. Do not clear the hold, run preview/dry-run/live, or switch to a
different bridge just to make the helper commands pass.

## Report Shape

<!-- starter-profile:home-control-preview-report-shape -->

Report only redacted bridge health, catalog binding, config context,
`CheckTracking`, optional read-only `CheckState`, and blockers. Use
`docs/proof-layers.md` for proof boundaries instead of copying a result-field
ledger into this starter profile.

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

## Boundary

This profile is read-only readiness. It does not claim preview/dry-run/live
execution, command submission, post-action HA-visible terminal state,
external/user observation, physical/device proof, or release readiness.
`preview/dry-run/live`: Not part of this starter profile.
