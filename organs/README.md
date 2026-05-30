# Organs

Standard organ layout target:

```text
organs/
  speech-input/
  reflex/
  thought/
  environment/
  action/
  expression/
  display/
  diagnostics/
```

Organs may be nested repositories. The Agent OS repository owns the placement,
contracts, manifests, and OS-specific integration rules.

Implementation checkouts are sourced through `manifests/organs/`. Do not copy
legacy organ folders directly into this repository. Use the manifest and
bootstrap script so the selected repository, branch, and commit remain
reproducible.

For where to add cross-organ contracts, driver declarations, action-boundary
logic, diagnostics, or display projections, see
`docs/module-usage-index.md`.
