# AITuberKit Sword Adapter Inventory

Status: source-static inventory

- Adapter version: `0.1.0`
- Patchset id: `sword-aituberkit`
- Patchset version: `0.1.0`
- Upstream: `tegnike/aituber-kit` `v2.43.2`
  (`abe1f7954e6c6ddd8afcc44ccbf9df7d408a4f62`)
- Sword fork pin: `hiro-collab/aituber-kit-sword`
  `experiment/aituber-gesture-voice-bridge`
  `6ac3cc17f13b0c2aa2379095d0c90a068ee85c7f`

This file records how Sword Agent OS treats AITuberKit as an official upstream
release plus a Sword adapter/patchset and Sword-facing contract tests. It is an
inventory and planning surface, not proof that the running review stack is
serving this source.

## Personas

| Persona | Default expectation | Not required by default |
| --- | --- | --- |
| Ordinary runtime user | use the prepared runtime install/start path and simple local configuration notes | `_codex`, `coordination`, `worktrees`, fork comparison, patch scripts, DOM/proof jargon, live hardware checks |
| OS operator / integrator | configure local runtime pieces, `.env.example` rendering, Thought Core endpoint, avatar/display/camera/Home Assistant readiness, bounded sanitized proof | publishing raw captures, raw logs, private paths, `.env` values, or calling optional live checks public proof |
| OS developer / module developer | maintain upstream delta inventory, adapter/patchset versioning, contract tests, exact source slices, and dry-run patch planning after approval | treating developer workspace, patch commands, or coordination outputs as ordinary runtime setup |

## Proof Levels

| Level | Meaning |
| --- | --- |
| `source-static` | manifests, path inventory, static tests, and source-level tests exist |
| `browser-local` | local browser/DOM proof exists with mocked or local-only data |
| `runtime-reflected` | running stack is proven to serve the adopted source |
| `live-pilot` | bounded live pilot proof exists under an explicit scope |

Current proof level: `source-static`. Runtime reflection is not proven.

## Path Classes

### Adapter-Owned

These are Sword-specific surfaces that should remain explicitly versioned as the
Sword adapter/patchset.

| Path | Reason |
| --- | --- |
| `src/pages/projection-visual.tsx` | Sword expression-organ display surface |
| `src/utils/projectionVisualQuery.ts` | query-scoped operator/passive/stage mode parsing |
| `src/components/projectionVisualHud.tsx` | Thought Core, Environment State, HUD rails, update signals |
| `src/components/projectionVisualAssistantBubble.tsx` | projection speech/readability surface |
| `src/components/projectionVisualDisplayStateBridge.tsx` | passive/stage display-state sync |
| `src/features/stores/projectionDisplay.ts` | local bounded display-state store |
| `src/pages/api/projectionDisplayState.ts` | bounded local passive display-state API |
| `src/features/chat/thoughtCoreChat.ts` | client Thought Core stream adapter |
| `src/pages/api/thoughtCoreChat.ts` | local Thought Core proxy and redacted trace behavior |
| `src/utils/localApiSecurity.ts` | local API boundary and token/loopback enforcement |
| `src/utils/serverUrlSecurity.ts` | server URL safety checks |

### Patchset-Owned Until Upstream Extension Exists

These are current upstream-file edits that are harder to isolate without
upstream extension hooks.

| Path | Reason |
| --- | --- |
| `src/features/stores/settings.ts` | Thought Core/system-cell defaults |
| `src/features/constants/settings.ts` | AI service enum surface |
| `src/components/settings/modelProvider/utils/aiServiceConfigs.ts` | settings metadata for Thought Core |
| `src/hooks/useBrowserSpeechRecognition.ts` | projection-specific STT timing and diagnostics |
| `src/styles/globals.css` | current HUD/passive/stage rules before style localization |

### Contract-Test Surfaces

| Surface | Required contract |
| --- | --- |
| `/projection-visual` | route remains the Sword expression-organ surface |
| Projection HUD rails | pending/success/stale/unknown/fallback states stay compact and distinguishable |
| Environment values | freshness, provenance, uncertainty, vision estimates, and action/recheck state are visible where relevant |
| `projectionDisplayState` | JSON shape is bounded and does not carry private prompts, raw provider payloads, local paths, or raw media |
| Display-state bridge | mocked updates can reflect without live media or appliance actions |
| Thought Core endpoint | configured local Thought Core endpoint is normal path; unavailable is distinct from completed |
| Dify compatibility | legacy Dify compatibility text remains developer/debug-only in the normal HUD |
| Vision Light/update signal | update indication represents meaningful evidence, not constant ambient animation |
| Passive mode | current bridge is bounded state/message sync, not same-produced-video-output parity |

## First Implementation Slices

Preferred order:

1. manifest metadata and validation;
2. this adapter inventory;
3. dry-run prepare planner;
4. static contract-test rows;
5. pure helper extraction, starting with query/update-signal normalization;
6. API contract lock for `projectionDisplayState` and `thoughtCoreChat`;
7. runtime reflection proof after source adoption.

Do not introduce dependency or lockfile changes, broad HUD rewrites, Thought Core
proxy rewrites, live checks, or patch-script apply mode as part of the first
slice.

## Safety Boundary

Do not publish `.env` values, raw media, raw logs, provider payloads, raw
captures, private paths, `.toe` files, or local runtime artifacts. Do not use
`git reset`, `git clean`, amend, force operations, broad staging, broad
cleanup, or broad `coordination/shared` pushes for this lane.
