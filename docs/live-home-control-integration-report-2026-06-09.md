# Live Home Control Integration Report - 2026-06-09

This report is for the Sword Agent OS integration owner. It intentionally omits
secrets, tokens, raw Home Assistant URLs, raw entity IDs, and raw media.

## Scope

- Live door/cover execution with restore.
- Live AC execution with restore.
- External observation path check.
- Proof layers are kept separate:
  - `command accepted`: bridge accepted and submitted the action.
  - `HA state/attribute observed`: Home Assistant state or attributes changed.
  - `external observation available`: camera/sensor path can be read.
  - `physical-state proof`: independent confirmation that the real device is in
    the claimed physical state.

## Preconditions

- Home Control bridge health was OK.
- Bridge action catalog contained 12 actions.
- `door_close`, `door_open`, `aircon_off`, and `aircon_on` were all still
  `state_tracking=ack_only` in the live config.
- Confirmation tokens were fetched separately for dry-run and live execution.
- Dry-runs did not execute Home Assistant calls.

## Door / Cover Live Pilot

Initial read-only HA state:

| anon entity | state | position |
|---|---:|---:|
| `cover#1` | `open` | 99 |
| `cover#2` | `open` | 99 |

`door_close` result:

| proof layer | result |
|---|---|
| preview | `preview` |
| dry-run | `dry_run`, `executed=false` |
| live execute | `submitted`, `executed=true` |
| bridge tracking | `ack_only`, no position proof in live config |

HA state/position after `door_close`:

| time | `cover#1` | `cover#2` |
|---|---|---|
| +30s | `closed`, position 18 | `open`, position 37 |
| +75s total | `closed`, position 18 | `open`, position 37 |

Interpretation:

- The command was accepted and caused real HA position changes.
- It did not prove a clean `closed` physical state.
- Both cover entities changed, so future proof should not assume only one cover
  target unless the script target and group behavior are reviewed together.
- State alone is insufficient: one cover reported `closed` while still at
  position 18, and the other remained `open` at position 37.

Restore with `door_open`:

| step | `cover#1` | `cover#2` |
|---|---|---|
| before restore | `closed`, position 18 | `open`, position 37 |
| +30s after first `door_open` | `open`, position 100 | `open`, position 71 |
| +75s total after first `door_open` | `open`, position 100 | `open`, position 71 |
| +30s after one retry | `open`, position 100 | `open`, position 100 |

Door/cover conclusion:

- `door_close` and `door_open` are live executable.
- Restore succeeded, but it required one additional `door_open` command.
- Do not promote door/cover to plain HA state proof.
- If door/cover is promoted later, use position-aware verification such as:
  - open proof: `state=open` plus `current_position >= 95`
  - closed proof: `state=closed` plus a conservative position threshold
  - target/group review before assuming one entity is enough

## Real AC Live Pilot

Initial read-only HA state:

| anon entity | state | target temperature |
|---|---:|---:|
| `climate#1` | `fan_only` | 21 |

Initial switch state distribution:

| state | count |
|---|---:|
| `off` | 1 |
| `unknown` | 2 |

`aircon_off` result:

| proof layer | result |
|---|---|
| preview | `preview` |
| dry-run | `dry_run`, `executed=false` |
| live execute | `submitted`, `executed=true` |
| bridge tracking | `ack_only` |

After 30s:

| signal | observed |
|---|---|
| `climate#1` | still `fan_only`, target temperature 21 |
| switch distribution | `off=2`, `unknown=1` |
| temperature sensors | no useful short-window change |

Restore with `aircon_on`:

| proof layer | result |
|---|---|
| preview | `preview` |
| dry-run | `dry_run`, `executed=false` |
| live execute | `submitted`, `executed=true` |
| bridge tracking | `ack_only` |

After 30s:

| signal | observed |
|---|---|
| `climate#1` | still `fan_only`, target temperature 21 |
| switch distribution | `off=1`, `on=1`, `unknown=1` |
| temperature sensors | no useful short-window change |

AC conclusion:

- `aircon_off` and `aircon_on` are live executable through the bridge.
- The current bridge actions are still switch-wrapper style and `ack_only`.
- The switch distribution changed, but the climate entity did not change in a
  way that proves AC mode transition.
- This supports the earlier recommendation: AC should remain `command_ack_only`
  until a dedicated climate-service path is designed and proven.

## External Observation

Camera no-save check:

| field | observed |
|---|---:|
| opened | true |
| read frame | true |
| backend | DSHOW |
| shape | 480 x 640 x 3 |
| mean brightness | 115.92 |
| raw media saved | false |
| raw media displayed | false |

Camera inventory also showed an available webcam device in OK state. This proves
the local camera observation path is usable, but it is not by itself a
door/cover or AC physical-state proof because no semantic image review was
performed.

HA external sensors were also readable, including illuminance and temperature
sensor values. They did not provide decisive proof for the short AC window.

## Integration Guidance

- Keep `CheckTracking` as the preflight proof-capability check.
- Keep `CheckState` as a post-action or post-restore check only.
- Do not call `ack_only` actions green from `CheckState`.
- Door/cover should either stay `ack_only` or use explicit position-aware
  verification after the target/group behavior is reviewed.
- AC should stay `ack_only` until the script path is moved from switch-wrapper
  operation to a climate-domain service and that path is proven.
- Camera/external observation is available, but physical-state proof requires a
  separate scoped observation run. No raw media was saved or displayed in this
  pass.

## Current End State

- Door/cover restored to `open`, positions 100 / 100.
- AC restored to the prior climate state observed in HA: `fan_only`, target
  temperature 21.
- No raw media artifacts were created.
