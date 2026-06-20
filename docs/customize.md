# Customize Sword Agent OS

Use this page when you know what you want to change, but not which file owns it.
Keep secrets and local-only values in `local/` or generated runtime files; do
not put raw tokens, Home Assistant ids, private URLs, screenshots, logs, or
local machine paths in tracked files.

| やりたいこと | 触る場所 | 最初に見る文書 |
| --- | --- | --- |
| LLM provider or model を変える | `local\env\sword-agent-os.env` | `docs/local-configuration.md` |
| LLM を使わずに起動確認する | `THOUGHT_CORE_LLM_ENABLED=false` | `docs/operate.md` |
| アバター / VRM を変える | `NEXT_PUBLIC_SELECTED_VRM_PATH` and local assets | `docs/local-configuration.md` |
| 声 / TTS を変える | VOICEVOX / TTS env values | `docs/local-configuration.md` |
| Home Assistant action を追加する | generated `home-control.yaml` action row from local inputs | `docs/home-control-action-authoring.md` |
| live proof を取りたい | bounded live ticket and route result | `docs/live-home-control-proof.md` |
| 家電操作を止めておきたい | `.\sword.ps1 hold-live` local marker | `runtime/control/README.md` |
| 起動状態を見たい | `.\sword.ps1 status -NoLive` | `docs/operate.md` |
| 壊れていないか確認したい | `.\sword.ps1 verify -NoLive` | `docs/operate.md` |
| 証拠層を確認したい | proof layer labels in reports | `docs/proof-layers.md` |
| organ / module を差し替える | manifests, contracts, and organ folders | `docs/module-usage-index.md` |

## Home Assistant Config Rule

For Home Assistant state proof, use a full-schema private/live config or a
reviewed clone-local equivalent. A short action-only override can be useful for
command shape or command-ack checks, but it is not enough for HA-visible
CheckState proof.

The action row needs the command binding and the verification metadata together:
script/action binding, expected-effect target, verification mode, accepted
post-action states, proof ceiling, settle/timeout, restore or stop metadata,
and safety blockers. Keep `CheckTracking` and `CheckState` separate:

- `CheckTracking` says whether an action row is tracked and testable.
- `CheckState` reads the current or post-action state and can only prove the
  layer named by the route.

## Change Flow

1. Make the local/private change in the selected config context.
2. Re-render generated env/config files when the source document requires it.
3. Run `.\sword.ps1 verify -NoLive` or the named no-live helper.
4. For Home Assistant, confirm the selected config is not demo/default/template.
5. Use preview / dry-run / execute only when an exact live route has been
   reviewed and the proof layer is explicit.

Do not promote command submission, preview, dry-run, or HA-visible state match
into external observation or physical/device proof.
