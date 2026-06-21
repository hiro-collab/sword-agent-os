# Connect Home Assistant

This page is the first-read checklist for using Sword Agent OS with an
external Home Assistant environment. It is product setup guidance, not a Codex
thread prompt and not live execution approval.

Use this page when:

- you cloned the project in a new environment;
- you want Home Assistant state or appliance actions to work;
- you are moving from mock/no-live checks to a real Home Assistant instance;
- you are using a fresh clone or Git worktree and need to know which private
  config must be available there.

## The Short Version

Home Assistant setup has two separate parts:

1. Connection: Sword can reach Home Assistant and read the Home Control action
   catalog.
2. Proof-ready config: the selected `home-control.yaml` action row tells Sword
   which Home Assistant state proves the action result.

Do not treat connection alone as proof-ready setup. A short action-only config
can make an action visible and still be unable to prove state.

For HA-visible `CheckState` proof, the selected config must be a full-schema
private/live config or a reviewed clone-local equivalent.

## First-Time Flow

Start with the no-live install/readiness route:

```powershell
.\sword.ps1 status -NoLive
.\sword.ps1 verify -NoLive
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard -DryRun
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard
```

Confirm Python through `uv`, not by guessing from `PATH`:

```powershell
uv python find
uv python list --only-installed
```

When you need to know the interpreter for a specific Python organ, run this
inside that organ directory:

```powershell
uv run python --version
```

Then set up local/private values. The central file is:

```text
local\env\sword-agent-os.env
```

At minimum for Home Assistant live work, provide:

| Value | Purpose |
| --- | --- |
| `HOME_ASSISTANT_TOKEN` | Long-lived token for Home Assistant state reads and action scripts |
| `HOME_CONTROL_API_TOKEN` | Local token for the Sword Home Control bridge |
| `HOME_CONTROL_CONFIG` | The selected Home Control YAML config path |
| `THOUGHT_CORE_TOOLS_ADAPTER=home_control` | Enables real Home Control routing instead of mock/no-live simulation |

After editing local env, render organ env/config files:

```powershell
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard -Force
```

If `-Force` regenerates the public demo/default `home-control.yaml`, reapply the
private/live full-schema config after the render step. This is the most common
place where fresh clones accidentally fall back to demo or minimal config.

## Required Config Context

Before any preview, dry-run, or live submit, confirm the selected config class.

| Checkpoint | Must be true | Stop if |
| --- | --- | --- |
| Selected workspace | The bridge is running from the clone/worktree being tested | You are looking at another workspace's bridge or stale port |
| Selected config | `HOME_CONTROL_CONFIG` points at the intended local/private config | It points at demo/default/template config |
| Full-schema row | The action row has command binding and verification metadata | It is only a short action/script mapping |
| Expected effect | The row names the target state surface and accepted result | The script exists but the target state is absent or guessed |
| Tracking gate | `-CheckTracking` returns tracked/testable readiness for this action | It returns `ack_only`, `external_required`, unavailable, or a blocker |
| State proof | `-CheckState` is used after execute/wait or restore/wait for action-result proof | A pre-command current-state read is used as live-effect proof |

## Full-Schema Action Row

A state-proof-capable action row needs both the command and the state proof
metadata. The exact ids belong in your private config, not in public reports.

```yaml
actions:
  vacuum_return:
    label: "Return vacuum to base"
    ha_script: "<script.your_return_script>"
    confirm_required: true
    control_type: "job_command"
    state_authority: "ha_entity"
    live_test_candidate: true
    terminal_action: true
    proof_ceiling: "ha_visible_vacuum_return_checkstate_layer"
    verification:
      mode: "ha_state"
      accepted_states: ["docked"]
      settle_seconds: 10
      timeout_seconds: 75
    expected_effect:
      domain: "vacuum"
      service: "return_to_base"
      entity_id: "<vacuum.your_target>"
      expected_state: "docked"
```

For other appliances, the same rule holds: do not claim HA-visible proof unless
the selected action row says which Home Assistant state surface is authoritative
and which state counts as success.

## Minimal Config Is Not Enough

This is valid for command shape or command acknowledgement:

```yaml
actions:
  vacuum_return:
    ha_script: "<script.your_return_script>"
```

But it is not enough for HA-visible `CheckState` proof. The bridge can submit or
preview the action, but it cannot know which Home Assistant state should prove
success. In that case `CheckTracking` should hold the route at an `ack_only` or
configuration-blocked ceiling.

If a fresh clone has only this minimal private config, do not guess the target
from Home Assistant registry contents or old coordination notes. Provide a
private ignored full-schema override or reviewed clone-local equivalent.

## Fresh Clones And Git Worktrees

Git worktrees and fresh clones are usable for verification. The condition is
that each clone/worktree must receive the same class of private full-schema
config that the route intends to test.

Safe handoff pattern:

1. Keep raw Home Assistant ids, tokens, URLs, and local paths in ignored local
   files.
2. Copy or generate a private full-schema config inside the clone/worktree.
3. Select it with `HOME_CONTROL_CONFIG`.
4. Render/reapply local config.
5. Run read-only gates before live work.

Never commit raw Home Assistant entity ids, script ids, tokens, private URLs,
raw logs, screenshots, or local absolute paths.

## Read-Only Gates

Start the bridge only for the selected workspace/config and check in this order:

The helper keeps the selected bridge in the foreground unless a route explicitly
owns the process lease; stop it after the check so later work does not read a
stale workspace.

```powershell
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckOnly -ExpectedActionId <allowed-action-id>
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckTracking -ActionId <allowed-action-id>
```

Only after a reviewed live ticket executes should `CheckState` be used as
post-action proof:

```powershell
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckState -ActionId <allowed-action-id>
```

`CheckTracking` answers whether the action row is proof-ready.
`CheckState` reads Home Assistant state. A pre-command `CheckState` read is a
current-state gate, not action-result proof.

## Live Route Boundary

Live Home Assistant work still needs a bounded ticket. The ticket should name:

- action id and action count;
- preview / dry-run / execute counts;
- confirmation-token behavior when confirmation is required;
- settle and timeout windows;
- restore or terminal-state rule;
- stop conditions;
- proof ceiling;
- whether external or physical observation is in scope.

Use `docs/live-home-control-proof.md` for the ticket ladder and proof wording.

## Troubleshooting Quick Map

| Symptom | Likely cause | Next step |
| --- | --- | --- |
| `CheckOnly` passes but `CheckTracking` is `ack_only` | Action exists, but selected config lacks full-schema verification metadata | Add or select full-schema config |
| Script binding exists but state proof is blocked | `expected_effect` target is missing or not readable | Fix private config; do not guess target |
| Fresh clone sees demo actions | `render-env-files.ps1 -Force` regenerated demo/default config | Reapply private full-schema config after render |
| Worktree route sees `state_unavailable` | Wrong config context, stale bridge, or unavailable HA state surface | Confirm workspace, selected config, and bridge health |
| Dry-run consumes confirmation path | Confirmation token is one-time | Use a reviewed route shape with fresh preview before live or dry-run count 0 |
| HA-visible state matched but device proof is requested | HA-visible proof is not physical proof | Add a separate external/physical observation route |

## What To Report

Shared reports should use class-level fields:

- selected config class;
- action count;
- `CheckTracking` class;
- `CheckState` class;
- preview / dry-run / live counts;
- proof ceiling;
- exact blocker if any.

Shared reports must not include raw tokens, raw HA entity/script/device ids,
private URLs, local absolute paths, raw logs, screenshots, media, transcripts,
or private room/device labels.
