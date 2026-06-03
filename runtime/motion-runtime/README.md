# Motion Runtime

Motion Runtime is the expression-layer boundary for avatar/body-expression
motion.

It is not Thought Core, not Reflex, and not an appliance/action lane. Thought
Core and Reflex decide why or when a movement should be requested. Motion
Runtime normalizes that request into a stimulus lifecycle, composes safe current
body state through a mixer, sends abstract state to a driver adapter, and
reports safe feedback/status.

## Slice 1 Contracts

RR003 Slice 1 introduces three source/static contracts:

- `contracts/motion_stimulus/motion_stimulus.v0.schema.json`
- `contracts/motion_mixer_snapshot/motion_mixer_snapshot.v0.schema.json`
- `contracts/motion_driver_result/motion_driver_result.v0.schema.json`

These contracts intentionally separate:

- requested motion: what Thought Core, GUI/operator, or Reflex asked for;
- composed motion: what the Motion Mixer can safely express as current body
  state;
- applied motion: what the current driver adapter actually applied, degraded,
  rejected, stopped, or failed safe.

## Action Target Indicators

One RR003 purpose is not only dance or emotion, but visible body-side
indication of what the agent is operating or attending to. For example, while a
home appliance action is previewing, executing, or checking feedback, the avatar
may point, turn its gaze, or shift posture toward the display-safe target.

This is represented as `kind: action_indicator` in `motion_stimulus.v0`. The
stimulus may carry a safe `target_context` such as a topology reference,
display label, action request id, and action phase. It must not carry raw Home
Assistant entity ids, service routes, private URLs, or secrets. The action still
belongs to Thought Core, Action Boundary, and the selected driver; Motion
Runtime only expresses the visible indicator.

Typical uses:

- point or gaze toward the appliance currently being controlled;
- show that an action is waiting for feedback;
- shift from pending-operation indication to result indication;
- degrade safely to gaze, face, or speech-only status when arm/hand motion is
  unavailable.

## Runtime Flow

```text
user / GUI / Thought Core / Reflex
  -> State/Event Ingest
  -> Motion Stimulus
  -> Motion Mixer snapshot
  -> VRM or future driver result
  -> Status Store current projection
  -> Event Journal redacted operational history
  -> Memory Core candidate boundary
  -> Body Schema current self-body summary
```

The first runtime target is expected to be VRM through AITuberKit after later
slices open. Slice 1 does not implement the mixer runtime, AITuberKit bridge,
operator UI, passive display, or visible proof.

## Status Store Keys

Slice 1 reserves these current-state keys:

```text
expression.motion.current
expression.body.current_summary
```

Status Store holds current safe values. Body Schema can read those summaries as
current self-body state. Body Schema v0 is not expanded in Slice 1.

## Source Classes

The first contracts represent:

- `user_command`
- `gui_operator_request`
- `thought_context`
- `reflex_forwarded`

The first runtime representative pass may exercise fewer classes, but the
contract must not be shaped as if only explicit user-commanded dance exists.

## Safety Boundary

Routine contracts, fixtures, status projections, and review outputs must not
contain:

- raw media, frames, audio, screenshots, or video;
- raw prompts, provider requests, provider responses, or transcripts;
- local absolute paths, raw filenames, source URLs, or unreviewed asset ids;
- private endpoints, tokens, entity ids, or secrets;
- full debug logs or unbounded per-frame bone/expression telemetry;
- Home Assistant or appliance action routes for avatar motion.

Use safe ids, short display labels, bounded counters, bucketed telemetry, and
redaction/shareability fields instead.

## Held For Later Slices

Still held until explicit scope opens:

- Motion Mixer implementation.
- AITuberKit / VRM adapter implementation.
- Thought Core runtime routing integration.
- Operator UI or passive motion status implementation.
- No-live VRM representative runtime pass.
- Real camera, mic, display, projector, TouchDesigner, VMC, OSC, UDP, or live
  Home Assistant proof.
- Third-party motion assets or generated captures.
