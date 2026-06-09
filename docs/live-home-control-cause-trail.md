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
tracking: action_id=<id> control_type=<type> state_authority=<authority> verification_mode=<mode> state_tracking=<tracked|external_required|ack_only|manual_required|unsupported|untracked> expected_state=<state|none> expected_states=<states|none> expected_position=<threshold|none> settle_seconds=<s> timeout_seconds=<s> status=<same>
state: action_id=<id> expected_state=<state|none> expected_states=<states|none> actual_state=<state|none> expected_position=<threshold|none> actual_position=<number|none> position_status=<matched|mismatch|unavailable|none> status=<matched|mismatch|position_unavailable|external_required|ack_only|manual_required|unsupported|untracked|unavailable>
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
For cover/door actions with `current_position`, state alone is not sufficient:
configure `verification.position` and require the inclusive numeric threshold to
match along with the accepted state before reporting `HA state matched`.

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
| `live_home_control.bridge.state_position_unavailable` | The target state was readable, but the required position attribute was absent or non-numeric | Check that the target entity exposes `current_position`, wait the ticket window, and rerun `-CheckState` |
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
proof_layer: source-static | no-live/mock | runtime/browser | live-bridge | live-preview | live-execute | live-ha-state | external-observation-route | physical-state
entrypoint: launcher | helper | direct-uvicorn | smoke-script | unknown
blocked_at: none | env-render | config-load | process-env | service-start | health | action-catalog | state-tracking | preview | execute | restore | state-check | physical-confirmation
observed_status: ok | warning | blocked | config_error | unavailable | timeout | unknown
cause_kind: none | missing-file | placeholder-secret | missing-process-env | config-mismatch | port-conflict | auth-failure | ha-unreachable | action-not-in-catalog | unsafe-ticket | unknown
evidence: short redacted facts only
next_probe: one concrete next check
safe_stop: yes/no
physical_action_executed: yes/no
action_execution_scope: this_helper_invocation
```

Keep no-live/mock proof, live startup/catalog proof, preview proof, execute
proof, and physical-state proof separate.
The bridge helper uses an organ-local `.uv-cache` for its child `uv run` so a
restricted or agent environment does not need persistent `UV_CACHE_DIR` changes
just to start the local bridge.
In helper-only checks such as `-CheckTracking` or `-CheckState`,
`physical_action_executed: no` means that this helper invocation did not send a
device command. It does not erase a prior ticketed execute; report the earlier
execute as a separate `live-execute` row and the later state read as
`live-ha-state`.

For actions that cannot produce Home Assistant state proof, keep the action in
an external or manual proof route. Camera, screenshot, recording, raw media, and
live appliance routes remain held until an explicit operator GO names the
target, capture scope, storage policy, and stop condition.

| Target family | Preferred external route | Fallback route | Do not claim |
| --- | --- | --- | --- |
| SwitchBot remote-style light | Environment State fed by a separate power/light sensor | Camera brightness summary or manual visual confirmation | `switch:unknown` as `on` / `off`; daylight camera brightness as electric-light certainty |
| Fan | Environment State fed by power, vibration, rotation, or airflow evidence | Camera motion summary or manual visual confirmation | IR/script accepted as running/stopped proof; audio proof without recording GO |
| Door / cover | Contact or position evidence through Environment State | Camera position summary or manual visual confirmation | `open` / `closed` state alone when position can disagree or partial movement is observed |
| Aircon | Reliable climate state through Home Assistant or Environment State | Power plus temperature trend, visual LED/louver summary, or manual confirmation | IR/script accepted as real HVAC state; delayed temperature drift as immediate state proof |

Use these short proof labels when summarizing a live action:

```text
command_ack_only: bridge/Home Assistant accepted the command, not appliance proof
external_required: this action cannot produce HA state proof and needs another proof route
external_observation: redacted camera, Environment State, separate-sensor, or manual evidence supports the physical-state claim
manual_required: automated proof is insufficient; operator confirmation is needed before claiming state
external_inconclusive: external evidence exists but is partial, stale, conflicted, or too ambiguous for the claim
conflict: source layers disagree; preserve redacted refs and do not silently re-operate
restored / reversible: restore path also reached its expected proof layer
restored / reversible with retry: restore succeeded, but only after extra execute attempts
```

For SwitchBot remote-style light proof, prefer the bounded helper:

```powershell
pwsh -NoProfile -File .\scripts\run-home-control-light-proof.ps1 -DryRun
pwsh -NoProfile -File .\scripts\run-home-control-light-proof.ps1 -ConfirmLiveLightTicket -OffActionId light_off -OnActionId light_on -Json
```

It keeps the proof layers separate:

```text
command_submission=<pass|blocked|preview-only>
physical_brightness_observation=<pass|inverted|not-reproduced>
restore_observed=<pass|not-reproduced>
```

The helper reports aggregate brightness metrics only. It does not save or
share raw media, does not expose secrets, and does not turn camera readiness
into physical-state proof if the brightness deltas are too small. If the
brightness moves in the opposite direction, report `inverted` and check action
mapping / observation route before claiming the requested physical state. If the
standard stack owns the camera, stop the stack or use a documented split route
before collecting independent no-save brightness proof.

For external observation evidence, keep only compact redacted facts:

```text
proof_layer: physical-state
proof_label: external_observation | manual_required | external_inconclusive | conflict
action_id: <allowed-action-id>
execution_ref: action:<redacted-id>
subject: capability.<safe-redacted-target>
observation_route: manual_visual | camera_summary | environment_state
source_layer: user_confirmation | camera_vision | environment_state | action_feedback
observed_value: on | off | open | closed | unknown | other
confidence: 0.0-1.0
freshness_ms: <number>
evidence_refs: action:<safe-id> | snapshot:<safe-id> | metric:<safe-id>
raw_media_saved: false
raw_media_shared: false
private_fields_omitted: token, ha_url, entity_id, raw_log, raw_catalog, raw_response, raw_frame, screenshot, audio, local_path
```

The 2026-06-09 no-save camera check proved only that the local observation path
could open a camera and read one frame without saving or displaying raw media.
It is not a door/cover, AC, light, or fan physical-state proof until a separate
scoped observation run records a semantic summary.

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
evidence: action_id=<allowed-action-id>; state_authority=ha_entity; state_tracking=tracked; expected_state=<state>; expected_states=<states>; expected_position=<threshold|none>; settle_seconds=<s>; timeout_seconds=<s>
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
evidence: action_id=<allowed-action-id>; expected_state=<state>; expected_states=<states>; actual_state=<state>; expected_position=<threshold|none>; actual_position=<number|none>; position_status=<matched|mismatch|unavailable|none>
next_probe: optional independent physical/camera confirmation if that proof layer is required
safe_stop: yes
physical_action_executed: no
```

Here `physical_action_executed: no` is expected: the state check reads the
post-action Home Assistant state but does not itself execute or restore the
device.

For the 2026-06-09 vacuum pilot, do not use all-vacuum domain counts as the
action proof. The HA setup exposes more than one `vacuum` entity, while the
script target is one redacted target entity. Use the configured
`expected_effect.entity_id` only.

```text
proof_layer: live-execute + live-ha-state
entrypoint: bridge helper + HA REST read-only state summary
blocked_at: target-state-wait
observed_status: warning
cause_kind: async-state-transition
evidence: multiple vacuum entities exist; bridge script targets one entity; start and return transitions can appear on different entities at different times; final target CheckState matched docked after an extra return
next_probe: use target-specific CheckState after every return; report retry count if the first wait does not match
safe_stop: yes
physical_action_executed: yes
```

This can be `HA state matched` only after the target-specific `CheckState`
matches. If another return was needed, report `restored / reversible with retry`
and keep the retry count visible.

For the 2026-06-09 Home Assistant script maintenance pass, keep it out of live
appliance proof:

```text
proof_layer: ha-config-maintenance
entrypoint: HA backup + script config API + config check + script reload
blocked_at: none
observed_status: ok
cause_kind: none
evidence: automatic backup API failed first; user-created backup was used; 12 bridge-referenced scripts were changed from implicit default mode to explicit mode=single; config check ok; script domain reload ok; post-read verification mode_single=12/12
next_probe: bridge CheckOnly / CheckTracking / CheckState for the next target action
safe_stop: yes
physical_action_executed: no
```

`mode: single` matches the Home Assistant script default. It is a readability and
operator-safety maintenance change, not proof that any appliance state changed.
If the Home Assistant backup API fails but a recent UI-created or automatic
backup exists, record that as `backup-external` instead of retrying API backup
creation blindly. A backup proof only protects rollback; it does not prove
script reload, command execution, HA state, or physical state.

For the 2026-06-09 door/cover pilot, see
`docs/live-home-control-integration-report-2026-06-09.md` and keep the action
out of HA state-proof promotion:

```text
proof_layer: live-execute + live-ha-state
entrypoint: bridge helper + HA REST read-only state summary
blocked_at: closed-state-proof
observed_status: warning
cause_kind: partial-position-transition
evidence: door_close submitted; multiple cover attributes changed but did not reach clean closed proof; one cover reported closed with a nonzero position while another remained open at a partial position; door_open restore needed one extra execute and returned both positions to the open threshold
next_probe: keep door_open/door_close as command_ack_only until target/group behavior is reviewed, local config uses verification.position, and ticketed execute/wait/CheckState proves the threshold
safe_stop: yes
physical_action_executed: yes
```

Do not treat `open` alone as restored for cover actions when
`current_position` is available. For this target, state and position can disagree
enough that `CheckState` proof must include the configured position threshold.

For the 2026-06-09 AC switch-wrapper pilot, live execute succeeded but climate
state proof did not:

```text
proof_layer: live-execute + live-ha-state
entrypoint: bridge helper + HA REST read-only state summary
blocked_at: climate-state-proof
observed_status: warning
cause_kind: switch-wrapper-not-climate-proof
evidence: aircon_off and aircon_on submitted; switch distribution changed; climate state stayed fan_only; short-window temperature sensors were inconclusive
next_probe: keep aircon_on/aircon_off as command_ack_only; prove a separate climate-domain action before claiming HA state proof
safe_stop: yes
physical_action_executed: yes
```

Do not use switch distribution changes, script submission, or short-window
temperature drift as immediate proof that the AC mode changed. Promote AC only
through a climate-domain route that can read back the intended state.
