# Manifest Ledger Authority

The parent repository is the source of standard-distribution truth. Do not copy
pin values into side notes or treat nested checkout state as authority without
the parent manifest row that names it.

| Surface | Role |
| --- | --- |
| `manifests/distributions/standard.json` | Standard distribution entry point |
| `manifests/releases/standard.json` | Release metadata and public-transition pin summary |
| `manifests/organs/legacy-github.json` | Nested checkout repository and commit pins |
| `manifests/profiles/*.json` | Launch profile and selected service shape |
| `manifests/services/*.json` | Expected service/process definitions |
| `manifests/tests/organ-test-packs/*.json` | Cross-module test pack manifests |
| `contracts/` | Runtime and organ boundary schemas |
| `docs/` | Explanation only; docs do not override manifests |

Pin states should be classified explicitly:

| Class | Meaning |
| --- | --- |
| `ok` | Checkout is at the manifest pin with no blocking source changes |
| `ahead_of_manifest` | Checkout is newer; parent adoption decision is required |
| `behind_manifest` | Checkout needs update or reinstall |
| `dirty_at_manifest_pin` | Checkout is pinned but has local source changes |
| `dirty_not_at_manifest_pin` | Checkout is both dirty and off-pin |
| `manifest_commit_missing_locally` | Local checkout cannot see the pinned commit |
| `git_unreadable` | Git status could not be read; classify environment access separately from source mismatch |

Strict distribution green requires the relevant strict checks to actually pass.
A scoped blocker closure or one organ pin repair is not a full release/readiness
approval.
