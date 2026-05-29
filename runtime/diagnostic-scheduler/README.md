# Diagnostic Scheduler

Diagnostic scheduler owns the timing of routine Agent OS observation pulses.
It decides when to ask organ drivers for evidence; organ drivers do not
schedule themselves.

The first contract is read-only. Scheduler pulses must not execute home
actions, start or stop organ services, delete memory, approve work, or mutate
organ state. Those operations belong to system-manager, approval-queue, and
organ-specific control surfaces.

## Pulse Tiers

Tier names describe cost and freshness, not organ function.

| Tier | Initial Interval | Expected Work |
| --- | ---: | --- |
| `instant` | 1 second | Read already materialized counters, timestamps, and driver cache. |
| `light` | 3 seconds | Check cheap local state such as known PID, port, and status files. |
| `standard` | 15 seconds | Probe routine HTTP health endpoints and use non-disruptive cached/process evidence for WebSocket services. |
| `snapshot` | 3 minutes | Refresh heavier state such as topology, assets, entity summaries, and readiness summaries. |
| `deep` | manual, startup, or anomaly-triggered | Run expensive checks such as strict WebSocket handshakes, real hardware E2E, full smoke, remote verification, and TOE expansion. |

## Storage Shape

Routine pulses update `status-store` as latest state. They append to
`event-journal` only when something changes, degrades, recovers, becomes stale,
or reaches a sampled heartbeat boundary.

Heavy details belong in evidence storage with a reference from the normalized
observation. Camera frames, raw images, full module logs, and generated media
must not be copied into the routine diagnostics journal.

## First Implementation

The first implementation is a run-once collector:

```powershell
.\scripts\update-diagnostics-status.ps1
.\scripts\read-diagnostics-status.ps1
.\scripts\watch-diagnostics-status.ps1
```

It reads the diagnostic policy, driver manifest, and service inventory, then
writes:

- `.cache/agent-os/status/current.json`
- `.cache/agent-os/status/topology.json`
- `.cache/agent-os/events/events-YYYY-MM-DD.jsonl`

The run-once shape is intentional. It lets Agent OS stabilize the normalized
output before turning the scheduler into a long-running pulse loop.

`watch-diagnostics-status.ps1` is the first lightweight pulse loop. It repeats
the same collector at a fixed interval for local validation and diagnostics
viewer work. Its default WebSocket probe mode is process evidence so frequent
pulses do not make browser monitors or Camera Hub clients appear to connect and
disconnect. Use `-WebSocketProbeMode strict` for an explicit handshake check.
It is still read-only and should be replaced later by a native system-manager
scheduler.

## Initial Retention

- `status-store/current`: overwrite latest state.
- `event-journal`: keep 30 days, rotate daily, compress rotated files.
- `snapshots`: keep 7 days, compact old snapshots when implemented.
- `evidence/deep logs`: keep 30 days or 5 GB, whichever limit is reached first.
