# Communication Fuzzing

Communication fuzzing checks whether organ boundaries reject malformed,
unexpected, oversized, unauthorized, or hostile-looking messages without
crashing or crossing authority boundaries.

This is separate from routine diagnostics. Routine diagnostics should remain
cheap and non-disruptive; fuzzing belongs to manual, startup, deep, or
anomaly-triggered checks.

## Boundary Classes

| Class | Examples | Default fuzz mode |
| --- | --- | --- |
| HTTP read/status | `/health`, `/api/status`, `/indicators/current` | Safe live |
| HTTP validation | `/api/messages`, `/api/thoughtCoreChat`, `/turn` malformed bodies | Safe live when payloads cannot trigger actions |
| Auth-gated observation | `/environment/current`, feedback summary | Unauthorized and bad-token checks by default; authorized checks require a token supplied at runtime |
| Action boundary | home action preview/execute | Dry-run or mocked only; real execution requires explicit side-effect permission |
| WebSocket sensor links | MediaPipe camera hub, vision snapshot | Strict handshakes and malformed frame tests only in deep mode; avoid routine reconnect churn |
| UDP display link | TouchDesigner UDP trigger | Disabled by default; enable only with explicit display side-effect permission |
| Browser/rendering | Projection Visual passive/operator pages | Browser smoke and screenshot checks, not protocol fuzzing |

## Current Runner

The first runner is:

```powershell
.\scripts\run-communication-fuzz.ps1 -PortMode isolated_override
```

It performs only safe live HTTP checks:

- malformed or missing request bodies
- invalid query values
- invalid `clientId` and message queue payload shapes
- non-loopback or untrusted `Origin` headers
- disallowed HTTP methods
- path traversal-like static file requests
- unauthorized access to protected APIs
- oversized Thought Core request body rejection
- safe queue sequence checks for AITuberKit using a unique synthetic
  `clientId`: POST one message, GET once, and confirm a second GET is empty

It does not:

- execute Home Assistant actions
- send TouchDesigner UDP packets
- open repeated WebSocket handshakes
- capture camera frames
- store raw prompts, images, audio, tokens, or response bodies in tracked files
- store raw exception messages in reports; blocked cases should keep only
  redacted error classes or capped sanitized summaries

Reports are written under:

```text
.cache/agent-os/fuzz/
```

## Expansion Plan

1. Add offline property tests near each module:
   - AITuberKit API handlers: message queue, Thought Core proxy, local API security.
   - Environment State Server: query parser, feedback payload validation, relation update validation.
   - Home Control Bridge: Pydantic request validation, dry-run semantics, idempotency.
   - Thought Core API: request body parsing, SSE malformed downstream events.

2. Add schema-based corpus generation:
   - Generate valid baseline payloads from contract schemas.
   - Mutate one field at a time: type flip, missing required field, null, empty string, overlong string, unknown enum, nested object, array, Unicode, control chars.
   - Validate expected status class and that errors remain structured.

3. Add sequence fuzzing:
   - POST/GET ordering for AITuberKit queues is covered by the safe live
     runner with a unique synthetic `clientId`.
   - Duplicate `request_id` for action dry-runs.
   - Repeated feedback idempotency keys.
   - Slow or failed Thought Core downstream responses.

4. Add deep-gated transport fuzzing:
   - WebSocket malformed topic envelopes against in-process parsers first.
   - Strict live WebSocket checks only when explicitly requested.
   - UDP payload shape checks against a fake receiver before TouchDesigner.

5. Add invariants:
   - No 5xx for invalid client input unless dependency is down.
   - No raw secret, token, prompt, image, or audio in diagnostic output.
   - No action execution unless the test mode explicitly allows side effects.
   - No persistent queue or feedback pollution after a fuzz run, or record it as a known mutation.
