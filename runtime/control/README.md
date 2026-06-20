# Runtime Control

This directory defines the runtime control vocabulary. Runtime control files are
local coordination signals; they are not live Home Assistant commands, provider
calls, browser/camera operations, or approval bypasses.

The current front-door command is:

```powershell
.\sword.ps1 hold-live
```

It writes `.cache\agent-os\control\hold-live.json`, which is runtime output and
is intentionally not tracked. The marker means:

- `live_home_assistant_actions_allowed=false`
- `provider_calls_allowed=false`
- `browser_or_camera_operations_allowed=false`
- `approval_bypass_allowed=false`
- `raw_private_publication=false`

## Vocabulary

| Control | Meaning | Current status |
| --- | --- | --- |
| `HOLD_LIVE` | Keep live Home Assistant / provider / browser-camera operations out of scope until a later exact route opens them. | Implemented by `sword.ps1 hold-live` marker |
| `STOP` | Stop launcher-owned runtime children under an explicit stop route. | Use `.\sword.ps1 stop` preview, then `.\sword.ps1 stop -Run` when in scope |
| `PAUSE` | Future pause/resume coordination for loops that can safely pause without teardown. | Reserved vocabulary |
| `REQUIRE_APPROVAL` | Future marker for routes that need explicit human approval before mutation. | Reserved vocabulary |

Keep runtime control and proof wording separate. A hold marker can make a live
route unavailable, but it does not prove source/static health, runtime/browser
health, HA-visible CheckState, external observation, or physical/device state.

<!-- runtime-control:hold-live-enforcement-boundary -->

## Enforcement Boundary

`hold-live.json` is currently a front-door and route-planning marker. It records
operator intent in a local file, but it is not yet a universal runtime interlock
that every service independently reads before acting.

Current expectation:

- `sword.ps1 hold-live` writes the marker and performs no live action.
- Any operator, Codex route, or Home Assistant live verification packet must
  check this marker before opening preview, dry-run, execute, provider,
  browser/camera, or media routes.
- If a service or route cannot read the marker, treat that as a route blocker
  for live work rather than assuming live work is allowed.
- An old marker remains active until the operator intentionally removes or
  replaces it; do not silently ignore it.

Known non-enforcement:

- The marker is not a Home Assistant service call.
- The marker is not a bridge execute request.
- The marker is not proof that the Home Control bridge, Thought Core, Launch
  Manager, or every organ has stopped.
- The marker is not an approval token and does not bypass a later live ticket.

<!-- runtime-control:hold-live-clear-policy -->

## Clearing A Hold

There is intentionally no one-click release command yet. In the current
implementation, clearing a hold is a local operator decision: remove or replace
`.cache\agent-os\control\hold-live.json` only after confirming no live route is
in progress and the next live route has its own exact scope, ticket, and proof
ceiling. Clearing the marker is not permission to run Home Assistant actions,
provider calls, browser/camera operations, or approval bypasses by itself.

If a route cannot determine whether an old hold is still intentional, treat that
as a live-route blocker and ask for a fresh operator decision rather than
silently ignoring the marker. A future front-door command may formalize
hold-status or clear-hold behavior after the live-route readers are implemented.

Current reader coverage:

- `scripts/start-home-control-bridge.ps1` blocks bridge start when the marker is
  present, while still allowing dry-run/read-only helper modes.

Future readers should include Action Boundary, other Home Control bridge
entrypoints, Launch Manager, and any Codex worker loop that can open mutation
routes. Until those readers are implemented and tested, documentation must
describe `HOLD_LIVE` as partial route-entry enforcement, not as complete
service-level enforcement.
