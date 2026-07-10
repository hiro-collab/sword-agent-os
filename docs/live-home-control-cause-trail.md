# Live Home Control Cause Trail

This note defines the compact diagnostic trail for Home Control routes that stop
before, during, or after a bounded operation. It is a reporting contract, not a
live-operation recipe.

Do not paste raw token values, Home Assistant URLs, entity IDs, full action
catalog payloads, raw logs, screenshots, media, or private local paths into
shared reports. Use counts, status labels, safe action aliases, and cause codes.

## Helper Surface

From the Sword Agent OS repo root:

```powershell
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckOnly -ExpectedActionId <allowed-action-id>
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckTracking -ActionId <allowed-action-id>
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckState -ActionId <allowed-action-id>
```

The helper emits redacted fields like this:

```text
HOME_CONTROL_API_TOKEN: present|missing|placeholder|too-short (value hidden)
HOME_ASSISTANT_TOKEN: present|missing|placeholder|too-short (value hidden)
config: yaml_loaded=True action_count=<n> config_error_kind=<name|none>
health: status=<ok|degraded|config_error> ok=<bool> actions_count=<n>
actions: status=ok count=<n> expected_action=<present|missing|not-requested>
tracking: action_id=<id> control_type=<type> state_authority=<authority> verification_mode=<mode> state_tracking=<tracked|external_required|ack_only|manual_required|unsupported|untracked> expected_state=<state|none> expected_states=<states|none> expected_position=<threshold|none> settle_seconds=<s> timeout_seconds=<s> proof_ceiling=<class> live_test_candidate=<true|false> live_test_readiness=<test_now|not_live_test_candidate|missing_action> live_test_blockers=<classes|none> restore_action=<id|none> stop_action=<id|none> terminal_action=<true|false> status=<same>
state: action_id=<id> expected_state=<state|none> expected_states=<states|none> actual_state=<state|none> expected_position=<threshold|none> actual_position=<number|none> position_status=<matched|mismatch|unavailable|none> status=<matched|mismatch|position_unavailable|external_required|ack_only|manual_required|unsupported|untracked|unavailable>
cause_code=<code>
```

`-CheckTracking` is pre-execution metadata. A `state_tracking=tracked` row is
designed for a later HA-visible state check; `external_required`, `ack_only`,
`manual_required`, `unsupported`, and `untracked` rows must stay at another
layer. It does not read current Home Assistant state.

`-CheckState` is a read-only state matcher for current, post-action, or
post-restore HA-visible state. A pre-command read can support a JIT gate, but it
does not prove that the next command changed anything. A post-action match is
still not physical or external observation proof.

`live_test_readiness` is metadata, not a separate approval gate. `test_now` only
means the row can enter a bounded exact Home Assistant route. `missing_action`
is the concrete technical blocker; `not_live_test_candidate` is only legacy
metadata and must not stop a user-selected exact action route by itself.

`live_test_blockers` reports concrete setup, restore, stop, or proof
limitations; it is not an approval queue. The compatibility `unsafe-ticket`
cause kind currently means a state or tracking diagnostic omitted its required
action id. Fix that request metadata; do not wait for standing manager or
security approval.

For cover/door actions with readable position attributes, state alone is not
enough. A matched row must satisfy the configured `verification.position`
threshold as well as the accepted state.

## Cause Codes

| Code | Meaning | Next action |
| --- | --- | --- |
| `live_home_control.local.checkout_missing` | Home Control organ checkout is not present | Install/update the standard distribution |
| `live_home_control.local.env_missing` | Generated organ `.env` is missing | Render env files |
| `live_home_control.local.config_missing` | Home Control config file is missing | Render config or provide the local override |
| `live_home_control.env.home_control_api_token_missing` | Bridge local API token is absent | Add it to local env and render again |
| `live_home_control.env.home_control_api_token_placeholder` | Bridge local API token still looks like a template value | Replace it with a generated local secret and render again |
| `live_home_control.env.home_control_api_token_too_short` | Bridge local API token is below the minimum length | Generate a 32+ character token and render again |
| `live_home_control.env.home_assistant_token_missing` | Home Assistant token is absent in the process env path | Add the token and render again |
| `live_home_control.env.home_assistant_token_placeholder` | Home Assistant token still looks like a template value | Replace it with the real local token and render again |
| `live_home_control.env.home_assistant_token_too_short` | Home Assistant token is present but clearly not valid length | Replace it and render again |
| `live_home_control.bridge.health_unreachable` | The bridge `/health` endpoint could not be read | Start the bridge with the helper or check port/process |
| `live_home_control.bridge.health_config_error` | Bridge started, but server config is not ready | Use `config_error_kind` and env classes to identify the missing value |
| `live_home_control.bridge.actions_unavailable` | Authenticated `/actions` failed or returned unavailable | Stop before preview/execute; inspect bridge config and auth class |
| `live_home_control.bridge.expected_action_missing` | `/actions` did not return the route action id | Fix the route or action mapping before preview |
| `live_home_control.bridge.state_action_missing` | State check was requested without an action id | Rerun with `-CheckState -ActionId <allowed-action-id>` |
| `live_home_control.bridge.state_tracking_action_missing` | Tracking metadata check was requested without an action id | Rerun with `-CheckTracking -ActionId <allowed-action-id>` |
| `live_home_control.bridge.state_tracking_untracked` | The action has no explicit state-check metadata | Add a proof-ready row or keep the action out of HA-visible state claims |
| `live_home_control.bridge.state_tracking_external_required` | The action is intentionally verified outside HA-visible state | Select the external or manual observation proof layer for this route |
| `live_home_control.bridge.state_tracking_ack_only` | The action can only prove command acceptance/submission | Do not claim current appliance state |
| `live_home_control.bridge.state_tracking_manual_required` | The action needs manual confirmation | Stop unless the route includes that proof layer |
| `live_home_control.bridge.state_tracking_unsupported` | The action declares an unsupported verification mode | Fix metadata or use another proof layer |
| `live_home_control.bridge.state_unavailable` | The bridge could not read redacted Home Assistant state | Check bridge auth/availability, then rerun `-CheckState` |
| `live_home_control.bridge.state_position_unavailable` | State was readable, but required position was absent/non-numeric | Check target position support and route wait window |
| `live_home_control.bridge.state_external_required` | The action needs external observation instead of HA-visible state | Select the external observation proof layer for this route |
| `live_home_control.bridge.state_ack_only` | The action can only prove command acknowledgement | Do not claim appliance state |
| `live_home_control.bridge.state_manual_required` | The action needs manual confirmation instead of HA-visible state | Get that proof layer separately |
| `live_home_control.bridge.state_unsupported` | The action cannot produce HA-visible state with current metadata | Fix metadata or use another proof layer |
| `live_home_control.bridge.state_untracked` | The action has no configured expected-effect check | Add/verify metadata before claiming HA-visible state |
| `live_home_control.bridge.state_mismatch` | Home Assistant state was read but did not match configured expected states | Wait the route interval, verify the action, or run the route-owned restore if selected |
| `none` | Startup and action catalog checks passed | Continue within the selected bounded route and its proof ceiling |

## Report Shape

Use this compact root-cause trace packet in task outputs, QA result files,
message summaries, and manager summaries. Active watch should track the latest
summary, not raw logs.

```text
proof_layer: source-static | no-live/mock | runtime/browser | live-bridge | live-preview | live-execute | live-ha-state | external-observation-route | physical-state
entrypoint: launcher | helper | direct-uvicorn | smoke-script | unknown
blocked_at: none | env-render | config-load | process-env | service-start | health | action-catalog | state-tracking | preview | execute | restore | state-check | physical-confirmation
observed_status: ok | warning | blocked | config_error | unavailable | timeout | unknown
cause_kind: none | missing-file | placeholder-secret | missing-process-env | config-mismatch | port-conflict | auth-failure | ha-unreachable | action-not-in-catalog | unsafe-ticket | unknown
evidence: short redacted facts only
next_probe: one concrete next check
safe_stop: yes/no
physical_action_executed: yes/no
action_execution_scope: this_helper_invocation | prior_exact_execute | not_applicable
```

Keep source/static, no-live readiness, runtime/browser, preview, dry-run,
command submission, HA-visible state, external observation, and physical/device
proof as separate rows. Helper-only checks such as `-CheckTracking` or
`-CheckState` should usually report `physical_action_executed: no`; that does
not erase a prior route execution, which should be reported as its own row.

The bridge helper uses an organ-local `.uv-cache` for its child `uv run` so a
restricted or agent environment does not need persistent `UV_CACHE_DIR` changes
just to start the local bridge.

Use `docs/live-home-control-proof.md` for the bounded live route ladder and
`docs/proof-layers.md` for cross-system proof vocabulary.
