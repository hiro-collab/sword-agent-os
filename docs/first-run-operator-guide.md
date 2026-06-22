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
| VRM / Live2D ファイル | アバターを表示する | サンプルVRMは同梱。自分のVRMは利用権を確認してローカルに置く |
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
| 同梱サンプルVRM | `/vrm/nikechan_v1.vrm` | そのまま使える |
| 独自VRM | `organs\expression\aituber-kit\public\vrm\<file>.vrm` に置き、`.env` で `NEXT_PUBLIC_SELECTED_VRM_PATH=/vrm/<file>.vrm` を指定 | 独自アバター確認は未準備 |
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
.\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc
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
New-Item -ItemType Directory -Force local\env | Out-Null
Copy-Item templates\env\sword-agent-os.env.example local\env\sword-agent-os.env
notepad local\env\sword-agent-os.env
```

よく使う設定:

| 設定名 | 何に使うか |
| --- | --- |
| `THOUGHT_CORE_LLM_ENABLED=false` | AIサービスなしで確認する |
| `THOUGHT_CORE_LLM_API_KEY` または `OPENAI_API_KEY` | AIサービスの応答を使う |
| `THOUGHT_CORE_LLM_MODEL`, `THOUGHT_CORE_LLM_BASE_URL` | 使うAIモデルや接続先を選ぶ |
| `VOICEVOX_SERVER_URL` | 音声合成を使う |
| `NEXT_PUBLIC_SELECTED_VRM_PATH` | 表示するVRMを選ぶ |
| `HOME_ASSISTANT_TOKEN` | Home Assistant の状態取得や操作に使う |
| `HOME_CONTROL_API_TOKEN` | このPC上の家電連携ブリッジを守る |
| `HOME_CONTROL_CONFIG` | 家電操作の設定ファイルを選ぶ |
| `THOUGHT_CORE_TOOLS_ADAPTER=mock` | 家電操作を本物には送らず確認する |
| `THOUGHT_CORE_TOOLS_ADAPTER=home_control` | Home Assistant 連携を使う |

編集したら、各部品用の設定ファイルを作り直します。

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

ここは「入れた後に何を試せるか」の一覧です。すべての家で同じ操作が
できるわけではありません。使える操作は、接続した機器、Home Assistant の設定、
AIサービス、マイク、カメラ、ローカルサンプルの有無で変わります。

### 会話とフィードバック

| 試すこと | 必要な準備 | 確認すること |
| --- | --- | --- |
| `こんにちは` と入力する | AIサービス、またはAIなし確認設定 | 入力を受け取り、返答または確認用の応答が返る |
| 今の状態を聞く | Environment State や診断画面が起動している | 現在状態や更新時刻を参照している |
| 直前の結果に意見を言う | フィードバック確認手順が有効 | 次の返答で、その意見が使われている |

### 音声入力とジェスチャー

音声入力をジェスチャーで開く場合は、カメラと `gesture_model.pkl` が必要です。

想定する流れ:

```text
カメラが刀印のジェスチャーを見る
-> 音声入力が有効になる
-> 短い発話を受け付ける
-> 音声認識が入力内容を要約する
-> Thought Core がその入力を使う
```

操作案内:

1. カメラに映る位置で、人差し指と中指を立てた刀印のジェスチャーをします。
2. ジェスチャーが認識された時だけ、短く話します。
3. 確認では、生音声や文字起こし全文ではなく、要約された入力情報を見るようにします。

実マイク、ブラウザ音声認識、VB-Cable、製品UIからの音声入力は、それぞれ
別の確認が必要です。音声サンプルだけで、実マイクが使えるとは扱いません。

### アバターと表示

| 試すこと | 必要な準備 | 確認すること |
| --- | --- | --- |
| アバター画面を開く | Launch Manager と AITuber Kit が起動している | ブラウザ画面が開く |
| 表情を変える | Projection Visual と VRM が準備済み | VRMの状態、または画面上のアバターの変化を見る |
| うなずきやダンスを見る | アバター動作の確認手順が有効 | 指定した動きが画面上で見える |
| TouchDesigner に出す | TouchDesigner が導入済み | 外部演出やプロジェクター表示を別途確認する |

VRMの内部状態が変わったことと、画面上で人間に見える動きが出たことは別です。
プロジェクターなど外部表示も、さらに別の確認です。

### Environment State

| 試すこと | 必要な準備 | 確認すること |
| --- | --- | --- |
| Environment State 画面を見る | Environment / diagnostics が起動している | 現在状態、更新時刻、家電操作の準備状態を見る |
| 部屋の明るさなどを見る | カメラまたはローカルサンプルがある | 情報源と信頼度を分けて見る |
| 操作後の状態を見る | Home Assistant または別の観測手段がある | Home Assistant上の状態、外部観測、物理状態を分けて見る |

「自分自身の状態」は、Launch Manager、Environment State、診断画面、
アバター/HUD表示を組み合わせて見ます。ひとつの画面だけですべてが
確認できるとは扱いません。

### 家電操作の例

Home Control は、接続済みの機器と設定ファイルがある場合だけ試します。
この一覧は「こういう操作を用意できる」という例であり、実行許可ではありません。

| 発話例 | 必要な接続 | 確認すること |
| --- | --- | --- |
| 電気をつけて | Home Assistant に照明やスイッチが登録されている | 操作候補、送信、状態確認、または観測結果 |
| 電気を消して | Home Assistant に照明やスイッチが登録されている | 消灯操作と復旧確認 |
| カーテンを開けて | 開閉状態や位置が読めるカーテンがある | 開閉操作と位置または状態 |
| カーテンを閉めて | 開閉状態や位置が読めるカーテンがある | 閉じる操作と状態確認 |
| 掃除機をかけて | 掃除開始操作と停止/復帰条件がある | 開始操作、安全条件、停止または復帰 |
| 掃除機を戻して | 充電台に戻る状態が読める掃除機がある | 戻る操作と Home Assistant 上の到着状態 |
| エアコンをつけて / 消して | エアコンの状態または観測手段がある | 操作送信と状態または観測結果 |
| 扇風機をつけて / 消して | 扇風機またはスイッチの状態/観測手段がある | 操作送信と状態または観測結果 |

赤外線リモコンやトグル式のスイッチは、命令を送れたことだけでは
物理状態が変わった証拠になりません。必要に応じて、Home Assistant の状態、
Environment State、カメラ要約、別センサー、または人間の目視確認を分けて
確認します。

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

## 9. 最低限の動作確認表

この文書に書いた操作は、最低限の動作確認対象です。確認できない環境では、
成功扱いにせず、「未準備」または「問題あり」として残します。

| 操作 | 最低限見ること | 成功の目安 | できない場合 |
| --- | --- | --- | --- |
| 取得とインストール | `.\scripts\install-distribution.ps1 -Profile standard` | インストールが終わる | インストール問題として扱う |
| 基本確認 | `.\sword.ps1 status`, `.\sword.ps1 verify` | 構成が見え、基本確認が通る | 初回導入未完了 |
| `.env` なし確認 | APIキーや家電設定なしで `verify` する | 実機なしの確認が通る | 基本確認の問題として扱う |
| ローカルファイル | PKL、VRM、音声/動画サンプルの置き場所を見る | 必要なものがある、または未準備と分かる | その機能だけ未準備 |
| 設定反映 | `render-env-files.ps1` の後に `verify` する | 設定ファイルが作られ、確認が通る | 設定問題として扱う |
| 起動予定 | `.\sword.ps1 start` | 何が起動するか見える | 起動前問題として扱う |
| 実起動 | `.\start-home-control-launcher.bat` または `.\sword.ps1 start -Run` | Launch Manager が開く | 起動問題として扱う |
| 画面リンク | Launch Manager から各画面を開く | 必要な画面が開く | その画面は未確認 |
| 停止予定 | `.\sword.ps1 stop` | 何を止めるか見える | 停止前確認の問題 |
| 実停止 | `.\sword.ps1 stop -Run` または `.\stop-home-control-launcher.bat` | 起動したものが止まり、ポートが残らない | 停止/後片付け問題 |
| 簡易テスト | `run-compat-smoke.ps1` | 実機なしの簡易テストが通る | 簡易テスト未完了 |
| 会話とフィードバック | 入力、応答、次の入力での反映を見る | 入力が使われ、フィードバックが反映される | 会話系は未確認 |
| 音声入力 | 音声またはサンプルから入力要約を見る | Thought Coreに渡る | 音声入力は未確認 |
| ジェスチャー | カメラとPKLで認識を見る | 音声入力が開く | ジェスチャーは未確認 |
| アバター | VRM状態または画面上の動きを見る | 表情や動きが確認できる | アバター動作は未確認 |
| Environment State | 状態画面を見る | 現在状態と更新状況が見える | 状態画面は未確認 |
| 家電準備 | Home Assistant 接続と操作候補を見る | 対象家電が操作候補に出る | 家電操作は未準備 |
| 家電操作 | 安全条件つきで1操作だけ試す | 命令送信と状態確認ができる | 家電操作は未確認 |
| 物理確認 | カメラ、センサー、目視などで見る | 実際の変化が確認できる | 物理確認なし |

起動停止の安全性は必須です。起動したなら、停止できること、残ったプロセスや
ポートがないこと、同じ手順をもう一度実行できることを確認します。

## 10. 何か足りない時

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
