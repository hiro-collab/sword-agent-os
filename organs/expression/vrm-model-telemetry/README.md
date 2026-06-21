# VRM Model Telemetry Organ

This expression organ owns future VRM model-state telemetry collection.

It is intentionally separate from Self Mirror. Self Mirror observes browser
pixels. VRM Model Telemetry reads the selected VRM runtime's model-state
summary, such as expression weights, morph buckets, and safe rig-track buckets.

## Responsibility

The organ should eventually provide a bounded sampler/adapter that:

- receives a selected motion stimulus/profile context from the reviewed runtime
  route;
- reads requested/effective/applied expression channels and safe model-state
  buckets from the selected VRM runtime;
- emits `vrm_model_telemetry_summary.json` that validates against
  `contracts/vrm_model_telemetry/vrm_model_telemetry.v0.schema.json`;
- keeps output summary-only and graph-ready.

The organ should not make Thought Core, diagnostics, or review agents scrape
README prose, private browser state, page stores, module internals, raw logs, or
local generated files.

## Current Status

This directory is a source/docs/contract scaffold. It does not yet contain a
runtime sampler, service, browser route, graph UI, or source adoption claim.

The runtime reader/discovery surface is:

- `runtime/vrm-model-telemetry/vrm-model-telemetry-consumer-routes.json`

## Proof Boundary

VRM Model Telemetry can support claims such as:

- the model received the full-relaxed expression profile;
- the runtime applied expression weights over a bounded sample window;
- a safe face/head/rig-track bucket changed or did not change.

It cannot prove by itself:

- browser-visible Self Mirror pass;
- expression-visible pass;
- semantic smile, joy, or dance correctness;
- physical/projector display proof;
- ROI or threshold authority;
- release/readiness or final RR003 pass.

## Safety Boundary

The organ must keep shared output free of raw media, screenshots, video, audio,
raw model asset names, private paths, browser storage, provider payloads,
transcripts, Home Assistant ids, device values, and tokens.

If a future implementation needs a raw overlay, contact sheet, screenshot,
model asset name, private path, or unbounded per-frame dump, stop and route a
separate review before sharing or adopting that output.
