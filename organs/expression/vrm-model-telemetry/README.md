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
- optionally reads allow-listed normalized humanoid bone/basis tracks such as
  `head`, `neck`, `spine`, and `body_root` for diagnostic model-state timing;
- emits `vrm_model_telemetry_summary.json` that validates against
  `contracts/vrm_model_telemetry/vrm_model_telemetry.v0.schema.json`;
- keeps output summary-only and graph-ready.

The organ should not make Thought Core, diagnostics, or review agents scrape
README prose, private browser state, page stores, module internals, raw logs, or
local generated files.

## Current Status

This directory is a source/docs/contract scaffold. It does not yet contain a
bone/basis runtime sampler, service, browser route, graph UI, or source
adoption claim.

The runtime reader/discovery surface is:

- `runtime/vrm-model-telemetry/vrm-model-telemetry-consumer-routes.json`

## Future Bone / Basis Sampler

A future implementation should keep the bone/basis recorder opt-in and off by
default. It should use canonical allow-listed tracks first:

- `head`
- `neck`
- `spine`
- `body_root`

The sampler should use relative monotonic elapsed time, capture after model /
mixer / humanoid update, and emit bounded summaries with `basis_point_id`,
`pose_space_class`, `sample_phase`, `target_fps`, `stop_reason`, and dropped
sample counts. Detailed raw transforms, quaternions, raw poses, BVH exports,
full skeleton dumps, rest poses, raw node names, and model asset names are
local-only unless a later exact review permits a narrower artifact.

## Proof Boundary

VRM Model Telemetry can support claims such as:

- the model received the full-relaxed expression profile;
- the runtime applied expression weights over a bounded sample window;
- a safe face/head/rig-track bucket changed or did not change.
- an allow-listed bone/basis track changed relative to a bounded baseline.

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
