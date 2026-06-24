# Customize Sword Agent OS

Use this page when you know what you want to change, but not which file owns it.
Keep secrets and local-only values in `local/` or generated runtime files; do
not put raw tokens, Home Assistant ids, private URLs, screenshots, logs, or
local machine paths in tracked files.

<!-- front-door:intent-customize-llm -->
<!-- front-door:intent-home-action -->
<!-- front-door:intent-live-proof -->
<!-- front-door:intent-proof-layer -->
<!-- front-door:no-live-default -->

| やりたいこと | 触る場所 | 最初に見る文書 |
| --- | --- | --- |
| 使う AI サービスやモデルを変えたい | `local\env\sword-agent-os.env` の LLM 設定 | `docs/local-configuration.md` |
| AI なしで起動確認したい | `THOUGHT_CORE_LLM_ENABLED=false` | `docs/operate.md` |
| アバター / VRM を変えたい | `NEXT_PUBLIC_SELECTED_VRM_PATH` とローカル asset | `docs/local-configuration.md` |
| 声 / TTS を変えたい | VOICEVOX / TTS の env 値 | `docs/local-configuration.md` |
| 声 / アバターの安全な小ルートを試したい | no-live voice/avatar starter profile | `examples/starter-profiles/voice-avatar/README.md` |
| アバターが実際に動く、笑う、うなずく、踊るか見たい | Projection Visual と Self Mirror visible-motion route | `examples/starter-profiles/projection-visual/README.md` |
| Home Assistant を外部環境につなぎたい | `HOME_ASSISTANT_TOKEN`, `HOME_CONTROL_API_TOKEN`, `HOME_CONTROL_CONFIG`, full-schema action row | `docs/home-assistant-setup.md` |
| 操作できる家電動作を増やしたい | local input から生成される `home-control.yaml` の action row | `docs/add-home-device.md`、`docs/home-control-action-authoring.md` |
| 実際の家電が動いた証拠を取りたい | 範囲を決めた live ticket と route result | `docs/live-home-control-proof.md` |
| 家電操作を止めておきたい | `.\sword.ps1 hold-live` local marker | `runtime/control/README.md` |
| 起動状態を見たい | `.\sword.ps1 status` | `docs/operate.md` |
| 壊れていないか確認したい | `.\sword.ps1 verify` | `docs/operate.md` |
| 機能単位で全体を把握したい | Core Body / Thought / Voice / Avatar / Home Control などの capability pack | `docs/capability-packs.md` |
| 構成や用語の責任分界を知りたい | Front Door / Configuration / Proof / Runtime Control / Module / Coordination | `docs/architecture.md` |
| どこまで動いたと言えるか確認したい | report の proof layer label | `docs/proof-layers.md` |
| organ / module を差し替えたい | manifest、contract、organ folder | `docs/module-usage-index.md` |
| Thought Core や診断が読む新しい参照値を増やしたい | contract と owner-local reference surface | `docs/reference-surfaces.md` |

## Home Assistant Config Rule

For first-time setup in an external Home Assistant environment, start with
`docs/home-assistant-setup.md`. For action row fields, use
`docs/add-home-device.md` and `docs/home-control-action-authoring.md`. Keep
short command-shape overrides separate from full-schema Home Assistant state
proof, and keep `CheckTracking` / `CheckState` wording in those canonical docs.

## Change Flow

1. Make the local/private change in the selected config context.
2. Re-render generated env/config files when the source document requires it.
3. Run `.\sword.ps1 verify` or the named no-live helper.
4. For Home Assistant, confirm the selected config is not demo/default/template.
5. Use preview / dry-run / execute only when an exact live route has been
   reviewed and the proof layer is explicit.

`status`, `verify`, and `doctor` are no-live by default. You may still add
`-NoLive` in reports when you want the safety intent to be obvious, but it is
not a separate stronger mode for those commands.

Do not promote command submission, preview, dry-run, or HA-visible state match
into external observation or physical/device proof.

## Avatar / Self Mirror Rule

Use `examples/starter-profiles/projection-visual/README.md` when you want to
check whether the avatar is visibly moving in the browser. Self Mirror can
measure scenario-scoped visible motion such as `context_nod`,
`expression_visible_change`, and `dance_visible_motion`.

For system readers, the stable discovery file is
`runtime/visual-motion-analyzer/self-mirror-consumer-routes.json`. Thought Core
or diagnostics may use that file to understand which Self Mirror route/result
is relevant, but Self Mirror is still observation/evaluation only. It does not
prove voice intent, provider response quality, semantic dance quality,
TouchDesigner/projector output, Home Assistant action, external observation, or
physical/device proof by itself.
