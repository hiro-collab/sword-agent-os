# Driver Manifests

Driver Manifests declare what a driver can do. They are separate from the
existing read-only diagnostic driver manifests under `manifests/drivers/`.

Use this directory for action-capable, dummy, compatibility, and display/runtime
capability declarations that feed Action Catalog and Action Boundary.

## v0 Rules

- Drivers do not remember their organism owner.
- Driver ids name implementation or adapter surfaces, not body roles.
- Action risk defaults live here.
- Reflex and Thought Core may raise risk but may not lower the manifest default.
- Dummy drivers are first-class development drivers and must report
  `driver_kind: dummy` plus `dry_run: true`.
