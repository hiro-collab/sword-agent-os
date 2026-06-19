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
