# Action Catalog

Action Catalog is the aggregated list of executable action ids and their
minimum safety classes.

The catalog is built from Driver Manifests. It should not be maintained as a
large handwritten central list. Each driver declares what it can do; the catalog
builder checks uniqueness, schema presence, and risk defaults.

## Inputs

- `manifests/driver-manifests/*.json`
- `contracts/driver_manifest/driver_manifest.v0.schema.json`

## Outputs

The runtime view used by Action Boundary:

- `action_id`
- providing `driver_id`
- target `organ_id`
- minimum `risk_class`
- parameter schema
- dummy/real driver kind
- explicit permission requirements

## Rules

- Unknown actions are rejected.
- Duplicate action ids are startup errors unless explicitly namespaced.
- Reflex and Thought Core may raise `risk_class`; they may not lower the driver
  manifest default.
- Dummy actions must surface `driver_kind: dummy` and `dry_run: true` in events
  and results.
