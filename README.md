# Sword Agent OS

Sword Agent OS is a local body OS for a PC-hosted agent: thought, voice,
avatar/display, sensing, diagnostics, and guarded Home Assistant action routes.

This README is only the front door. Detailed rules live in the docs and
manifests listed below. If a detail appears in both README and a specialist
doc, treat the specialist doc or manifest as the authority and reduce the
duplicate here.

## Safety Default

The default product posture is no-live and local-first.

- No provider, microphone, camera, browser, Home Assistant, or device mutation
  is implied by install, status, doctor, or verification commands.
- Home Control live work requires an exact route, bounded action family,
  just-in-time gates, redacted summary output, and a proof ceiling.
- HA-visible state, external observation, physical movement, release readiness,
  and final RR003 review are separate claims.
- Local secrets, tokens, private paths, raw logs, media, Home Assistant entity
  ids, and provider/browser payloads must stay out of tracked docs.

## Front Door Commands

Run these from the repository root.

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 doctor
.\sword.ps1 start
.\sword.ps1 hold-live
```

`start` previews the planned runtime start by default. Use explicit run flags
only when the current route authorizes that layer.

## Fresh Install / No-Live Readiness

The standard first-time path is:

```powershell
.\scripts\install-distribution.ps1 -Profile standard
.\scripts\render-env-files.ps1 -Profile standard -Force
.\scripts\validate-manifests.ps1
.\scripts\check-distribution-pins.ps1 -Strict
.\scripts\check-launch-readiness.ps1
.\scripts\test-organ-packs.ps1
.\scripts\run-compat-smoke.ps1
```

Use `docs/verification-commands.md` for command intent and expected proof
layers. Use `docs/troubleshooting.md` when a readiness check fails.

## Canonical Map

| Need | Authority |
| --- | --- |
| Daily operation and front-door behavior | `docs/operate.md` |
| Architecture planes and where new rules belong | `docs/architecture.md` |
| User-facing capability choices | `docs/capability-packs.md` |
| Customization and local env/config shape | `docs/customize.md`, `docs/local-configuration.md` |
| Standard distribution contents and pin checks | `manifests/README.md`, `docs/standard-distribution-map.md`, `docs/distribution-maintenance.md` |
| Module ownership and implementation surfaces | `docs/module-usage-index.md` |
| Machine-readable reference surfaces | `docs/reference-surfaces.md` |
| Home Assistant setup and action authoring | `docs/home-assistant-setup.md`, `docs/add-home-device.md`, `docs/home-control-action-authoring.md` |
| Home Control live proof boundaries | `docs/live-home-control-proof.md`, `docs/proof-layers.md` |
| Verification commands and failure handling | `docs/verification-commands.md`, `docs/troubleshooting.md` |

Older one-off reports, startup notes, and legacy indexes are not canonical
product documentation. Promote durable rules into one of the files above, then
delete the old record.

## Distribution Shape

The standard distribution is described by manifests, not by README prose.

- `manifests/body-plans/` defines body roles.
- `manifests/distributions/` defines installable profiles.
- `manifests/releases/` defines human-readable versions.
- `manifests/driver-manifests/` and `contracts/` define driver and packet
  contracts.
- `manifests/compat-aliases/` is transitional only; do not add new product
  behavior there.

## Proof Layers

Keep proof wording narrow:

- source/config inspection proves only source/config shape;
- no-live bridge/catalog/readability proves only the checked no-live layer;
- runtime/browser health proves only reachable local runtime surfaces;
- command submission proves only accepted submission;
- HA-visible `CheckState` proves only HA-visible matched state;
- external or physical proof requires a separate observation route;
- review-ready, release-ready, and final RR003 pass require explicit review.

If a result is already terminal before a command, do not claim transition or
motion causality from the command. State the limitation directly.

## Home Control

Home Control is deliberately ticketed and bounded. The usual ladder is:

1. source/config shape;
2. bridge health;
3. catalog parity;
4. `CheckTracking`;
5. pre-command `CheckState`;
6. at most one reviewed command submission;
7. post-action `CheckState`;
8. optional external/physical observation under a separate route.

Do not convert a Home Assistant state match into physical proof.

## External Projects

Some organ implementations and helper surfaces are vendored or pinned from
external projects. Keep licenses and upstream pin updates in their specialist
docs/manifests rather than expanding this README.

When in doubt, shrink this file and move durable detail to the smallest
specialist authority.
