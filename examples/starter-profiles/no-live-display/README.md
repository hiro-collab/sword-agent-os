# no-live-display Starter Profile

<!-- starter-profile:no-live-display -->

This starter profile is the smallest product-facing route for checking Sword
Agent OS display/runtime surfaces without live providers or physical devices.
It is an example profile, not a new front-door command.

## Goal

Confirm that a fresh developer can reach the safe display/runtime path before
touching Home Assistant live actions, browser/camera capture, provider calls, or
physical-device proof.

## Route

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 start
```

`start` is a command preview by default. Use `docs/operate.md` before adding
`-Run`.

## Does Not Prove

- provider response quality;
- live Home Assistant execution;
- camera/microphone proof;
- external or physical/device proof;
- release/readiness.

## Next Paths

- For voice/avatar changes, use `docs/customize.md`.
- For Home Assistant setup, use `docs/home-assistant-setup.md`.
- For proof wording, use `docs/proof-layers.md`.
