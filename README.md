# Sword Agent OS

Sword Agent OS は、PC上でAIエージェントを動かすためのローカル実行基盤です。
会話、音声入力、アバター表示、状態確認、Home Assistant 経由の家電操作、
結果フィードバック、自己状態の点検、記憶をひとつの流れとして扱います。

<!-- front-door:system-at-a-glance -->
## 何のシステムか

Sword Agent OS は、ローカルPCを中心にした「声、身振り、思考、表示、環境状態、
家電操作、結果フィードバック、自己点検、記憶」をつなぐAIエージェント実行基盤です。
クラウドサービス単体、チャットボット単体、家電操作ツール単体、アバター画面単体、
MCPサーバー単体、スクリプト集ではありません。PC上の control-plane と複数の organ を
組み合わせて、人間の入力、エージェントの判断、アバターやHUDへの表示、Home Assistant
連携、確認レポートを層ごとに分けて扱います。

![Projection Visual のアバター表示、状態HUD、会話バブル、入力欄](docs/assets/readme/projection-visual-example-1.png)

上の画面が、人に見える代表的な姿です。中央のアバター、左右の状態HUD、
会話バブル、下部の入力欄を同じ Projection Visual 上で扱います。

流れを短く書くと、声、身振り、UI入力 → recognizer / input gate →
Thought Core / control-plane → Expression organ または Home Control / Home Assistant です。
各境界は、前段の観測を受け取りますが、前段の役割や判断権限を引き継ぎません。
Expression organ → アバター → Projection Visual / 会話バブル / TTS の出力も、
実行、外部観測、ユーザー確認を同一視せず、確認できた proof layer ごとに記録します。

内側では、人間の声、身振り、UI入力を recognizer / input gate が受け、
control-plane 内の Thought Core が会話内容や判断を決め、Expression organ が
アバター、Projection Visual、会話バブル、TTSに返します。Thought Core が
決めた応答文が、バブルとTTSの正本です。両者がずれる場合は、
どちらか一方を正しい表示として選ぶのではなく、表示面が別の権威を読んでいる
不具合として扱います。

人間が操作する導入/確認ルート、AIエージェントが実行中に使う runtime ルート、
Codex などの保守者が点検/修復する inspection ルートは別です。ChatGPT/Codex は
保守と検査の例であり、runtime が動くための必須部品ではありません。環境状態や
Home Control / Home Assistant 連携は別の境界として扱い、確認レポートや
proof layer は「何を確認したか」を分けて残します。

初めて使う人は、まず
`docs/first-run-operator-guide.md` を読んでください。必要なもの、Git clone、
ローカルファイルの置き場所、`.env` の作り方、起動、画面の開き方、
試し動作、停止確認までを順番に書いています。

この README は入口です。細かい設定や安全上の決まりは、下の表にある
専門文書に分けています。

## 重要な注意と免責

このプロジェクトは実験的なソフトウェアです。コードの相当部分は Codex などの
AI支援ツールを用いて作成・変更されており、保守者による網羅的な行単位レビューや、
独立した専門家によるセキュリティ監査は完了していません。構成の一貫性、正確性、
安全性、可用性、特定目的への適合性、継続的な保守を保証しません。

利用者は、コード、設定、依存関係、外部サービスとの接続、権限、データの保存先、
マイク・カメラ・Home Assistant・家電などへの作用を自ら確認し、隔離された
最小権限の環境で使用してください。本ソフトウェアは現状有姿で提供され、
適用法令で認められる最大限の範囲で、開発者、保守者および貢献者は、利用または
利用不能から生じる損害、データ損失、機器の誤動作、サービス停止その他の結果に
ついて責任を負いません。

このリポジトリが公開されていること自体は、利用、改変または再配布の許諾を
意味しません。ルートに明示的な `LICENSE` が追加されるまでは、適用される
著作権法に従ってください。セキュリティ上の前提と報告方法は `SECURITY.md` を
参照してください。この記載は法的助言ではありません。

<!-- front-door:thin-entry-rule -->
## 入口を薄く保つ基準

README に残すのは、初めて読む人が安全に最初の一歩を選ぶための情報だけです。

- 残すもの: 最初の安全コマンド、最初に読む文書、危険な誤解を止める proof boundary、
  近い専門文書への地図。
- 専門文書へ移すもの: 詳しい手順、長い参照表、設定の全項目、live route の証拠形式、
  module/organ の担当範囲、保守用チェックの詳細。
- 削除、または履歴へ送るもの: 閉じた一回限りの経路報告、退役 helper の案内、
  現在の専門文書と重複する古い説明、現在の標準構成と違う起動メモ。

長いから消すのではありません。入口で判断する必要がない内容を、正しい持ち場へ
移すか、現在の正本ではない履歴として扱います。

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
- 家電操作は、対象、回数、確認方法を決めた exact route で実行し、命令送信、
  HA上の状態、外部観測、物理的な動きは分けて記録します。
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
構いません。

Launcher の `Demo settings` と demo-safe 候補の扱いは
`docs/operate.md` を見てください。Start は家電操作や proof を実行しません。
Proof は別の明示ルートで扱います。

カメラ入力は Launcher の接続済みカメラ一覧から選び、必要なら `Refresh` で
再取得します。同じ表示名のカメラも別候補として扱い、選択にはローカルだけで
解決する不透明キーを使います。選択は Git 管理外のローカル状態へ保存され、
選んだ機器が一時的に見つからない時も別のカメラへ自動置換しません。詳しくは
`docs/operate.md` の Camera input selection を見てください。

## 初回導入の確認

最初の安全確認は次の流れです。

```powershell
.\scripts\install-distribution.ps1 -Profile standard
.\scripts\render-env-files.ps1 -Profile standard -Force
.\scripts\validate-manifests.ps1
.\scripts\check-distribution-pins.ps1 -Strict
.\scripts\check-launch-readiness.ps1
.\scripts\run-organ-test-packs.ps1
```

各コマンドが何を確認するかは `docs/verification-commands.md` を見てください。
失敗した時は `docs/troubleshooting.md` を見てください。

## ユーザーに見せるデモ前の確認

画面、音声、アバター、家電操作を人に見せる前に、preflight で
「今その場で見せてよい範囲」を分けて確認します。

```powershell
.\scripts\run-visible-demo-preflight.ps1
```

既定では provider/network STT/TTS、マイク、カメラ、Home Assistant /
Home Control の命令送信は行いません。詳しい demo-safe settings、
operator-confirmed switch、proof boundary は `docs/operate.md` と
`docs/proof-layers.md` を見てください。

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
| セキュリティ上の前提、免責、脆弱性の報告 | `SECURITY.md` |
| Codex保守担当のスレッド分割とモデル配分 | `governance/development/codex-threading.md`, `governance/development/codex-model-selection.md` |

古い一回限りの報告、起動メモ、旧索引は、現在の正本ではありません。
残すべき内容は上の専門文書へ移し、重複した古い文書は増やさない方針です。

## 配布構成

標準構成は README の文章ではなく、manifest で管理します。

- `manifests/body-plans/`: 体の役割。
- `manifests/distributions/`: インストールできる構成。
- `manifests/releases/`: 人間が読むバージョン情報。
- `manifests/driver-manifests/` と `contracts/`: 外部連携やデータ受け渡しの決まり。

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

Home Control は、対象と確認範囲を決めた exact route として扱います。設定は
`docs/home-assistant-setup.md`、操作追加は `docs/add-home-device.md`、
live route と proof wording は `docs/live-home-control-proof.md` を見てください。
Home Assistant の状態一致だけを、物理的に動いた証拠へ変換しないでください。

## 外部プロジェクト

一部の部品は、外部プロジェクトを同梱または特定バージョンに固定して使います。
ライセンスやバージョン更新の情報は、それぞれの専門文書や manifest に置きます。
README に重複して書き増やさないでください。

迷ったら、この README は短く保ち、詳しい内容は最も近い専門文書に移します。
