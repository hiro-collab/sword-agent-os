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
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckTracking -ActionId <allowed-action-id>
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckState -ActionId <allowed-action-id>
```

The helper reports:

```text
HOME_CONTROL_API_TOKEN: present|missing|placeholder|too-short (value hidden)
HOME_ASSISTANT_TOKEN: present|missing|placeholder|too-short (value hidden)
config: yaml_loaded=True action_count=<n> config_error_kind=<name|none>
health: status=<ok|degraded|config_error> ok=<bool> actions_count=<n>
actions: status=ok count=<n> expected_action=<present|missing|not-requested>
tracking: action_id=<id> control_type=<type> state_authority=<authority> verification_mode=<mode> state_tracking=<tracked|external_required|ack_only|manual_required|unsupported|untracked> expected_state=<state|none> expected_states=<states|none> settle_seconds=<s> timeout_seconds=<s> status=<same>
state: action_id=<id> expected_state=<state|none> expected_states=<states|none> actual_state=<state|none> status=<matched|mismatch|external_required|ack_only|manual_required|unsupported|untracked|unavailable>
cause_code=<code>
```

`cause_code=none` means the startup/catalog checks passed. It does not prove
preview, execute, restore, or physical appliance state.
`-CheckTracking` is a pre-execution metadata check: it reports whether the action has
configured HA state proof metadata (`tracked`) or needs a different proof layer
(`external_required`, `ack_only`, `manual_required`, or `unsupported`). It does not
read current Home Assistant state. For `tracked` actions, `expected_states`
includes the primary `expected_effect.expected_state` plus any additional
`verification.accepted_states`; `settle_seconds` and `timeout_seconds` are the
ticketed wait window, not proof by themselves. `-CheckState` is a post-action or
restore confirmation check: `cause_code=none` means Home Assistant state matched
one of the configured expected states for that action at the time it was read.
It still does not prove independent physical or camera confirmation. A
`-CheckState` mismatch before execute is not a bridge startup failure; it may
simply mean the target is not already in that action's expected post-state.

Remote-control or SwitchBot-style devices can be `stateless_toggle`: one press changes
the physical state, but Home Assistant cannot read whether the appliance is currently
on or off. Those actions must not be reported as HA state proof; they require external
observation, a separate sensor, or manual confirmation.

Use `state_authority` to keep state sources separate. `ha_entity` can support
Home Assistant state proof when the entity state is reliable. `ha_inferred` is a
shadow or last-command state and is not physical proof. `open_loop` means no current
state authority is available. `submitted_only` means the bridge can only prove that
the script command was accepted/submitted.

For `confirmation_required` actions, confirmation tokens are one-time tokens. A
dry-run that uses a token consumes it. Before the real execute, request a fresh
preview and use the new token only for that execute request.

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
| `live_home_control.bridge.state_action_missing` | State check was requested without an action id | Rerun with `-CheckState -ActionId <allowed-action-id>` |
| `live_home_control.bridge.state_tracking_action_missing` | Tracking metadata check was requested without an action id | Rerun with `-CheckTracking -ActionId <allowed-action-id>` |
| `live_home_control.bridge.state_tracking_untracked` | The action has no configured `expected_effect` metadata for later HA state proof | Add `expected_effect` plus reliable `verification.mode: ha_state`, or keep the action out of HA state-proof claims |
| `live_home_control.bridge.state_tracking_external_required` | The action is intentionally verified outside HA state | Use external/manual proof before claiming physical state |
| `live_home_control.bridge.state_tracking_ack_only` | The action can only prove that the command was accepted/submitted | Do not claim appliance state; add tracking metadata only if the target state is readable |
| `live_home_control.bridge.state_tracking_manual_required` | The action needs manual confirmation | Stop before state proof unless the ticket includes manual confirmation |
| `live_home_control.bridge.state_tracking_unsupported` | The action declares a verification mode the helper cannot turn into HA state proof | Fix metadata or keep it out of state-proof flows |
| `live_home_control.bridge.state_unavailable` | The bridge could not read redacted Home Assistant state for the action | Check bridge auth, Home Assistant availability, and rerun `-CheckState` |
| `live_home_control.bridge.state_external_required` | The action needs external observation instead of HA state proof | Use camera/sensor/manual proof only if separately approved |
| `live_home_control.bridge.state_ack_only` | The action can only prove command acknowledgement | Do not claim appliance state |
| `live_home_control.bridge.state_manual_required` | The action needs manual confirmation instead of HA state proof | Get the manual proof layer separately |
| `live_home_control.bridge.state_unsupported` | The action cannot produce HA state proof with the current metadata | Fix metadata or use another proof layer |
| `live_home_control.bridge.state_untracked` | The action has no configured `expected_effect` to check | Add/verify expected-effect metadata before claiming HA state proof |
| `live_home_control.bridge.state_mismatch` | Home Assistant state was read but did not match the configured expected states | Wait the ticket interval, verify the ticketed action, or run a ticketed restore |
| `none` | Startup and action catalog checks passed | Continue only to ticketed preview/dry-run/execute after live guardrails are confirmed |

## Report Shape

Use this compact root-cause trace packet in task outputs, QA result files,
message summaries, and manager summaries. The helper emits the same shape in
`-CheckOnly` failure paths. Active-watch should track only the latest summary,
not raw logs.

```text
proof_layer: source-static | no-live/mock | runtime/browser | live-bridge | live-preview | live-execute | live-ha-state | physical-state
entrypoint: launcher | helper | direct-uvicorn | smoke-script | unknown
blocked_at: none | env-render | config-load | process-env | service-start | health | action-catalog | state-tracking | preview | execute | restore | state-check | physical-confirmation
observed_status: ok | warning | blocked | config_error | unavailable | timeout | unknown
cause_kind: none | missing-file | placeholder-secret | missing-process-env | config-mismatch | port-conflict | auth-failure | ha-unreachable | action-not-in-catalog | unsafe-ticket | unknown
evidence: short redacted facts only
next_probe: one concrete next check
safe_stop: yes/no
physical_action_executed: yes/no
```

Keep no-live/mock proof, live startup/catalog proof, preview proof, execute
proof, and physical-state proof separate.

Use these short proof labels when summarizing a live action:

```text
command accepted: bridge/Home Assistant accepted the command, not appliance proof
HA state matched: expected_state or accepted_states matched after the wait
external observed: camera, sensor, manual observation, or other independent proof
restored / reversible: restore path also reached its expected proof layer
restored / reversible with retry: restore succeeded, but only after extra execute attempts
```

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

For a successful helper state check, use this shape:

```text
proof_layer: live-bridge
entrypoint: helper
blocked_at: none
observed_status: ok
cause_kind: none
evidence: action_id=<allowed-action-id>; state_authority=ha_entity; state_tracking=tracked; expected_state=<state>; expected_states=<states>; settle_seconds=<s>; timeout_seconds=<s>
next_probe: proceed to preview/dry-run; run CheckState only after ticketed execute/wait or restore/wait
safe_stop: yes
physical_action_executed: no
```

For a successful post-action helper state check, use this shape:

```text
proof_layer: live-ha-state
entrypoint: helper
blocked_at: none
observed_status: ok
cause_kind: none
evidence: action_id=<allowed-action-id>; expected_state=<state>; expected_states=<states>; actual_state=<state>
next_probe: optional independent physical/camera confirmation if that proof layer is required
safe_stop: yes
physical_action_executed: no
```
