# VRM Model Telemetry

VRM Model Telemetry is the runtime module boundary for summary-only readback of
VRM model state. It runs parallel to Self Mirror.

Self Mirror answers:

- did browser pixels move in the expected ROI?

VRM Model Telemetry answers:

- did the selected VRM runtime receive and apply the requested expression,
  profile, morph, or safe rig-track state over time?
- did an explicitly allow-listed VRM bone/basis track, such as `head`,
  `neck`, `spine`, or `body_root`, change relative to a bounded baseline?

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
- optional bone/basis buckets for allow-listed normalized humanoid tracks;
- sample window, sample count, min/max/mean buckets, changed flags, and
  confidence;
- safe correlation ids for stimulus, runtime result, and driver result;
- redaction flags and non-claims.

Use buckets and bounded series. Do not publish raw per-frame dumps by default.

## Bone / Basis Diagnostics

Bone/basis telemetry is an opt-in diagnostic extension of this module, not a
separate proof authority. The public module remains VRM Model Telemetry, while
internal samplers may stay split between expression/profile telemetry and
bone/basis telemetry.

The default recorder state is off. A future runtime route must explicitly
enable capture, provide a bounded track allowlist, and keep shared output
summary-first. The canonical first tracks are:

- `head`
- `neck`
- `spine`
- `body_root`

Use normalized/shared humanoid pose or bone surfaces for shared summaries.
Raw poses, raw bone nodes, full skeleton dumps, BVH export, rest poses, raw
node names, and exact per-frame transforms/quaternions are local-only
diagnostic material unless a later exact review clears a narrower artifact.

Shared bone/basis summaries should include:

- `basis_point_id`, `root_track_id`, and `coordinate_space`;
- `pose_source_kind`, `pose_space_class`, and `bone_access_mode`;
- `sample_phase` / `sample_after_update_class` so readers know the sample was
  taken after model, mixer, or humanoid update;
- unsupported/missing track counts and reasons;
- `capture_enabled`, `capture_mode`, `detail_export_enabled`,
  `export_behavior`, and `shareability_class`.

Detailed time-series output, such as
`vrm_model_telemetry_timeseries.jsonl`, is diagnostic-mode-only and
local-only by default. Do not turn VRM telemetry into an all-bone always-on
recorder.

## Timebase

Shared telemetry uses relative monotonic elapsed time. It must not publish raw
system clocks, browser performance origins, timezone offsets, or private
machine timing details.

For bone/basis diagnostics, the result packet should define:

- `clock_kind: relative_monotonic_elapsed`;
- a canonical `t0_event`, normally the first accepted sample after runtime,
  VRM, scene, track allowlist, and sampler readiness;
- `trigger_at_ms` or `trigger_dispatched_at_ms` in the same elapsed timebase;
- `baseline_kind` and a bounded baseline window;
- `window_map` aligned with Self Mirror-style windows such as `pretrigger`,
  `active`, `release`, optional `late_watch`, and `settle`;
- `sampler_mode`, target/effective cadence, dropped/late sample counts, and a
  bounded `stop_reason`.

The route wrapper owns lease/config/caps/cleanup. A future runtime sampler owns
measurement start/stop. The capture helper may arm, dispatch, and read. The
telemetry builder folds and validates; it should not decide timing by itself.

## Relationship To Self Mirror

Use both layers when needed:

1. VRM Model Telemetry can show model/runtime state changed.
2. Self Mirror can show browser-visible ROI motion.
3. A higher claim needs both packets to be correlated by a separately reviewed
   route.

If telemetry says expression weights changed but Self Mirror says the face/head
ROI stayed static, report that split honestly. Do not promote guard UI,
body-wide motion, or broad avatar motion into face/head expression authority.

If model-state telemetry says a bone/basis track changed but Self Mirror says
the browser-visible authority ROI stayed static, report it as model-state
diagnostic evidence only, for example:

```text
model_active_motion_observed / self_mirror_authority_roi_static_no_pass
```

If expression weights changed but selected bone/basis tracks stayed static,
report:

```text
expression model-state changed / selected bone basis static
```

## Current Status

This module currently has a source/docs/contract surface and a bounded
expression-profile runtime summary builder:

- the result contract exists;
- a source/static example exists;
- the consumer route map exists;
- expression/profile summary output can be validated as
  `vrm_model_telemetry_summary.json`;
- bone/basis runtime sampler implementation is held for a later RR003-02 route.

No bone/basis runtime recorder, graph UI, final RR003 pass, expression-visible
pass, or Self Mirror pass is created by this contract shape.

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
