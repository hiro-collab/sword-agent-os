# Legacy Reference Index

Legacy sources are reference only. They can reveal missing requirements, but
they are not authoritative until current Agent OS files adopt them.

## Current Reference Root

```text
C:\Users\kawai\works\sword-agent-system
```

## High-Value Sources

| Topic | Legacy source | Use in Agent OS |
| --- | --- | --- |
| Control-plane feature inventory | `sword-control-plane/README.md`, `ops/README.md`, `ops/manifests/README.md`, `tools/home-control-launcher/README.md` | Build runtime/control-plane inventory before implementation. |
| Service and adapter boundaries | `sword-control-plane/docs/service-boundary-map.md`, `docs/component-map.md`, `docs/module-responsibilities.md`, `docs/decisions/0001-0004*.md` | Seed service manifests and organ placement; verify against current code. |
| State authority | `sword-control-plane/docs/state_authority.md`, `docs/decisions/0005-memory-state-policy-boundaries.md` | Seed `manifests/authorities/standard.json` and data-safety policy. |
| Runtime layout | `sword-control-plane/docs/runtime-layout.md`, `docs/logging-conventions.md` | Seed status-store, event-journal, retention, and local-sensitive rules. |
| Security and access | `sword-control-plane/policies/access/`, `contracts/access-control/`, `src/sword_voice_agent/adapters/auth.py`, `system/event_journal.py`, `adapters/console_status.py` | Seed security/data-safety inventory; code and tests are evidence. |
| Thought Core turn path | `sword-control-plane/services/thought-core/README.md`, `src/sword_voice_agent/apps/watch_handoff_to_thought_core.py`, related tests | Seed turn-router inventory and expression connection tasks. |
| Expression surfaces | `contracts/expression/README.md`, `organs/expression/tts-service/README.md`, `organs/expression/aituber-kit/docs/security-notes.md`, AITuber `src/pages/api/messages.ts`, `src/pages/api/thoughtCoreChat.ts`, `src/components/projectionVisualHud.tsx` | Split speech-output, presentation, and runtime adapter responsibilities. |
| Display projection | `organs/display/touchdesigner-ai-controller/README.md`, `tools/server.js` | Seed display/projection contract and local/remote access policy. |
| Environment state | `organs/environment/environment-state-server/README.md`, `organs/environment/vision-snapshot-processor/README.md` | Seed environment authority and indicators connection. |
| Action bridge | `organs/action/home-assistant-server/docs/security-notes.md`, `docs/integration-contract.md`, source/tests | Seed action authority, confirmation, idempotency, and token handling rules. |
| Reflex attention gate | `organs/reflex/mediapipe-sword-sign/README.md`, `docs/integration-contract.md`, source/tests | Seed reflex attention-gate connection and user-response urgency rules. |
| Diagnostics | `organs/diagnostics/system-house-renderer/README.md`, sanitizer/tests | Seed diagnostics organ and redaction behavior. |

## Reference Rules

- Prefer current code and tests over old docs.
- Treat archives and retired-path docs as missing-topic detectors only.
- Do not import Dify compatibility, `full-local`, or `thought-core-experimental`
  as standard Agent OS behavior without a new decision.
- `avatar-service` is reference only unless an expression runtime replacement
  decision reintroduces it.
- Any adopted rule should point to its evidence and target file.

