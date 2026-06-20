---
name: repair-no-live-readiness
description: Repair Sword Agent OS no-live install/readiness failures without entering live provider, Home Assistant, browser/camera, or physical-device routes.
---

# Repair No-Live Readiness

Use this skill when a fresh clone or developer workspace fails before live work:
manifest validation, pin checks, env rendering, readiness, or no-live smoke.

## Boundaries

- Do not submit Home Assistant preview, dry-run, or execute.
- Do not call providers, browser/camera routes, or physical-device helpers.
- Do not publish raw env, tokens, private paths, logs, screenshots, media, or
  Home Assistant IDs.
- Keep source/static, install/env-render, readiness, runtime/browser,
  HA-visible state, external observation, and physical proof separate.

## Workflow

1. Read `README.md`, `docs/operate.md`, `docs/standard-distribution-map.md`,
   and `docs/troubleshooting.md` only as needed.
2. Run `.\sword.ps1 status`.
3. Run `.\sword.ps1 verify`.
4. If Python is involved, prefer `uv` and inspect `uv python find` before
   diagnosing a broken interpreter.
5. Classify the failure as source, manifest/pin, env render, local input,
   readiness, port/process, dependency, or restricted-environment friction.
6. Patch the smallest product file or local setup instruction that fixes the
   no-live failure.
7. Re-run the exact failed no-live check and one focused guard test.

## Report

Return:

- changed paths;
- proof layer reached;
- exact blocker if still blocked;
- checks run;
- explicit non-claims for live/provider/browser/camera/physical proof.
