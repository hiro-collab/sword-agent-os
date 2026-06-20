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
