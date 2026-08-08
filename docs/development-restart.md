# Clean development restart

This document records the bounded clean rebuild completed on 2026-08-08. It is
an operational restart point, not a new product specification or a release
acceptance record. Product intent and unresolved decisions remain governed by
`HANDOVER.md`, current manifests, contracts, policies, and later explicit user
decisions.

## Product intent carried forward

Sword Agent OS is intended to join natural human input, current context and
memory, genuine Thought Core reasoning, safe action, receipts and
re-observation, and expression into one local agent system. The user-facing
result is an agent that can understand ordinary wishes, ask when meaning is
unclear, respond naturally, show the same response through its expression
surfaces, and act only through bounded, inspectable routes.

The central design boundary is retained:

- AI owns meaning, clarification, selection among permitted intentions, and
  the natural response.
- Deterministic code owns schemas, permissions, validation, deduplication,
  execution, receipts, privacy boundaries, identity-bound Stop, and cleanup.
- An action request, an accepted plan, execution, external observation,
  physical effect, visible expression, and final user acceptance are separate
  proof layers.

The target flow is:

`wish/input -> recognizer and input gate -> context/memory -> Thought Core ->`
`validated plan -> selected organ -> receipt/re-observation -> expression ->`
`identity-bound Stop and cleanup`

## Rebuild authority and source pins

The parent repository was reconstructed from the requested source snapshot:

- repository: `hiro-collab/sword-agent-os`
- requested branch: `work/parent-ordinary-route-contract-v1`
- handover commit: `096cf13bc50230870be799e7a2ab665ef197b19c`
- direct technical parent: `ebf1758cb4daa1ffecf018bbba183a6a786c8231`
- the only change from the technical parent to the handover commit is the
  addition of `HANDOVER.md`
- `HANDOVER.md` blob size: 76126 bytes
- `HANDOVER.md` SHA-256:
  `F23C36DEBC9FB123E1FD2838D4F04C7EB2D26B6AB15727FB0F6A32B7E4DE92E9`

That SHA-256 is the LF-normalized Git blob hash. With Windows
`core.autocrlf=true`, `Get-FileHash` reads the CRLF working-tree copy as
`91CB14CA4F043AD16519FD2168AA7A3A48BF179260EBA5EB3D44AE676675CF62`;
the difference is line-ending conversion, not evidence of tampering.

The standard manifest selected the following checkouts, and strict pin
verification passed for all 10 entries:

| Component | Selected commit |
| --- | --- |
| Control | `9a8fa2fb1c617dbe8dd572115267becdb2123169` |
| AI Talk Core | `0478291` |
| MediaPipe Sword Sign | `292ff9c` |
| Environment State Server | `4b51066` |
| Vision Snapshot Processor | `685fcec` |
| Home Assistant Server | `163c81b` |
| TTS Service | `404fb04` |
| AITuberKit | `ce27f69` |
| TouchDesigner AI Controller | `fc82651` |
| System House Renderer | `148ae71` |

The short organ hashes above identify the manifest-selected commits recorded
in this snapshot. Run the strict pin checker for the complete current values;
do not treat this table as a replacement for the manifests.

## What was and was not carried forward

The rebuild contains the parent repository, selected Control checkout, and the
nine standard organs listed above. It generated ignored, placeholder-only env
and Home configuration files from repository templates.

It did not import:

- the deferred avatar service;
- the unselected Control candidate beginning `2b00bdd`;
- legacy local assets or runtime state;
- `.runtime`, caches, secrets, or raw evidence;
- local camera, microphone, projector, Home Assistant, VOICEVOX, or provider
  state.

The selected exact nested source contains a user-specific absolute Windows path
literal in four tracked synthetic redaction-test fixtures. The prefix is
represented here as `<USER_HOME>`. The exact fixtures are:

- `control-plane/core/tests/test_thought_core_codex_cli_responder.py:526`
- `control-plane/core/tests/test_thought_core_codex_cli_responder.py:527`
- `control-plane/core/tests/test_thought_core_codex_cli_responder.py:567`
- `organs/reflex/mediapipe-sword-sign/tests/test_serve_camera_hub.py:1177`

They are test input, not real secrets or runtime evidence, but a
zero-literal-local-path publication criterion therefore remains on hold. This
bootstrap does not rewrite pinned nested source. The corrective unit is to
replace the literals with placeholders in the nested repositories, run the
focused tests, commit those nested changes, and adopt the new commits through
parent manifest pins.

Tracked AITuberKit assets arrived with the remote checkout: six `.vrm` files,
one `.vrma`, one `.moc3`, one `.model3.json`, 22 `.png` files, and one `.wav`.
That inventory records clone contents only. It is not a decision that these
assets may be bundled, republished, or adopted for product distribution.

## Safe local setup

Use the front-door scripts from the repository root. Keep generated state
untracked. The clean rebuild used template rendering only:

```powershell
.\scripts\render-env-files.ps1 -Profile standard -CreateCentralEnv
.\scripts\check-distribution-pins.ps1 -Profile standard -Strict
.\scripts\doctor-distribution.ps1 -Profile standard
```

For each Python organ, use Python 3.11 and a project-local uv cache:

```powershell
uv --cache-dir .uv-cache sync --python 3.11
```

Home Assistant Server also needs its development extra for its test suite:

```powershell
uv --cache-dir .uv-cache sync --python 3.11 --extra dev
```

For AITuberKit, use `npm.cmd install`. Do not run automatic audit fixes without
reviewing their source and lockfile impact. After any dependency install,
confirm that tracked dependency files did not change unexpectedly.

Generated `.env` and Home configuration files are ignored placeholders. Do
not put API keys, tokens, device identifiers, personal paths, or other secrets
in Git. The clean snapshot keeps the Thought Core tools adapter on `mock` and
does not provide the local gesture model.

## Verification snapshot

The following checks were completed without provider calls, paid requests,
Home actions, or physical device use:

| Area | Result |
| --- | --- |
| manifest and remote selection | valid; selected set verified |
| strict distribution pins | 10/10 passed |
| front-door status | passed; manifest status only |
| front-door verify / doctor | scripts completed, readiness remained blocked by the missing gesture model and placeholder/mock settings |
| Python dependency sync and imports | 7 of 8 Python checkouts passed |
| AI Talk Core dependency sync | blocked while compiling `webrtcvad==2.0.10` with MSVC on Windows; Flask was therefore unavailable for its import check |
| Control focused Node tests | 90 passed, 1 skipped, 0 failed |
| Control focused Python tests | 28 passed, 2 failed |
| Environment tests | 56 passed, 4 skipped |
| Vision tests | 21 passed, 1 skipped |
| Home tests | 91 passed |
| TTS tests | 30 passed |
| System House tests | 17 passed |
| MediaPipe tests | 205 passed, 1 skipped; synthetic unit behavior only, not a camera claim |
| AITuberKit focused tests | 94 passed in 3 suites |
| AITuberKit dependency tracked-diff gate | `package-lock.json` unchanged; parent and nested tracked state remained clean |
| AITuberKit audit | 18 findings: 2 low, 3 moderate, 13 high; no automatic fix applied |
| AITuberKit typecheck / lint / build | failed on existing source and test type/lint issues; production build is not proven |
| AITuberKit bounded dev reachability | one Projection Visual route returned HTTP 200; the owned process tree was stopped and the port was cleared |

The two focused Control Python failures are an expected frozen graph hash that
does not match the selected source, and a private plan reader command that
returns failure for its valid-command test. They were recorded, not patched
into a new specification.

## Known hard stops

Do not describe this snapshot as runtime-ready or exact3-ready:

- The selected Control PowerShell loader marks optional Home, Environment,
  watcher, and TouchDesigner cells as required, which conflicts with the
  selected exact3 graph and private plan.
- The selected `system.ps1` payload does not supply the required
  `expectedConfigSha256` value.
- `sword.ps1 start -Run` launching the Launcher does not prove exact3 Start or
  Ready.
- Installer text saying that a workspace is ready for first launch is not
  runtime evidence.
- The missing gesture model blocks the current readiness check.
- AI Talk Core still has the Windows native dependency blocker described
  above.
- AITuberKit typecheck, lint, production build, and dependency audit findings
  remain unresolved.

The unselected Control candidate beginning `2b00bdd` may contain related work,
but it was deliberately not imported or adopted. Any decision to select it
requires an explicit source review and manifest-pin change.

## Licensing boundary

The parent repository has no root `LICENSE` or `NOTICE`. Among the selected
nested roots, AITuberKit includes its own license, and its bundled assets and
models can have additional terms. Cloning source for local inspection, using
it, and redistributing it are separate decisions. Do not vendor, bundle, or
publish selected nested code or assets until the applicable rights have been
reviewed.

## Proof ceiling

This rebuild proves source composition, the handover hash, manifest selection,
strict nested pins, most local dependency/import paths, focused test results,
and one bounded AITuberKit HTTP route. It does not prove:

- exact3 Launcher Start or Ready;
- a provider-backed, input-specific AI response;
- browser-visible avatar, bubble, Stop behavior, or pixel output;
- whole-stack process cleanup;
- voice, motion, Home, effects, camera, microphone, projector, or physical
  device behavior;
- redistribution permission, release readiness, or final user acceptance.

Mock, placeholder, and fixed responses must stay labeled as test substitutes.

## Recommended implementation order

1. Decide explicitly which Control commit should be selected; do not
   automatically adopt the `2b00bdd` candidate.
2. Align the selected exact3 loader and `system.ps1` payload with the current
   graph and contract, then obtain an independent focused review.
3. Re-run strict pins and focused tests; resolve the AI Talk Core Windows
   dependency path and the AITuberKit typecheck, lint, build, and audit gates.
4. Use a fresh task-owned, no-live exact3 preview/plan route and preserve its
   identity through Start, receipt, Stop, and cleanup.
5. Only then test a real provider-backed, input-specific response, browser
   bubble and Stop behavior, and process cleanup as separate proof layers.
6. Reuse the existing avatar surface before adding another one; add memory,
   environment, voice, motion, Home, and effects incrementally after the core
   route is trustworthy.

If a later instruction changes product behavior, record the decision in the
appropriate governance, manifest, contract, or policy file. Do not infer a new
specification from a failing test or from this reconstruction report.
