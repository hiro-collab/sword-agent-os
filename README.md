# Sword Agent OS

Sword Agent OS は、AI エージェントを「思考」「反射」「環境認識」「家電操作」「表現」「表示」「記憶」「診断」といった交換可能な器官の組み合わせとして動かすための、ローカル AI 身体 OS です。

このリポジトリの標準例では、家の中で使う AI エージェントを構成します。ブラウザとマイクから入力を受け、Thought Core が考え、部屋や家電の状態を読み、Home Assistant 経由で家電を操作し、AITuber Kit と必要に応じて TouchDesigner でアバターや HUD を表示します。

![Projection Visual example](docs/assets/readme/projection-visual-example-1.png)

上の画像は標準表示例です。これは、単なるキャラクターチャット UI ではありません。アバターは OS の表示レイヤーの一つです。中の Thought Core や器官を差し替えることで、自律的な AI エージェントとしても、人が使うサイバー器官としても扱える構成を目指しています。

## 標準ディストリビューションの流れ

Sword Agent OS は、用途に合わせて organ / module を組み替えられる OS です。
このリポジトリの標準ディストリビューションでは、家の中で使う AI エージェントを
例にしています。

標準構成の典型的な runtime flow では、カメラ側の reflex organ が刀印ジェスチャーを
見ます。ユーザーが刀印を出すと、それが入力ゲート、つまり音声入力開始の合図になります。
これは「OK Google」のような wake word を声で言う代わりに、手のジェスチャーで
入力開始を伝える仕組みです。これが "Sword" という名前の由来でもあります。

入力された音声は Thought Core に渡され、必要に応じて部屋や家電の状態確認、
Home Assistant 経由の操作 preview / 実行、音声応答、アバターの動き、Projection Visual
の HUD 表示、任意の TouchDesigner 表示につながります。no-live/mock 検証は、この
実カメラ認識、実マイク入力、live 家電操作、物理家電動作の proof とは分けて扱います。

標準構成の organ checkout、local-only asset slot、proof layer、live 操作境界を
まとめて確認したい場合は、`docs/standard-distribution-map.md` を参照してください。

<img src="docs/assets/readme/sword-sign-gesture.png" alt="刀印ジェスチャー" width="220">

刀印は、人差し指と中指をそろえて伸ばし、薬指と小指を折って親指で押さえる手形を
目安にしています。

## 15分 quick-start

標準構成をまず起動して、画面と基本入力を確認したい人向けの最短ルートです。
目安は、clone が成功し、必要な local input が手元にある状態から 15 分程度で
install、readiness、smoke、Launch Manager、Projection Visual / AITuber 到達までを
確認することです。Home Assistant の実家電操作や TouchDesigner 投影は後から追加できます。

```powershell
git clone <sword-agent-os-repo-url>
cd sword-agent-os

pwsh -NoProfile -File .\scripts\show-version.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard -DryRun
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard

notepad local\env\sword-agent-os.env
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard -Force
pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1
pwsh -NoProfile -File .\scripts\check-voicevox-readiness.ps1
pwsh -NoProfile -File .\scripts\run-organ-test-packs.ps1
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc -RunManualTurn -RunSafeIntegrationProbes

.\start-home-control-launcher.bat
```

最小構成で LLM を使わずに表示や起動だけ確認する場合は、
`local\env\sword-agent-os.env` で `THOUGHT_CORE_LLM_ENABLED=false` にします。
実 LLM 応答を試す場合は `THOUGHT_CORE_LLM_API_KEY` または互換 provider の
API key を入れます。実家電操作をしない場合、Home Assistant token は後で設定できます。

起動後は Launch Manager で主要 service が ready になるのを待ち、
Projection Visual を開いて次のような短い入力から確認します。
音声出力まで含める場合、VOICEVOX が down なら通常ユーザー端末で
`scripts\check-voicevox-readiness.ps1 -StartIfNeeded` を実行してから
Start Stack をやり直します。音声出力を今回の proof に含めない場合だけ、
Launch Manager 側の voice check を skip する判断として分けて記録します。

```text
聞こえていますか
```

この quick-start は no-live/mock を基本にします。実カメラ、実マイク、刀印ゲート、
Home Assistant 実操作は、対象、回数、戻し方、停止条件を決めた別レーンで確認します。

## 読む人別ガイド

| 読む人 | まず読む節 | ゴール |
| --- | --- | --- |
| 標準構成を起動したい人 | `15分 quick-start`、`ローカル設定`、`起動方法` | 画面を開き、基本入力と表示を確認する |
| Home Assistant / 実家電を試す人 | `ローカル設定`、`最初の動作確認`、`安全とローカルデータ` | 家電状態確認と低リスク操作を安全に確認する |
| organ / module を開発する人 | `OS の構造`、`開発者向け入口`、`検証コマンド` | organ の差し替え、契約、テストを把握する |
| Codex 複数スレッドで開発管理する人 | `開発用 / Codex 用 workspace セットアップ`、`安全とローカルデータ` | coordination / worktree / local artifact の境界を守る |

## 構成レーン

| レーン | 目的 | 追加で必要なもの | 主な env / 注意 |
| --- | --- | --- | --- |
| A. 最小構成 / no-live | clone 後に install / readiness / mock/static 動作を確認する。画面・入力確認は次の runtime/browser lane として分ける | Git、PowerShell 7、Python/uv、Node/npm、Chrome | `THOUGHT_CORE_LLM_ENABLED=false` で LLM なし確認可。Home Assistant token は後回し可 |
| B. LLM あり標準構成 | Thought Core の自然文応答を確認する | LLM provider の API key | `THOUGHT_CORE_LLM_API_KEY`、必要に応じて `THOUGHT_CORE_LLM_MODEL` / `THOUGHT_CORE_LLM_BASE_URL` |
| C. Home Assistant live家電 | 家電状態確認と低リスク操作を確認する | Home Assistant、対象家電、戻し方 | `HOME_ASSISTANT_TOKEN`、`HOME_CONTROL_API_TOKEN`、device mapping。実操作は対象/回数/停止条件を決める |
| D. 開発 / Codex workspace | organ 変更、複数 thread、coordination を使う | private coordination repo は任意 | 通常利用と混ぜず、`coordination/`、`local/`、`worktrees/`、`_codex/` を GitHub 公開対象にしない |

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
```

大きな実装は `organs/` や `control-plane/` の中にある nested checkout として扱います。トップレベルの `sword-agent-os` は、OS 全体の manifest、runtime 境界、policy、標準構成の正本です。

通常利用に必要なのは、この `sword-agent-os/` 本体と、その中に取得する
`control-plane/` / `organs/` の nested checkout です。`../coordination/`,
`../worktrees/`, `../_codex/`, `../local/` は複数エージェント開発や
Codex 作業用の workspace-local 領域であり、通常利用では作成不要です。

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
| `ffmpeg` / `ffprobe` | MediaPipe / media smoke の test source と診断 | no-camera compat smoke では必要 |
| `mediamtx` | Camera Hub / MediaPipe stream bridge の起動 | MediaPipe / compatibility smoke では必要 |
| マイク | 音声入力 | 音声利用では必須 |
| カメラ | ジェスチャー、部屋の明るさ推定 | 推奨 |
| MediaPipe gesture model | Camera Hub のジェスチャー分類。`organs/reflex/mediapipe-sword-sign/gesture_model.pkl` にローカル配置 | カメラ/ジェスチャー利用では必須 |
| Custom VRM model | 標準の tracked sample 以外のアバター表示。ライセンス済み `.vrm` を `organs/expression/aituber-kit/public/vrm/` にローカル配置 | 任意 |
| VOICEVOX | 音声合成 | 推奨 |
| LLM API key | Thought Core の自然文応答 | 通常は必要 |
| Home Assistant | 家電状態確認と操作 | 家電操作に必要 |
| TouchDesigner | 投影演出、外部表示 | 任意 |
| アバター/モデル素材 | ローカル表示 | 任意、ライセンスに従う |

`.env`、API key、device token、provider key、撮影データ、ローカルログ、個人用スクリーンショットは Git に入れないでください。

初回検証で使う local-only 入力資材は、製品として特定のフォルダ名を要求しません。
手元の「準備済みローカル入力」や「準備済みローカル資材 bundle」から、必要な値や
ファイルだけを配置します。`_secret_inputs` のような名前は test harness や手元検証の
例であり、README の必須 product convention ではありません。secret 値は log、screen
shot、message、commit、push に含めないでください。

検証環境に `_secret_inputs\scripts\prepare-local-inputs.ps1` が用意されている場合は、
local-only helper として使えます。これは env/config、gesture model、VRM などの配置先を
手早く整えるための補助であり、GitHub からの通常 install に必須のフォルダではありません。
helper の出力や report でも secret 値、raw `.env`、raw media、private path は共有しません。

### MediaPipe gesture model の準備

`gesture_model.pkl` は、Camera Hub のジェスチャー分類で使う local-only model
です。Git には入れません。手元にあるかどうかで、初回セットアップの進め方が
変わります。

手元に `gesture_model.pkl` がない場合:

- clone、distribution install、dependency install、中央 env 作成などは先に進められます。
- ただし標準の launch readiness や Camera Hub 起動は
  `model_not_found` / Camera Hub topics timeout で止まることがあります。
- カメラ/ジェスチャーを使わない source/static check や no-live の一部だけを確認し、
  full readiness / runtime proof / gesture proof は model 準備後に分けて実行します。
- 作成元、取得元、コピー元が不明な `.pkl` は公開 Git や配布物に入れず、license と
  provenance を確認してからローカルに置いてください。

手元に `gesture_model.pkl` がある場合:

- organ checkout 作成後、次の場所にファイル名を変えずに置きます。

```text
organs\reflex\mediapipe-sword-sign\gesture_model.pkl
```

- その後、起動前チェックで model が見つかるか確認します。

```powershell
pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1
```

この model は local-only asset です。`.env` や VRM と同じく、commit / push /
公開 screenshot / raw log には含めないでください。

## インストール

### ワンタッチ配布インストール

初めて標準構成を入れる場合の入口です。通常は、標準 distribution installer
を使います。control plane と各 organ の checkout、ローカル `.env` 生成、
依存関係の導入をまとめて実行できます。

```powershell
git clone <sword-agent-os-repo-url>
cd sword-agent-os

pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard -DryRun
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard
```

同じ test workspace に既存の `sword-agent-os` directory がある場合は、上書きせず、
timestamp 付きの別 directory に clone するか、意図して clean にした workspace で
やり直します。

クラウド開発環境 / AI エージェント / CI などでは、GitHub clone、nested checkout、
dependency download が network permission によって一度止まることがあります。
README の install step として必要な同じ command なら、network permission を許可して
再実行します。通常のローカル端末での install に管理者権限が必須という意味ではありません。

`-DryRun` は clone / env 生成 / dependency install の予定だけを表示します。
通常インストール後に利用者が最初に編集するファイルは
`local\env\sword-agent-os.env` です。この中央 env から、各 organ の `.env`
が生成されます。既存の `.env` や `config/home-control.yaml` はデフォルトでは
上書きしません。作り直したい場合だけ `-ForceEnv` を付けます。

初回の no-live/mock install-readiness lane は、ここで install が終わった後に
中央 env と local-only asset を配置し、必要なら organ `.env` を再生成してから
readiness / smoke を見るところまでです。これは Launch Manager start、Start Stack、
browser UI、実マイク、実カメラ、live Home Assistant、物理家電の proof とは別に扱います。

```powershell
notepad local\env\sword-agent-os.env
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard -Force
pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1
pwsh -NoProfile -File .\scripts\run-organ-test-packs.ps1
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc -RunManualTurn -RunSafeIntegrationProbes
```

`-MediapipeVideoSource testsrc` は、実カメラを使わない compatibility smoke 用です。
実カメラで Camera Hub / gesture proof を見る場合は、別 lane としてカメラ権限、
`gesture_model.pkl`、media source、runtime/browser 状態を確認してください。

準備済みローカルメディアがある環境では、no-live/mock install-readiness の後に
任意の local-media replay preview を挟めます。これは private な `local/media/`
を使う repeatability lane で、asset id と redacted summary だけを扱います。
raw video、raw audio、frame、transcript、private absolute path は共有しません。

```powershell
pwsh -NoProfile -File .\scripts\run-local-media-replay.ps1 -Mode camera-hub -AssetId gesture.sword.20260603
pwsh -NoProfile -File .\scripts\run-local-media-replay.ps1 -Mode camera-hub -AssetId gesture.victory.20260603
pwsh -NoProfile -File .\scripts\run-local-media-replay.ps1 -Mode camera-hub -AssetId gesture.open_hand.20260603
pwsh -NoProfile -File .\scripts\run-local-media-replay.ps1 -Mode room-light -AssetId vision.room_light.on.20260603
pwsh -NoProfile -File .\scripts\run-local-media-replay.ps1 -Mode room-light -AssetId vision.room_light.off.20260603
```

`run-local-media-replay.ps1` は command-preview-only helper です。`local/media/media-index.json`
を asset id で読み、Camera Hub replay や room-light replay の command shape を
`<workspace>` placeholder 付きで表示します。メディア再生、実カメラ/実マイク起動、
generated output 作成、live Home Assistant 実行は行いません。

複数の proof layer を一度に見失わないための入口として、full install verification
helper もあります。デフォルトでは no-live/no-device の source/static、dry-run、
preview だけを集約し、実カメラ、実マイク、virtual audio、gesture gate、live
Home Assistant は `held` または `blocked` として分離表示します。

```powershell
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1 -RunNoLiveSmoke
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1 -RunRuntimeHttpChecks
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1 -WorkspaceRoot <fresh-clone-root> -SecretInputsRoot <private-secret-inputs-root>
```

live/device layer を開く場合も、flag を明示します。helper は raw media、raw audio、
raw transcript、raw screenshot、secret、Home Assistant route/token/entity を出しません。
Home Assistant の物理 action は、`-RequestLiveHomeAssistant` に加えて
`-ConfirmHomeAssistantTicket`、`-AllowedActionId`、`-RestoreActionId`、
期待 state、最大 action 数、停止条件が揃っていても、この helper からは直接 execute
しません。preview / dry-run / execute の ladder は、単独の live owner が別途実行します。

よく使うオプション:

| オプション | 用途 |
| --- | --- |
| `-DryRun` | 何を clone / 生成 / install するか確認する |
| `-NoDeps` | repo と `.env` だけ準備し、`uv sync` / `npm install` は後で行う。依存導入用の `uv` / `node` / `npm` 検査も省略する |
| `-NoEnv` | `.env` / local config 生成を行わない |
| `-ForceEnv` | 既存 `.env` / local config をテンプレから再生成する |
| `-VerifyOnly` | clone や install を行わず、manifest と readiness だけ確認する |
| `-VerifyRemote` | manifest pin と remote branch head の一致を確認する |

distribution の定義は `manifests/distributions/standard.json` です。追加の
配布形態を作る場合は、ここに profile、依存導入、env 生成先を増やします。

## バージョン / 診断 / アップデート

標準構成の version、source pin、update、maintenance smoke の詳細は
`docs/distribution-maintenance.md` にまとめています。README では、初回利用でよく使う入口だけを残します。

```powershell
pwsh -NoProfile -File .\scripts\show-version.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\doctor-distribution.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\check-distribution-pins.ps1 -Profile standard -Strict
```

既存 install を更新する場合は、top-level repo を `git pull --ff-only` で更新し、
その後 `update-distribution.ps1` で control plane と organ checkout を manifest pin に合わせます。

```powershell
pwsh -NoProfile -File .\scripts\update-distribution.ps1 -Profile standard -DryRun
pwsh -NoProfile -File .\scripts\update-distribution.ps1 -Profile standard
```

README、installer、update script を変更した時の軽量確認は次を使います。

```powershell
pwsh -NoProfile -File .\scripts\test-distribution-maintenance.ps1
```

`ahead_of_manifest` は nested checkout が manifest より進んでいる正式採用待ち状態です。
`git_unreadable` は checkout の Git 情報を読めない環境摩擦であり、pin mismatch とは分けて扱います。

### 通常利用の手動セットアップ

ワンタッチ installer を使わず、clone や依存導入を手動で確認したい時だけ読む
下位手順です。通常の入口は上の distribution installer です。

手動で進める場合も、基本の順番は同じです。

```powershell
git clone <sword-agent-os-repo-url>
cd sword-agent-os
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard -DryRun
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard
```

control plane / organ checkout を個別に確認したい場合や、依存導入を手で追いたい場合は
`docs/remote-workstation-setup.md` の manual bootstrap 手順を参照してください。
通常利用では、追加の workspace-local フォルダを作る必要はありません。

### 開発用 / Codex 用 workspace セットアップ

複数 Codex thread、worktree、private coordination repo、ローカル artifact cache を使って
開発する場合だけ、通常利用とは別の workspace root を作ります。手順は
`docs/remote-workstation-setup.md` にまとめています。

`coordination/`、`local/`、`worktrees/`、`_codex/` は本体 repo ではなく、
GitHub にまとめて push する対象ではありません。

## ローカル設定

インストール後に API key、token、家電設定、ローカル URL を入れる時に読む節です。
標準 installer は、中央の local env を使って各 organ の `.env` を生成します。
通常利用で直接編集するのは、原則としてこの 1 ファイルです。詳しい env 変数表、
secret 境界、生成先一覧は `docs/local-configuration.md` にまとめています。

```text
local\env\sword-agent-os.env
```

各 organ の `.env` は、この中央 env から生成される出力先です。まずは中央 env を
正本として扱うと、どこに値を書いたか迷いにくくなります。

### 初回 `.env` 作成手順

installer を通常実行した場合は、`local\env\sword-agent-os.env` が作られます。
手動で作る場合は、`sword-agent-os` の root で公開テンプレートをコピーします。

```powershell
cd <sword-agent-os のパス>
$RepoRoot = (Resolve-Path .).Path
Set-Location $RepoRoot

if (-not (Test-Path local\env\sword-agent-os.env)) {
  New-Item -ItemType Directory -Force local\env | Out-Null
  Copy-Item templates\env\sword-agent-os.env.example local\env\sword-agent-os.env
}
```

中央 env を開いて、自分の環境の値を書きます。Home Assistant を使わない場合は
家電操作用 token や URL を後回しにできます。最小構成で起動だけ確認する場合は、
LLM と live 家電の値も後回しにできます。

```powershell
notepad local\env\sword-agent-os.env
```

`local\env\sword-agent-os.env` は Git 管理外です。API key、token、家電設定、
ローカル URL、使用する model 名など、公開してはいけない値はここに入れます。
`NEXT_PUBLIC_*` はブラウザ側から見えるため、secret を入れないでください。

`HOME_CONTROL_API_TOKEN` は Home Assistant の token ではありません。ローカル
bridge 用のランダム値です。必要なら次のように作って、中央 env に貼ります。

```powershell
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

中央 env を各 organ の `.env` へ反映します。

```powershell
Set-Location $RepoRoot
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard
```

すでに organ 側の `.env` がある環境で、中央 env の変更を反映したい場合だけ
`-Force` を付けます。既存の organ `.env` はデフォルトでは上書きしません。

```powershell
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard -Force
```

中央 env を編集しても、既存の organ `.env` は自動では変わりません。
Home Assistant token、`HOME_CONTROL_API_TOKEN`、`ENVIRONMENT_API_TOKEN` を
後から入れた場合は、`-Force` で再生成した後に起動確認してください。
`-Force` は `organs\action\home-assistant-server\config\home-control.yaml`
も再生成します。live 用 config を別ファイルや手元の控えから反映している場合は、最後の
`-Force` の後で live config を再反映し、bridge helper の `-CheckOnly` と
`-CheckTracking` で起動と追跡メタデータを確認してから実行へ進んでください。
`-CheckState` は実行後または restore 後の state confirmation に使います。
すでに Launch Manager / stack が起動中の場合、`render-env-files.ps1 -Force` の
変更は実行中 process へ自動反映されません。設定を再生成した後は対象 stack を停止し、
fresh clone の `workspaceRoot` から Start Stack し直してから確認してください。

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

`8799` や標準 service port が既に使われている場合は、まずどの workspace の Launch Manager
または stack が残っているかを確認します。古い検証用 stack なら停止してから fresh clone 側を
起動します。並行して残す必要がある場合は、`-PortMode isolated_override` で別 port に分けます。
port 競合を無視して起動確認を続けると、別 workspace の service を見て pass と誤認します。

## 主な画面

起動後にどの URL を開けばよいか確認したい時に読む節です。
通常 port mode の代表的な URL です。

| 画面 / service | URL | 用途 |
| --- | --- | --- |
| Launch Manager | `http://127.0.0.1:8799` | 起動、停止、準備状態確認 |
| AITuber Kit | `http://127.0.0.1:3000` | アバター UI |
| Projection Visual | `http://127.0.0.1:3000/projection-visual/` | アバター + HUD のメイン画面 |
| Thought Core health | `http://127.0.0.1:18787/health` | 思考 API の liveness |
| Environment State | `http://127.0.0.1:8790/health` | 環境 API の liveness |
| Home Assistant bridge | `http://127.0.0.1:8787/health` | 家電操作 bridge の liveness |
| VOICEVOX | `http://127.0.0.1:50021/version` | 音声合成 engine の readiness |
| TouchDesigner control GUI | `http://127.0.0.1:8788` | 表示 / 投影制御 |
| MediaPipe monitor | `http://127.0.0.1:8770/browser_camera_hub_viewer.html` | カメラ / ジェスチャー確認 |

Projection Visual の表示例です。

![Projection Visual room control](docs/assets/readme/projection-visual-example-2.png)

![Projection Visual environment HUD](docs/assets/readme/projection-visual-example-3.png)

![Projection Visual conversation](docs/assets/readme/projection-visual-example-4.png)

## 最初の動作確認

### no-live 確認

Home Assistant の実家電操作を使わず、まず画面、入力、Thought Core への接続を
確認する流れです。

1. Launch Manager を起動し、少なくとも Launch Manager、AITuber Kit、
   Projection Visual、Thought Core が ready になるのを待ちます。
2. Projection Visual を開きます。
3. Chrome のマイク権限を許可します。
4. 短い文を話すか入力します。

```text
聞こえていますか
```

5. 部屋や環境状態の読み取りを確認します。

```text
今、電気はついてる？
部屋は明るい？
```

この段階では、家電が実際に動かなくても問題ありません。Home Assistant 未設定の
場合は、state が未接続、mock、または unavailable として見えることがあります。
`THOUGHT_CORE_TOOLS_ADAPTER=mock` の場合、家電操作の返答はテストモード上の
想定です。実際の Home Assistant へは送信されません。

daylight がある部屋で「電灯がついているか」を確認する場合は、明るさそのものと
electric-light ON/OFF を分けて見ます。手元に `local/media/movie/sample20260604`
の sunshine sample がある検証環境では、次の helper で raw frame を出さずに
集計だけを確認できます。

```powershell
pwsh -NoProfile -File .\scripts\evaluate-room-light-sunshine.ps1 -Json
```

この helper は direct-file evaluation です。raw video、raw frame、crop、screenshot、
生成 model は出力・commit しません。共有用には sample id、window count、label count、
probability summary、pass / partial / fail / blocked だけを使います。

### 音声出力を含める場合の VOICEVOX 確認

音声合成まで確認する場合は、先に VOICEVOX の endpoint を分けて確認します。

```powershell
pwsh -NoProfile -File .\scripts\check-voicevox-readiness.ps1
```

endpoint が応答していない場合に、既存のローカル VOICEVOX アプリを探して起動まで
試すには、通常ユーザー端末で明示的に `-StartIfNeeded` を付けます。

```powershell
pwsh -NoProfile -File .\scripts\check-voicevox-readiness.ps1 -StartIfNeeded
```

この helper は VOICEVOX の install / update / download、global audio device 変更、
PATH や永続環境変数の変更は行いません。共有用の報告では、検出された実行ファイルの
フルユーザーパスではなく、`known_pc_path` や `start_menu_shortcut` のような discovery
source と pass / skipped / blocked を記録します。

### Home Assistant 設定済みの場合の live 確認

Home Assistant bridge が ready で、対象家電、戻し方、停止条件が分かっている場合だけ
低リスクな操作を試します。いきなり複数家電や長時間 fuzzing を実行しないでください。

live 確認は、no-live が通った後に、1 回分の小さな ticket として分けます。
次の ladder を上から順に実行し、OpenAPI や Home Assistant の raw URL / entity を
手探りで調べるのは、この ladder が失敗した時だけにします。

1. no-live prerequisite を通します。これは実家電 proof ではありません。

```powershell
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc -RunManualTurn -RunSafeIntegrationProbes
```

2. 対象 action を 1 つだけ決めます。戻し操作が必要なら、それも ticket に明記します。
   回数、間隔、禁止 action、停止条件も先に決めます。
3. 中央 env や local config を直したら、最後に再生成します。

```powershell
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard -Force
```

`-Force` は `organs\action\home-assistant-server\config\home-control.yaml` を
template から再生成します。live 用の config を使う場合は、この後に live config を
再反映してください。ここを飛ばすと demo action や古い mapping のままになります。

4. 別ターミナルで Home Control bridge を起動します。この helper は foreground の
   long-running process で、停止するまでその terminal を使い続けます。
   `organs/action/home-assistant-server/.env` を読み込み、secret 値は表示しません。
   起動時に port、helper PID、log path ラベル、停止方法を表示します。
   test では別 terminal か background terminal で起動し、停止するときはその test 用に
   起動した bridge process だけを止めます。

```powershell
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1
```

5. もう 1 つのターミナルで、live-ready かを先に確認します。

```powershell
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckOnly -ExpectedActionId <allowed-action-id>
```

`/health` が `config_error` の場合、または authenticated `/actions` が期待 action を
返さない場合は、preview / execute に進まず停止します。診断では token、entity URL、
secret 値を貼らず、key presence、placeholder/length class、config path、action count、
status、`config_error_kind`、`cause_code` だけを共有してください。原因の追跡用コードは
[Live Home Control Cause Trail](docs/live-home-control-cause-trail.md) にまとめています。

`/health` が non-error で、`/actions` に ticket の action があることを確認したら、
次にその action がどの種類の操作か、Home Assistant state confirmation まで追跡できるかを
確認します。これは実行前の「追跡メタデータ確認」であり、現在の家電状態が期待状態かどうかは
判定しません。

```powershell
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckTracking -ActionId <allowed-action-id>
```

`-CheckTracking` が `tracked` なら、その action には後確認用の `expected_effect` があり、
`-CheckState` で Home Assistant state proof を取れます。`external_required`、`ack_only`、
`manual_required`、`unsupported` の場合は、preview / dry-run 自体は ticket 次第で進められても、
その action では helper による Home Assistant state proof を主張できません。

Action metadata は次のように分けます。

| Field | Typical values | Meaning |
| --- | --- | --- |
| `control_type` | `stateful_target`, `stateless_toggle`, `stateless_command`, `position_command`, `mode_command`, `job_command` | The kind of appliance/control behavior. |
| `state_authority` | `ha_entity`, `ha_inferred`, `open_loop`, `external_sensor`, `submitted_only` | Where the state claim comes from. Inferred/open-loop state is not physical proof. |
| `verification.mode` | `ha_state`, `external_observation`, `command_ack_only`, `manual_confirmation` | What proof layer can confirm the action. |
| `expected_effect` | HA domain/service/entity/expected state | Only used when `verification.mode` is `ha_state`. |
| `verification.accepted_states` | e.g. `["closed"]`, `["docked"]` | Optional HA states that also count as post-state proof. The primary `expected_effect.expected_state` is still included. |
| `verification.settle_seconds` / `timeout_seconds` | e.g. `8` / `60` | The wait window to use in the ticketed execute/wait/check procedure. These are metadata; do not treat them as proof by themselves. |

Report Home Control proof with separate labels:

| Proof label | Meaning |
| --- | --- |
| `command accepted` | Bridge/Home Assistant accepted the command. This is send/submission proof, not appliance-state proof. |
| `HA state matched` | Home Assistant current state matched `expected_state` or `accepted_states` after the ticketed wait. |
| `external observed` | Camera, sensor, manual observation, or another independent source confirmed the physical result. |
| `restored / reversible` | The pilot also proved the planned restore path, such as start/change then return/docked. |

SwitchBot remote-style devices may be `stateless_toggle`: a button press changes the
physical state, but Home Assistant cannot know the current state. Do not model such a
device as `light_on` / `light_off` with HA state proof unless the target state is
actually readable. Use external observation, manual confirmation, or a separate sensor
before claiming physical state.

For the current live SwitchBot-style setup, actions backed by `switch` entities whose
current state is `unknown` should stay out of `ha_state` proof. Keep them as
`open_loop` or `submitted_only` until Home Assistant shows a reliable current state.
`cover` and `vacuum_return` may become HA state-proof candidates, but only after a
separate read-only state review and a ticketed execute/wait/post-state proof. When
promoting them, use `verification.mode: ha_state`, keep `state_authority: ha_entity`,
set `expected_effect`, and add `accepted_states` plus settle/timeout windows before
claiming `tracked`.

For vacuum proof, check the specific `expected_effect.entity_id` targeted by the
script. Do not use all-domain `vacuum` counts as the action proof when Home
Assistant exposes multiple vacuum entities or multiple state authorities.

For SwitchBot remote-style light checks, use the redacted physical-light helper
instead of ad hoc scripts when the review needs command submission plus camera
brightness observation. The helper starts a temporary bridge unless
`-UseExistingBridge` is supplied, performs preview / dry-run for each action,
and executes only when `-ConfirmLiveLightTicket` is present.

```powershell
pwsh -NoProfile -File .\scripts\run-home-control-light-proof.ps1 -DryRun
pwsh -NoProfile -File .\scripts\run-home-control-light-proof.ps1 -ConfirmLiveLightTicket -OffActionId light_off -OnActionId light_on -Json
```

The output separates `command_submission`, `physical_brightness_observation`,
and `restore_observed`. It reports aggregate brightness numbers only and keeps
`raw_media_saved=false`, `raw_media_shared=false`, `raw_secret_shared=false`,
and `entity_id_shared=false`. If the camera is owned by the standard stack,
stop that stack first or run a documented split procedure; camera readiness
alone is not appliance proof. If `physical_brightness_observation=inverted`,
the physical light changed in the opposite direction; fix the local action
mapping or rerun with the off/on action IDs swapped before claiming the
requested `on` proof.
In the current live setup, read-only registry review showed separate local and
cloud-side vacuum entities; bridge scripts target the cloud-side vacuum path.

For vacuum actions, define start and return proof separately. `vacuum_start`
must state which post-start states count as progress, and why; avoid accepting
any state that merely hides uncertainty. `vacuum_return` should normally require
`docked` after a wait window. A strong pilot is `start -> wait -> non-docked or
cleaning/returning proof -> return -> wait -> docked proof`.
If restore only succeeds after an extra return command, report it as
`restored / reversible with retry`. `tracked` means the post-state check is
configured; it does not by itself prove that one return command is always
reliable within the chosen timeout.

For air conditioner work, a same-device `climate` candidate may exist even when
the current bridge script calls an `unknown` switch. Do not add `expected_effect`
to that switch. Design a separate climate-service action and prove it before
promoting aircon actions to `ha_state`.

ここまで通ってから、preview、dry-run、execute の順に進めます。
HTTP を直接使う場合の最小形は次です。
`<ticket-id>` は実行ごとに変えます。execute 回数は ticket に書いた回数だけです。

```powershell
$Headers = @{ Authorization = "Bearer <HOME_CONTROL_API_TOKEN>" }

Invoke-RestMethod `
  -Method Post `
  -Uri "http://127.0.0.1:8787/actions/<allowed-action-id>/preview" `
  -Headers $Headers `
  -ContentType "application/json" `
  -Body '{"source":"first-run-live-pilot","request_id":"<ticket-id>-preview"}'

Invoke-RestMethod `
  -Method Post `
  -Uri "http://127.0.0.1:8787/actions/<allowed-action-id>/execute" `
  -Headers $Headers `
  -ContentType "application/json" `
  -Body '{"source":"first-run-live-pilot","request_id":"<ticket-id>-dry-run","dry_run":true}'

Invoke-RestMethod `
  -Method Post `
  -Uri "http://127.0.0.1:8787/actions/<allowed-action-id>/execute" `
  -Headers $Headers `
  -ContentType "application/json" `
  -Body '{"source":"first-run-live-pilot","request_id":"<ticket-id>-execute","dry_run":false}'
```

確認必須 action の `confirmation_token` は一度だけ使えます。dry-run で token を
使った場合、その token は消費済みです。本実行の直前に preview を取り直し、
新しい token を execute だけに使ってください。

execute response は `status=submitted` かつ `executed=true` で返ることがあります。
これは操作要求が bridge から送信された層の結果であり、最終的に対象家電が期待状態に
なった proof とは分けて扱います。preview、dry-run、execute、wait、Home Assistant
state confirmation、独立した物理/カメラ確認を同じ green にまとめないでください。

6. ticket で決めた反映待ちの間隔を待ち、Home Assistant state を helper で確認します。
   `-CheckTracking` output may include `settle_seconds` / `timeout_seconds`;
   use those as the wait window only for actions that are `tracked`.
   `-CheckState` は実行後または restore 後の確認です。実行前に全 action を通すための
   preflight ではありません。たとえば stateful な `light_on` は「今すでに on か」を見るので、
   実行前に off なら mismatch になります。stateless toggle のライトでは、そもそも
   HA state proof を取れないため `external_required` などで止めます。helper は action id、
   expected state、actual state、status だけを表示し、raw Home Assistant URL / entity /
   token は表示しません。

```powershell
Start-Sleep -Seconds 30
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckState -ActionId <allowed-action-id>
```

7. restore も ticket に書いた場合だけ、同じ順で preview、dry-run、1 回だけ execute、
   wait、state check を行います。
   If restore needs another execute, record the retry count separately; do not
   collapse that into a single-action green proof.

```powershell
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckOnly -ExpectedActionId <restore-action-id>
pwsh -NoProfile -File .\scripts\start-home-control-bridge.ps1 -CheckTracking -ActionId <restore-action-id>
```

proof は層ごとに分けます。no-live/mock、live bridge、preview、execute、
Home Assistant state confirmation、独立した物理/カメラ確認は同じ green ではありません。
初回レポートでは、install/readiness pass、no-live/mock pass、real camera
service/topic readiness、sword-sign positive gesture detection、gesture-to-voice-input
gate transition、real microphone speech recognition、ticketed live appliance action、
independent physical/camera confirmation を分けて書きます。

```text
電気をつけて
電気を消して
```

Thought Core は、環境を観測し、Action Boundary で操作を preview / execute し、必要なら反映待ちをしてから再観測し、結果または不確実な点を返します。

## 検証コマンド

詳細なコマンド表と proof layer の扱いは `docs/verification-commands.md` にまとめています。
README では、初回導入時によく使う入口だけを残します。

```powershell
pwsh -NoProfile -File .\scripts\doctor-distribution.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\check-distribution-pins.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc -RunManualTurn -RunSafeIntegrationProbes
```

複数 lane の状態を redacted summary にまとめる場合は full install verification helper を
使えます。デフォルトは `default_safety=no-live/no-device` で、実カメラ、実マイク、
browser runtime、gesture gate、Home Assistant live action は別 layer の `held` /
`blocked` として扱います。

```powershell
pwsh -NoProfile -File .\scripts\run-full-install-verification.ps1
```

実機レビュー、local-media replay、runtime/browser、live Home Assistant の詳しい開き方は
`docs/verification-commands.md` を見てください。live action は、対象、回数、間隔、
停止条件、戻し方を決めてから実行します。

## うまく起動できないとき

完全版は `docs/troubleshooting.md` にあります。README では、初回導入で最初に見る
症状だけを残します。

| 症状 | 確認すること |
| --- | --- |
| Launcher が開かない | PowerShell で script 実行できるか、`8799` port が空いているか |
| fresh clone なのに古い service が見える | 既存 workspace の Launch Manager / stack が残っていないか確認します。古い検証用なら停止し、並行検証が必要なら `start-launcher.ps1 -PortMode isolated_override` を使います |
| service が down のまま | Launch Manager の service card と各 organ README |
| source pin が合わない / `ahead_of_manifest` が出る | `scripts/check-distribution-pins.ps1 -Profile standard` で対象 organ を確認します。`ahead_of_manifest` は nested repo が manifest より進んでいる状態で、正式採用待ちを意味します。配布前は `-Strict` で失敗扱いにし、親 manifest 更新と fresh install proof を行います |
| `git_unreadable` が出る | 現在の実行ユーザーや制限付き環境が nested checkout の Git 情報を読めていません。通常ユーザー端末で再実行するか、診断目的で exact path の `safe.directory` override を使います。これは真の source pin mismatch とは分けて扱います |
| Thought Core が down | control-plane `.env`、LLM 設定、`18787` port |
| VOICEVOX が down | `scripts/check-voicevox-readiness.ps1` で endpoint-first に確認します。必要な時だけ通常ユーザー端末で `-StartIfNeeded` を付け、既存 VOICEVOX app の検出/起動を試します。install/update/download、global audio device、PATH/env 変更はしません |
| カメラが動かない | 他アプリがカメラを掴んでいないか、カメラ名が合っているか |
| `model_not_found` / Camera Hub topics timeout | `gesture_model.pkl` がある場合は `organs/reflex/mediapipe-sword-sign/gesture_model.pkl` に置いたか確認。ない場合は、Camera Hub / gesture proof は未準備として分け、カメラ不要の no-live / source-static 確認だけを先に進めます。これはローカル専用資材なので Git には入れません |
| API key や token を入れたのに家電が動かない | `THOUGHT_CORE_TOOLS_ADAPTER` が `mock` なら no-live simulation です。実家電へ送る場合だけ `home_control` に変更 |
| Home Control bridge が `config_error` になる / `/actions` が 503 になる | bridge process に generated organ `.env` が読み込まれていない、token が placeholder/too-short、または `HOME_CONTROL_CONFIG` が意図した config を指していない可能性があります。`scripts/start-home-control-bridge.ps1 -CheckOnly` で secret 値を出さずに health、action count、`config_error_kind`、`cause_code` を確認します。bridge helper は organ-local `.uv-cache` を一時利用するため、通常は persistent `UV_CACHE_DIR` を変更する必要はありません |

## OS の構造

各 organ がどの役割を持ち、どうつながるかを把握したい時に読む節です。
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

コードや manifest を変更する開発者はここから読みます。

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

push、公開、スクリーンショット追加、実家電テストの前に確認する注意事項です。

- `.env`、token、provider key、cookie、local memory、raw media、camera capture、machine-specific log は Git に入れません。
- ローカル専用のものは `local/`、runtime/cache、または各 organ の ignored フォルダに置きます。
- README に入れる画像は、秘密情報、ローカル絶対パス、ユーザー固有情報、raw sensor data が写っていないものだけにします。
- 実家電操作は物理環境に影響します。まず dry-run、no-live test、または範囲を絞った pilot で確認してください。
- TouchDesigner project、アバター、モデル、音声、SDK には個別のライセンスや再配布条件があります。

## 外部モジュールと謝辞

公開、配布、イベント利用の前に、外部プロジェクトや素材の扱いを確認する節です。
Sword Agent OS は、AITuber Kit、MediaPipe、Home Assistant、VOICEVOX、TouchDesigner、各種アバター / モデル素材など、複数の外部プロジェクトやアプリケーションと連携して動きます。利用・再配布・公開の前に、それぞれのライセンスと利用規約を確認してください。

この README のスクリーンショットは、ローカル環境の一例です。このリポジトリは、第三者のアバターモデル、VOICEVOX 音声、TouchDesigner project、Home Assistant device 設定の再配布権を与えるものではありません。
