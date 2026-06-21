# VRM Model Telemetry

VRM Model Telemetry is the runtime module boundary for summary-only readback of
VRM model state. It runs parallel to Self Mirror.

Self Mirror answers:

- did browser pixels move in the expected ROI?

VRM Model Telemetry answers:

- did the selected VRM runtime receive and apply the requested expression,
  profile, morph, or safe rig-track state over time?

Those are different proof layers. A telemetry packet can explain why a subtle
expression might be hard to see in Self Mirror, but it is not a Self Mirror
pass, not an expression-visible pass, not semantic expression correctness, and
not physical/projector proof.

## Reader Surface

System readers should start from:

- `runtime/vrm-model-telemetry/vrm-model-telemetry-consumer-routes.json`

That file points to the result contract:

- `contracts/vrm_model_telemetry/vrm_model_telemetry.v0.schema.json`

The expected authority result packet is:

- `vrm_model_telemetry_summary.json`

The route map is discovery and interpretation only. It is not command
authority, not runtime execution authorization, not ROI/threshold authority,
and not a route runner.

## Organ Boundary

The concrete expression organ scaffold lives at:

- `organs/expression/vrm-model-telemetry/README.md`

Future sampler or adapter code should stay behind that organ boundary and emit
the contracted summary packet. It should not require Thought Core, diagnostics,
or review agents to reach into private page, module, store, browser, or driver
internals.

## Graph-Ready Shape

Telemetry should be small enough to share and easy to graph:

- requested/effective/applied/dropped expression profile refs and channels;
- decimated time buckets for expression weights or morph/rig-track buckets;
- sample window, sample count, min/max/mean buckets, changed flags, and
  confidence;
- safe correlation ids for stimulus, runtime result, and driver result;
- redaction flags and non-claims.

Use buckets and bounded series. Do not publish raw per-frame dumps by default.

## Relationship To Self Mirror

Use both layers when needed:

1. VRM Model Telemetry can show model/runtime state changed.
2. Self Mirror can show browser-visible ROI motion.
3. A higher claim needs both packets to be correlated by a separately reviewed
   route.

If telemetry says expression weights changed but Self Mirror says the face/head
ROI stayed static, report that split honestly. Do not promote guard UI,
body-wide motion, or broad avatar motion into face/head expression authority.

## Current Status

This module is currently a source/docs/contract scaffold:

- the result contract exists;
- a source/static example exists;
- the consumer route map exists;
- runtime sampler implementation is held for a later RR003-02 route.

No runtime/browser execution, graph UI, source adoption, or final RR003 pass is
created by this scaffold.

## Safety Boundary

Routine telemetry outputs must not contain:

- raw screenshots, video, audio, browser frames, or media;
- raw model asset names, private paths, browser storage, or local absolute
  paths;
- provider prompts, responses, payloads, transcripts, or keys;
- Home Assistant entity ids, service routes, device values, or tokens;
- unbounded raw per-frame model dumps.

Telemetry must not mutate ROI, thresholds, driver commands, selected profiles,
or runtime behavior by itself.
