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
| runtime/status | Launcher-owned processes, endpoints, status fields | User-visible browser behavior unless checked |
| runtime/model telemetry | Summary-only VRM/runtime model-state telemetry shows requested/effective expression weights or safe rig-track buckets changed over time | Browser-visible motion, semantic expression correctness, physical/projector proof, ROI/threshold authority, release/readiness |
| browser/display | Projection Visual, AITuber, or UI reachability | Physical device movement |
| browser-visible avatar motion | Self Mirror reports event-correlated visible motion in expected avatar ROIs for a named scenario | Voice intent, provider response, semantic dance/expression quality, physical projector output |
| Home Assistant preview | Command shape and local safety checks | Device action or HA state change |
| Home Assistant dry-run | Bridge accepts a dry-run execute request | Device action or HA state change |
| Home Assistant execute | Command submitted to the bridge | HA state match, external observation, or physical proof |
| HA state match | Readable Home Assistant state matches expected state | External or physical observation |
| external observation | Separate observation source sees the expected change | Raw media publication or universal device coverage |
| physical/device proof | A bounded, restored physical effect was observed | Broad appliance support beyond the tested target |

Always report command acknowledgement, HA/device state, external observation,
and physical proof as separate rows. For stale or unavailable state, use
last-known/unavailable wording and set `must_revalidate_current_state=true`.

Raw media, raw audio, transcripts, screenshots, provider payloads, secrets,
tokens, entity ids, private URLs, and private paths must stay out of shared
reports.
