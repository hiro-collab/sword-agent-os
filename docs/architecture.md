# Sword Agent OS Architecture And Structure Spine

<!-- architecture:structure-spine -->

This page is the stable structure spine for Sword Agent OS. Use it when the
repo feels like a mix of docs, scripts, organs, manifests, local inputs, and
proof reports. It names which file owns each concern so a fresh operator,
developer, or review thread does not need private chat history to understand
the system.

This is not a release-readiness claim, live Home Assistant authorization, or
physical-device proof. It is an information architecture and maintenance guide.

## Design Verdict

Sword Agent OS should not be organized around whichever diagnostic lane most
recently failed. It should be organized around six stable planes:

| Plane | Owns | Primary source of truth | Must not own |
| --- | --- | --- | --- |
| Front Door | Safe first commands and user entry points | `README.md`, `docs/operate.md`, `sword.ps1` | Internal proof ladders, private config values, broad script reference |
| Configuration | Local inputs, selected profiles, provider/model choices, Home Assistant config selection | `docs/local-configuration.md`, `docs/home-assistant-setup.md`, templates under `templates/` and organ `.env.example` files | Live permission, proof claims, raw secrets in tracked files |
| Runtime Control | Stop/hold/pause/approval vocabulary and marker semantics | `runtime/control/README.md`, `sword.ps1 hold-live` | Complete service-level enforcement until readers exist and are tested |
| Proof And Verification | What each check proves and does not prove | `docs/proof-layers.md`, `docs/live-home-control-proof.md`, verification reports | Physical proof from HA state alone, release/readiness approval |
| Module / Organ Architecture | Where code belongs, how nested organs are selected/pinned, and how system-readable reference surfaces are contracted | `docs/module-usage-index.md`, `docs/reference-surfaces.md`, `manifests/`, `contracts/`, `runtime/` | User-facing quick-start or private coordination history |
| Coordination / Governance | Review routing, role messages, temporary decisions, handoffs | workspace-level `coordination/shared`, `governance/` for durable product decisions | Product source behavior unless adopted through exact product diff |

If a new document or script crosses more than two planes, it is a design smell.
Either split it or make the cross-plane handoff explicit.

## Capability Packs Are The External Shape

<!-- architecture:capability-pack-layer -->

The six planes above are ownership boundaries. They are not the best first view
for users. Users usually think in capability packs: chat/thought, voice, avatar,
home control, environment, gesture, diagnostics, or agent-worker assistance.

Use `docs/capability-packs.md` as the external product map. It translates the
internal planes into selectable functional slices. This follows the useful part
of AITuber OnAir's public shape: clear entry paths and modular packages before
deep implementation detail. Sword should borrow that packaging idea while
preserving stricter Home Assistant and physical-world proof boundaries.

Do not replace architecture planes with capability packs:

- planes answer "who owns this concern?";
- packs answer "what feature is the user trying to use?";
- starter profiles answer "what is the smallest route to try this safely?";
- proof layers answer "what evidence does this actually prove?".

Starter profiles use `examples/starter-profiles/_template.md` as their standard
shape. A valid starter profile keeps Goal, Safe Route, Report Shape, Stop
Conditions, and Next Paths separate, while making claim/non-claim boundaries
explicit. This prevents examples from becoming a second undocumented product
surface.

## External Patterns Used

- Diataxis: keep tutorials, how-to guides, reference, and explanation separate.
  In this repo, `README.md` and quick-start are tutorial-like, `docs/operate.md`
  and `docs/home-assistant-setup.md` are how-to guides, manifests/contracts are
  reference, and this file is explanation.
- Twelve-Factor config: tracked source should not contain deploy/user secrets.
  Sword keeps public defaults/templates in the repo and selects local/private
  config through env/rendered files.
- CLI design guidance: front-door command names should stay short,
  discoverable, and safe by default. `sword.ps1` should grow slowly.

These patterns are guides, not cargo-cult rules. Sword has local-device and
proof-layer requirements that typical web-app patterns do not cover.

## Definition Table

<!-- architecture:definition-table -->

| Term | Recommended definition | Source of truth |
| --- | --- | --- |
| Front door | The small safe entry surface for first operators: `status`, `verify`, `doctor`, `start`, `stop`, `hold-live` | `README.md`, `docs/operate.md`, `sword.ps1` |
| no-live | A mode or route that does not submit provider calls, Home Assistant actions, browser/camera operations, or physical-device mutations | `docs/operate.md`, `docs/proof-layers.md` |
| live | A scoped route that can submit a mutation or external operation after explicit review/ticket bounds | `docs/live-home-control-proof.md` |
| selected config context | The actual env/profile/config path selected by the current workspace or worktree after render | `docs/home-assistant-setup.md` |
| full-schema config | Home Control action rows with command binding plus verification metadata: expected effect, verification mode, proof ceiling, timing, restore/stop/safety metadata | `docs/home-control-action-authoring.md`, `docs/home-assistant-setup.md` |
| short/minimal action-only override | A config useful for command-shape or ack-only checks, not for HA-visible CheckState proof | `docs/home-assistant-setup.md` |
| reviewed clone-local equivalent | A redacted, clone-local full-schema config package or equivalent approved for that exact fresh clone/worktree context | `docs/home-assistant-setup.md` |
| CheckTracking | Pre-execution metadata check: whether an action row is tracked and testable for a later proof layer | `docs/proof-layers.md`, `docs/home-control-action-authoring.md` |
| CheckState | State matcher for current/post-action/post-restore HA-visible state. It is not physical proof by itself | `docs/proof-layers.md`, `docs/live-home-control-proof.md` |
| proof layer | A named evidence ceiling such as source/static, no-live readiness, preview, dry-run, command submission, HA-visible CheckState, external observation, or physical/device proof | `docs/proof-layers.md` |
| route | A bounded task packet with target, allowed actions, counts, stop conditions, evidence fields, and non-claims | `docs/live-home-control-proof.md` |
| reference surface | A contracted machine-readable value, packet, or map that Thought Core, diagnostics, review tools, or source code can read without private chat history | `docs/reference-surfaces.md`, `contracts/` |
| ticket | Explicit live-route authority for one bounded target/action scope. It is not inferred from config, docs, or readiness | `docs/live-home-control-proof.md` |
| HOLD_LIVE | A local marker and route gate that keeps live work out of scope until a later exact route opens it | `runtime/control/README.md` |
| release-ready | A final product/readiness classification after required evidence and reviews, not a synonym for install/pass/local smoke | future release/readiness docs plus review packets |

When a report uses one of these words differently, it must say why.

## Canonical Journeys

### Fresh Operator: Safe First Look

1. Read the README front-door section.
2. Run `.\sword.ps1 status`.
3. Run `.\sword.ps1 verify`.
4. Use `docs/operate.md` for start/stop/doctor/hold-live.
5. Do not enter Home Assistant live work until a separate route exists.

### External Home Assistant Setup

1. Read `docs/home-assistant-setup.md`.
2. Put secrets and local/private values in ignored local inputs.
3. Render env/config files.
4. Confirm the selected config context is not demo/default/template.
5. Confirm a full-schema private/live config or reviewed clone-local equivalent.
6. Run read-only bridge/catalog/CheckTracking/CheckState parity gates.
7. Only then consider preview/dry-run/live under `docs/live-home-control-proof.md`.

### Developer Adding Or Moving A Module

1. Use `docs/module-usage-index.md` to classify the change.
2. Update manifests/contracts when the standard distribution shape changes.
3. Keep local secrets, generated env, logs, screenshots, and coordination outputs
   out of product source.
4. Run the narrow test that guards the plane you changed.

### Live Proof Route

1. Open a route with target/action/count/timing/restore/stop/evidence fields.
2. Pass current JIT gates before mutation.
3. Keep preview, dry-run, execute, post-action HA-visible CheckState, external
   observation, and physical/device proof in separate fields.
4. Preserve non-claims in the result packet.

## Spaghetti And Chimera Watch

Treat these as active review smells:

- README grows detailed reference tables that already belong in `docs/`.
- `sword.ps1` gains commands before the current six commands have clear reader
  behavior and help/discovery.
- A starter profile omits the template sections or uses `preview` without
  saying whether it means read-only readiness, command preview, or a Home
  Assistant preview endpoint.
- Home Assistant connection success is described as proof-ready config success.
- A short/minimal action-only override is allowed to masquerade as full-schema
  proof context.
- Generated ignored files become the only place a fresh developer can discover
  required config shape.
- A system reader depends on a new value that has no contract, no `contract_ref`,
  or no owner-local reference surface.
- Coordination messages become the only record of product behavior.
- Tests assert long prose sentences instead of stable anchors or structured
  responsibility markers.
- Legacy/fallback paths are left unnamed instead of classified as active,
  compatibility, or delete-candidate.

## Review Thread Use

<!-- architecture:review-thread-use -->

Other existing review threads should use this file as the product-side structure
spine, then return deltas rather than re-litigating every previous coordination
message. A good review should say:

- which plane is affected;
- whether the issue is a user journey, developer journey, proof-layer, config,
  runtime-control, module-boundary, or coordination/governance issue;
- the one next patch that would improve the system most without broad rewrite.

If a reviewer needs private context to understand a product behavior, that is a
documentation or structure gap unless the behavior is intentionally private.

## Reference Links

These references informed the structure above:

- Diataxis documentation framework: https://diataxis.fr/
- Twelve-Factor App config guidance: https://12factor.net/config
- Microsoft command-line design guidance: https://learn.microsoft.com/en-us/dotnet/standard/commandline/design-guidance

Use these as pressure tests. Do not import a pattern when it would collapse
Sword-specific proof layers, local-device safety, or private Home Assistant
boundaries.
