# Capability Packs

<!-- capability-packs:overview -->

Capability packs are the user-facing way to understand Sword Agent OS features.
They sit above the internal planes in `docs/architecture.md`. A plane says which
part of the repo owns a concern; a capability pack says which functional slice a
user or developer is trying to use, extend, or replace.

This distinction keeps the repo from becoming a chimera:

- Use architecture planes to decide ownership and proof boundaries.
- Use capability packs to decide what a user wants to enable or customize.
- Use manifests/contracts to decide what is in the standard distribution.
- Use local/private config to decide what is selected in this workspace.

Do not treat a capability pack as live permission or proof. It is a navigation
and maintenance unit only.

## Pack Map

| Pack | User-facing purpose | Main docs | Main implementation surfaces |
| --- | --- | --- | --- |
| Core Body Pack | Run the basic body loop: status, thought, guarded action, feedback | `README.md`, `docs/operate.md`, `docs/architecture.md` | `sword.ps1`, `runtime/`, `contracts/`, `control-plane/` |
| Thought / Chat Pack | Configure LLM-backed or mock thought/chat behavior | `docs/customize.md`, `docs/local-configuration.md` | Thought Core settings, provider/model env values |
| Voice Pack | Speech input, TTS, VOICEVOX, audio readiness | `docs/local-configuration.md`, `docs/operate.md` | `organs/speech-input/`, `organs/expression/tts-service` |
| Avatar / Projection Pack | AITuber Kit, Projection Visual, TouchDesigner display surfaces | `README.md`, `docs/operate.md`, `docs/aituberkit-sword-adapter-inventory.md` | `organs/expression/aituber-kit`, `organs/display/` |
| Home Control Pack | Home Assistant bridge, action rows, preview/dry-run/live proof routes | `docs/home-assistant-setup.md`, `docs/add-home-device.md`, `docs/home-control-action-authoring.md`, `docs/live-home-control-proof.md` | `organs/action/home-assistant-server`, local Home Control config |
| Environment Pack | Environment state, vision snapshot, room-light evidence | `docs/proof-layers.md`, `docs/verification-commands.md` | `organs/environment/` |
| Gesture / Reflex Pack | Sword sign, gesture preview, future approval gesture boundary | `README.md`, `docs/proof-layers.md` | `organs/reflex/mediapipe-sword-sign` |
| Diagnostics Pack | Version, manifests, pins, readiness, doctor, maintenance smoke | `docs/standard-distribution-map.md`, `docs/troubleshooting.md`, `docs/verification-commands.md` | `scripts/validate-manifests.ps1`, `scripts/check-distribution-pins.ps1`, `scripts/doctor-distribution.ps1`, `scripts/test-distribution-maintenance.ps1` |
| Agent Worker Pack | Future Codex/agent repair skills and loop state | `AGENTS.md`, future `docs/agent-skills.md` | `skills/repair-no-live-readiness/`, future `runtime/loop-state/` |

## Choose Your Path

<!-- capability-packs:choose-your-path -->

Use this table instead of starting from internal folders.

| Want | Start here | Then check |
| --- | --- | --- |
| I just want to inspect safely | `.\sword.ps1 status` | `docs/operate.md` |
| I want to verify the install without live actions | `.\sword.ps1 verify` | `docs/standard-distribution-map.md` |
| I want to change AI/model behavior | Thought / Chat Pack | `docs/customize.md`, `docs/local-configuration.md` |
| I want to change voice or avatar behavior | Voice Pack or Avatar / Projection Pack | `docs/customize.md` |
| I want to connect Home Assistant | Home Control Pack | `docs/home-assistant-setup.md` |
| I want to add a home device action | Home Control Pack | `docs/add-home-device.md`, `docs/home-control-action-authoring.md` |
| I want live proof | Home Control Pack plus Proof And Verification plane | `docs/live-home-control-proof.md`, `docs/proof-layers.md` |
| I want to change an organ/module | Module / Organ Architecture plane | `docs/module-usage-index.md` |
| I want an agent to help repair a repeated task | Agent Worker Pack | future `docs/agent-skills.md` |

## Starter Profile Plan

<!-- capability-packs:starter-profile-plan -->

Sword should expose starter profiles gradually. These are product/user journeys,
not proof claims.

| Starter profile | Purpose | Status |
| --- | --- | --- |
| `no-live-display` | Inspect and launch display/runtime surfaces without live providers or devices | first example exists under `examples/starter-profiles/no-live-display/` |
| `voice-avatar` | Confirm voice/avatar flow with explicit local/provider boundaries | planned |
| `home-control-preview` | Connect Home Assistant and exercise catalog/tracking/read-only readiness gates only; not the HA preview endpoint | first example exists under `examples/starter-profiles/home-control-preview/` |
| `home-control-live` | Ticketed live Home Assistant route with restore/stop/proof fields | planned, never default |
| `projection-visual` | Projection Visual / TouchDesigner-focused visual route | planned |
| `developer` | Manifest/contract/organ development and maintenance smoke route | planned |

Do not add all of these to `sword.ps1` at once. First make them documentation
and validation concepts; add front-door commands only when their safety and
reader/enforcement behavior is stable.

## AITuber OnAir Comparison Takeaways

AITuber OnAir is useful as a comparison because its public README makes the
external product surface clear: hosted app, starter app, examples, and modular
packages. Sword should borrow that information architecture, not its risk
model.

What to borrow:

- offer a small number of visible paths before internal implementation detail;
- make package/capability boundaries easy to scan;
- keep model/provider additions synchronized across constants, docs, examples,
  and tests;
- use examples/starter profiles for small entry points.

What not to borrow directly:

- do not make live Home Assistant actions as easy as chat/model selection;
- do not let Settings/UI convenience bypass local/private config boundaries;
- do not expose MCP or agent tools that can mutate physical devices without
  Action Boundary, approval, and proof-layer separation.

Reference:

- AITuber OnAir public repository: https://github.com/shinshin86/aituber-onair

## Maintenance Rules

- Every capability pack must point to one primary how-to or reference doc.
- A pack may span multiple architecture planes, but it must name those planes.
- If a feature cannot be understood without a coordination message, promote the
  durable rule into product docs or mark it intentionally private.
- If an example requires secrets, private Home Assistant IDs, screenshots, logs,
  or media, keep those values out of the tracked example and document the local
  handoff instead.
- Capability pack docs should use stable anchors for tests rather than locking
  long prose sentences.
