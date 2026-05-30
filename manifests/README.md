# Manifests

Manifests describe the standard Agent OS distribution: services, profiles,
connections, data authorities, service inventories, organ implementation
sources, organ driver contracts, diagnostic pulse and retention policy, legacy
reference points, organ test packs, and the runtime components required by each
profile.

## Current Manifest Families

- `body-plans/`: canonical organism/body structure. These files define body
  roles such as `thought.core`, `reflex.core`, `sense.vision.primary`, and
  `display.projection`.
- `driver-manifests/`: action-capable, dummy, compatibility, and display/runtime
  driver capability declarations used by Action Catalog and Action Boundary.
- `drivers/`: existing read-only diagnostic driver contracts. These remain
  separate from action-capable driver manifests.
- `compat-aliases/`: transitional mapping from legacy labels and service ids to
  canonical ids.

New runtime code should depend on body plans, driver manifests, and contracts.
Legacy aliases are for external compatibility and migration only.

For the practical "where should this change go?" entry point, see
`docs/module-usage-index.md`.
