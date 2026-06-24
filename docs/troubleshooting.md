# Troubleshooting

This is the full troubleshooting table for Sword Agent OS.

Start with `README.md` for first-run setup. Use this document when the short
README checklist does not cover the symptom, or when a verification report
needs a precise failure classification.

## Quick Table

| Symptom | What To Check |
| --- | --- |
| Launcher が開かない | PowerShell で script 実行できるか、`8799` port が空いているか確認します。 |
| fresh clone なのに古い service が見える | 既存 workspace の Launch Manager / stack が残っていないか確認します。古い検証用なら停止し、並行検証が必要なら `start-launcher.ps1 -PortMode isolated_override` を使います。 |
| service が down のまま | Launch Manager の service card と各 organ README を確認します。 |
| source pin が合わない / `ahead_of_manifest` が出る | `scripts/check-distribution-pins.ps1 -Profile standard` で対象 organ を確認します。`ahead_of_manifest` は nested repo が manifest より進んでいる正式採用待ち状態です。配布前は `-Strict` で失敗扱いにし、親 manifest 更新と fresh install proof を行います。詳しくは `docs/distribution-maintenance.md` を見ます。 |
| `git_unreadable` が出る | 現在の実行ユーザーや制限付き環境が nested checkout の Git 情報を読めていません。通常ユーザー端末で再実行するか、診断目的で exact path の `safe.directory` override を使います。これは真の source pin mismatch とは分けて扱います。 |
| AITuber Kit が down | `organs/expression/aituber-kit` で `npm install` 済みか確認します。 |
| Thought Core が down | control-plane `.env`、LLM 設定、`18787` port を確認します。 |
| VOICEVOX が down | `scripts/check-voicevox-readiness.ps1` で endpoint-first に確認します。必要な時だけ通常ユーザー端末で `-StartIfNeeded` を付け、既存 VOICEVOX app の検出/起動を試します。install/update/download、global audio device、PATH/env 変更はしません。 |
| カメラが動かない | 他アプリがカメラを掴んでいないか、カメラ名が合っているか確認します。 |
| `model_not_found` / Camera Hub topics timeout | `gesture_model.pkl` がある場合は `organs/reflex/mediapipe-sword-sign/gesture_model.pkl` に置いたか確認します。ない場合は、Camera Hub / gesture proof は未準備として分け、カメラ不要の no-live / source-static 確認だけを先に進めます。これはローカル専用資材なので Git には入れません。 |
| アバター / VRM が表示されない | `NEXT_PUBLIC_SELECTED_VRM_PATH` は AITuberKit の `public/vrm` 配下を指す `/vrm/<file>.vrm` です。`scripts/doctor-distribution.ps1 -Profile standard` で、選択中のVRMが現在の checkout に存在するか確認します。 |
| マイクが反応しない | Chrome のマイク権限、入力欄の focus を確認します。 |
| 家電操作が失敗する | Home Assistant URL / token、action catalog mapping を確認します。 |
| API key や token を入れたのに家電が動かない | `THOUGHT_CORE_TOOLS_ADAPTER` が `mock` なら no-live simulation です。実家電へ送る場合だけ `home_control` に変更します。 |
| Home Control bridge が `config_error` になる / `/actions` が 503 になる | bridge process に generated organ `.env` が読み込まれていない、token が placeholder/too-short、または `HOME_CONTROL_CONFIG` が意図した config を指していない可能性があります。`scripts/start-home-control-bridge.ps1 -CheckOnly` で secret 値を出さずに health、action count、`config_error_kind`、`cause_code` を確認します。bridge helper は organ-local `.uv-cache` を一時利用するので、通常は persistent `UV_CACHE_DIR` を変更しません。詳細分類は `docs/live-home-control-cause-trail.md` を見ます。 |
| Home Assistant state 確認で URL / entity を調べる必要が出る | まず `scripts/start-home-control-bridge.ps1 -CheckState -ActionId <allowed-action-id>` を使います。helper が state check できない時だけ、設定と Home Assistant 側を個別に確認します。 |
| `-CheckState` を全 action にかけると `matched` が 0 件になる | `-CheckState` は post-action / restore 後の確認です。実行前 preflight ではありません。実行前は `-CheckOnly` で health/catalog、`-CheckTracking -ActionId <allowed-action-id>` で `control_type` / `state_authority` / `verification.mode` / state tracking metadata と `live_test_readiness` を確認します。`tracked` 以外は HA state proof の対象ではありませんが、`restore_required=false` の command-stimulus route では command submission の刺激として使えます。その場合、current state unknown は proof limitation として返し、HA state proof とは主張しません。 |
| Environment State に家電情報が出ない | 中央 env の変更を `render-env-files.ps1 -Profile standard -Force` で organ `.env` へ反映したか確認します。さらに `organs/action/home-assistant-server/config/home-control.yaml` が `home-control.example.yaml` と同じ demo 設定ではないか、`.cache/home_control/events.jsonl` に成功 action event があるか確認します。 |
| Environment State / `LIGHT EST` が review で信頼できるか不安 | `scripts/check-rr003-env-state-review-preflight.ps1` を使い、`/environment/current` の周期更新、source freshness、room-light evidence の変化、HUD の `Action Mode` を分けて確認します。`unknown/daylight` や low-confidence のままなら `available-but-not-decisive-camera-light-estimate` と扱い、電灯 ON/OFF proof とは主張しません。`Action Mode UNKNOWN` は runtime/status wiring または再起動反映の gap です。`Bridge OK` は接続状態だけで、live Home Control mode の証明ではありません。 |
| `uv --env-file ..\home-assistant-server\.env` が失敗する | Windows では `uv --env-file` に渡す相対 backslash path が崩れることがあります。`$EnvPath = (Resolve-Path ..\home-assistant-server\.env).Path -replace "\\", "/"` のように forward slash 化した絶対 path を渡します。 |
| Python version / interpreter が分からない | `PATH` や古い thread 前提で推測せず、まず `uv python find` と `uv python list --only-installed` を見ます。特定 organ の実行 interpreter はその organ directory で `uv run python --version` を確認します。必要な場合だけ command-scoped に `UV_PYTHON=<version>` を指定し、persistent `PATH` や machine-wide env は変更しません。 |
| クラウド開発環境 / AI エージェント / CI などの制限付き環境で `uv` cache 書き込みや Git ownership warning が出る | 通常のローカル端末で再実行するか、必要に応じて書き込み可能な local cache を `UV_CACHE_DIR` に指定します。これは利用中の検証環境の制限による摩擦であり、通常 install 手順の必須設定ではありません。 |
| 制限付き環境で GitHub clone / nested checkout / dependency download が止まる | README の install step として必要な同じ command なら、network permission を許可して再実行します。通常のローカル install に管理者権限が必須という意味ではありません。 |
| test workspace に `sword-agent-os` が既にある | 上書きせず timestamp 付き sibling directory に clone するか、意図して clean にした workspace でやり直します。既存の `sword-agent-os` directory / existing `sword-agent-os` directory をそのまま上書きしないでください。 |
| install 中に `npm audit` vulnerability が表示される | npm の依存監査警告です。現在の install / readiness / no-live smoke の pass/fail 判定とは別に読みます。公開運用や依存更新の前には、対象 organ で別途 `npm audit` と影響範囲を確認してください。 |
| 電気の ON/OFF 判定がおかしい | Home Assistant state と camera 由来の `LIGHT EST` を分けて見ます。SwitchBot remote-style のライトは `stateless_toggle` の場合があり、押すたびに状態が反転しても HA では現在 on/off が `unknown` のままです。その場合は `light_on` / `light_off` を HA state proof 可能とは扱わず、`verification.mode: external_observation` や別センサー/目視確認に分けます。 |
| cover / vacuum は state tracking できそうに見える | 現在 state が読めることと、操作後の完了状態を信頼できることは別です。read-only state review と明示GO付きの execute/wait/check proof が通ってから、対象 action に `expected_effect`、`verification.mode: ha_state`、必要なら `accepted_states` / wait window を足します。vacuum は全 domain 件数ではなく、script が実際に target する `expected_effect.entity_id` だけで `CheckState` します。cover は `state=open` のまま `current_position` だけ動くことがあるため、`verification.position` に `current_position` の `min` / `max` threshold を設定し、state と position の両方が post-state で一致するまで `ha_state` に昇格しません。 |
| `door_close` / `door_open` は動いたが closed/open proof にならない | live execute が成功しても、複数 cover の state と `current_position` が食い違う場合は `command_ack_only` のまま扱います。2026-06-09 の実証では restore に追加 `door_open` が必要でした。target/group behavior を確認し、`verification.position` の threshold を通すまで HA state proof には昇格しません。 |
| `aircon_on` / `aircon_off` は submitted だが climate が変わらない | 現行 action が switch-wrapper の場合、script submission や switch distribution の変化は AC mode proof ではありません。climate entity が期待 mode に変わる climate-domain action を別に設計・実証するまで `command_ack_only` として扱います。 |
| カメラが1フレーム読めたのに家電 proof にならない | no-save camera check は観測経路の readiness だけを示します。家電の物理状態 proof にするには、保存しない redacted summary の範囲、対象 action、観測タイミング、stop 条件を別途決めた scoped observation run が必要です。toggle-only light は true on/off proof として扱わず、`scripts/run-home-control-light-proof.ps1` も directional light proof helper ではなく retired/hold helper として `light_toggle` と外部観測要件を返します。standard stack が MediaPipe/VSP でカメラを掴んでいる時は、独立 no-save observation route を明示します。 |
| Home Assistant backup API が失敗する | まず API failure と rollback safety を分けます。日次自動バックアップや UI で作成済みのバックアップが確認できる場合は `backup-external` として記録し、設定変更後は config check と対象 domain reload を別 proof として確認します。バックアップがあることは家電操作や物理状態の proof ではありません。 |
| TouchDesigner が反応しない | `.toe` project が開いているか、UDP target が合っているか確認します。 |

## Classification Notes

Keep environment friction separate from product failure. Restricted execution
contexts can produce uv cache, Git ownership, GitHub clone, nested checkout, or
dependency download errors that should be retried in a normal local terminal or
with an explicitly writable local cache before they are treated as product
regressions.

Keep proof layers separate. Install/readiness pass, no-live/mock pass, runtime
browser proof, local-media replay, real camera proof, real microphone proof,
Home Assistant state proof, and physical appliance confirmation are different
claims.
