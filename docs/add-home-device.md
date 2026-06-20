# Add A Home Device Action

<!-- add-home-device:overview -->

Use this page when you want to add one Home Assistant-backed device action to
Sword Agent OS. It is a beginner-facing path for the Home Control Pack; the
field-level reference remains `docs/home-control-action-authoring.md`.

This guide is not live authorization. It helps you reach a proof-ready
configuration shape before any preview, dry-run, or live route exists.

## Safe Order

<!-- add-home-device:safe-order -->

1. Confirm the device exists in Home Assistant without copying raw entity IDs
   into tracked files or shared reports.
2. Add or update the local/private Home Control config selected by
   `HOME_CONTROL_CONFIG`.
3. Use a full-schema action row, not only a short action/script binding.
4. Render generated env/config files if the selected source requires it.
5. Run read-only bridge/catalog checks.
6. Run `CheckTracking` to confirm the row is tracked and testable.
7. Run `CheckState` only as the proof layer named by the route. It does not
   prove physical/device state by itself.
8. Open preview, dry-run, execute, external observation, or physical proof only
   through a separate bounded route.

## Full-Schema Checklist

<!-- add-home-device:full-schema-checklist -->

For HA-visible state proof, the action row needs all of these at a redacted
class level:

| Need | Why |
| --- | --- |
| command binding | The bridge knows which action to request |
| expected-effect target | The bridge knows which state surface to compare |
| `verification.mode` | The route knows whether this is HA state, external observation, or ack-only |
| accepted states or position criteria | `CheckState` has a bounded match rule |
| `proof_ceiling` | Reports do not over-claim |
| settle/timeout | The route has a bounded wait window |
| restore, stop, or terminal metadata | The action has a safe ending model |
| `live_test_candidate` and readiness/blockers | Live routes can stop before mutation when setup is incomplete |

A minimal action-only override can be useful for command-shape work, but it is
not enough for HA-visible `CheckState` proof.

## Proof Ladder

<!-- add-home-device:proof-ladder -->

Keep each result separate:

| Step | What it can prove | What it cannot prove |
| --- | --- | --- |
| catalog/readiness | The action is visible to the bridge | device movement |
| `CheckTracking` | The row carries proof metadata | current or post-action state |
| pre-command `CheckState` | Current state is readable/matched for a JIT gate | that the next command changed anything |
| preview | command shape / confirmation path | command execution |
| dry-run | non-mutating route acceptance | physical change |
| execute | command submitted through the bridge | physical state by itself |
| post-action `CheckState` | HA-visible terminal state matched | independent physical proof |
| no-media user/external observation | operator-observed class | camera/media proof or path history |
| physical/device proof | separately captured physical evidence | release/readiness by itself |

If the device is remote-control, toggle-only, or state-unreadable, use
`external_observation` or `command_ack_only` honestly instead of inventing a
tracked HA-state proof.

## Local/Private Boundary

Do not commit raw HA entity IDs, script IDs, device labels, private room names,
private URLs, tokens, screenshots, media, or logs. Put those in ignored local
inputs and report only class-level results.
