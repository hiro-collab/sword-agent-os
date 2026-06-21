# Manifests

Manifests describe the standard Agent OS distribution: services, profiles,
connections, data authorities, service inventories, organ implementation
sources, organ driver contracts, diagnostic pulse and retention policy, organ
test packs, and the runtime components required by each profile.

Manifest files are the authority for standard distribution contents and pins.
README files and docs should summarize them, not duplicate their full ledgers.

## Current Manifest Families

- `body-plans/`: canonical organism/body structure. These files define body
  roles such as `thought.core`, `reflex.core`, `sense.vision.primary`, and
  `display.projection`.
- `distributions/`: installable distribution profiles. These files tie together
  control-plane and organ source manifests, dependency install commands, local
  env rendering, and manual asset reminders.
- `releases/`: human-readable OS, distribution, and component versions. These
  files complement Git commit pins in source manifests; semantic versions say
  what compatibility release this is, while commit pins say exactly which source
  revision will be installed.
- `driver-manifests/`: action-capable, dummy, compatibility, and display/runtime
  driver capability declarations used by Action Catalog and Action Boundary.
- `drivers/`: existing read-only diagnostic driver contracts. These remain
  separate from action-capable driver manifests.
- `compat-aliases/`: transitional mapping from old labels and service ids to
  canonical ids. Do not add new behavior here; delete stale aliases instead of
  expanding compatibility surfaces.

New runtime code should depend on body plans, driver manifests, and contracts.
Aliases are for migration only.

## Pin State Classes

Use these classes when summarizing manifest pin health:

- `present`: a required pin or manifest entry exists.
- `missing`: an expected pin or entry is absent.
- `stale`: the pin exists but no longer matches the requested standard
  distribution.
- `local-only`: the value is expected to be supplied outside tracked files.
- `not-applicable`: the manifest family does not own the requested value.

For the practical "where should this change go?" entry point, see
`docs/module-usage-index.md`.
