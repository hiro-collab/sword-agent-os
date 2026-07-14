# Body Schema

Body Schema is the current self-body model generated from Body Plan, Status
Store, and selected summarized evidence.

It is not the static body configuration and it is not raw runtime history.

## Inputs

- Body Plan: static organism/body/organ structure.
- Status Store: current normalized state.
- Summarized diagnostics or topology snapshots when available.

## Outputs

- Current organ presence and health.
- Current confidence/freshness labels.
- Current body connectivity as understood by the OS.
- Compact body-state records for Body Display Projection and diagnostics.

## Current v0 Builder

The initial builder is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-body-schema-snapshot.ps1 -Check
```

It reads `manifests/body-plans/system-cell-v0.json`,
`manifests/driver-manifests/system-cell-v0.json`, compatibility aliases, and the
current diagnostics status when present. It writes generated local snapshots
under `.cache/agent-os/body-schema/` and `.cache/agent-os/body-display-projection/`.
The Body Schema snapshot payload follows
`contracts/body_schema_snapshot/body_schema_snapshot.v0.schema.json`.
`status_source` uses a logical source id such as `status-store.current`; it must
not retain local filesystem paths.

Use `-NoWrite` for read-only validation in test packs.

## Boundaries

- Do not reconstruct current state by replaying Event Journal on every read.
- Do not store raw camera frames, raw prompts, raw audio, or secret-bearing
  payloads.
- Do not retain local filesystem paths in generated snapshots.
- Do not own action decisions or reflex rules.

## RR003 Motion Current Summary

For RR003, Body Schema should read safe current motion/body summaries from
Status Store, not raw Event Journal replay. The expected current projection
source is:

```text
expression.body.current_summary
```

Useful fields include available tracks, occupied tracks, degraded tracks,
unavailable tracks, active body scope, current pose summary, stop/reset state,
compatibility summary, freshness/staleness timestamps, and a logical status
source such as `status-store.current`. Raw motion assets, local paths, raw
media, prompts, transcripts, provider payloads, and full logs remain outside
Body Schema snapshots.

## Hearing Organ Current State

When Status Store contains one current, canonical
`sense.hearing.primary.input_gate.body_state` row, Body Schema may attach its
fixed `input_gate_body_state.v0` projection to the hearing organ. It copies the
owner classes and their logical status-source metadata without recomputing
them.

The InputGate remains the only owner of `self-speaking`, `input-receivable`,
and `ambiguity-held`. Body Schema does not inspect AEC, VAD, PCM, transcripts,
candidate/session identifiers, lifecycle transport, or caller claims. It does
not accept a candidate, mint a capability, materialize TurnInput, or upgrade a
process observation to user-heard proof. Stale, duplicated, malformed,
wrong-organ, wrong-driver, or private-bearing rows are not projected.
