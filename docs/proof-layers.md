# Proof Layers

Use these labels in install, readiness, runtime, and review returns. A lower
layer can support a higher one, but it does not replace it.

| Layer | Proves | Does not prove |
| --- | --- | --- |
| source/static | Files, manifests, parser behavior, command previews | Runtime process health |
| install/env-render | Clone, dependency plan, generated env/config presence | Runtime service behavior |
| manifest/pin | Parent manifests and nested checkout commits | Public release readiness by itself |
| readiness/no-live | Local setup classes, expected skips, mock/no-live adapter state | Live devices, provider calls, browser proof |
| local-media preparation | Redacted media index and asset readiness | Gesture/STT correctness or raw media evidence |
| local-media replay | Bounded fixture replay through a named helper | Live camera, live microphone, physical environment |
| recognizer/STT result | A named recognizer produced result/final/content-match classes for an input source | User intent, Thought Core turn materialization, assistant response, or command authority |
| input gate | A recognized or typed candidate was accepted, held, or rejected for source/provenance/contract reasons | Meaning, intent, response quality, or downstream action proof |
| Thought Core turn | Accepted user input materialized as a Thought Core turn | Bubble/TTS parity, user-heard audio, device action, or physical proof |
| assistant response | Thought Core / Soft Core produced response content | That every output surface displayed or spoke the same content |
| bubble/TTS parity | Bubble text and TTS provider input are derived from the same Thought Core / Soft Core response authority | User-heard audio, recognizer accuracy, or semantic response quality |
| runtime/status | Launcher-owned processes, endpoints, status fields | User-visible browser behavior unless checked |
| runtime/model telemetry | Summary-only VRM/runtime model-state telemetry shows requested/effective expression weights or safe rig-track buckets changed over time | Browser-visible motion, semantic expression correctness, physical/projector proof, ROI/threshold authority, release/readiness |
| browser/display | Projection Visual, AITuber, or UI reachability | Physical device movement |
| Projection Visual output surface | Human-visible avatar, HUD, bubble, and state/intention surface is reachable or observed | Thought Core correctness, user intent, or physical projector proof |
| browser-visible avatar motion | Self Mirror reports event-correlated visible motion in expected avatar ROIs for a named scenario | Voice intent, provider response, semantic dance/expression quality, physical projector output |
| Home Assistant preview | Command shape and local request checks | Device action or HA state change |
| Home Assistant dry-run | Bridge accepts a dry-run execute request | Device action or HA state change |
| Home Assistant execute | Command submitted to the bridge | HA state match, external observation, or physical proof |
| HA state match | Readable Home Assistant state matches expected state | External or physical observation |
| external observation | Separate observation source sees the expected change | Raw media publication or universal device coverage |
| physical/device proof | A bounded, restored physical effect was observed | Broad appliance support beyond the tested target |

Always report command acknowledgement, HA/device state, external observation,
and physical proof as separate rows. For stale or unavailable state, use
last-known/unavailable wording and set `must_revalidate_current_state=true`.

Whole-loop conversation claims must keep recognizer/STT, input gate, Thought
Core turn, assistant response, bubble/TTS parity, Self Mirror or Projection
Visual observation, feedback/state handling, and final/readiness claims as
separate rows. Positive lower-layer evidence supports the next layer; it does
not silently become it.

Raw media, raw audio, transcripts, screenshots, provider payloads, secrets,
tokens, entity ids, private URLs, and private paths must stay out of shared
reports.
