# 初回導入と動作確認ガイド

この文書は、Sword Agent OS を初めて使う人が、準備、インストール、
起動、画面確認、試し動作まで進むための手順です。

開発中の確認用語ではなく、実際に使う人が読むことを想定しています。
詳しい設定項目や安全上の細かい決まりは、各項目からリンクしている
専門文書を参照してください。

## このシステムは何をするものか

Sword Agent OS は、PC上で動く「家の中のエージェント本体」です。
大きく分けると、次の流れを扱います。

```text
人からの入力
-> 会話や状況を理解する
-> 必要なら家電操作やアバター表現を選ぶ
-> 画面、声、アバター、家電操作として出す
-> 結果や状態を見る
-> 次の会話や判断に反映する
```

たとえば、次のような使い方を目指します。

- `こんにちは` と話すと、AIが返事をする。
- カメラが刀印のジェスチャーを見た時だけ、音声入力を受け付ける。
- アバターが表情を変えたり、うなずいたりする。
- Home Assistant とつながっていれば、照明、カーテン、掃除機などを操作できる。
- Environment State の画面で、システムや部屋の状態を確認できる。
- 操作結果へのフィードバックを、次の判断に使える。

ただし、すべてを一度に確認するわけではありません。まずは安全な基本確認、
次に画面、音声、アバター、家電、物理確認という順に分けて確認します。

## この文書で出てくる名前

| 名前 | かみ砕いた意味 |
| --- | --- |
| Launch Manager | 標準サンプルの起動/操作画面。起動状態を見たり、各画面へのリンクを開いたりする入口画面 |
| Thought Core | 入力を受け取り、会話や判断を担当する中枢 |
| Environment State | 部屋やシステムの現在状態を見るための状態画面 |
| Home Assistant | 家電やセンサーをまとめる外部システム |
| Home Control | Home Assistant 経由で家電操作を行うためのSword側の機能 |
| AITuber Kit / Projection Visual | アバターや表示を出す画面 |
| VOICEVOX | 返答を音声にするための音声合成ソフト |
| `gesture_model.pkl` | カメラ映像から刀印などのジェスチャーを認識するためのモデルファイル |
| VRM | 3Dアバターのモデルファイル |
| `.env` | APIキー、接続先、使うVRMなど、各PCごとの設定を書くファイル |

## この手順で確認すること

この手順では、次を順番に確認します。

1. 必要なソフト、機器、ローカルファイルを用意する。
2. Git でプロジェクトを取得し、標準構成をインストールする。
3. APIキーや家電連携の設定がない状態でも、基本チェックを通す。
4. 必要な設定ファイルを作り、AI、音声、アバター、家電連携の準備をする。
5. 起動用バッチファイルを実行し、表示された画面を開く。
6. 接続済みの機能について、試し動作を一通り確認する。
7. 起動と停止が安全にできることを確認する。

ここでいう「確認できた」は、必ず範囲を分けて扱います。たとえば、
画面が開いたこと、Home Assistant が状態を返したこと、実際の家電が物理的に
動いたことは、それぞれ別の確認です。

## 1. 先に用意するもの

最低限必要なもの:

| 用意するもの | 何に使うか |
| --- | --- |
| Windows PC | このシステムを動かすPC |
| Git | プロジェクトを取得する |
| PowerShell 7 | インストールや確認スクリプトを動かす |
| `uv` | Python製の部品を準備する |
| Node.js / npm | ブラウザ画面やアバター画面を動かす |

使いたい機能に応じて必要なもの:

| 用意するもの | 何に使うか | 備考 |
| --- | --- | --- |
| Home Assistant | 照明、カーテン、掃除機などの家電状態取得や操作 | Raspberry Pi + Home Assistant OS でも、既存の Home Assistant でもよい |
| Home Assistant の長期アクセストークン | 家電の状態取得や操作 | `.env` にだけ書く |
| Home Control 用のローカルトークン | このPC上の家電連携ブリッジを守る | `.env` にだけ書く |
| Home Control 設定ファイル | どの家電をどう操作し、何を成功状態と見るか決める | 家電IDやスクリプトIDは公開しない |
| マイク、または音声サンプル | 音声入力を試す | 生音声や文字起こし全文は共有しない |
| カメラ | ジェスチャー入力や外部観測を試す | 基本インストールだけなら不要 |
| `gesture_model.pkl` | ジェスチャー認識 | `organs\reflex\mediapipe-sword-sign\gesture_model.pkl` に置く |
| VOICEVOX | 音声で返答させる | ローカルで起動する |
| VRM / Live2D ファイル | アバターを表示する | 標準は同梱サンプル。独自モデルは利用権を確認してローカルに置く |
| TouchDesigner | プロジェクターや外部演出 | 必要な場合だけ別途インストール |
| ffmpeg / ffprobe / mediamtx | カメラ映像の配信や診断 | カメラ系の確認で使う |

`gesture_model.pkl` の作り方や、独自VRM、音声サンプル、動画サンプルの作成は、
この導入手順とは別の準備です。まだ用意できていない場合は、その機能だけを
「未準備」として残し、他の確認を先に進めます。

## 2. プロジェクトを取得してインストールする

任意の作業場所でプロジェクトを取得します。

```powershell
git clone <sword-agent-os repository url> sword-agent-os
cd sword-agent-os
```

標準構成をインストールします。

```powershell
.\scripts\install-distribution.ps1 -Profile standard
```

まずは基本状態を確認します。

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 doctor
```

この3つは安全な確認です。AIサービス、マイク、カメラ、ブラウザ画面、
Home Assistant、家電操作は勝手には実行されません。

## 3. ローカルファイルを置く

ローカルファイルは Git に入れません。置き場所だけを合わせます。

| ファイル | 置き場所 / 設定 | ない場合 |
| --- | --- | --- |
| ジェスチャー認識モデル | `organs\reflex\mediapipe-sword-sign\gesture_model.pkl` | ジェスチャー確認は未準備 |
| VRM | 標準は `/vrm/nikechan_v1.vrm`。独自VRMは `organs\expression\aituber-kit\public\vrm\<file>.vrm` に置き、`.env` で `/vrm/<file>.vrm` を指定 | 独自アバター確認は未準備 |
| 音声、動画などのローカルサンプル | 非公開の素材フォルダから `local\media\media-index.json` を作る | サンプル再生や音声サンプル確認は未準備 |
| Home Control 設定 | `.env` の `HOME_CONTROL_CONFIG` で指定 | 家電の状態確認や操作は未準備 |

ローカルサンプルの索引を作る場合:

```powershell
.\scripts\prepare-local-media-index.ps1 -DryRun
.\scripts\prepare-local-media-index.ps1
```

別の場所にある非公開素材フォルダを使う場合:

```powershell
.\scripts\prepare-local-media-index.ps1 `
  -WorkspaceRoot <このプロジェクトの場所> `
  -SecretInputsRoot <非公開素材フォルダの場所> `
  -DryRun
```

生の音声、動画、画像、文字起こし全文、秘密鍵、トークン、Home Assistant の
家電ID、ローカルの絶対パスは、Git や共有用の文書に入れないでください。

## 4. `.env` なしで確認する

APIキーや Home Assistant のトークンを入れる前でも、基本チェックはできます。

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 start
```

`.\sword.ps1 start` は、何を起動する予定かを見る確認です。実際に起動するには、
後述のバッチファイル、または `.\sword.ps1 start -Run` を使います。

この段階で確認できること:

| 確認できること | 意味 |
| --- | --- |
| ファイルと設定の整合性 | 必要な構成ファイルが揃っている |
| 起動前チェック | すぐ分かる不足や衝突が見つかる |
| 安全な簡易テスト | 実機を使わない範囲で部品の相性を見る |
| 起動予定 | どの画面やサービスを起動しようとしているか分かる |

この段階では、AIサービスの実応答、実マイク入力、実カメラ入力、
ジェスチャー開門、Home Assistant の家電操作、VRMの画面上の動き、
物理的な家電動作はまだ確認していません。

## 5. `.env` を作る

中央設定ファイルは次です。

```text
local\env\sword-agent-os.env
```

存在しない場合は、テンプレートから作ります。

```powershell
if (-not (Test-Path local\env\sword-agent-os.env)) {
  New-Item -ItemType Directory -Force local\env | Out-Null
  Copy-Item templates\env\sword-agent-os.env.example local\env\sword-agent-os.env
}
notepad local\env\sword-agent-os.env
```

AITuberKit のアバター、ブラウザ入力、画角、音声設定は中央設定と分け、
次のローカルファイルで管理します。既にある場合は上書きしません。

```powershell
if (-not (Test-Path organs\expression\aituber-kit\.env)) {
  Copy-Item organs\expression\aituber-kit\.env.example organs\expression\aituber-kit\.env
}
notepad organs\expression\aituber-kit\.env
```

よく使う設定:

| 設定名 | 何に使うか |
| --- | --- |
| `THOUGHT_CORE_LLM_ENABLED=false` | AIサービスなしで確認する |
| broker 固有 ignored `.env` の `OPENAI_API_KEY` | broker だけが AI service 接続に使う。Thought Core には渡さない |
| `THOUGHT_CORE_LLM_PROVIDER=sword-openai-broker`, `THOUGHT_CORE_LLM_BASE_URL=http://127.0.0.1:18786/v1` | credential-free Thought Core の標準 broker 接続 |
| 中央 env の `VOICEVOX_ENDPOINT` | サーバー側 tts-service で VOICEVOX adapter を使う |
| AITuberKit `.env` の `VOICEVOX_SERVER_URL`, `NEXT_PUBLIC_VOICEVOX_*` | AITuberKit の声・話速を選ぶ |
| AITuberKit `.env` の `NEXT_PUBLIC_SELECTED_VRM_PATH` | 表示するVRMを選ぶ |
| `HOME_ASSISTANT_TOKEN` | Home Assistant の状態取得や操作に使う |
| `HOME_CONTROL_API_TOKEN` | このPC上の家電連携ブリッジを守る |
| `HOME_CONTROL_CONFIG` | 家電操作の設定ファイルを選ぶ |
| `THOUGHT_CORE_TOOLS_ADAPTER=mock` | 家電操作を本物には送らず確認する |
| `THOUGHT_CORE_TOOLS_ADAPTER=home_control` | Home Assistant 連携を使う |

中央 env を編集したら、中央管理の各部品用設定を作り直します。
この処理は既存の AITuberKit `.env` を上書きしません。AITuberKit の変更は
そのプロセスを再起動して反映します。

```powershell
.\scripts\render-env-files.ps1 -Profile standard -Force
.\sword.ps1 verify
```

`-Force` を使うと、Home Control のサンプル設定が再生成されることがあります。
実家電用の設定を使う場合は、この後に自分の Home Control 設定が選ばれているか
確認してください。

## 6. 起動する

標準サンプル Launcher で起動する場合は、プロジェクト直下の次のファイルを
ダブルクリックします。Sword Agent OS の本体 runtime stack は、この Launcher だけを
起動手段とする必要はありません。自分の環境に組み込む場合は、別の launch system から
同じ service / readiness / cleanup 境界を使って起動できます。

```text
start-home-control-launcher.bat
```

コマンドで起動する場合:

```powershell
.\start-home-control-launcher.bat
```

ブラウザに Launch Manager が開きます。そこから、各画面へのリンクを開きます。
ポート番号は環境によって変わることがあるので、古いURLを直接入力するより、
Launch Manager に表示されたリンクを使ってください。

よく見る画面:

| 見たいもの | 開き方 | 詳細 |
| --- | --- | --- |
| 起動状態、停止操作 | Launch Manager | `docs\operate.md` |
| Thought Core の状態 | Launch Manager のサービス表示 | `docs\operate.md` |
| アバター / Projection Visual | Launch Manager の AITuber / Projection Visual リンク | `examples\starter-profiles\projection-visual\README.md` |
| Environment State | Launch Manager の Environment / diagnostics リンク | `docs\verification-commands.md` |
| Home Control の準備状態 | Home Control 用の確認手順 | `examples\starter-profiles\home-control-preview\README.md` |
| 音声 / アバターの準備 | voice-avatar 手順 | `examples\starter-profiles\voice-avatar\README.md` |
| TouchDesigner / projector | TouchDesigner を使う手順 | `docs\standard-distribution-map.md` |

## 7. 導入後に試せる操作

ここでは操作例を広げすぎません。試す範囲は、準備済みの starter profile
または専門文書から選びます。

| 試したいこと | 最初に見る場所 |
| --- | --- |
| 会話、音声、アバター | `examples\starter-profiles\voice-avatar\README.md` |
| Projection Visual / Self Mirror | `examples\starter-profiles\projection-visual\README.md` |
| Environment State | `docs\standard-distribution-map.md` |
| Home Assistant / 家電 | `docs\home-assistant-setup.md` と `docs\live-home-control-proof.md` |

画面表示、ブラウザ上の動き、Home Assistant 上の状態、外部観測、物理的な
家電動作は別の確認です。ひとつの成功を、別の proof layer の成功として
扱わないでください。

## 8. どこまでできたら完了か

初回導入の最小完了:

- `.\sword.ps1 status` で現在の構成が見える。
- `.\sword.ps1 verify` が成功する、または不足しているものを具体的に示す。
- ローカルファイルの有無が、準備済み / 未準備として分かる。
- `.env` を作った後、設定反映と再確認をしている。
- Launch Manager を開き、必要な画面リンクを開ける。
- 起動後に安全に停止できる。

追加機能は、次のように分けて確認します。

| 「できる」と言う内容 | 追加で必要な確認 |
| --- | --- |
| 音声入力ができる | マイクまたは音声サンプル、音声認識結果、Thought Coreへの受け渡し |
| ジェスチャーで音声入力が開く | カメラ、`gesture_model.pkl`、ジェスチャー認識、音声入力の有効化 |
| アバターが動く | アバター画面、VRM状態、または画面上の動き |
| AIが自然に返答する | AIサービス設定、応答結果、必要なら応答品質の確認 |
| 家電操作ができる | Home Assistant設定、操作送信、状態確認、必要なら外部観測 |
| 物理的に家電が動いた | カメラ、センサー、人間の目視など、Home Assistant以外の観測 |
| 公開版として準備完了 | 別途、公開前レビュー |

## 9. 何か足りない時

| 足りないもの | 先に進める範囲 | まだ言えないこと |
| --- | --- | --- |
| `.env` 未設定 | 基本確認、実機なしの簡易テスト | AI応答、家電操作、音声入力 |
| `gesture_model.pkl` なし | 会話、アバター、家電準備 | ジェスチャー認識 |
| 独自VRMなし | 同梱サンプルVRM | 独自アバターの確認 |
| Home Assistantなし | AI、アバター、実機なし確認 | 家電操作、Home Assistant状態確認 |
| カメラなし | 音声サンプル、画面確認 | 実カメラ、物理観測 |
| マイクなし | テキスト入力、音声サンプル | 実マイク入力 |
| VOICEVOXなし | テキスト応答、画面確認 | 音声合成 |
| TouchDesignerなし | ブラウザ上のProjection Visual | 外部プロジェクター表示 |

足りないものがある場合は、無理に成功扱いにしません。何が足りないかを
そのまま書き、準備できるものから順に確認します。
