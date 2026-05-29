# Organ Test Packs

Organ test packs describe how Agent OS can verify organ capabilities without
teaching the OS core every organ's private implementation.

The first contract is intentionally black-box and read-only by default. A pack
declares checks that can be run by the common runner, plus checks that require
replay fixtures, live hardware, manual inspection, or explicit side-effect
permission.

## Responsibility Split

| Layer | Owner | Responsibility |
| --- | --- | --- |
| Test pack contract | Agent OS / integration-main | Shared shape, result states, and safety rules. |
| Test runner | Runtime/integration | Execute safe checks and summarize all results. |
| Initial organ packs | Integration workers | External checks for selected organs while dedicated organ owners are unavailable. |
| Internal organ tests | Organ repositories | Detailed module logic, UI, model, and API tests. |
| Safety review | security-data-safety | Live action, camera, replay, logs, secrets, and raw media boundaries. |

## Modes

| Mode | Meaning |
| --- | --- |
| `auto` | Safe, local, no side effects. Default runner mode. |
| `replay` | Uses local-only fixtures such as video/images. Raw media must remain untracked. |
| `live` | Requires running services, hardware, browser, or local external systems. |
| `manual` | Requires human visual/physical confirmation. |
| `deep` | Expensive startup/anomaly checks, strict handshakes, or fuller smoke tests. |

Live checks that can mutate the home, send UDP, trigger a real device, or
capture/retain sensitive media must also require explicit side-effect
permission. Diagnostics and routine pack execution do not grant that permission.

## Result States

| Result | Meaning |
| --- | --- |
| `pass` | The check succeeded. |
| `fail` | The check ran and contradicted the expected condition. |
| `blocked` | The check could not run because an environment, fixture, dependency, or permission was missing. |
| `manual` | The check is recorded for human confirmation and was not automated. |
| `skipped` | The check mode was not selected. |

## First Pack Location

The first standard pack lives at:

```text
manifests/tests/organ-test-packs/standard.json
```

Run it with:

```powershell
.\scripts\run-organ-test-packs.ps1
.\scripts\run-organ-test-packs.ps1 -Modes auto,replay
.\scripts\run-organ-test-packs.ps1 -Modes auto,live -PortMode isolated_override
```

The runner writes no tracked files. It refreshes diagnostics in safe mode unless
`-NoRefreshDiagnostics` is passed.
