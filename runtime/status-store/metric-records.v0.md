# Metric Records v0

Metric records are small confidence, freshness, divergence, and feedback
estimates used by status-store, topology snapshots, event journal decisions,
and Thought Core memory/ticket promotion.

This contract is intentionally lightweight. Initial records store numeric
values and context; labels are computed at read time from the current Agent OS
policy/config.

## Initial Record Shape

```json
{
  "metric": "reality_divergence",
  "subject": "capability:lighting.living_room",
  "value": 0.72,
  "recorded_at": "2026-05-29T19:35:20+09:00",
  "stale_after": "2026-05-29T19:35:30+09:00",
  "source": "thought_core",
  "provenance": ["home_assistant", "camera_vision"],
  "basis": "home_assistant_on_but_vision_dark",
  "evidence_refs": ["event:abc123", "snapshot:xyz789"]
}
```

Required fields for v0:

- `metric`: estimate name.
- `subject`: lightweight readable string tag for what the estimate is about.
- `value`: numeric estimate.
- `recorded_at`: timestamp when the value was recorded.
- `source`: component that produced the metric record.

Recommended fields for v0:

- `stale_after`: timestamp when the metric should no longer be treated as fresh.
- `provenance`: source layers or components that contributed to the estimate.
- `basis`: short machine-readable reason.
- `evidence_refs`: typed references to supporting evidence.

## Metric Semantics

Each metric must define numeric direction.

Initial metric names:

- `reality_divergence`: `0.0` means no known divergence, `1.0` means severe
  divergence between internal state and likely real-world state.
- `state_confidence`: `0.0` means low confidence, `1.0` means high confidence
  in the inferred state.
- `feedback_match`: `0.0` means observed effect did not match expectation,
  `1.0` means observed effect matched expectation.
- `source_confidence`: `0.0` means low confidence, `1.0` means high confidence
  in a source-local observation.

Drivers primarily report source-local values such as `source_confidence`,
freshness, and staleness. Thought Core primarily derives system-level values
such as `reality_divergence`, `state_confidence`, and `feedback_match` by
comparing sources, memory, and action feedback.

## Subjects

`subject` starts as a lightweight string tag, not a strict URI or guaranteed
topology node id.

Examples:

- `room:living_room`
- `entity:light.living_room`
- `capability:lighting.living_room`
- `action:turn_on_light`
- `camera:main`
- `view:main.camera_hub`
- `object:remote_control.candidate`

Keep subjects reasonably namespaced and readable. Do not put private local
paths, raw media names, secrets, prompts, or sensitive payloads in `subject`.

Future topology providers may map these tags to explicit topology node IDs.

## Staleness

Staleness is driver-defined.

Drivers may report:

- `stale_after`
- `ttl_ms`
- `freshness`
- equivalent metadata that a collector can convert into `stale_after`

If a driver cannot provide staleness, consumers should treat freshness as
unknown or degraded. Missing staleness never means an observation is fresh
forever.

## Evidence References

`evidence_refs` point to evidence without embedding it.

Initial prefixes:

- `event:...`
- `snapshot:...`
- `turn:...`
- `action:...`

Do not embed raw camera frames, images, generated media, secrets, prompts, long
logs, or large payloads in a metric record.

## Labels

Initial metric records do not store historical labels. Labels such as `low`,
`medium`, `high`, or `unknown` are derived when read from current Agent OS
policy/config.

Recorded-label history is deferred. If audit later requires "what label did the
system see then", add it as a separate retention and audit design slice.

## Placement

Metric records are placed by use:

- `topology snapshot`: current readable state for Thought Core, diagnostics,
  and local consumers.
- `event journal`: decisions and notable events such as degraded execution,
  blocked execution, approval routing, source conflict, or feedback mismatch.
- `Thought Core memory / issue ticket`: repeated problems or long-lived context
  promoted from events and observations.

Do not append every routine metric sample to the event journal. Do not promote
routine current metric values to memory by default.

## Conflict Handling

When sources disagree, keep the observations distinguishable. Do not silently
fuse them into one truth.

Ordinary low-risk capability conflicts may run as `degraded` with stronger
post-action feedback checks. High-risk operations may escalate to confirmation,
approval, or blocked state by policy.
