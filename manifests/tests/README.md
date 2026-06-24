# Test Layout Policy

This directory is the index for Agent OS test placement. It explains where a
test belongs before adding or moving files.

## Placement Rules

| Test or evidence type | Canonical location | Notes |
| --- | --- | --- |
| Module-internal unit and contract tests | Beside that module, usually `tests/` for Python or framework-native `__tests__/` for TypeScript/React | These tests may know module internals and should be owned by the module. |
| Cross-module or black-box capability checks | `manifests/tests/organ-test-packs/*.json` | These declare what capability is checked without embedding organ internals in the OS core. |
| Shared runners and local check commands | `scripts/` | Runners execute manifests, readiness checks, smoke checks, or bounded proof helpers. |
| Runtime-generated outputs and evidence | `.cache/agent-os/...`, `test-runs/...`, or private coordination task outputs | Do not write generated proof output into source modules unless it is an intentional checked-in fixture. |
| Review packets and coordination evidence | Workspace-level `coordination/shared/task-outputs/...` | These are not product source and should not be treated as module tests. |

Tracked manifests and docs must not contain private paths, raw media, secrets,
tokens, entity ids, raw logs, raw transcripts, raw screenshots, or local
environment values.

## Runtime, Organs, And Services

Use these terms consistently:

| Term | Meaning | Example |
| --- | --- | --- |
| `runtime/` | Agent OS substrate responsibilities and authorities used by ordinary operation: memory, event journal, status, process registry, routers, action boundary, action catalog, organ drivers, organ test packs | `runtime/memory-core/`, `runtime/event-journal/`, `runtime/action-boundary/` |
| `organs/` | Concrete capability modules or external organs. Many are runnable servers/apps, but their primary category is capability responsibility | `organs/action/home-assistant-server/`, `organs/environment/vision-snapshot-processor/`, `organs/expression/aituber-kit/` |
| `services` | Execution/process shape: an independently launched server, worker, UI, bridge, or adapter. A service can live under `organs/` or `control-plane/`; do not add a top-level `services/` directory just to satisfy the name | Thought Core under `control-plane/sword-voice-agent/services/thought-core`; Home Control bridge under `organs/action/home-assistant-server/` |
| `manifests/services/` | Data describing selected runnable/observable services for a profile | `manifests/services/thought-core-v0-compat.json` |

Therefore, an organ can be a service, but not every service lives under a
directory named `services/`. `organ` is a role/module category; `service` is how
something runs. Memory Core and Event Journal are runtime substrate authorities,
not ordinary organs, even if a later implementation runs them as managed
processes.

See also:

- `docs/module-usage-index.md`
- `manifests/services/README.md`
- `runtime/README.md`
- `organs/README.md`

## Current Test Location Inventory

| Path | Owner / module | Classification |
| --- | --- | --- |
| `control-plane/sword-voice-agent/tests/` | Control plane / Thought Core | Module-local Python tests. Keep Thought Core trace/candidate helper tests here unless the Thought Core service test root is intentionally moved. |
| `manifests/tests/` | Agent OS manifests | Cross-module test manifest index and organ test pack declarations. |
| `manifests/tests/organ-test-packs/standard.json` | Agent OS manifests / Test-QA / integration | Standard black-box organ capability pack. |
| `organs/action/home-assistant-server/tests/` | Home Control action organ | Module-local bridge/config/API tests. |
| `organs/diagnostics/system-house-renderer/tests/` | Diagnostics organ | Module-local diagnostic/topology tests. |
| `organs/display/touchdesigner-ai-controller/tests/` | Display runtime organ | Module-local display bridge tests. |
| `organs/environment/environment-state-server/tests/` | Environment State organ | Module-local environment state tests. |
| `organs/environment/vision-snapshot-processor/tests/` | Vision Snapshot Processor organ | Module-local vision/light tests. |
| `organs/expression/aituber-kit/src/__tests__/` | AITuberKit / Projection Visual | Framework-native source tests. |
| `organs/expression/aituber-kit/src/features/motionRuntime/__tests__/` | AITuberKit motion runtime feature | Framework-native feature tests. |
| `organs/expression/aituber-kit/src/features/vrmViewer/__tests__/` | AITuberKit VRM viewer feature | Framework-native feature tests. |
| `organs/expression/tts-service/tests/` | TTS expression organ | Module-local TTS tests. |
| `organs/reflex/mediapipe-sword-sign/tests/` | Camera/Gesture reflex organ | Module-local camera/gesture tests. |
| `organs/speech-input/ai-talk-core/smoke_test.py` | Speech input organ | Module-local smoke script. Accept as existing style; if this organ becomes project-owned, consider wrapping or moving under a local `tests/` directory. |
| `organs/voice/ai-talk-core/smoke_test.py` | Voice/input legacy organ | Module-local smoke script. Accept as existing style; if this organ becomes project-owned, consider wrapping or moving under a local `tests/` directory. |

Raw filesystem searches may also find tests under `.venv`, `.uv-cache`,
`.cache`, `node_modules`, or other generated dependency trees. Those are not
Agent OS source tests and should be excluded from layout audits.

## Current Shared Runner Inventory

Shared runners live under `scripts/`. Do not move them into
`manifests/tests/`; manifests are data, while scripts execute checks.

| Runner | Role |
| --- | --- |
| `scripts/run-organ-test-packs.ps1` | Executes `manifests/tests/organ-test-packs/*.json` packs. |
| `scripts/run-full-install-verification.ps1` | Full install/readiness verification wrapper. |
| `scripts/check-launch-readiness.ps1` | Launch readiness and local config preflight. |
| `scripts/check-ui-review-route-readiness.ps1` | UI/review route readiness check. |
| `scripts/check-voicevox-readiness.ps1` | VOICEVOX ready/absent/start/skip helper. |
| `scripts/validate-manifests.ps1` | Manifest validation. |
| `scripts/test-distribution-maintenance.ps1` | Distribution maintenance smoke/check script. |
| `scripts/check-distribution-pins.ps1` | Pin and nested checkout consistency check. |
| `scripts/show-version.ps1` | Version/profile summary. |
| `scripts/install-distribution.ps1` | Distribution install/dry-run path. |
| `scripts/render-env-files.ps1` | Render local env/config into module locations. |
| `scripts/prepare-local-media-index.ps1` | Prepare local media index inputs without committing raw media. |

Scoped helpers such as local-media, Home Control, Self Mirror, Environment
State, screenshot/UI, doctor/troubleshooting, and
organ-contract/status scripts may also live under `scripts/`, but they should
not be presented as the main fresh-install or service-mode entrypoint unless a
specific review route says so.

## Verification Reporting Rule

Implementation is not enough for active RR003 lanes. Each lane should run the
strongest feasible verification for its current scope and report one of:

- `passed`: what command/route ran and what passed;
- `failed`: what ran, what failed, and the suspected layer;
- `blocked`: what prerequisite is missing and the exact reopen condition;
- `held`: what authority or safety scope is intentionally not open.

Use proof-layer labels rather than generic "done":

| Proof layer | Use when |
| --- | --- |
| `module-test` | A module-local unit/contract test ran under `tests/` or `__tests__/`. |
| `organ-test-pack` | A black-box pack under `manifests/tests/organ-test-packs/*.json` ran. |
| `runtime-service` | A service/process was started or queried for readiness/status. |
| `browser-runtime` | Browser or Projection Visual behavior was exercised. |
| `replay` | Local sample media or fixture replay was used. |
| `live-device` | A real device, camera, microphone, Home Assistant action, or physical side effect was used. |
| `manual-user-observation` | A user or reviewer visually/physically confirmed behavior. |

If a feature is incomplete, keep the failure or blocked row visible. Do not
collapse it into "not done".

## Memory Core Placement

If durable Memory Core semantics are implemented under `runtime/memory-core/`,
then SQLite schema, migrations, and Memory Core module tests should live under
that runtime component, for example:

```text
runtime/memory-core/migrations/001_initial_memory_core.sql
runtime/memory-core/tests/test_memory_core_sqlite_migrations.py
runtime/memory-core/tests/test_memory_core_record.py
runtime/memory-core/tests/test_memory_core_organize.py
runtime/memory-core/tests/test_memory_core_reference.py
```

Generated SQLite databases and evidence must stay out of tracked source. Use a
test temp directory, `.cache/memory-core/`, `.cache/agent-os/...`, or
`test-runs/memory-core/`. If module-local generated output is necessary, add a
module-local ignore rule for `*.db`, `*.sqlite`, `*.sqlite3`, `*.db-wal`,
`*.db-shm`, and generated evidence directories.

Thought Core trace and memory-candidate helper tests remain under
`control-plane/sword-voice-agent/tests/` because they test Thought Core service
artifact shapes such as `thought_core_turn_trace.v0` and proposal-only
`memory_candidate.v0`. Durable commit, protected/deletable classes, forgetting,
retrieval indexes, and SQLite persistence belong to Memory Core tests.

Cross-module representative proof should not be hidden in either module-local
test suite. Put it in `manifests/tests/organ-test-packs/*.json` and/or Test-QA
cockpit rows.

See `runtime/memory-core/README.md` for the proposed SQLite package shape and
first verification route when the exact durable memory slice opens.

## Move Policy

Do not move tests just to make the tree look cleaner. A move is safe only when:

- the owning module agrees or the owner is unambiguous;
- imports, runner paths, package discovery, and CI references are updated;
- the old and new proof layers remain clear;
- no private paths, raw evidence, or local artifacts are introduced;
- the change is exact-path reviewed.

When unsure, add an index or manifest row first, then open a separate exact move
slice.
