# Live Home Control Cause Trail

This note defines the short diagnostic trail used when a live Home Control
pilot stops before preview or execute. It is meant for user reports, QA notes,
and manager handoffs.

Do not paste raw token values, Home Assistant URLs, entity IDs, full action
catalog payloads, raw logs, or private local paths into shared reports. Use
counts, status labels, and cause codes.

## Helper

From the Sword Agent OS repo root:

```powershell
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckOnly -ExpectedActionId <allowed-action-id>
```

The helper reports:

```text
HOME_CONTROL_API_TOKEN: present|missing|placeholder|too-short (value hidden)
HOME_ASSISTANT_TOKEN: present|missing|placeholder|too-short (value hidden)
config: yaml_loaded=True action_count=<n> config_error_kind=<name|none>
health: status=<ok|degraded|config_error> ok=<bool> actions_count=<n>
actions: status=ok count=<n> expected_action=<present|missing|not-requested>
cause_code=<code>
```

`cause_code=none` means the startup/catalog checks passed. It does not prove
preview, execute, restore, or physical appliance state.

## Cause Codes

| Code | Meaning | Next action |
| --- | --- | --- |
| `live_home_control.local.checkout_missing` | Home Control organ checkout is not present | Install/update the standard distribution |
| `live_home_control.local.env_missing` | Generated organ `.env` is missing | Run `scripts/render-env-files.ps1 -Profile standard -Force` |
| `live_home_control.local.config_missing` | Home Control config file is missing | Render config or provide the local override |
| `live_home_control.env.home_control_api_token_missing` | Bridge local API token is absent | Add it to local env and render again |
| `live_home_control.env.home_control_api_token_placeholder` | Bridge local API token still looks like a template value | Replace it with a generated secret and render again |
| `live_home_control.env.home_control_api_token_too_short` | Bridge local API token is below the minimum length | Generate a 32+ character token and render again |
| `live_home_control.env.home_assistant_token_missing` | Home Assistant token is absent in the process env path | Add the token and render again |
| `live_home_control.env.home_assistant_token_placeholder` | Home Assistant token still looks like a template value | Replace it with the real long-lived token and render again |
| `live_home_control.env.home_assistant_token_too_short` | Home Assistant token is present but clearly not valid length | Replace it and render again |
| `live_home_control.bridge.health_unreachable` | The bridge `/health` endpoint could not be read | Start the bridge with the helper or check port/process |
| `live_home_control.bridge.health_config_error` | Bridge started, but server config is not live-ready | Use `config_error_kind` and env classes to identify the missing/rejected value |
| `live_home_control.bridge.actions_unavailable` | Authenticated `/actions` failed or returned unavailable | Stop before preview/execute; inspect bridge config and auth class |
| `live_home_control.bridge.expected_action_missing` | `/actions` did not return the ticketed action id | Fix the live ticket or action mapping before preview |
| `none` | Startup and action catalog checks passed | Continue only to ticketed preview/dry-run/execute after live guardrails are confirmed |

## Report Shape

Use this compact shape in task outputs or messages:

```text
lane: live Home Control
proof_level: live startup/catalog only
result: stopped-before-preview | catalog-ready
config_loaded: true|false
action_count: <n>
config_error_kind: <name|none>
health_status: <ok|degraded|config_error|unreachable>
expected_action: present|missing|not-requested
cause_code: <code>
preview: not-run|pass|fail
execute: not-run|pass|fail
physical_state: not-claimed|confirmed
```

Keep no-live/mock proof, live startup/catalog proof, preview proof, execute
proof, and physical-state proof separate.
