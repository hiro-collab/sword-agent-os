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

Use this compact root-cause trace packet in task outputs, QA result files,
message summaries, and manager summaries. The helper emits the same shape in
`-CheckOnly` failure paths. Active-watch should track only the latest summary,
not raw logs.

```text
proof_layer: source-static | no-live/mock | runtime/browser | live-bridge | live-preview | live-execute | physical-state
entrypoint: launcher | helper | direct-uvicorn | smoke-script | unknown
blocked_at: env-render | config-load | process-env | service-start | health | action-catalog | preview | execute | restore | physical-confirmation
observed_status: ok | warning | blocked | config_error | unavailable | timeout | unknown
cause_kind: missing-file | placeholder-secret | missing-process-env | config-mismatch | port-conflict | auth-failure | ha-unreachable | action-not-in-catalog | unsafe-ticket | unknown
evidence: short redacted facts only
next_probe: one concrete next check
safe_stop: yes/no
physical_action_executed: yes/no
```

Keep no-live/mock proof, live startup/catalog proof, preview proof, execute
proof, and physical-state proof separate.

For the confirmed 2026-06-02 failure, the redacted packet shape is:

```text
proof_layer: live-bridge
entrypoint: direct-uvicorn
blocked_at: process-env
observed_status: config_error
cause_kind: missing-process-env
evidence: config_loaded=True; actions_count=12; .env had HOME_ASSISTANT_TOKEN; process init without env-file reported HOME_ASSISTANT_TOKEN; init with env-file reported none
next_probe: rerun helper -CheckOnly with expected action id
safe_stop: yes
physical_action_executed: no
```
