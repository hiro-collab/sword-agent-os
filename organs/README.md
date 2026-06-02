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

## Organ setup documentation

Each organ repository should make its first-use path obvious. A reader should
not have to infer installation from a section named only "Start" or "Run".

Expected README shape for owned organ repositories:

- `Initial setup`: dependency install commands such as `uv sync` or the required
  Node.js version.
- `dotenv / local config`: whether `.env` is required, where `.env.example`
  lives, and which sibling organ `.env` is reused.
- `Normal start`: the command used after dependencies and local config are in
  place.
- `Smoke check`: a cheap command or endpoint check when the organ has one.
- `Local-only artifacts`: caches, logs, generated media, model files, tokens,
  `.toe` expansions, and other files that must not be committed.

External or upstream-derived organs may keep their upstream README intact. Put
Sword Agent OS specific wiring, dotenv, and review notes in this repository's
setup docs or in a project-owned fork note instead of sending broad upstream
README edits. `organs/expression/aituber-kit` is treated this way unless the
manager/user explicitly scopes work on the project fork.

For where to add cross-organ contracts, driver declarations, action-boundary
logic, diagnostics, or display projections, see
`docs/module-usage-index.md`.
