# Organ Drivers

Organ drivers translate organ-specific implementation details into Agent OS
status, event, topology, and capability evidence.

They are comparable to OS device drivers, but the first contract is read-only:
drivers observe, normalize, and explain. They do not execute home actions,
start or stop processes, delete memory, mutate organ state, or approve work.
Operations belong to system-manager and approval-queue surfaces.

## Why This Exists

Each organ service has different local truth:

- process names, PID files, ports, and health endpoints
- JSONL logs, audit files, event streams, or status files
- service-specific capability semantics
- local hardware or asset requirements
- safety and approval constraints

If the Agent OS core understands every organ implementation directly, the core
becomes brittle. Organ drivers keep that boundary narrow. The core asks a
driver for normalized evidence; the driver knows how to read the current
implementation.

## Driver Outputs

Drivers may produce five read-only output types:

- `topology_observation`: observed services, ports, processes, endpoints,
  local files, and peer relationships.
- `capability_evidence`: evidence used to map a capability to `available`,
  `degraded`, `unavailable`, `blocked`, or `unknown`.
- `metric_record`: source-local confidence, freshness, quality, or staleness
  estimates using `runtime/status-store/metric-records.v0.md`.
- `event_projection`: normalized event summaries derived from module logs or
  event streams.
- `health_evidence`: liveness and health observations with timestamps,
  freshness, and source references.

The first neural-monitoring coverage map for selected services is
[`neural-monitoring-driver-coverage.v0.md`](neural-monitoring-driver-coverage.v0.md).
It lists the status, topology, and capability evidence paths that are ready,
need live verification, or still need implementation.

Every output should include:

- `driver_id`
- `observed_at`
- `tier`
- `source`
- `evidence`
- `freshness`

When evidence is missing or stale, drivers must report that explicitly. They
must not infer `available` from absence of an error.

## Metric Records

Drivers may emit `metric_record` outputs for their own observations. These
records describe the driver's local evidence; they do not decide the whole
system's truth.

Example driver-local metric:

```json
{
  "driver_id": "camera-vision-driver",
  "observed_at": "2026-05-29T10:35:36Z",
  "tier": "standard",
  "source": "camera_vision",
  "metric_record": {
    "metric": "source_confidence",
    "subject": "view:main.camera_hub",
    "value": 0.64,
    "recorded_at": "2026-05-29T10:35:36Z",
    "stale_after": "2026-05-29T10:35:41Z",
    "source": "driver:camera_vision",
    "provenance": ["camera_vision"],
    "basis": "low_light_hand_landmark_quality",
    "evidence_refs": ["event:camera-hub-status-def456"]
  },
  "freshness": "fresh",
  "evidence": ["event:camera-hub-status-def456"]
}
```

The status collector or topology snapshot exporter can place current metric
records under `metrics.current[]` in `.cache/agent-os/status/topology.json`.
Labels are computed from current Agent OS policy/config when read; initial
driver records should store numeric values, freshness, subject, provenance,
basis, and safe evidence references.

## Driver Tiers

Tier names describe cost and freshness, not organ function.

| Tier | Intended Frequency | Purpose |
| --- | --- | --- |
| `instant` | 0.5-2 seconds | Read already materialized values such as timestamps and counters. |
| `light` | 2-5 seconds | Check cheap local state such as known PID, port listen, and status files. |
| `standard` | 5-30 seconds | Run routine health checks such as HTTP health and non-disruptive cached/process evidence for WebSocket services. |
| `snapshot` | 1-5 minutes or event-triggered | Refresh heavier state such as local assets, entity state, and readiness summaries. |
| `deep` | manual, startup, or anomaly-triggered | Run expensive or side-effect-sensitive checks such as strict WebSocket handshakes, full smoke, real hardware E2E, remote verification, and TOE expansion. |

## Driver Classes

Drivers are intentionally composable.

- Generic drivers cover common mechanisms such as process/port observation,
  HTTP health, WebSocket process evidence, strict WebSocket health, JSONL event
  tailing, and Git checkout state.
- Organ drivers compose generic drivers and add organ-specific meaning.
- Legacy adapter drivers can bridge older modules until the module exports a
  native Agent OS status or event outbox.

## Ownership

The Agent OS repository owns the driver contract and initial compatibility
drivers. Individual organ repositories may later provide native driver
metadata such as `agent-os-driver.json`, `agent-os-status.json`, or
`agent-os-events.jsonl`.

The system-manager or status collector decides when to invoke drivers. Drivers
do not schedule themselves.

## Safety Rules

- Default to read-only.
- Never print secret values.
- Never stop unowned processes.
- Never execute real home actions from a diagnostics driver.
- Mark stale or missing evidence as stale or missing.
- Keep operation requests behind approval-queue and system-manager contracts.
