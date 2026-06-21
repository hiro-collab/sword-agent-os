# Capability Packs

<!-- capability-packs:overview -->

Capability packs are navigation units. They describe what a user wants to use
or customize; they do not grant live permission, proof, or release readiness.

Use architecture planes for ownership, manifests/contracts for distribution
truth, and local/private config for workspace selection.

## Pack Map

| Pack | Purpose | Primary docs | Main surfaces |
| --- | --- | --- | --- |
| Core Body Pack | Status, thought loop, guarded action, feedback | `README.md`, `docs/operate.md`, `docs/architecture.md` | `sword.ps1`, `runtime/`, `contracts/`, `control-plane/` |
| Thought / Chat Pack | Provider or mock thought behavior | `docs/customize.md`, `docs/local-configuration.md` | Thought Core settings and provider/model env values |
| Voice Pack | Speech input, TTS, VOICEVOX, audio readiness | `docs/local-configuration.md`, `docs/operate.md` | `organs/speech-input/`, `organs/expression/tts-service/` |
| Avatar / Projection Pack | AITuber Kit, Projection Visual, Self Mirror, VRM Model Telemetry | `docs/operate.md`, `examples/starter-profiles/projection-visual/README.md`, `docs/aituberkit-sword-adapter-inventory.md` | `organs/expression/`, `organs/display/`, `runtime/visual-motion-analyzer/`, `runtime/vrm-model-telemetry/` |
| Home Control Pack | Home Assistant bridge, action rows, preview/live proof boundaries | `docs/home-assistant-setup.md`, `docs/add-home-device.md`, `docs/home-control-action-authoring.md`, `docs/live-home-control-proof.md` | `organs/action/home-assistant-server/`, local Home Control config |
| Environment Pack | Environment state, vision snapshot, room-light evidence | `docs/proof-layers.md`, `docs/verification-commands.md` | `organs/environment/` |
| Gesture / Reflex Pack | Sword sign and gesture-preview boundaries | `docs/proof-layers.md` | `organs/reflex/mediapipe-sword-sign/` |
| Diagnostics Pack | Manifests, pins, readiness, doctor, maintenance smoke | `manifests/README.md`, `docs/standard-distribution-map.md`, `docs/troubleshooting.md`, `docs/verification-commands.md` | `scripts/validate-manifests.ps1`, `scripts/check-distribution-pins.ps1`, `scripts/doctor-distribution.ps1`, `scripts/test-distribution-maintenance.ps1` |
| Agent Worker Pack | Future agent repair skills and loop state | `AGENTS.md` | `skills/repair-no-live-readiness/`, future `runtime/loop-state/` |

## Choose Your Path

<!-- capability-packs:choose-your-path -->

| Want | Start here | Then check |
| --- | --- | --- |
| Inspect safely | `.\sword.ps1 status` | `docs/operate.md` |
| Verify install without live actions | `.\sword.ps1 verify` | `docs/verification-commands.md` |
| Change AI/model behavior | Thought / Chat Pack | `docs/customize.md`, `docs/local-configuration.md` |
| Change voice or avatar behavior | Voice Pack or Avatar / Projection Pack | `docs/customize.md` |
| Try voice/avatar safely | `voice-avatar` starter profile | `examples/starter-profiles/voice-avatar/README.md` |
| Check visible avatar motion | `projection-visual` starter profile | `examples/starter-profiles/projection-visual/README.md` |
| Connect Home Assistant | Home Control Pack | `docs/home-assistant-setup.md` |
| Add a home action | Home Control Pack | `docs/add-home-device.md`, `docs/home-control-action-authoring.md` |
| Request live proof | Home Control Pack plus proof docs | `docs/live-home-control-proof.md`, `docs/proof-layers.md` |
| Change an organ/module | Module / Organ plane | `docs/module-usage-index.md` |
| Ask an agent to repair repeated work | Agent Worker Pack | future agent-skill docs |

## Starter Profiles

<!-- capability-packs:starter-profile-plan -->

Starter profiles are product journeys, not proof claims and not automatic
front-door commands. Use `examples/starter-profiles/_template.md` when adding
or materially rewriting a profile. Required sections are Goal, Safe Route,
Result Fields, Stop Conditions, and Does Not Prove.
If a profile says preview, it must distinguish read-only/helper readiness from
Home Assistant preview endpoint proof.

| Starter profile | Purpose | Status |
| --- | --- | --- |
| `no-live-display` | Inspect and launch display/runtime surfaces without live providers or devices | example exists |
| `voice-avatar` | Confirm voice/avatar flow with explicit local/provider boundaries | example exists |
| `home-control-preview` | Exercise catalog/tracking/read-only readiness gates only | example exists |
| `home-control-live` | Ticketed live Home Assistant route with restore/stop/proof fields | planned, never default |
| `projection-visual` | Projection Visual / Self Mirror visible-motion route | example exists |
| `developer` | Manifest/contract/organ development and maintenance smoke route | planned |

Machine-readable reader surfaces remain separate:

- Self Mirror routes:
  `runtime/visual-motion-analyzer/self-mirror-consumer-routes.json`
- VRM Model Telemetry routes:
  `runtime/vrm-model-telemetry/vrm-model-telemetry-consumer-routes.json`
- Reference-surface rules:
  `docs/reference-surfaces.md`
