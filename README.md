# Sword Agent OS

Sword Agent OS は、PC上でエージェントを動かすためのローカルシステムです。
会話、音声入力、アバター表示、状態確認、Home Assistant 経由の家電操作を
ひとつの流れとして扱います。

初めて使う人は、まず
`docs/first-run-operator-guide.md` を読んでください。必要なもの、Git clone、
ローカルファイルの置き場所、`.env` の作り方、起動、画面の開き方、
試し動作、停止確認までを順番に書いています。

この README は入口です。細かい設定や安全上の決まりは、下の表にある
専門文書に分けています。

## 最初にやること

1. 必要なソフトと機器を用意する。
2. このリポジトリを clone する。
3. `gesture_model.pkl`、VRM、音声や動画などのローカル素材を指定場所に置く。
4. `.env` がない状態で基本確認を行う。
5. `.env` にAPIキーや Home Assistant の接続情報を書く。
6. 標準サンプルの起動用バッチファイルを開き、Launch Manager から各画面を開く。
7. 会話、音声入力、アバター、状態画面、家電操作を、用意できた範囲で試す。
8. 起動したものを安全に停止できることを確認する。

詳しい手順:

- `docs/first-run-operator-guide.md`

<!-- Safety Default -->
## 安全の基本

インストール、状態確認、診断コマンドだけでは、マイク、カメラ、
Home Assistant、実家電操作は勝手に動きません。

- APIキー、トークン、家電ID、ローカルの絶対パス、生ログ、生音声、
  画像、動画、文字起こし全文は Git に入れないでください。
- Home Assistant の状態が一致していることと、実物が物理的に動いたことは
  別の確認です。
- `CheckState` は実行後または restore 後の Home Assistant 状態確認です。
  It is a post-action / post-restore state check, not physical proof.
  実行前は `CheckTracking` などの metadata 確認と分けて扱います。
- 家電操作は、対象、回数、確認方法を決めた上で、必要な時だけ実行します。
- 公開版として使えるかどうかは、別途レビューが必要です。
- 制限付き環境で clone や dependency download が止まる場合は、必要な
  install command だけ network permission を許可して再実行します。

## よく使うコマンド

リポジトリ直下で実行します。

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 doctor
.\sword.ps1 start
.\sword.ps1 hold-live
```

`start` は、既定では起動予定の確認です。実際に起動する時は、
起動手順に沿ってバッチファイルまたは明示的な実行オプションを使います。
`.\sword.ps1 start -Run` は通常、標準サンプル Launcher を起動または再利用して
readiness/status を確認するだけです。Launcher は本体 runtime stack の必須条件では
なく、各ユーザーの環境では別の launch system から同じ runtime surfaces を起動しても
構いません。旧スタック委譲が必要な互換確認では `-CompatLegacyDelegate` を明示してください。

Launcher の左メニューには `Demo settings` があります。fresh clone の
demo-safe 候補はすべて `enabled=false` から始まり、ユーザーの選択は
gitignored なローカル Launcher 状態に保存されます。Start は家電操作や
proof を実行しません。Demo は enabled な demo-safe 候補だけを対象にし、
Proof は別の明示ルートで扱います。

## 初回導入の確認

最初の安全確認は次の流れです。

```powershell
.\scripts\install-distribution.ps1 -Profile standard
.\scripts\render-env-files.ps1 -Profile standard -Force
.\scripts\validate-manifests.ps1
.\scripts\check-distribution-pins.ps1 -Strict
.\scripts\check-launch-readiness.ps1
.\scripts\run-organ-test-packs.ps1
.\scripts\run-compat-smoke.ps1
```

各コマンドが何を確認するかは `docs/verification-commands.md` を見てください。
失敗した時は `docs/troubleshooting.md` を見てください。

## ユーザーに見せるデモ前の確認

画面、音声、アバター、家電操作を人に見せる前に、次の preflight で
「今その場で見せてよい範囲」を分けて確認します。

```powershell
.\scripts\run-visible-demo-preflight.ps1
```

この script は既定で provider/network STT/TTS、マイク、カメラ、
Home Assistant / Home Control の命令送信を行いません。Launch Manager、
Thought Core、AITuber / Projection Visual、VOICEVOX などのローカル到達性と、
デモで必要な確認項目を summary/class だけで返します。

ユーザーまたは操作担当者が実際に確認した画面・音声・AC 操作面は、
明示的な switch で折り込みます。

```powershell
.\scripts\run-visible-demo-preflight.ps1 `
  -OperatorConfirmedAvatarForeground `
  -OperatorConfirmedChromeWindowHygiene `
  -OperatorConfirmedAudioHeard `
  -OperatorConfirmedAcControlSurfaceReadable `
  -OperatorConfirmedRestoreOffReadable
```

AC を見せる場合は、Chrome / Home Assistant の見える操作面で現在状態と
戻し先が読める時だけ進めます。正方向の操作は最大1回、off / restore も
必要かつ読める時に最大1回、retry は0、無関係な家電ループは0です。
これは Home Control `/actions` catalog の成功証明ではありません。

画面の前景、Chrome window の整理、VOICEVOX のローカル再生、ブラウザ上の
会話応答、アバターの見える動き、物理的な家電変化は別の層です。script の
fallback 文字列をそのまま使うと、Codex / Claude でも同じ止め方で報告できます。

## 文書の場所

| Need | Authority |
| --- | --- |
| 初めて使う人向けの導入と動作確認 | `docs/first-run-operator-guide.md` |
| 日常の起動、停止、状態確認 | `docs/operate.md` |
| 全体構成 | `docs/architecture.md` |
| 使える機能の選び方 | `docs/capability-packs.md` |
| `.env` やローカル設定 | `docs/customize.md`, `docs/local-configuration.md` |
| 配布物とバージョン固定の確認 | `manifests/README.md`, `docs/standard-distribution-map.md`, `docs/distribution-maintenance.md` |
| 各部品の担当範囲 | `docs/module-usage-index.md` |
| Home Assistant の準備と家電操作の書き方 | `docs/home-assistant-setup.md`, `docs/add-home-device.md`, `docs/home-control-action-authoring.md` |
| 家電操作で何を確認できたと言えるか | `docs/live-home-control-proof.md`, `docs/proof-layers.md` |
| 確認コマンドと失敗時の見方 | `docs/verification-commands.md`, `docs/troubleshooting.md` |

古い一回限りの報告、起動メモ、旧索引は、現在の正本ではありません。
残すべき内容は上の専門文書へ移し、重複した古い文書は増やさない方針です。

## 配布構成

標準構成は README の文章ではなく、manifest で管理します。

- `manifests/body-plans/`: 体の役割。
- `manifests/distributions/`: インストールできる構成。
- `manifests/releases/`: 人間が読むバージョン情報。
- `manifests/driver-manifests/` と `contracts/`: 外部連携やデータ受け渡しの決まり。
- `manifests/compat-aliases/`: 互換用。新しい機能はここに増やしません。

## 確認できた範囲を分ける

このプロジェクトでは、「何が確認できたか」を狭く書きます。

- ファイルや設定を読んだだけなら、ファイルや設定の形だけが確認済みです。
- 家電連携ブリッジや一覧を読んだだけなら、実行前の準備だけが確認済みです。
- 画面やローカルサービスが起動しただけなら、画面やサービスの到達だけが確認済みです。
- 命令を送れたことと、Home Assistant 上の状態が変わったことは別です。
- Home Assistant 上の状態と、実物が物理的に動いたことも別です。
- 公開準備完了、リリース準備完了、最終レビュー完了は、別の判断です。

命令前からすでに目的の状態だった場合は、その命令で実物が動いたとは書きません。
その場合は「すでにその状態だったので、命令は不要だった」と書きます。

## Home Control

Home Control は、誤操作を避けるために範囲を決めて扱います。通常は次の順で
確認します。

1. 設定ファイルに必要な情報がある。
2. 家電連携ブリッジが起動できる。
3. 操作候補の一覧に対象操作がある。
4. 実行してよい条件や確認方法が定義されている。
5. 命令前の現在状態が読める。
6. 必要な場合だけ、確認済みの操作を最大1回送る。
7. 命令後の Home Assistant 上の状態を読む。
8. 物理的な動きまで言うなら、別途カメラ、センサー、人間の目視などで確認する。

Home Assistant の状態一致だけを、物理的に動いた証拠へ変換しないでください。

## 外部プロジェクト

一部の部品は、外部プロジェクトを同梱または特定バージョンに固定して使います。
ライセンスやバージョン更新の情報は、それぞれの専門文書や manifest に置きます。
README に重複して書き増やさないでください。

迷ったら、この README は短く保ち、詳しい内容は最も近い専門文書に移します。
