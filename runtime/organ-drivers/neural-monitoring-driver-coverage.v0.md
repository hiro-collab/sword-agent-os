# Neural Monitoring Driver Coverage v0

This note maps the edge/driver side of the first neural monitoring plan. It is
about safe evidence paths, not live action execution.

Related contract:

- `runtime/diagnostic-scheduler/neural-monitoring-test-plan.v0.md`
- `runtime/status-store/metric-records.v0.md`
- `manifests/drivers/standard.json`

## Coverage Summary

| Service or view | Status evidence | Topology evidence | Capability evidence | Current gap |
| --- | --- | --- | --- | --- |
| `home_assistant_bridge` | HTTP `/health` through the bridge. | Bridge endpoint, Home Assistant base URL as redacted/summary metadata, allowlisted action catalog. | `home_action`: bridge health, action catalog present, approval requirement known. | Real Home Assistant URL/token and reversible light action still need live/user-approved verification. Diagnostics must not execute actions. |
| `environment_state_server` | HTTP `/ready` and display-safe `/indicators/current`; tokened state only at snapshot/deep tier. | Environment current-state endpoint, source layers for Home Assistant and camera/vision observations. | `environment_state`: ready/indicator state plus feedback freshness. | Tokened richer environment state and feedback freshness need live-stack verification. |
| `mediapipe_camera_hub_stack` | Managed process evidence and WebSocket process evidence for routine checks; strict topic sample only at deep tier. | Camera Hub WebSocket endpoint, RTSP/MediaMTX path, video source mode. | `camera_reflex`, `gesture_state`: camera status and sword-sign topic summaries. | Real camera and strict WebSocket topic checks remain live/deep. Replay can cover synthetic evidence without committing media. |
| `vision_snapshot_processor` | Managed process/WebSocket evidence and latest room-light topic freshness. | Vision endpoint plus dependency on camera/reflex topic. | `vision_snapshot`, `room_light_estimate`: latest room-light estimate metadata and freshness. | Real room-light model validation and RTSP/camera input remain live/deep. |
| `thought_core_api` | HTTP `/health`; deterministic readiness turn belongs to startup/deep checks. | Thought Core API endpoint and turn-processing boundary. | `minimum_turn_processing`, `turn_routing`: health plus readiness-turn/event evidence. | Full conscious turn and issue-ticket/memory loop are center/E2E work, not driver-only proof. |
| `thought_core_watcher` | Managed process evidence and latest handoff/response file freshness. | Watcher handoff path and AITuber forwarding route. | `expression_forwarding`: watcher completed turn and AITuber forward evidence when checked. | Real forwarding and speech delta delivery need live/E2E validation. |
| `aituber_kit` | HTTP root/projection visual reachability; avoid draining queue endpoints in routine checks. | AITuber endpoint, direct-send API, Thought Core chat API, VRM asset availability as filename/boolean only. | `expression_projection`, `conversation_log_projection`: page reachability and non-sensitive trace/log counts. | A non-draining status/queue-count endpoint would improve routine diagnostics. Browser rendering remains deep/live. |
| `touchdesigner_control_gui` | HTTP `/api/status` from Display Runtime GUI; HTTP root is shallow. | GUI endpoint, UDP target, TOE project identity as summary metadata. | `display_projection`, `touchdesigner_udp_projection`: GUI status and static TOE/project evidence. | Real projection, projector/display output, and UDP behavior remain live/deep. Diagnostics must not fire test UDP from routine checks. |
| `system-house-renderer` | Short-lived CLI status when invoked; no long-running service. | Input schema, topology snapshot/view output, renderer CLI availability. | `diagnostics_view`, `topology_rendering`: CLI import/test readiness and viewer input readability. | Snapshot exporter implementation is still future work; current docs define `metrics.current[]` placement. |

## MediaPipe Replay Evidence

`hand_movie.mp4` and generated replay frames are local-only test inputs. They
must not be committed or copied into routine status, topology, event-journal, or
metric records.

Safe replay evidence may include:

- filename-only source labels such as `local-file:hand_movie.mp4`;
- counts, frame totals, timestamps, and gesture-state summaries;
- local fixture manifest ids or stable observation ids;
- typed evidence refs such as `event:camera-hub-replay-smoke` or
  `snapshot:mediapipe-replay-hand_movie`;
- metric records such as `source_confidence` with subject
  `view:camera_hub.replay`.

Unsafe replay evidence:

- absolute local video paths;
- raw frames, images, or binary video data;
- raw camera URLs with tokens;
- large logs or unredacted payload bodies.

## Projection Visual Routing

Projection Visual is an expression/display context surface, not a user-agency
source by itself.

Routing model:

- Environment State provides environment context and indicators.
- MediaPipe/Camera Hub provides reflex state such as gesture or sword-sign
  state.
- Thought Core or watcher output provides conscious turn/response context.
- AITuberKit and Display Runtime project the resulting expression/display
  context.

Gesture-triggered microphone activation is system-autonomic/reflex behavior. It
should be represented as reflex/input affordance evidence, not as a user intent
or user approval. Any later user action or home-control command must still pass
through the normal Thought Core, action-boundary, and approval policy surfaces.

## Driver Coverage Gaps

Ready enough for structural monitoring:

- service and capability ids are declared in manifests;
- generic status and capability projections are present;
- `metrics.current[]` is present in topology snapshots;
- metric records use small typed evidence refs and safe subject strings.

Needs live hardware or user-approved verification:

- real Home Assistant light action and feedback comparison;
- live camera stream and strict Camera Hub topic sample;
- vision snapshot validation against real room/light conditions;
- browser AITuber rendering;
- TouchDesigner projection and UDP output.

Needs implementation:

- richer native readers for selected drivers beyond generic liveness;
- topology snapshot exporter that intentionally owns `metrics.current[]`;
- non-draining AITuber status/queue-count endpoint for routine diagnostics;
- explicit storage/evidence locations for deep replay summaries.
