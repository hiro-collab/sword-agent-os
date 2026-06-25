# no-live-display Starter Profile

<!-- starter-profile:no-live-display -->

This starter profile is the smallest product-facing route for checking Sword
Agent OS display/runtime surfaces without live providers or physical devices.
It is an example profile, not a new front-door command.

## Goal

Confirm that a fresh developer can reach the safe display/runtime path before
touching Home Assistant live actions, browser/camera capture, provider calls, or
physical-device proof.

## Safe Route

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 start
```

`status` and `verify` are no-live/read-only checks. `start` is a command
preview by default. Use `docs/operate.md` before adding `-Run`.

## Report Shape

Report the route name, command result, claim, and non-claim. Keep command
preview separate from runtime/browser reachability, provider responses, live
Home Assistant execution, camera/microphone proof, external observation,
physical/device proof, and release readiness.

## Stop Conditions

Stop before the next proof layer if:

- `status` or `verify` reports a missing required local input or dependency;
- `start` would require `-Run`, a browser/runtime operation, a provider call, a
  camera/microphone surface, or Home Assistant live action;
- explaining the result would require raw logs, screenshots, audio, private
  paths, tokens, or local config values.

## Next Paths

- For voice/avatar changes, use `docs/customize.md`.
- For Home Assistant setup, use `docs/home-assistant-setup.md`.
- For proof wording, use `docs/proof-layers.md`.
