# Neural Monitoring Test Plan v0

This plan defines the first end-to-end checks for the Agent OS monitoring
system. The model is nervous-system-like: edge observations flow toward the
center, and center decisions flow back toward organs through explicit
boundaries and feedback checks.

The goal is not to prove every organ feature permanently. The goal is to make
the standard cell observable enough that every organ service, driver, status
projection, topology snapshot, and behavior-critical event can be checked
repeatably.

## Main Flows

| Flow | Direction | Purpose | First pass criteria |
| --- | --- | --- | --- |
| Diagnostic pulse | edge to center | Drivers observe services and capabilities. | `update-diagnostics-status.ps1` writes current status, topology, and only notable events. |
| Metric projection | edge to center | Current confidence/freshness estimates become small metric records. | Topology has `metrics.current[]` records matching `runtime/status-store/metric-records.v0.md`. |
| Topology context | edge to center | Thought Core can read internal and environmental topology as context. | Missing or stale topology degrades context but does not block ticket tagging. |
| Reflex response | edge to expression/input | Autonomic reflex can respond without a conscious turn. | Gesture/reflex evidence reaches the projection visual or input affordance as reflex state. |
| Conscious turn | input to center to output | Thought Core interprets input, decides intent, and emits response/action events. | Manual speech/text turn yields a response event and optional safe action boundary decision. |
| Action feedback | center to edge to center | A home action is checked against observed feedback. | Home Assistant action is routed through allowlist/policy, then environment or vision feedback records match, mismatch, or unknown. |

## Organ Coverage

| Organ service | Driver focus | Required first checks | Deep or manual checks |
| --- | --- | --- | --- |
| `home_assistant_bridge` | action boundary and Home Assistant bridge health | HTTP health, allowlist/catalog presence, safe dry-run or reversible action evidence | Real light on/off plus feedback comparison |
| `environment_state_server` | environment projection | HTTP health, current/indicator state availability, separation of Home Assistant and camera/vision state | Token-protected state query and feedback freshness |
| `mediapipe_camera_hub_stack` | reflex/camera hub | managed process evidence, WebSocket topic freshness when allowed, gesture state current metric | Camera live E2E and replay-image/video gesture regression |
| `vision_snapshot_processor` | slower visual environment estimate | managed process evidence, vision topic dependency, room-light estimate freshness | Snapshot model validation against still images |
| `thought_core_api` | conscious turn kernel | HTTP health, deterministic readiness turn, event output | Multi-turn issue-ticket continuity and feedback loop |
| `thought_core_watcher` | handoff router | managed process evidence, latest handoff/response file freshness | AITuber forwarding and speech delta delivery |
| `aituber_kit` | expression projection | HTTP root/projection visual, VRM asset availability, direct send path | Browser rendering and conversation log behavior |
| `touchdesigner_control_gui` | display runtime status | HTTP health, display status, UDP target projection | TOE expansion/static inspection and real projection evidence |
| `system-house-renderer` | diagnostics viewer/topology view | input schema readable, read-only rendering path | Live auto-refresh viewer and topology drilldown |

## Contract Tests

Run these before claiming the monitoring layer is healthy:

```powershell
.\scripts\validate-manifests.ps1
.\scripts\update-diagnostics-status.ps1 -ManifestOnly -NoJournal
.\scripts\check-neural-monitoring-contract.ps1
```

When the stack is live, run the same checks without `-ManifestOnly`. Use the
default non-disruptive WebSocket process evidence for routine pulses. Use strict
WebSocket checks only as a deep check, because routine strict handshakes can
make browser monitors appear to connect and disconnect.

## Behavior Tests

| Test | Tier | Expected evidence |
| --- | --- | --- |
| Reflex alive | startup/deep | `check-runtime-reflex.ps1` reports the low-level reflex stage without requiring a conscious response. |
| Conscious ready | startup/deep | `check-conscious-readiness.ps1` reports a deterministic Thought Core response. |
| Full organ readiness | startup/deep | `check-organ-readiness.ps1` or launcher status shows all required organ services available or explicitly blocked/degraded. |
| Manual speech/text turn | deep | Event chain has input, interpretation, turn, response, and expression forwarding. |
| Reversible home action | deep/manual | Action boundary emits preview/execute decision; Home Assistant bridge executes or dry-runs; environment/vision feedback is recorded. |
| Gesture reflex route | deep/manual or replay | MediaPipe detects gesture, reflex state is visible, and projection visual/input affordance reacts as autonomic behavior. |
| Metric record validation | standard/snapshot | `check-neural-monitoring-contract.ps1` passes with current metrics in topology. |
| Event journal placement | standard/snapshot | Routine success overwrites current status; only changes, warnings, recoveries, stale transitions, conflict, blocked/degraded, or sampled heartbeat append. |
| Security/data safety | standard/deep | Metric records and journal entries do not embed secrets, raw media, full logs, prompts, or private paths. |

## Feedback Control

Drivers report source-local evidence. The OS evaluates whether enough evidence
was reported and can later send lightweight tuning instructions to drivers.

Initial tuning should adjust event classification by ordered rules rather than
rewriting driver code. Rules may match normalized event text, event type,
service id, driver id, or capability and assign a reporting level. Newer rules
override older rules with the same rule identity. A conflict audit can later
retire stale or frequently shadowed rules during a safe maintenance window.

The monitoring layer should score gaps such as:

- missing required evidence
- stale evidence presented as fresh
- too much routine success noise in the event journal
- insufficient event detail for a degraded, blocked, or feedback-mismatch case
- raw or unsafe payload copied into routine records

## Review Cadence

Integration-main periodically reviews worker outputs before treating them as
accepted. Worker changes should be checked for:

- alignment with metric-record and event-journal placement rules
- no hard startup dependency on topology snapshots
- no action execution in diagnostics drivers
- no raw local logs, media, secrets, or unredacted user content in tracked files
- runnable validation commands or clear manual evidence when hardware is needed
