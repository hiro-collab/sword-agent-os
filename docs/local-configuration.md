# Local Configuration

Use this guide after installation when adding API keys, tokens, device
settings, or local URLs.

Sword Agent OS uses a central local env file and renders organ-specific `.env`
files from it.

```text
local\env\sword-agent-os.env
```

This file is not tracked by Git. Put secrets, local URLs, model names, and
machine-specific device settings here.

## First Env Setup

If the installer already created `local\env\sword-agent-os.env`, start at step
3. If you are creating it manually, start at step 1.

1. Move to the `sword-agent-os` root.

```powershell
cd <sword-agent-os path>
$RepoRoot = (Resolve-Path .).Path
Set-Location $RepoRoot
```

2. Copy the public template.

```powershell
if (-not (Test-Path local\env\sword-agent-os.env)) {
  New-Item -ItemType Directory -Force local\env | Out-Null
  Copy-Item templates\env\sword-agent-os.env.example local\env\sword-agent-os.env
}
```

3. Edit the central env.

```powershell
notepad local\env\sword-agent-os.env
```

4. Check the main values.

Home Assistant values can wait if you are not using live appliances. LLM values
can also wait if you only want a minimal no-live startup check.

| Item | Env | Purpose |
| --- | --- | --- |
| LLM API key | `THOUGHT_CORE_LLM_API_KEY` or `OPENAI_API_KEY` | Thought Core natural-language responses. For no-LLM checks, use `THOUGHT_CORE_LLM_ENABLED=false`. |
| LLM model / URL | `THOUGHT_CORE_LLM_MODEL`, `THOUGHT_CORE_LLM_BASE_URL` | OpenAI-compatible LLM endpoint. |
| Home Assistant token | `HOME_ASSISTANT_TOKEN` | Appliance state checks and actions. |
| local bridge token | `HOME_CONTROL_API_TOKEN` | Local protection for the Home Assistant bridge. |
| Home Control config path | `HOME_CONTROL_CONFIG` | Selected full-schema private/live `home-control.yaml` or reviewed clone-local equivalent. |
| appliance adapter | `THOUGHT_CORE_TOOLS_ADAPTER` | `mock` is no-live simulation. Use `home_control` only for live appliance action. |
| Environment API token | `ENVIRONMENT_API_TOKEN` | Local protection for the Environment State API. It can be empty in the standard no-live setup. |
| VOICEVOX URL | `VOICEVOX_SERVER_URL` | Speech synthesis endpoint. |
| avatar path | `NEXT_PUBLIC_SELECTED_VRM_PATH` | AITuber Kit / Projection Visual avatar path. Clean install uses tracked sample `/vrm/nikechan_v1.vrm`. Use `/vrm/<your-model>.vrm` only for a local licensed model. |
| Thought Core endpoint | `THOUGHT_CORE_BASE_URL`, `NEXT_PUBLIC_THOUGHT_CORE_BASE_URL` | AITuber Kit to Thought Core connection. |

## Secret Boundaries

`NEXT_PUBLIC_*` values are visible to browser code. Do not put secrets in them.

| Name | Protects / Connects | Secret | Browser-visible | Can Be Empty For Mock / No-Live | Required For Live Appliances |
| --- | --- | --- | --- | --- | --- |
| `HOME_ASSISTANT_TOKEN` | Home Assistant state read and action execution | yes | no | yes | yes |
| `HOME_CONTROL_API_TOKEN` | Local Sword Home Assistant bridge | yes | no | depends on setup | recommended |
| `ENVIRONMENT_API_TOKEN` | Environment State API | yes | no | yes | no |
| `THOUGHT_CORE_LLM_API_KEY` | Thought Core LLM provider | yes | no | yes, when LLM is disabled | no |
| `OPENAI_API_KEY` | Some OpenAI-compatible adapters | yes | no | yes | no |
| `DIFY_API_KEY` | Dify compatibility route | yes | no | yes | no |
| `NEXT_PUBLIC_*` | Browser / AITuber Kit / Projection Visual display and connection settings | no | yes | depends on item | no |

`HOME_CONTROL_API_TOKEN` is not the Home Assistant token. It is a random local
bridge token. Generate one with:

```powershell
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

If `THOUGHT_CORE_TOOLS_ADAPTER=mock`, appliance actions stay in no-live
simulation even when API keys or Home Assistant tokens are present. Change it to
`home_control` only when the target, count, restore path, and stop condition are
defined.

## Render Env Files

Render the central env into organ `.env` files:

```powershell
Set-Location $RepoRoot
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard
```

Existing organ `.env` files are not overwritten by default. Use `-Force` only
when you want to regenerate them from the central env:

```powershell
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard -Force
```

After adding Home Assistant token, `HOME_CONTROL_API_TOKEN`, or
`ENVIRONMENT_API_TOKEN`, rerun with `-Force` before startup.

`-Force` also regenerates
`organs\action\home-assistant-server\config\home-control.yaml`. If you maintain
a live-specific config separately, reapply that config after the last `-Force`,
then use the bridge helper `-CheckOnly` and `-CheckTracking` before execution.
Use `-CheckState` only after a ticketed execute/wait or restore/wait step.

## Home Assistant Config Context

For a first-time external Home Assistant setup, read `docs/home-assistant-setup.md`
first. This section is the detailed local config rule behind that front door.

For Home Assistant verification, the selected config context is part of the
proof. A fresh clone, Git worktree, or RR003-style verification checkout can be
used, but it must load the same class of config that the route intends to test.

Use this order:

1. Render the central env into organ env files.
2. Confirm which `HOME_CONTROL_CONFIG` path the Home Control bridge will use.
3. Confirm the selected `home-control.yaml` is not the public demo/default
   template when live appliance proof is being claimed.
4. Confirm each live candidate row is full-schema: it has `ha_script`,
   `verification.mode`, `expected_effect`, proof ceiling metadata, and any
   restore/stop/terminal metadata required by the action family.
5. Run `start-home-control-bridge.ps1 -CheckOnly` and `-CheckTracking` from the
   same workspace that will run the route.
6. Treat `-CheckState` as a read of current Home Assistant state. It proves a
   live action result only after the ticketed execute/wait or restore/wait step.

Do not use a short/minimal action-only override as a tracked-state proof
context. It can be useful for command shape, preview, or command-ack checks, but
without `expected_effect` and verification metadata the current bridge schema
cannot know which Home Assistant state surface should prove the result.

If a worktree or fresh clone cannot see private local files directly, do not
copy raw private values into Git. Provide a private ignored full-schema override
or a reviewed clone-local equivalent. Shared reports should name only the class
of context, such as `reviewed_clone_local_full_schema_equivalent`, not raw
entity ids, script ids, URLs, tokens, or local paths.

Home Control action row authoring is separate from local env setup. Use
`docs/home-control-action-authoring.md` for `control_type`, `state_authority`,
`verification.mode`, `proof_ceiling`, `live_test_readiness`,
`restore_action_id`, vacuum start/return criteria, and HA-readable cover,
door, climate, or vacuum state rows.

Ticketed live execution is also separate. Use
`docs/live-home-control-proof.md` for preview, dry-run, execute, wait,
post-state, restore, external observation, and physical proof boundaries.

Environment State `appliances` or `state_queries` do not appear just because
tokens exist. The Home Control config must point at the real Home Assistant URL,
scripts, and readable state source. If demo script or demo light identifiers
are still present, treat it as demo configuration.

## Generated Files

`render-env-files.ps1` generates or updates these main outputs:

```text
control-plane\sword-voice-agent\.env
control-plane\sword-voice-agent\services\thought-core\.env
organs\action\home-assistant-server\.env
organs\expression\tts-service\.env
organs\expression\aituber-kit\.env
organs\action\home-assistant-server\config\home-control.yaml
```

Usually edit the central env. Edit organ-specific `.env` files directly only
for debugging or temporary organ-specific values. Direct edits are overwritten
the next time `render-env-files.ps1 -Force` runs.

Template references:

```text
templates\env\sword-agent-os.env.example
control-plane\sword-voice-agent\.env.example
control-plane\sword-voice-agent\services\thought-core\.env.example
organs\action\home-assistant-server\.env.example
organs\expression\tts-service\.env.example
organs\expression\aituber-kit\.env.example
```

## Configuration Areas

| Area | Role |
| --- | --- |
| Thought Core LLM settings | OpenAI-compatible base URL, model, and API key. |
| Thought Core endpoint | Local Thought Core API URL. |
| AITuber Kit settings | Projection Visual, voice output, and Thought Core connection. |
| Home Assistant settings | URL, long-lived token, local API token, and device mapping. |
| Camera settings | Camera name or input used by MediaPipe / Camera Hub. |
| VOICEVOX URL | Local speech synthesis endpoint. |

Home Assistant is required for real appliance action. Without Home Assistant,
you can still run many source/static checks, display-development flows, and
no-live tests.

## Local Media Seed

Local replay helpers read:

```text
local\media\media-index.json
```

After a reset, `_secret_inputs` may still contain private media, but replay
helpers do not read that directory directly. Put a private seed file at:

```text
_secret_inputs\local-media-index.seed.json
```

Example shape:

```json
{
  "assets": [
    {
      "id": "gesture.sword.20260603",
      "kind": "video",
      "source_path": "media/sword.mp4",
      "duration_sec": 3.2
    }
  ]
}
```

`source_path` may be relative to `_secret_inputs` or an absolute path under
`_secret_inputs`. Then prepare the local workspace index:

```powershell
pwsh -NoProfile -File .\scripts\prepare-local-media-index.ps1 -DryRun
pwsh -NoProfile -File .\scripts\prepare-local-media-index.ps1
```

If the fresh clone and the private seed bundle are in different roots, keep
`-WorkspaceRoot` pointed at the clone that will receive `local\media\...`, and
point `-SecretInputsRoot` at the private `_secret_inputs` directory:

```powershell
pwsh -NoProfile -File .\scripts\prepare-local-media-index.ps1 -WorkspaceRoot <fresh-clone-root> -SecretInputsRoot <private-secret-inputs-root> -DryRun
```

The helper writes `local\media\media-index.json` and copies media into ignored
`local\media\assets\`. It prints only redacted counts and asset ids. Do not
commit raw media, private seed files, screenshots, transcripts, or absolute
local paths.

Asset ids are visible in redacted proof output, so treat the id itself as
shareable metadata. Use short non-personal, non-secret ids and avoid names,
places, account labels, private project labels, or device/location hints.
Duplicate asset ids are rejected because they make replay proof ambiguous.
