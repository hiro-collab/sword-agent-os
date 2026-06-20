# Home Control Action Authoring

This page describes how to author Home Control rows. It is configuration
guidance, not live execution approval.

Each action row should state:

| Field | Purpose |
| --- | --- |
| `control_type` | Whether the target is tracked, stateless, submitted-only, mode-like, cover, climate, vacuum, or another class |
| `state_authority` | Which source can read current state, if any |
| `verification.mode` | `ha_state`, `external_observation`, `command_ack_only`, or another explicit proof mode |
| `proof_ceiling` | The highest claim this row can support |
| `live_test_candidate` / `live_test_readiness` | Whether this row can enter a bounded live ticket |
| `restore_action_id`, `stop_action_id`, or `terminal_action` | How the target returns to a safe/original state |
| `live_test_blockers` | Exact setup, restore, stop, or safety gaps |

Use `verification.mode: ha_state` only when Home Assistant can read the target
state. For remote-control or toggle-only devices whose state stays unknown, use
`control_type: stateless_toggle`, `state_authority: open_loop`, and
`verification.mode: external_observation` instead of claiming HA state proof.

For command-only actions, use `state_authority: submitted_only` and
`verification.mode: command_ack_only`.

## Full-Schema Rows vs Minimal Overrides

For any action that should support HA-visible `CheckState` proof, use a
full-schema row. A full-schema row includes:

- `ha_script`
- `control_type`
- `state_authority`
- `verification.mode`
- accepted state or position criteria when applicable
- `expected_effect` with the target state surface
- `proof_ceiling`
- `restore_action_id`, `stop_action_id`, or `terminal_action` when required
- `live_test_candidate` and readiness metadata when the row can enter a live
  ticket

A short/minimal action-only override is not wrong by itself, but it is an
ack-only or command-shape context. It must not be used to claim tracked
Home Assistant state proof, because the bridge has no reviewed target state
surface to compare. If a route needs a fresh clone or Git worktree to verify a
real appliance, pass a private ignored full-schema override or a reviewed
clone-local equivalent into that checkout and verify that the selected context
is not demo/default/template.

The bridge should never guess a target entity just to make `CheckState` green.
If the script exists but `expected_effect` is missing or points to the wrong
state surface, the correct result is a config-context blocker or an ack-only
ceiling, not a proof upgrade.

For HA-tracked cover, curtain, inner-door, vacuum, climate, or mode commands,
add accepted states and wait windows only after read-only state review shows the
states are reliable. These fields describe the proof window; they do not make
an unknown or inferred state physically verified.

For vacuum rows, keep start and return criteria separate. Start-side tracking
must say which states prove progress and why. Return-side tracking should
normally require `docked` after the wait window.

If multiple HA entities describe one appliance, track only the entity actually
targeted by the bridge script. A second local or cloud integration entity is
context, not action proof.

Setting `mode: single` on bridge-referenced Home Assistant scripts is a
readability improvement because it matches the Home Assistant default. It does
not prove appliance state.
