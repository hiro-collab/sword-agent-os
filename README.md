# Sword Agent OS

Sword Agent OS は、AI エージェントを「思考」「反射」「環境認識」「家電操作」「表現」「表示」「記憶」「診断」といった交換可能な器官の組み合わせとして動かすための、ローカル AI 身体 OS です。

このリポジトリの標準例では、家の中で使う AI エージェントを構成します。ブラウザとマイクから入力を受け、Thought Core が考え、部屋や家電の状態を読み、Home Assistant 経由で家電を操作し、AITuber Kit と必要に応じて TouchDesigner でアバターや HUD を表示します。

![Projection Visual example](docs/assets/readme/projection-visual-example-1.png)

これは、単なるキャラクターチャット UI ではありません。アバターは OS の表示レイヤーの一つです。中の Thought Core や器官を差し替えることで、自律的な AI エージェントとしても、人が使うサイバー器官としても扱える構成を目指しています。

## 何ができるか

- 音声入力、ジェスチャー入力、Thought Core、環境認識、家電操作、アバター表示、投影表示を一つの system cell として起動できます。
- Projection Visual で、環境状態、反射状態、Thought Core の処理、Action Boundary、発話状態、表示状態を見ながら対話できます。
- Home Assistant の家電状態と、カメラから推定した部屋の明るさなどを別の根拠として扱えます。
- Home Assistant bridge を通じて、許可された家電操作を実行できます。
- 起動、停止、準備状態確認、スモークテスト、organ test pack をスクリプトから実行できます。
- 秘密情報、ローカルログ、撮影データ、実行時キャッシュを Git に入れない前提で運用できます。

## フォルダ構成

```text
sword-agent-os/
  README.md                         # この説明
  start-home-control-launcher.bat    # Windows での起動入口
  stop-home-control-launcher.bat
  scripts/                           # bootstrap / 起動 / readiness / smoke test
  manifests/                         # profile / service / organ / driver 定義
  runtime/                           # OS runtime の契約と骨格
  contracts/                         # organ 間の境界仕様
  policies/                          # safety / communication ルール
  control-plane/sword-voice-agent/    # 現在の Thought Core / control plane organ
  organs/                            # action / display / environment / expression など
  docs/                              # セットアップ、移行、開発者向け文書
  local/                             # Git 管理しないローカル資材
```

大きな実装は `organs/` や `control-plane/` の中にある nested checkout として扱います。トップレベルの `sword-agent-os` は、OS 全体の manifest、runtime 境界、policy、標準構成の正本です。

## clone する前に用意するもの

このリポジトリを clone しただけでは、会話、カメラ、家電操作、アバター表示、TouchDesigner 投影の全部は動きません。標準例を動かすには、Git に入れないローカル資材と外部アプリが必要です。

| 種類 | 用途 | 必須度 |
| --- | --- | --- |
| Windows PC | 全体の実行 | 必須 |
| PowerShell 7 | 起動・停止スクリプト | 必須 |
| Git | リポジトリ取得 | 必須 |
| Python と `uv` | Thought Core と Python organ | 必須 |
| Node.js と npm | AITuber Kit と Web GUI | 必須 |
| Chrome | Projection Visual とマイク入力 | 必須 |
| マイク | 音声入力 | 音声利用では必須 |
| カメラ | ジェスチャー、部屋の明るさ推定 | 推奨 |
| VOICEVOX | 音声合成 | 推奨 |
| LLM API key | Thought Core の自然文応答 | 通常は必要 |
| Home Assistant | 家電状態確認と操作 | 家電操作に必要 |
| TouchDesigner | 投影演出、外部表示 | 任意 |
| アバター/モデル素材 | ローカル表示 | 任意、ライセンスに従う |

`.env`、API key、device token、provider key、撮影データ、ローカルログ、個人用スクリーンショットは Git に入れないでください。

## インストール

まずトップレベルのリポジトリを clone します。

```powershell
git clone <sword-agent-os-repo-url>
cd sword-agent-os
```

ローカル用の workspace フォルダを作ります。

```powershell
pwsh -NoProfile -File .\scripts\bootstrap-workspace.ps1
```

control plane と organ checkout を確認します。最初は dry-run で、何が clone されるか確認してください。

```powershell
pwsh -NoProfile -File .\scripts\bootstrap-control-plane.ps1 -DryRun
pwsh -NoProfile -File .\scripts\bootstrap-organs.ps1 -DryRun
```

問題なければ実行します。

```powershell
pwsh -NoProfile -File .\scripts\bootstrap-control-plane.ps1
pwsh -NoProfile -File .\scripts\bootstrap-organs.ps1
```

標準例で主に使う依存関係を入れます。

```powershell
cd control-plane\sword-voice-agent
uv sync

cd ..\..\organs\expression\aituber-kit
npm install
```

その他の organ は、それぞれの README や起動ログに従って準備します。Launch Manager で特定サービスが unavailable / down になる場合は、その organ の README を確認してください。

## ローカル設定

`.env.example` がある場所では、`.env` を作成してローカル値を入れます。

```powershell
cd control-plane\sword-voice-agent
Copy-Item .env.example .env

cd ..\..\organs\expression\aituber-kit
Copy-Item .env.example .env
```

主に確認する設定です。

| 設定領域 | 役割 |
| --- | --- |
| Thought Core LLM 設定 | OpenAI 互換 base URL、model、API key |
| Thought Core endpoint | ローカル Thought Core API の URL |
| AITuber Kit 設定 | Projection Visual、音声出力、Thought Core 接続 |
| Home Assistant 設定 | URL、long-lived token、local API token、device mapping |
| Camera 設定 | MediaPipe / Camera Hub が使うカメラ名や入力 |
| VOICEVOX URL | ローカル音声合成 endpoint |

Home Assistant は、実際に家電を操作する場合に必要です。Home Assistant がなくても、source/static check、表示開発、no-live test の多くは実行できます。

## 起動方法

一番簡単な入口は Launch Manager です。

```powershell
.\start-home-control-launcher.bat
```

![Launch Manager overview](docs/assets/readme/launch-manager-overview.png)

ブラウザで次が開きます。

```text
http://127.0.0.1:8799
```

標準の Thought Core profile を選び、port や camera 設定を確認して、`Start Stack` を押します。停止は画面上のボタンか、次のコマンドで行います。

```powershell
.\stop-home-control-launcher.bat
```

並行検証や port 衝突の調査では、isolated port mode を使えます。

```powershell
pwsh -NoProfile -File .\scripts\start-launcher.ps1 -PortMode isolated_override -OpenBrowser
```

## 主な画面

通常 port mode の代表的な URL です。

| 画面 / service | URL | 用途 |
| --- | --- | --- |
| Launch Manager | `http://127.0.0.1:8799` | 起動、停止、準備状態確認 |
| AITuber Kit | `http://127.0.0.1:3000` | アバター UI |
| Projection Visual | `http://127.0.0.1:3000/projection-visual/` | アバター + HUD のメイン画面 |
| Thought Core health | `http://127.0.0.1:18787/health` | 思考 API の liveness |
| Environment State | `http://127.0.0.1:8790/health` | 環境 API の liveness |
| Home Assistant bridge | `http://127.0.0.1:8787/health` | 家電操作 bridge の liveness |
| TouchDesigner control GUI | `http://127.0.0.1:8788` | 表示 / 投影制御 |
| MediaPipe monitor | `http://127.0.0.1:8770/browser_camera_hub_viewer.html` | カメラ / ジェスチャー確認 |

Projection Visual の表示例です。

![Projection Visual room control](docs/assets/readme/projection-visual-example-2.png)

![Projection Visual environment HUD](docs/assets/readme/projection-visual-example-3.png)

![Projection Visual conversation](docs/assets/readme/projection-visual-example-4.png)

## 最初の動作確認

1. Launch Manager を起動し、主要サービスが ready になるのを待ちます。
2. Projection Visual を開きます。
3. Chrome のマイク権限を許可します。
4. 短い文を話すか入力します。

```text
聞こえていますか
```

5. 部屋や家電の状態を確認します。

```text
今、電気はついてる？
部屋は明るい？
```

6. Home Assistant が設定済みなら、低リスクな家電操作を試します。

```text
電気をつけて
電気を消して
```

Thought Core は、環境を観測し、Action Boundary で操作を preview / execute し、必要なら反映待ちをしてから再観測し、結果または不確実な点を返します。

## 検証コマンド

実機レビューの代わりにはなりませんが、最初の確認に便利なコマンドです。

```powershell
pwsh -NoProfile -File .\scripts\system.ps1 status -Profile thought-core-v0 -ManifestOnly
pwsh -NoProfile -File .\scripts\check-runtime-reflex.ps1
pwsh -NoProfile -File .\scripts\check-conscious-readiness.ps1
pwsh -NoProfile -File .\scripts\check-organ-readiness.ps1
pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1
pwsh -NoProfile -File .\scripts\run-organ-test-packs.ps1
```

compatibility smoke test です。

```powershell
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -RunManualTurn
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -RunManualTurn -RunSafeIntegrationProbes
```

実家電に影響する live action は、必ず対象、回数、間隔、停止条件、戻し方を決めてから実行してください。広い appliance fuzzing や長時間操作をいきなり実行しないでください。

## うまく起動できないとき

| 症状 | 確認すること |
| --- | --- |
| Launcher が開かない | PowerShell で script 実行できるか、`8799` port が空いているか |
| service が down のまま | Launch Manager の service card と各 organ README |
| AITuber Kit が down | `organs/expression/aituber-kit` で `npm install` 済みか |
| Thought Core が down | control-plane `.env`、LLM 設定、`18787` port |
| VOICEVOX が down | VOICEVOX を起動し、ローカル endpoint を確認 |
| カメラが動かない | 他アプリがカメラを掴んでいないか、カメラ名が合っているか |
| マイクが反応しない | Chrome のマイク権限、入力欄の focus |
| 家電操作が失敗する | Home Assistant URL / token、action catalog mapping |
| 電気の ON/OFF 判定がおかしい | Home Assistant state と camera 由来の `VISION LIGHT` を分けて見る |
| Dify compatibility が表示される | 通常の Thought Core 経路では Dify は必須ではありません。debug mode だけで確認します |
| TouchDesigner が反応しない | `.toe` project が開いているか、UDP target が合っているか |

## OS の構造

標準 profile は、システムを身体のように分けて扱います。

```text
speech / gesture input
  -> reflex layer
  -> Thought Core
  -> environment observation
  -> action boundary
  -> expression / display
  -> event journal and status projection
```

主な考え方です。

- `reflex` は、低遅延の観測やジェスチャーを扱います。
- `thought` は、turn 単位の推論、tool 選択、feedback、recheck を扱います。
- `environment` は、部屋、カメラ、家電の状態を集約し、根拠を混ぜずに出します。
- `action` は、Home Assistant などの driver 経由で許可済み操作を実行します。
- `expression` は、アバター、発話、ログ、HUD を表示します。
- `display` は、TouchDesigner などの投影・演出面に接続します。
- `runtime` と `manifests` は、起動、health、organ 接続の正本です。

各 module は差し替え可能であることを前提にしています。別の Thought Core や別の organ set を入れることで、用途を変えられます。

## 開発者向け入口

開発時はここから読みます。

- [Remote workstation setup](docs/remote-workstation-setup.md)
- [Thread startup guide](docs/thread-startup-guide.md)
- [Module usage index](docs/module-usage-index.md)
- [Legacy reference index](docs/legacy-reference-index.md)
- [Runtime overview](runtime/README.md)
- [Manifest overview](manifests/README.md)
- [Organ overview](organs/README.md)
- [Contract overview](contracts/README.md)

UI / HUD を変えたらブラウザで実画面を確認してください。action や state の挙動を変える場合は、source/static test、no-live test、live appliance claim を分けて扱います。

## 安全とローカルデータ

- `.env`、token、provider key、cookie、local memory、raw media、camera capture、machine-specific log は Git に入れません。
- ローカル専用のものは `local/`、runtime/cache、または各 organ の ignored フォルダに置きます。
- README に入れる画像は、秘密情報、ローカル絶対パス、ユーザー固有情報、raw sensor data が写っていないものだけにします。
- 実家電操作は物理環境に影響します。まず dry-run、no-live test、または範囲を絞った pilot で確認してください。
- TouchDesigner project、アバター、モデル、音声、SDK には個別のライセンスや再配布条件があります。

## 外部モジュールと謝辞

Sword Agent OS は、AITuber Kit、MediaPipe、Home Assistant、VOICEVOX、TouchDesigner、各種アバター / モデル素材など、複数の外部プロジェクトやアプリケーションと連携して動きます。利用・再配布・公開の前に、それぞれのライセンスと利用規約を確認してください。

この README のスクリーンショットは、ローカル環境の一例です。このリポジトリは、第三者のアバターモデル、VOICEVOX 音声、TouchDesigner project、Home Assistant device 設定の再配布権を与えるものではありません。
