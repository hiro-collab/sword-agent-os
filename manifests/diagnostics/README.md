# Diagnostic Manifests

Diagnostic manifests define how often Agent OS observes itself, which stores
receive the outputs, and how long diagnostic data may be retained.

They do not define organ behavior. Organ-specific evidence contracts live under
`manifests/drivers/`. The diagnostic manifest defines the common pulse,
storage, and retention policy that invokes those drivers.

- `standard.json`: first read-only diagnostics schedule and retention policy for
  the current `thought-core-v0-compat` baseline.

