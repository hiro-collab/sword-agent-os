# Sword Agent OS Project Handover

更新日: 2026-08-08
状態: 現行実装作業を一時停止し、別の開発ディレクトリ／プロジェクトで方針を再検討するための引継ぎ。製品Goalはtransition receiptがないため、台帳上の`ACTIVE / NOT_RUNNABLE`と実装作業の停止を分ける
対象: 新しい担当開発者またはAIエージェント

## 1. この文書の読み方

この文書は、新しい環境で Sword Agent OS を理解するための最初の入口です。
利用者がGitHubへ残す恒久的なonboarding／design indexとして明示的に依頼した文書であり、task間の一時messageやprivate coordination handoffではありません。private packetやraw evidenceは本文書へ移しません。
旧作業ディレクトリの日誌や一時証拠をすべてコピーする代わりに、次を一つにまとめています。

- 何を実現しようとしていたシステムか
- なぜ現在の構成と名称になっているか
- 現在選択されているソースと、まだ選択されていない候補
- どこまで実装・検証できているか
- 何が未完成か
- 次の環境へ持ち込むものと、持ち込まないもの
- 再開時に最初に確認・判断すること

記述は次のラベルで区別します。

- **事実**: 現在のコード、manifest、commit、既存テストまたは保存済み結果から確認できること
- **設計意図**: 採用済み文書、要件、過去の日誌で一貫して確認できる狙い
- **推定**: 現在の事実から妥当に考えられるが、まだ確定していないこと
- **未証明**: 実装またはテストがあっても、必要な実行・画面・機器・利用者評価まで確認していないこと

古い台帳の詳細なpinや進捗名は歴史資料です。現在の選択状態は、この文書に記載した
manifestとGitの状態を優先してください。

## 2. 現在の結論

- **事実**: 現在の製品目標は完了していません。現行実装作業は、利用者の引継ぎ指示により方針見直しまで一時停止中です。
- **事実**: Goal自体を`stopped`／`abandoned`へ遷移させる`GoalTransitionReceipt`はありません。新しい明示指示が更新するまで、台帳上のGoal状態は`ACTIVE / NOT_RUNNABLE`として扱い、実装作業の停止と混同しません。
- **事実**: 選択済みのParent構成、Control、AITuber Kit、その他organのソースはGit commitで再構築できます。
- **事実**: 最小のAI応答表示と、session／turn／assistant-messageに結び付くpresentation Stop／late fence、Launcherのexact3構成、Windows worker lifecycleにはsource/staticおよびfocused testの強い証拠があります。operation／generation／revision-boundな製品全体のStopは未証明です。
- **未証明**: 選択済みの全構成で、実providerからの応答を実ブラウザの吹き出しへ表示し、visible Stopと全process cleanupまで完了する一連のlive成功はありません。
- **未証明**: 音声、アバター、視覚効果、Home、カメラ、プロジェクター、部屋での存在感、別の人による導入、利用者本人の最終評価は完了していません。
- **事実**: 現コードには固定・fallback・compatibility経路が残ります。minimal routeは`semantic_authority=agentic_provider`の正規event列だけを成功候補として受理し、compatibility／degraded responseを成功bubbleへ通さない境界を持ちます。
- **設計意図／受入規則**: 固定文、canned reply、template、replay、fallback、`direct_send`、同じ入力／turnに対する重複Thought dispatchをordinaryな「AIが考えた成功応答」として扱いません。receipt／再観測後の相関付き再判断はcybernetic loopであり、この重複禁止とは別です。

したがって、現在の正直な状態は **権限を持つ開発者がexact commitからsource compositionを技術的に再構築できる、製品は未完成、live runnableは未証明** です。これは第三者への再配布権を意味しません。

## 3. システムが実現しようとしていたこと

### 3.1 北極星

**設計意図**: Sword Agent OSは、単なるチャット画面、固定コマンド解析器、
アバター表示、Home Assistant操作、エフェクト集のいずれか一つではありません。

利用者が自分のPCと部屋で自然な願いを伝え、ひとつの身体性をもつAIが、
状況・継続記憶・能力を踏まえて本当に判断し、安全に応答・保留・質問・行動し、
結果を観測して訂正し、音声・アバター・表示・部屋の変化で表現し、最後に
Stopと後始末を正直に完了するためのローカル実行基盤です。

```text
自然な願い／観測
  → 入力として受理するかを判定
  → 現在環境・会話継続・関連記憶を取得
  → Thoughtが意味、質問、保留、能力、自然な応答を判断
  → 決定論的な境界が権限・範囲・schemaを検証
  → 一回の行動または表現を実行
  → receipt・現在状態・外部観測を取得
  → 必要ならThoughtが再判断・訂正
  → 吹き出し・音声・アバター・効果・Homeで表現
  → identity-bound Stop／cleanup／residue確認
```

### 3.2 AIと決定論的処理の責務分離

**設計意図**:

- AI／Thoughtは、意味、能力選択、質問、保留、自然な応答を所有します。
- 決定論的コードは、schema、allowlist、権限、重複防止、実行、receipt、Stop、cleanup、privacyを所有します。
- 実行層は成功する会話文を捏造しません。
- AIは実行済み、観測済み、cleanup済みという事実を捏造しません。
- 現在状態、履歴、永続記憶、表示済み、物理的に起きたことを同一視しません。

### 3.3 最初の価値単位と完成形

**設計意図**: 最初の価値単位は小さく、次の順序でした。

1. privateな一つの自然文入力
2. current session／turn／operation identityと、最小限のworking context／freshnessを束縛
3. その入力に対して正規Thought／providerが行う一つの意味判断
4. 一つのterminal outcome。成功時のcanonical assistant responseは`0|1`で、1を超えない。provider unavailable／invalid、privacy rejection、identity不一致ではassistant bubble 0とし、固定された非assistant failure状態だけを許す
5. 一つの既存表示面に、一つの一時テキスト吹き出しを`applied|unknown`として記録
6. 同じidentityに結び付いたvisible Stop
7. duplicate、private echo、誤成功表示、遅延結果の再表示が0
8. presentation cleanupとprocess／listener／temporary artifact cleanupを別々に確認

これは完成形ではなく、完成形へ進むための最小縦経路です。Memory、Environment、
self-output、音声、アバター、Home、effects、導入性、full stack、物理観測、U1は、
この最小経路から外しても要求として削除してはいけません。

**目標と現実装の差**: 歴史的な第一レビュー像は、既存アバター上の応答表示までを
意図していました。現在選択されている`/projection-visual-minimal`はアバターを読み込まず、
吹き出しとStopの境界だけを意図的に切り出しています。これは最小検証には有効ですが、
アバターをもつAIとしての身体性を達成した証拠ではありません。

MemoryやEnvironmentの広い実装は後段でも、最小縦経路を文脈ゼロにしてはいけません。
identity、bounded working context、freshness、privacy、dedupe、receipt、Stop、cleanupは
すべての段階を横断する条件です。Installabilityとmaintainabilityも最後だけの機能ではなく、
各sliceでmanifest、config、README、再現可能なcommitを保つ横断条件です。

## 4. 構成名が表すコンセプト

このプロジェクトの名称は、技術方式より責務と利用体験を表しています。
名前だけで実装済みと誤解せず、「名前が約束するもの」と「現在満たす範囲」を分けてください。

| 名称 | 名前が表すコンセプト | 所有すること | 所有しないこと／現在のギャップ |
|---|---|---|---|
| **Sword Agent OS** | 身体・思考・感覚・行動を一つのローカルAIとして接続するOS層 | 構成、実行境界、proof分離 | 一つの巨大monolithやCodexそのものではない |
| **Parent / Distribution** | どの部品を一つの製品構成として選ぶか | repo、branch、commit、target path | nested checkoutが先に進んだだけでは採用にならない |
| **Control Plane** | 意味を実行可能な運用へ変換する制御面 | contracts、policies、Launcher、Thought、broker | 画面、家電、音声の意味を勝手に再解釈しない |
| **Launcher / Supervisor** | 選択された構成を所有して起動・監視・停止する管理者 | plan、worker、probe、相関、owned cleanup | サービスが起動しただけで製品成功とはしない |
| **Worker** | 一つのサービス操作をOSプロセスとして実行する実働単位 | start/probe/stopのtransportと結果 | semantic判断、全体cleanupの成功宣言 |
| **Plan / Probe** | 起動すべき構成と、その準備完了を別々に表す | 選択service集合、依存、readiness観測 | previewをlive成功へ昇格しない |
| **Thought Core** | 製品の意味判断の中心 | 会話、質問、hold、capability、自然応答 | 権限・実行済み事実・物理状態 |
| **Provider Broker** | credentialを隔離し、外部LLM経路を一つに限定する門 | loopback provider transport、固定失敗分類 | 意味判断、表示、公式same-turn receiptは未完成 |
| **Memory Core** | 永続的に残す価値のある記憶の正本 | candidate policy、hold/reject/promote/commit、forget、retrieval scope | Thought等からcandidate提出は受けるが、現在状態、raw transcript、Event Journalではない |
| **Environment State** | 現在の世界を出典・鮮度付きで表す | Home/camera/vision/healthの集約 | 物理世界そのもの、Thoughtの推測、永続記憶 |
| **Event Journal** | 何が起きたかのredacted履歴 | operational history | 現在状態、学習済み記憶、成功権限 |
| **Current View / Status** | 今の状態を投影する読み取り面 | current status | 履歴や将来予測 |
| **Body / Body Schema** | 自分が利用できるorgan、health、接続、鮮度を表す身体図 | body planとstatusからの自己状態投影 | 外界scene、意味判断、完全な動的身体モデルは未完成 |
| **Self-observation / Self Mirror** | 自分の出力が実際に描画・再生されたかを測り、利用者入力と分離する自己観測 | 現行のvisual ROI／metric、将来の相関済みaudio/visual self-output、unclearの保持 | 自分の出力からuser intentやretry権限を生成しない。physical proof、U1でもない |
| **Organ** | 身体の器官のように交換可能な能力単位 | 入力、反射、環境、行動、表現、診断 | 全体のsemantic authority |
| **Input Gate** | 音があったことではなく、利用者入力として受理する境界 | user-intent admission | VAD/AEC/transportだけでの自動受理 |
| **AITuber Kit / Embodiment** | AIの応答を身体と画面上の存在として表す | bubble、avatar、motion、speech queue、projection | provider secret、行動済み事実 |
| **Projection Visual family / Stage** | operator modeは入力・操作面、passive／stage-outputは利用者・部屋へ見せる清潔な最終表示面 | avatar、bubble、effects、HUD、operatorとstageの表示状態連携 | semantic判断、単独での物理proof |
| **Bubble** | 一つのassistant messageを短時間だけ見せる吹き出し | message identityに結び付くpresentation | 固定された成功文、server/process cleanup |
| **Stop** | 対象identityの進行・表示・所有resourceを正直に止める要求 | 各層の停止と結果分類 | DOM削除だけを全cleanupと呼ばない |
| **Home Control Safety Bridge** | AI判断と家電APIの間の安全な橋 | allowlist、preview、execute、receipt | 自然言語の意味判断、物理動作の自動断定 |
| **Projection Effects** | 意味に応じた有限の身体表現 | bounded effect、lifecycle、receipt、auto-end | 無限常駐、別のsemantic authority |
| **System House / Diagnostics** | システム全体の状態を外から確認する家の見取り図 | topology、redacted trace | 製品体験そのもの |

## 5. 現在のソース選択状態

この章では、似ているが別の状態語を次のように使います。

- **candidate**: localまたはreview済みの候補。remote到達性もParent採用も含意しない。
- **published**: exact commitを指すremote refが確認できること。品質、license、採用、runtimeを含意しない。
- **Parent-selected pin**: Parent manifestがそのbranch／commitを構成要素として参照していること。
- **checkout-reconciled**: 選択Parent配下のnested checkoutがmanifest commitと一致すること。
- **Parent-adopted composition**: Parent-selected pin、remote validation、nested checkout reconciliationを同じ構成で確認したこと。
- **runnable**: 選択構成を実際に起動し、必要serviceのReadyと所有・停止境界を確認したこと。source/test/adoptionだけではrunnableにならない。

### 5.1 選択済みParent

**事実**:

- Repository: `https://github.com/hiro-collab/sword-agent-os.git`
- Branch: `work/parent-ordinary-route-contract-v1`
- Commit: `ebf1758cb4daa1ffecf018bbba183a6a786c8231`
- Distribution version: `0.1.39`
- Control pin: `work/control-ait-worker-error-class-v0` / `9a8fa2fb1c617dbe8dd572115267becdb2123169`
- AITuber pin: `work/aituber-minimal-text-bubble-stop-r3-v0` / `ce27f69bfcfdb63983c0de8599788197248bcb78`
- 選択Parent配下のtracked sourceはcleanで、10個のnested checkoutはmanifest commitと一致していました。

`ebf1758...` は製品構成を選択したtechnical baseです。本引継ぎ文書を保存するdocumentation-only descendantが同じbranchへ追加された場合、fresh branch HEADはこれより新しくなります。再開時はbranch HEADの差分を確認し、manifest／source選択が変わっていないことを確かめてください。

`main`はこの選択構成より古いため、再開時に単にmainだけをcloneしてはいけません。

### 5.2 organ pins

正本は [standard-sources.json](manifests/organs/standard-sources.json) です。
この節の`selected`は「このParent compositionから参照されるsource identity」という狭い意味です。manifest内の`standard_candidate`、Controlの`reference_source`、avatarの`deferred_reference`等のadoption表現を上書きせず、license clear、publication、runnable、product acceptanceを意味しません。

| Organ | Role | Branch | Commit | 状態 |
|---|---|---|---|---|
| ai-talk-core | speech-input | `main` | `0478291bff94a5068bc1c6da59e2ce6f4fc904a3` | selected source |
| mediapipe-sword-sign | reflex | `feature/camera-hub-topic-envelope` | `292ff9c51bb88363d062bc6d74877bd87b039f23` | selected source |
| environment-state-server | environment | `work/environment-camera-exclusion-readiness-v1` | `4b5106610828eff7bdab8120cf2c7942fbf929b3` | selected source |
| vision-snapshot-processor | environment input | `main` | `685fceca0e56ea33beaa0d999aa1788724429af9` | selected source |
| home-assistant-server | action | `work/home-curtain-standing-authority-v1` | `163c81b48a3333f005df721c3a337d5c6acab839` | selected source |
| tts-service | expression | `main` | `404fb041a1a25447bef3d03937b32f736bf2465f` | selected source |
| avatar-service | expression | `main` | `abd203a28e1bb83732c20db8a7b7cf49841bdefe` | deferred reference |
| aituber-kit | expression | `work/aituber-minimal-text-bubble-stop-r3-v0` | `ce27f69bfcfdb63983c0de8599788197248bcb78` | selected source; runtime reflection not proven |
| touchdesigner-ai-controller | display | `codex/projection-visual-docs` | `fc82651fe2adcc14fed129d64e2fade6417df182` | selected source |
| system-house-renderer | diagnostics | `codex/system-house-authority-map` | `148ae714d3631b73b48dc51634c69c3acc5aab1f` | selected source |

### 5.3 未選択の最新Control候補

**事実**:

- Branch: `work/control-windows-worker-fixture-v0`
- Commit: `2b00bdd1c9a7794f84d80c607dc72c2f3b0f3631`
- Parent: selected Control `9a8fa2fb1c617dbe8dd572115267becdb2123169`
- Subject: `fix(launcher): align exact3 Windows worker plan`
- Exact paths:
  - `ops/scripts/home-control-stack/launcher-service-plan.psm1`
  - `ops/scripts/home-control-stack/launcher-job-worker.ps1`
  - `tests/launcher-job-worker.test.js`

この候補は、exact3でoptionalなHome、Environment、Thought watcher、TouchDesignerを
Windows worker plan上でも正しく欠落可能にし、requiredなbroker、Thought、AITをfail-closeに保つ修正です。
新service、profile、schema、store、endpoint、authorityは増やしていません。

**事実**: source/static review、focused lifecycle、実AITのstart/probe/page/stop/worker cleanupについて
保存済みのclear結果があります。`/projection-visual-minimal/` はdirect HTTP 200まで確認されています。

**未選択／未証明**:

- Parent manifestはまだこのcommitを選択していません。
- fresh remote queryでは、選択済み親refは`9a8fa2f...`と一致し、candidate refは不在でした。
- exact commit/historyの公開前Security reviewはCLEARですが、実際のpushは個別承認境界でHOLDされ、完了していません。
- この候補を含むfull exact3 Launcher、provider、browser bubble、visible Stopのlive chainは未証明です。

**選択済みControlに残る既知の不整合**: `9a8fa2f...`のgraph／private planはbroker＋Thought＋AITのexact3を意図しますが、選択済みPowerShell loaderの`launcher-service-plan.psm1`はHome、Environment、Thought watcher、TouchDesignerをまだ`required`として扱います。したがって、選択pinだけでWindows exact3のend-to-end coherenceが証明されたとは言えません。`2b00bdd...`はこのloader／worker境界を直す未選択候補であり、そのfocused／real-AIT結果を選択済み`9a8fa2f...`のruntime結果として数えてはいけません。

再開時は、まずremote refをfreshに確認し、候補を保存するか破棄するかを方針決定してください。
自動的にParentへ採用してはいけません。

## 6. 全体アーキテクチャ

次の図は、最小表示routeだけでなくMemory／Environment／action／observationまで閉じる**目標アーキテクチャ**です。

```text
User / Room
  ├─ text / browser ──────────────┐
  ├─ microphone / ai-talk-core ───┴─► Input Gate ─► Thought Core
  └─ camera
       ├─► MediaPipe ─► bounded Reflex
       │       └──────► Environment observations ─┐
       └─► Vision Snapshot ─► Environment State ──┴─► Thought context

     Thought Core ───── Provider Broker ───── External LLM
         │   │
         │   ├─ Memory candidates / continuity
         │   └─ Environment context / observations
         ├─ action_request
         │      └─► Deterministic Action Boundary
         │              └─► Home Assistant Safety Bridge / bounded actuator
         ├─ canonical assistant response / expression request
         │      └─► owner-local Expression Boundary
         │              ├─► AITuber bubble / avatar / browser playback
         │              ├─► standalone TTS synthesis
         │              └─► Display Runtime / optional TouchDesigner adapter
         └─ motion / effect request
                └─► owner-local Motion / Effect Boundary
                        └─► AITuber motion / finite effect

      receipt / status / journal / environment re-observation
             │
             └──────────────► Thought re-evaluation

Launcher / Supervisor surrounds selected runtime services and owns
plan → worker → probe → stop → cleanup classification.
```

Camera、MediaPipe、Vision、Environmentの観測はcurrent context／bounded Reflexの材料です。観測、gesture、model outputだけで新しいuser turnを作ってはいけません。`Input Gate`を通るprivate text／speechと、世界のobservation provenanceを分離します。

現在選択されているminimal text routeは、より狭く次を直接結びます。

```text
projection-visual-minimal
  → /api/thoughtCoreChat
  → Thought Core SSE
  → validated assistant.message
  → one strict transient bubble / presentation Stop
```

このrouteはInput Gate、Environment、Memory、deterministic action、Homeを通りません。境界検証用の最小sliceであり、目標アーキテクチャのfull loopや既存avatar体験を証明しません。

主要な設計資料:

- [README.md](README.md)
- [Architecture](docs/architecture.md)
- [Module Usage Index](docs/module-usage-index.md)
- [Standard Distribution Map](docs/standard-distribution-map.md)
- [Proof Layers](docs/proof-layers.md)
- [Distribution manifest](manifests/distributions/standard.json)
- [Control manifest](manifests/control-plane/standard.json)
- [Organ manifest](manifests/organs/standard-sources.json)

## 7. 主要コンポーネント

### 7.1 Front Door / Configuration / Distribution

**事実**:

- `sword.ps1` が `status`、`verify`、`doctor`、`start`、`hold-live`、`stop` の入口です。
- [standard distribution manifest](manifests/distributions/standard.json) がcontrol、organs、env、dependencies、manual assetsを結びます。
- [env template](templates/env/sword-agent-os.env.example) からローカル設定を生成します。
- AITuberの`.env`は`preserve_local=true`で、中央envによる機械的上書きを避けます。

**設計意図**: 人、AI実行、保守者の入口を薄くし、各moduleの内部実装をfront doorへ逆流させません。
Human operator、AI runtime、maintainer／Codex inspectionは別routeです。Codexは製品runtimeの必須部品ではなく、保守証拠はuser intent、device proof、Git adoption、final readinessを付与しません。

### 7.2 Control Launcher / Supervisor / Worker

主要ファイル:

- `control-plane/core/tools/home-control-launcher/server.js`
- `control-plane/core/tools/home-control-launcher/launcher-private-service-plan.js`
- `control-plane/core/tools/home-control-launcher/launcher-supervisor-runtime.js`
- `control-plane/core/tools/home-control-launcher/launcher-supervisor-reducer.js`
- `control-plane/core/tools/home-control-launcher/launcher-supervisor-contract.js`
- `control-plane/core/tools/home-control-launcher/launcher-job-worker-client.js`
- `control-plane/core/ops/scripts/home-control-stack/launcher-job-worker.ps1`
- `control-plane/core/ops/scripts/home-control-stack/launcher-service-plan.psm1`
- `control-plane/core/ops/manifests/launcher-service-graph.standard.v1.json`
- `control-plane/core/ops/manifests/launcher-probe-descriptors.standard.v1.json`

**事実**: 選択済みgraph／private planが意図するexact3の必須serviceはbroker、Thought、AITです。Home、Environment、watcher、TouchDesigner等はoptionalで、VOICEVOXはexternalです。ただし選択PowerShell loaderは四つのoptional owned serviceをまだ`required`として扱う既知不整合があり、未選択`2b00bdd...`だけがそのWindows loader／worker境界を揃えています。

**設計意図**: 同じLauncher familyでminimal planとfull profileを扱い、別のSupervisorや二重authorityを増やさないためです。

**既知の契約差**:

- Launcher serverの`/api/start`は保存済み`expectedConfigSha256`を要求しますが、現行compat client `system.ps1`は`profileId + options`だけを送ります。user-facing Startはこのままrunnableとみなせません。
- `sword.ps1 start -Run`はLauncher processを開始しmanifest healthを確認する入口で、exact3 stack Start／Ready完了そのものではありません。
- 選択runtimeのrepeated `STOPPED`／no-operation経路、Launcher PID消滅、HTTP成功、wrapperの`already_stopped`表示だけでは、保持client、private plan、lease、child residue 0を証明しません。

**未証明**: 選択済み最新構成でのfresh Start/Readyと、identityに結び付くStop後の全owned resource cleanup。

### 7.3 Thought Core / LLM / Provider

主要ファイル:

- `control-plane/core/services/thought-core/src/thought_core/server.py`
- `control-plane/core/services/thought-core/src/thought_core/loop.py`
- `control-plane/core/services/thought-core/src/thought_core/agentic_turn_runtime_provider.py`
- `control-plane/core/services/thought-core/src/thought_core/agentic_turn_decision.py`
- `control-plane/core/services/thought-core/src/thought_core/conversation_continuity.py`
- `control-plane/core/src/sword_voice_agent/apps/openai_broker.py`
- `control-plane/core/src/sword_voice_agent/adapters/openai_broker.py`

**事実**:

- Thought Coreは`POST /turn`とSSEを持ちます。
- agentic decisionはconversation、clarification、hold、capabilityを区別します。
- loopback brokerがcredentialを隔離し、concurrency、queue、retryを制限します。
- process-localなconversation continuityがあります。

**設計意図**: LLMに意味と文章を任せつつ、事実、権限、実行、cleanupを任せないためです。

**未完成**:

- Memory CoreとEnvironmentの完全なlive binding
- restart後のlater-turn continuity
- official provider-attempt receiptとsame-turn authorship proof
- 旧README、degraded parser、互換経路の整理

### 7.4 Minimal AITuber route / Bubble / Stop

主要ファイル:

- `organs/expression/aituber-kit/src/pages/projection-visual-minimal.tsx`
- `organs/expression/aituber-kit/src/pages/api/thoughtCoreChat.ts`
- `organs/expression/aituber-kit/src/components/projectionVisualStrictAssistantBubble.tsx`
- `organs/expression/aituber-kit/src/__tests__/pages/projectionVisualMinimalText.test.tsx`
- `organs/expression/aituber-kit/src/__tests__/pages/api/thoughtCoreChat.test.ts`
- `organs/expression/aituber-kit/src/__tests__/components/projectionVisualStrictAssistantBubble.test.tsx`

ここでいう **バブル** は、AIの応答を画面上に一時表示するテキスト吹き出しです。
成功文が固定されているわけではありません。

**事実**:

- ページは入力、Send、一つの応答、Stopだけの最小構成です。
- requestは一回だけ`/api/thoughtCoreChat/`へ送ります。
- session、turn、assistantMessage identityとイベント順序を厳密に検証します。
- private/raw provider dataをブラウザへ出しません。
- エラー時は成功バブルを出しません。
- Stopは対象バブルだけを消し、requestをabortし、late resultの再表示を防ぎます。
- DOM上の`complete|unknown`はpresentation cleanupだけで、process cleanupではありません。
- 現在の`complete|unknown`はsource/test上のlocal DOM subtree観測です。machine-consumedな`bubble_applied|presentation_unknown` terminal receipt、live DOM、visible pixel、利用者観測は未接続／未証明です。

**設計意図**: 古い音声・アバター・message receiver経路と混線せず、「AIが考えた応答」を最小の表示面で検証するためです。

### 7.5 Speech Input / STT

主要ファイル:

- `organs/speech-input/ai-talk-core/src/core/input_gate.py`
- `organs/speech-input/ai-talk-core/src/core/pipeline.py`
- `organs/speech-input/ai-talk-core/src/core/handoff_bridge.py`
- `organs/speech-input/ai-talk-core/docs/integration-contract.md`
- AITuber: `src/hooks/useVoiceRecognition.ts`、`useWhisperRecognition.ts`、`useBrowserSpeechRecognition.ts`

**事実**: ai-talk-coreはaudio/mic/browser入力、Whisper、VAD、silence trim、partial/final、handoff候補、InputGateを持ちます。AITuberにもブラウザ単体のSTT経路があります。

**設計意図**: 音が検出されたことと、利用者の意図として受理したことを分けます。

**標準authority**: 利用者の標準TurnInput admissionはai-talk-core／InputGateです。AITuber内蔵STTはcompatibility資産であり、第二の標準ownerではありません。未決定なのは、互換資産として維持するかconsumer確認後に退役させるかです。`ai_talk_core_web`のprofile→Control propagationはPARTIALです。

**security residual**: AITuberのWhisper APIにはファイル情報やtranscription応答をserver logへ出す箇所があり、live再開前にprivacy再点検が必要です。

### 7.6 Memory / Journal / Current View

主要ファイル:

- `runtime/memory-core/README.md`
- `runtime/memory-core/src/memory_core/store.py`
- `runtime/event-journal/README.md`
- `control-plane/core/src/sword_voice_agent/system/memory_store.py`

**事実**: SQLite Memory Coreと、Thought側のlegacy JSONL memory storeが並存します。Event Journalはredacted operational historyで、MemoryやCurrent Viewとは別です。Thought等は明示的rememberからredacted candidateを提出できますが、durable truthを直接commitしません。Memory Core policyがhold／reject／promote／commit／forgetを決めます。

**設計意図**: 現在状態、履歴、永続記憶を混同せず、明示的remember、forget、retrieval scopeを政策下で扱います。推定嗜好はsession-first、現在状態らしい記憶はhistorical observationとして扱い、利用前にcurrent Environmentで再検証します。

**未完成**: SQLiteをThoughtの正規writer/retrieverへ接続し、JSONL/short memory/fallbackを一方向に退役させること。第三のstoreやsilent dual-writeを作ってはいけません。

### 7.7 Environment / Vision / Reflex

主要ディレクトリ:

- `organs/environment/environment-state-server`
- `organs/environment/vision-snapshot-processor`
- `organs/reflex/mediapipe-sword-sign`

**事実**: EnvironmentはHome action state、camera/gesture、room-light推定、module healthを出典・鮮度付きで集約します。自分でカメラを開かず、gesture推論もしません。

**設計意図**: Thoughtの推測ではなく、現在世界を別authorityから渡します。

**未完成**: stable entity track、bounds、velocity、occlusion、spatial relation、moving-target revisionとThought binding。カメラ照度を物理照明やHome論理状態の証明にしてはいけません。

### 7.8 Home / Action

主要ディレクトリ:

- `organs/action/home-assistant-server`
- `control-plane/core/services/thought-core/src/thought_core/tools.py`

**事実**: Home Safety Bridgeはallowlist、一覧、状態、preview、execute、audit、fault injectionを持ちます。Thoughtはraw entity IDではなくbounded action IDを使います。

**設計意図**: Thoughtが意味を決め、Bridgeは一回の安全な具体実行とreceiptだけを所有します。

**未証明**: current routeでの一操作、Home状態、外部観測、物理動作、restoreを同じ相関系列で確認すること。

### 7.9 TTS / Voice Output

主要ディレクトリ:

- `organs/expression/tts-service`
- AITuber: `src/features/messages/speakCharacter.ts`、`speakQueue.ts`、`synthesizeVoice*`

**事実**: standalone tts-serviceは複数synthesizer、local player、dedupe、status、volumeを持ちます。AITuberにもavatar/lipsyncと密結合した音声queueがあります。

**目標owner**: 標準形ではtts-serviceをbounded synthesisに限定し、AITuberを唯一のbrowser playback／lipsync／render-applied ownerにします。現時点ではtts-service→AIT playback artifact adapterがMISSINGで、standalone local playbackとAIT内蔵synthesisはcompatibility経路です。minimal text routeはvoice 0で、bubble Stopと音声Stopは別責務です。

### 7.10 Avatar / Motion / Projection

主要ファイル:

- AITuber: `src/pages/projection-visual.tsx`
- `src/components/vrmViewer.tsx`
- `src/features/motionRuntime/`
- `src/features/projectionDisplay/`
- Display: `organs/display/touchdesigner-ai-controller/tools/`

**事実**: VRM/VRMA、Live2D、PNGTuber、motion registry/session/driver/Stop/late-after-stopの内部足場、operator/passive/stage-output、display-state bridge、TouchDesigner UDP投影があります。

**設計意図**: AIの意味を身体表現へ変換し、操作画面とstage出力を分離します。製品runtimeではTouchDesignerはsemantic authorityではなく投影器です。一方、O1／T053のTOE／ExpandはFire／Thunderを再現するsource-recipe／provenance oracleです。製品presentation authority、recipe oracle、未確定の最終background／compositor authorityを混同しません。

**PARTIAL／HELD**: 標準semantic motionにはParent producer→AIT adapter、source provenance、semantic Ready、共通generation/reset epoch、accepted/applied/terminal-cleanup receiptが不足します。別Startは標準ではbusy rejectし、暗黙のreceiver-local置換を通常成功にしません。motion indicator／mouth reachabilityは実際の自然motionやtrue lipsyncの証明ではありません。

AIT stage-outputがcanonical composite host、Display Runtimeが最終AIT compositeのprojector transport、TouchDesignerがoptional UDP／visual adapterです。TouchDesignerはsemantic authorityでもcanonical compositorでもありません。`hud=0`はstatus HUDだけを隠し、assistant bubbleとは別です。

**Stage Reset**は、全active transient bubble／audio／lipsync／motion／effects／SFXを停止・除去し、安全なneutral background＋idle avatarへ戻すpresentation操作として必要ですが、現在`MISSING / HOLD`です。選択effectだけを止めるEffect Reset、Launcher Stop、Emergency、Display停止、projector rollbackとは別です。genericな「Reset」は対象不明ならclarify／action 0にします。

**未証明**: 選択buildでのavatar、motion、stage-output、projector、room、physical pixels、U1。`avatar-service`はdeferred referenceです。

### 7.11 Projection Effects

主要領域:

- AITuber: `src/features/projectionEffects/`
- `registry.ts`、`effectHost.ts`、`projectionEffectIntent.ts`
- `browser/avatarFireThunderLabOverlay.tsx`、`browser/fireThunderLabCanvasLayer.tsx`、`browser/fireThunderPooledSurfaces.ts`
- `browser/projectionEffectCompositor.tsx`、`browser/projectionEffectSurfacePool.ts`
- `plugins/fire/p027/*`、`plugins/thunderBall/webgl2/*`
- Fire/Thunder experiment pagesはmanual/reference surface

Production joinは次です。

```text
projection-visual.tsx
  → projectionEffectIntent.ts
  → AvatarFireThunderEffectLayer / avatarFireThunderLabOverlay.tsx
  → fireThunderLabCanvasLayer.tsx
  → pooled surfaces / compositor / surface pool
  → Fire P027 または ThunderBall WebGL2 engine
```

source上、stage-outputだけがproduction receiverで、layer順序はbackground-input → avatar → effects → speech-hudです。operator、passive、manual labはproduction receiverではありません。このDOM／host seamは、一つの最終GPU framebuffer、背景合成、projector出力の完成証明ではありません。

**事実**: finite lifetime、fade、内部Stop/reset/dispose、intent receipt、dedupe、cross-tab transport、cleanup/quarantine、bounded surface pool、WebGL2/Canvas実装があります。

Fire／Thunderはstage-outputの専用intent-host経路へsource-integratedされていますが、default registry／settingsの通常選択肢ではありません。defaultは`none|fluidFireRelay`で、Fire／Thunder登録はlab／dedicated host側です。20-effect catalogは計画であり、実装済みinventoryではありません。current live browser、final composite、projector／room、U1 proofは0です。

選択AIT `ce27f69...`のcritical effects sourceは、歴史的なvisual source `2fcb69e...`から保持されていますが、同じsource byteはcurrent selected-buildのvisual parityを証明しません。generic evidence commitやfilming lineageはhistory/referenceに留めます。

**設計意図**: 会話に応じた効果を一つだけ有限時間実行し、安全に自動終了する身体表現です。

**CURRENT内部／PARTIAL cross-hop**: host内部scaffoldは存在しますが、標準producer→adapter→consumer mapping、外部finite-complete＋resource-cleanup terminal receipt、選択effect/session/reset epochは未完成です。標準Start中の別Startはbusy rejectし、置換は明示操作と旧effectのReset／cleanup完了後にだけ行います。Effect Resetは選択effectだけを対象にし、内部receiptをfull standard lifecycle proofへ昇格しません。

Fire／Thunderはcybernetic dexterityを学習・評価する代表sliceであり、製品そのもののontologyではありません。外部のcyber-techniqueやTouchDesigner知識はadvisory inputに留め、Sword側がbounded adaptation、実行、観測、cleanupを所有します。

最終的には、AIがeffectを選択→parameterize→有限実行→receipt／観測→必要なら調整する再利用可能なcapability loopを目指します。scene、手／頭、複数／移動target、relation grounding、final compositionは未完成です。

#### Private external recipe oracles

Fire／Thunderの旧PC oracleはlocal-onlyです。local／private path、file name、size、hash、抽出recipe値はこのpublic handoverへ記載せず、旧ディレクトリ側のprivate inventoryで管理します。provenance、license、公開・派生利用権が確認されるまで、製品repoへのvendor／公開／実装移植はHOLDします。

candidate screenshotやmanual lab thresholdは原典toleranceを決めません。S4の最終background／compositor recipeは未確定です。green placeholder、FluidFireRelay compatibility surface、旧demoからalpha／tone／palette／background authorityを推定しません。

Reuse分類は次です。

- Keep/reuse: stage-output sole host、intent／host／registry、pool／compositor、P027／T053 WebGL2 engines、lifecycle／receipt／dedupe／quarantine／cleanup、oracle index。
- Reference/manual only: experiment pages、Self Mirror exact4、generic evidence、historical filming runs。
- Retain without conflating: Canvas2D Fluid compatibility surfaceとCPU topology renderer。consumer0／置換証拠まで削除しません。
- Defer: stale definition metadata、final S4 background／compositor、広いcatalog、relation-based placement。

**未証明**: Fire/Thunderの原典parity、current production stage、最終composite、projector/room/U1。lab pageの成功をproduction成功にしてはいけません。

### 7.12 Body Schema / Self Mirror

主要ディレクトリ:

- `runtime/body-schema/README.md`
- `runtime/body-schema/`のBody Plan／builder／contracts
- `runtime/visual-motion-analyzer/README.md`
- `runtime/visual-motion-analyzer/`のscenario／consumer route／bounded metric helper

**事実**: Body Schemaは利用可能organ、health、connection、freshnessをcurrent self-body projectionとして組み立てます。Self Mirrorはbrowser ROI／visual motionの相関付きmetricを測る診断面です。VRM Model Telemetryの内部適用と、Self Mirrorの画面変化観測は別のproofです。

**責務境界**: Body SchemaはInputGate、action、意味判断を所有しません。Self Mirrorはcommand、retry、physical proof、U1を所有せず、観測からuser intentを作りません。audio self-output／InputGate fenceは別契約です。

**未証明**: selected live Body binding、current stageのSelf Mirror、audio self-output fence、physical avatar／U1。

### 7.13 Diagnostics / System House

主要ディレクトリ:

- `organs/diagnostics/system-house-renderer`
- `docs/proof-layers.md`

**設計意図**: topology、status、traceをprivate dataを漏らさず確認し、source、runtime、display、physical、U1を別々に扱います。

## 8. Proofの現在地

下位の証拠を上位へ昇格してはいけません。

| Layer | 現在確認できること | 現在確認できないこと |
|---|---|---|
| Source / static | manifests、contracts、minimal route、exact3 plan、Stop/lifecycle code | 実provider、実画面、物理動作 |
| Focused tests | AIT minimal 3 suites 94/94、Control exact3/worker/probeのfocused結果、後続candidate lifecycle | broad current full suite、別環境再現 |
| Candidate publication | Parent `ebf1758`とControl `9a8fa2f`は追跡refがある | Control `2b00bdd`はSecurity preflight CLEARだがremote ref不在・push未完了 |
| Parent selection / checkout reconciliation | Parent `ebf1758`のmanifestはControl `9a8fa2f`を選択し、配下checkoutはlocal manifest 10/10一致 | 後続candidateのParent選択、remote validation、nested reconciliation |
| Real AIT reachability | candidate workerでAIT start/probe/minimal page HTTP 200/stop/worker cleanupの保存済み結果 | full Launcher exact3、provider、browser interaction |
| Provider / Thought | source上のagentic authorityとprivacy境界 | official same-turn attempt receipt、live input固有応答 |
| Browser / presentation | source/test上のone bubble、visible Stop、late fence | 選択live browserでの実表示とDOM cleanup |
| Process cleanup | focused worker lifecycleと限定AIT worker cleanup | full Launcher/broker/Thought/AITのowned cleanup |
| Voice / avatar / effects / Home | 各moduleのsourceと個別歴史証拠 | current full-stack、audible/visible/device coexistence |
| Physical / U1 | なし | projector、room、家電、音、魅力、最終利用者評価 |

## 9. 既知の問題と未完成事項

### P0: 再開前に閉じるか判断すること

1. Control `2b00bdd`をexact payload/destination承認後にGitHubへ保存するか、selected `9a8fa2f`で再開するか。
2. 選択構成でfresh exact3 LauncherをStart/Readyまで到達させること。
3. provider→Thought→AIT→実browserの一回のinput-specific responseを証明すること。
4. 一つのbubble、visible Stop、late0、presentation cleanup、process cleanupを別々に証明すること。
5. official provider attempt/authorshipを既存event family内でどう証明するか。

### P1: 最小routeの後に失ってはいけない要求

- Memory Coreとlater-turn influence
- Environment dynamic grounding
- self-outputと同時入力の境界
- voice/TTS/lipsync
- avatar/motion/effects
- Home action/receipt/re-observation/restore
- installability by another person
- current full-stack coexistence
- physical projector/room/device proof
- user U1と公開・撮影同意
- capability-as-API: AIの提案とdeterministic validator／executorの分離
- 観測→比較→補正のcybernetic loop
- operator面とstage-output面の分離
- Stopとは別のReset／Emergency／unmount契約
- owner、phase、reason、cleanup certaintyを限定公開する診断

**Accepted requirement**: `REQ-PRODUCT-COMPLETION-001`は、loopがhuman wishだけでなくAI／Thought Core自身のboundedなwish、feeling、motivationから始まることも認めます。これらは直接の実行権限ではありません。意味解釈、能力選択、clarify／hold／action、自然応答はAI側に置き、すべての提案actionは権限、範囲、schema、policy、dedupe、receipt、observation provenance、cleanup、reset、emergency safetyを所有する同じdeterministic capability-as-API境界を必ず通します。

### Accepted requirements: deferredは削除ではない

旧作業ディレクトリにあるaccepted requirementは、技術pinが古くても要求の索引として保持します。新環境では少なくとも次の残件を再確認してください。

| Requirement / row | 残すべき要求と未完部分 |
|---|---|
| `REQ-PRODUCT-COMPLETION-001` / `A-CYBERNETIC-LOOP` | AIの提案、決定論的実行、receipt、観測、比較、補正、truthful completionを一つのloopとして閉じる |
| 同 / `A-SELF-OUTPUT-AWARENESS` | 既知TTS相関、実PC-output loopback、同時の本物の利用者発話、privacy、cleanupを分離し、自音声を新しいTurnInputへ戻さない |
| 同 / `B-INSTALLABILITY` | 別の人が新しい環境へ導入し、秘密値を再設定し、標準構成を再現できること。旧cache／worktreeのコピーを成功扱いしない |
| 同 / `C-PLATFORM-MAINTAINABILITY` | source/runtime/browser/device/physical/U1のproofを混ぜず、失敗やunknownを成功へ変換しない。重複authority／legacyをconsumer証拠付きで整理し、境界付きcapabilityを安全に増減できること |
| 同 / `D-PRODUCT-APPEAL-AND-ROOM-PRESENCE` | Sword固有で魅力的・記憶に残り、部屋に置きたい身体性と表現を目指すこと |
| 同 / `VISUAL-SURFACES` | operator、passive、stage-output、projection、effect、diagnostic surfaceの所有とclean outputを分けること |
| 同 / `FULL-STACK-CONVERSATION` | 実browser STT、実VOICEVOX、avatar release／late motion 0、production display transport、Home coexistence、厳密cleanupを、一つのcorrelation identityが通る一回のproduction-topology runで証明する。別々の成功を継ぎ合わせない |
| 同 / `U1` | 技術証拠の後に、利用者本人が魅力・自然さ・受容性を判断する。U1は技術証拠を代替しない |
| `REQ-RR001-NATURAL-CONVERSATION-AND-STATE-AWARENESS` | camera画像判断、provenance／conflict、policy switching、実LLM review、利用者が確認できる二次元Thought graph |
| `REQ-AVATAR-MOTION-DANCE-001` | 柔軟なmotion／dance、model compatibility、asset provenance／license、安全fallback、Homeと混線しないroute |

### 文書・設計の不一致

- `docs/aituberkit-sword-adapter-inventory.md` はadapter `0.1.2`／旧commitを記載し、manifest `0.1.3`／`ce27f69`より古い。
- 古いREADMEにはThoughtへAPI keyを直接置く説明やCodex CLI経路が残る可能性がある。
- `context_refs.route`はminimal pageでも`projection-visual`名称が残る。
- Memory READMEの広いraw記録案は現在のprivacy規則と再照合が必要。
- Effect definition/diagnostics/defaultsには古いFire/Thunder表現が残る可能性がある。
- checkpoint097台帳のParent/Control値は、後続の選択済みGit状態より古い。

### 過去の繰返し失敗から残す教訓

- test oracle failureをproduction defectと即断しない。
- 共有cache、既存state、sandboxのdubious ownershipをsource mismatchと混同しない。
- preview clearをprivate-plan/save/start/ready proofにしない。
- 一つのHOLDを無関係な全作業停止へ広げない。
- 同じtest/runを繰返す前に、lifecycle前提とcapture contractを一括で静的確認する。
- Managerは技術調査をIntegrationと重複せず、目的・価値・優先・完了を判断する。
- 新service/store/schema/authorityを増やす前に既存familyで閉じられないか確認する。
- role titleや古い日誌だけでownerを決めず、task identity、project binding、cwd、lineage、appointment、counterpartを確認する。
- terminal result／first blockerは即時routingし、laneを閉じる前に非衝突のnext-safe unitを用意する。heartbeatや監視だけをmanagement progressに数えない。
- 30分間、diff／artifact、review／test result、commit／push、runtime gate、new blocker、実dispatchのいずれも0なら`ACTIVE_STALLED`として介入する。
- writerは一人、scopeはexact bounded、戻りbyteはimmutable refreezeし、同一byteを独立QA／Securityへ渡してterminal reconciliationする。
- review可能な自然単位ごとにexact commitを作り、全変更path／upstreamを再確認してnormal non-force pushする。

## 10. セットアップと設定

### 10.1 必須ツール

- Git
- PowerShell 7
- uv
- Node.js `24.x`（選択AITuber `package.json`のengine条件）
- npm `>=11.16.0 <13`（同engine条件）
- Python: componentにより`>=3.10`または`>=3.11`。MediaPipe organは`>=3.11,<3.13`

構成により任意:

- ffmpeg / ffprobe
- MediaMTX
- VOICEVOX
- TouchDesigner
- Camera / microphone / projector

### 10.2 主要ライブラリ、framework、外部サービス

これは全依存の転記ではなく、構成を理解するための要約です。正確なversionは各lockfileを正とします。

| 領域 | 主な技術 | 用途・注意 |
|---|---|---|
| Parent / operations | PowerShell、JSON manifest | install、env render、pin、doctor、Launcher front door |
| Control / Thought | Python `>=3.10`、標準HTTP／SSE実装、Node.js Launcher | semantic turn、broker、process supervision。Controlの`pyproject.toml`は依存を最小化 |
| Home bridge | FastAPI、Uvicorn、Pydantic、HTTPX、pytest | allowlistされたHome Assistant actionのHTTP bridge |
| Speech input | Flask、OpenAI Whisper、WebRTC VAD | browser／mic／file STTとInputGate |
| Vision | OpenCV、websockets | low-frequency snapshotとCamera Hub互換topic |
| AITuber | Next.js 15、React 18、TypeScript、Zod、Zustand | browser UI、minimal API、Projection Visual |
| Avatar / graphics | Three.js、`@pixiv/three-vrm`、PixiJS、Live2D patch、Canvas／WebGL2 | VRM／Live2D／motion／effects |
| AIT tests | Jest、Testing Library、jsdom、Playwright | focused component/API、必要時のbrowser verification |
| TTS | Python service、SAPI／VOICEVOX／OpenAI等のadapter | 現sourceはsynthesis／local playback／dedupe／statusを持つ。目標標準形はtts-service＝bounded synthesis、AIT＝browser playback／lipsync owner。adapterは未完成 |
| External LLM | OpenAI互換APIをloopback broker経由で利用 | secretはbroker private envだけ。providerは差替可能でもproof条件は維持 |
| Home | Home Assistant | logical stateと物理動作の証明を分離 |
| Display | TouchDesigner、UDP loopback、browser projector | presentation receiver。semantic authorityではない |
| Media | ffmpeg／ffprobe、MediaMTX | camera publish／diagnostics／relay。標準no-liveには任意 |

AITuberのupstreamはv2.43.2を基準にしたSword forkです。`package.json`には多数の
LLM、TTS、desktop、Cloudflare向け依存が残っていますが、存在する依存すべてが
現在のminimal routeで利用・採用されているわけではありません。

### 10.3 初回の安全な確認

新しい環境では、まずlive機器やproviderを起動せずに確認します。

```powershell
.\sword.ps1 status
.\sword.ps1 verify
.\sword.ps1 doctor

.\scripts\validate-manifests.ps1
.\scripts\check-distribution-pins.ps1 -Profile standard -Strict -Json
.\scripts\doctor-distribution.ps1 -Profile standard -Json
.\scripts\install-distribution.ps1 -Profile standard -DryRun -NoDeps
.\scripts\render-env-files.ps1 -Profile standard -DryRun
```

`start`と`stop`は既定ではpreviewです。`-Run`を付ける実runtimeは、方針決定とfresh preflight後にだけ実施してください。

### 10.4 依存関係

[distribution manifest](manifests/distributions/standard.json) が各checkoutの依存コマンドを定義します。

- Python系: `uv sync`
- Home server: `uv sync --extra dev`
- AITuber: 現行distribution installerは`npm install`を実行する。lockfileを入力にするが、`npm ci`のfrozen installではない
- TouchDesigner controller: Node標準機能中心

`node_modules`、`.venv`、cacheを旧環境からコピーせず、新しい環境で再生成してください。AITuberの`npm install`後に`package-lock.json`その他tracked fileが変化した場合は自動採用せずHOLDし、toolchain versionと差分をreviewします。

### 10.5 設定と秘密値

- GitHubへ保存するのは`.env.example`、キー名、型、安全なplaceholderだけです。
- private envは [central template](templates/env/sword-agent-os.env.example) から新規作成します。
- OpenAI keyはbrokerが読むignored private envだけに置きます。
- Home token、local API token、device identity、private URLはGitへ入れません。
- `NEXT_PUBLIC_*`へprovider secretを置いてはいけません。
- AITuber envはlocal-authoritative設定を含むため、旧envを一括上書きせず、必要キーだけ再設定します。
- 旧credentialの由来が不明なら再利用せず、rotate/revokeを検討します。
- bounded minimal AI-body rehearsalでは、Launcher所有process treeに限って`THOUGHT_CORE_PERSONA=plain`、`THOUGHT_CORE_LLM_VISIBLE_SPEECH_ENABLED=0`、`THOUGHT_CORE_REQUIRE_LLM_VISIBLE_SPEECH=0`をprocess-localに設定していました。これはcanned persona／second visible phraseを通常成功へ混ぜないための条件であり、永続machine envへ書きません。
- 上記設定でもofficial provider-attempt cardinalityや、任意のprovider bodyがbyte-identicalに表示されたことは証明されません。fresh same-turn identityとinput-specific responseを別に確認します。
- validation結果は`missing_key`等の固定分類にし、値を出しません。

### 10.6 Runtime reconstruction card

- central private envの既定位置はrepo-relative `local/env/sword-agent-os.env`です。templateから新規作成し、Gitへ入れません。
- Launcherは既定で`127.0.0.1:8799`、brokerは`127.0.0.1:18786`、Thoughtは`127.0.0.1:18787`、AITuberは`127.0.0.1:3000`です。full profile側のHome bridgeは8787、TouchDesigner GUIは8788ですが、minimal exact3では起動しません。
- Launcher state dirは`--state-dir`、`HOME_CONTROL_STACK_STATE_DIR`、または既定のworkspace `.cache/home-control-stack`で決まります。config、operation、private plan、lease／PID／logはlocal private runtime artifactで、repoへcommitせず、新しいgraph／binding／candidateで旧stateを再利用しません。
- `render-env-files.ps1 -Force`は生成先env／configを上書きし得ます。Home等のlocal実機設定を値非公開でbackup／inventoryしてから実行し、再生成後に必要キーを手動で再設定します。
- 現行`system.ps1 start`のpayloadとserverの`expectedConfigSha256`要求には既知の差があります。新環境では保存済みconfig identityをfreshに取得・照合し、互換clientが直るまでfront doorだけでstack開始完了としません。
- `sword.ps1 start -Run`はLauncher起動境界です。broker／Thought／AITのStart／Ready、provider response、browser presentation、Stop／cleanupは別の実行証拠です。

### 10.7 手動資産

次はコードと別にライセンス／所有を確認して移行します。

- VRM、Live2D、VRMA、Cubism関連資産
- gesture model
- VOICEVOX本体とspeaker設定
- TouchDesignerとcanonical `.toe`
- カメラ、マイク、projector設定

tracked sample assetでも、コードライセンスとモデルライセンスを別々に確認してください。

### 10.8 ライセンスと再配布の境界

- Parent repository rootには、プロジェクト全体を一括して再配布できることを示すroot `LICENSE`／`NOTICE`を確認できませんでした。確認したnested repoの大半にもtracked license fileがありません。public visibilityは利用・改変・再配布権を自動的に付与しないため、各nested repo、コード、モデル、ロゴ、音声、`.toe`を別々に確認してください。
- 選択AITuber forkはv2以降のcustom licenseを引き継ぎます。商用利用やforkの再配布には条件があり、商用licenseの適用範囲はmain branch等に制限されています。selected work branchをそのまま商用利用可能とみなしてはいけません。
- AITuberにtrackedされているNike-chan VRM／Live2Dモデルは、コードとは別のmodel termsに従います。第三者再配布は原則禁止で、VRMの一部許諾にも事前同意が必要です。新プロジェクトへcloneできることを、モデルを別repo／配布物へコピーできる権利と解釈しません。
- ロゴ、Cubism／Live2D、VRM／VRMA、TouchDesigner oracle、音声、外部shader等も、それぞれの権利とprovenanceを確認します。不明な資産は参照位置とhashだけを残し、bundleへ含めません。

## 11. 次の環境へ持ち込むもの

### Gitから再構築するもの

- Parent、Control、各organのrepo URL／branch／commit
- manifests、contracts、policies、governance
- source、focused tests、setup/diagnostic scripts
- lockfiles、`.env.example`、設定テンプレート
- tracked assetと対応license/provenance文書
- 本文書

trackedであることだけを移行許可にしません。新projectへ実体を持ち込むassetは、exact assetごとの再配布権とprovenanceを独立確認できたものだけです。それ以外はlocal-only／HOLDとし、参照位置とhashだけを残します。

### Git外で安全に再設定するもの

- API key、token、private URL
- Home entity/actionのローカル設定
- device選択
- local licensed avatar/motion/media assets
- VOICEVOX、TouchDesigner、camera/mic/projector環境

### 旧ディレクトリを参照元として残すもの

- 過去の日誌、review packet、rawではない証拠索引
- 現在未公開のControl候補commit
- Projection Effectsの原典oracleへの所在情報
- main checkoutの未追跡exact4診断候補

## 12. 持ち込まないもの

- `.env`、API key、token、cookie、credential
- `node_modules`、`.venv`、`.uv-cache`、npm cache、`.next`
- `.runtime`、Launcher state、operation/private plan、lease
- test-runs、coverage、temporary state、PID、listener snapshot
- raw logs、stack trace、CLIXML、command line dump
- raw prompt、provider request/response/event、private attempt reference
- raw audio、transcript、video、frame、screenshot、TTS WAV
- browser storage、blob URL、user-dropped model
- local absolute path、device label、Home entity ID
- parked worktreeそのもの
- coordination messagesの全量

必要な履歴は、旧ディレクトリをread-only参照し、この文書へ確定事実だけを抽出します。

## 13. ローカル限定・保留中の資産

### 13.1 Control Windows worker candidate

`2b00bdd...`は有用な最新開発成果です。fresh remote queryではcandidate ref不在、選択済み親ref`9a8fa2f...`一致を確認し、exact commit/historyの公開前Security reviewもCLEARでした。ただしParent採用と実pushは行っていません。
新環境へ移る前に、次の境界で保存を判断します。

- ref absent: それだけでは公開権限にならないためHOLD。現行formal ownerのrelease、exact commit/ref確認、redactedなsecret/private-path/license/provenance履歴scan、利用者によるexact payload/destination承認がすべてCLEARの場合だけ、normal non-forceのexact-ref pushを別途実行する
- ref equal: push不要。ただしremote上の到達性だけを採用・安全性・runtime証明へ昇格しない
- ref differentまたはquery failure: HOLDして判断

### 13.2 Fire/Thunder Self Mirror exact4

古いmain checkoutに、相互依存する未追跡4ファイルがあります。

- `runtime/visual-motion-analyzer/fire-thunder-lab-scenarios.json`
- `scripts/capture-fire-thunder-lab-self-mirror.mjs`
- `scripts/run-fire-thunder-lab-self-mirror.ps1`
- `scripts/tests/capture-fire-thunder-lab-self-mirror.test.mjs`

これは一時生成物ではなく、loopback Playwrightで実験用Fire/Thunderを観測する**参考候補**です。
ただしproduction stageではなくmanual lab routeを対象とし、Thunder selectorとcurrent WebGL2経路にもずれがあります。
現状のままcurrent proofや必須引継ぎには使えません。採用する場合はexact4を一組として、current pin、stage-output、WebGL2 selector、O1/T053 oracleに合わせて再設計・reviewしてください。

実行時に生成される`.cache`配下のsummaryやanalyzer outputは持込不要です。

## 14. Git / GitHub引継ぎ境界

### サニタイズ後の公開候補

- 目的、設計、構成、非目標
- public repo URL、branch、commit、repo-relative path
- サニタイズ済みtest結果、proof ceiling、nonclaim
- 設定キー名、型、安全なplaceholder
- 本文書

これは**内容上の公開候補**という分類であり、commit、push、publication、commercial use、remote destination、履歴全体の安全性、第三者資産の再配布権を自動的に付与しません。

### 公開してはいけないもの

- task/thread ID、Windowsユーザー名、絶対local path
- secret、private env、private config
- raw user/provider data
- raw logs/media/captures
- Home entity、device label、個人用URL

### 現在のGit注意点

- Workspace rootはGit repositoryではありません。
- selected Parent branchはtracked cleanですが、`.runtime/`がuntrackedかつこのrepoの`.gitignore`では除外されていません。stageしません。
- public main checkoutには上記Fire/Thunder exact4がuntrackedです。bulk stageしません。
- AITの`local/evidence`とTouchDesignerの`.toe`候補にも、repo側でignoreされていないlocal/private/generated資産があり得ます。広いstageをhard-stopし、各nested repoで`check-ignore`とexact statusを確認します。
- coordination repositoryは複数ownerの変更を含むため、handover目的でbulk commitしません。
- commitは各repo／branchでexact pathに限定します。pushはpath単位ではないため、直前に対象commitの全変更pathとupstream差分を確認し、normal non-forceのexact-ref pushとして分けます。
- stage後はcached path setとcached diffを全文確認し、secret／private-path／license／provenance scanを同じbyteへ実施します。commit後はcommit全変更path、parent、tree、subject、upstream差分を再確認します。
- `git add .`、`git add -A`、広いpathspec、mixed-owner stagingはhard-stopです。このhandover commitのstaged path setは`HANDOVER.md` exactly oneで、`.runtime/`は0でなければなりません。
- local evidenceやlocal `.toe`はrepository外で保持するか、別releaseでreviewしたignore ruleを先に採用してから作成します。既存ファイルをignore追加のために移動・削除しません。
- force push、amend、rebase、history rewrite、tag作成、upstreamの暗黙変更を行いません。対象remote refが想定baseと一致する場合だけfast-forward／new exact-refとしてpushし、直後にremote equalityを再確認します。remote query failureやdivergence時は進めません。
- publication直前に、対象exact hashとdestinationについてformal owner／利用者の承認、current treeとremoteへ到達する新規historyのredacted privacy／license／provenance scanを揃えます。
- nested commitの正しさとParent manifestへの採用は別commit／別証明です。

### 全worktreeの保存census

引継ぎ作成時に、登録済みworktreeを読取専用で全件確認しました。

| Repo family | 登録worktree | status成功 / 失敗 | dirty / clean | tracked変更 | untracked | staged / conflict |
|---|---:|---:|---:|---:|---:|---:|
| Parent | 9 | 9 / 0 | 2 / 7 | 0 | 13 | 0 / 0 |
| Control（main registry＋selected Parent配下registry） | 61 | 60 / 1 | 12 / 48 | 46 | 16 | 0 / 0 |
| AIT（main registry＋selected Parent配下registry） | 59 | 59 / 0 | 15 / 44 | 62 | 31 | 0 / 0 |
| Coordination | 2 | 2 / 0 | 1 / 1 | 81 | 約9,456 | 0 / 0 |
| 合計 | 131 | 130 / 1 | 30 / 100 | 189 | 約9,516 | 0 / 0 |

この表は「変更が価値ある」「公開してよい」を意味しません。保存判断が必要な主要群は次です。

- Parent main: Fire/Thunder Self Mirror exact4。相互依存するsource/test候補ですが、current productionとoracleへ合わせ直すまでHOLDです。
- selected Parent: 本文書だけが公開候補です。`.runtime` 8件はLauncher生成状態であり公開しません。
- Control: dirty 12 worktreeにLauncher／Supervisor／Thought／OpenAI brokerのsource/testがあります。main registryとselected Parent配下registryを重複なく照合し、採用系譜を一つ選ぶまでHOLDです。
- AIT main: tracked `.env.example` 変更1件は、秘密値混入と採用価値を別reviewしてから判断します。`local/evidence` 15件は画像・log・metrics等のprivate/generated evidenceであり公開しません。
- AIT: dirty 15 worktreeです。bubble系dirty laneには同型変更の重複があります。複数laneを別々に保存せず、current選択 `ce27f69...` との差分を比較して一系譜だけ判断します。
- Coordination: scripts、registry、requirements、handoffs、tasksには個別保存候補がありますが、messages約7,293件とtask-outputs約2,101件を含むmixed-owner private運用repoです。一括stage/pushは禁止します。

見落としやすいdirty候補として、Controlの`control-b0-provider-attempt-terminal-join-v0`（Thought／broker／watcherのsource-test 11件）、`control-combined-wrapper-rematerialization-v0`、`control-stop-causal-observability-v0`、`control-truthful-stop-result-preservation-v0`（後三者はStop script／supervisor testの同系統）、AITの`ait-home-action-truthful-status-v1`（`projectionVisualHud.tsx`とtest）があります。いずれも価値や採用を確定せず、dedupe／lineage／security reviewまで旧ディレクトリでHOLDします。

登録Control worktree `control-plane-lane-a-event-journal-proof` は、`.git` が旧配置を参照しており `not a git repository` となるため、dirtinessを確認できませんでした。引継ぎが終わるまで削除、prune、再登録を行わず、旧ディレクトリ参照とともにHOLDします。

## 15. 再開時の最短手順

### Phase A: 方針決定前のno-live復元

1. この文書と [AGENTS.md](AGENTS.md) を読む。
2. `work/parent-ordinary-route-contract-v1`のfresh HEADをclone／checkoutし、technical base `ebf1758...`以後がdocumentation-onlyかを確認する。
3. manifestから10個のsourceをexact commitで用意する。
4. secretを入れず、manifest validation、pin check、doctor、dry-runを行う。
5. old state、cache、runtime artifactを使っていないことを確認する。
6. `2b00bdd...`はexact push承認後のcandidate保存、Fire/Thunder exact4はreview後の保存／採用／破棄を判断する。

### Phase B: 最小縦経路を続ける場合

1. 採用するControl commitを決め、独立QA／Security evidenceとexact bytesを再確認する。
2. 未公開candidateなら、remote destination不在／expected baseをfresh確認し、明示承認されたexact SHAをnormal non-forceのcandidate refへ保存する。
3. ParentのControl manifestだけをexact1でcandidate branch／commitへ更新する。
4. `validate-manifests.ps1 -VerifyRemote`とAIT adapterの`-VerifyRemote -DryRun`を同じmanifest bytesへ実行する。
5. Parent exact1をreview、commitし、normal fast-forwardでParent refへpushする。
6. そのParent commitをformalに選択してから、nested Control checkoutだけをnamed-ref fetch＋ff-onlyでexact commitへ整合させる。
7. `check-distribution-pins.ps1 -Profile standard -Strict -VerifyRemote -Json`でlocal／remote 10/10を確認する。
8. 新しい環境で依存を生成し、AITuber installがtracked lockfileを変えた場合はHOLDする。
9. exact3 configuration／worker／probe testsとAIT minimal 3 suitesを実行する。
10. fresh task-owned stateでnon-starting previewとplan compileを確認する。
11. Launcher所有processだけに`THOUGHT_CORE_PERSONA=plain`とvisible-speech二設定`=0`を与え、broker、Thought、AITだけをStartしてReadyを確認する。
12. fresh sessionと予測不能な入力で、一回のprovider-backed応答を得る。
13. 一つのbubble、identity、visible Stop、late0、DOM cleanupを確認する。
14. Launcher Stop、child／process／listener／private-artifact cleanupを別に確認する。

ここまではboundary／runtime proofであり、最初のproduct review targetそのものではありません。利用者レビュー前に、同じcanonical responseをselected existing-avatar surfaceへ一度だけ載せ、`applied|unknown`、late output 0、presentation Stop／cleanupを確認します。新しいrenderer、page、serviceを先に増やす必要はありません。

### Phase C: 完成形へ戻す場合

最小routeを壊さず、次を一つずつ再導入します。

1. Memory Coreとlater-turn
2. Environment dynamic grounding
3. self-output境界
4. voice input / TTS / lipsync
5. avatar / motion
6. Homeまたはeffectの一能力
7. operator/passive/stage/projector
8. current full-stack coexistence
9. 別の人によるinstallability
10. physical proof
11. user U1と公開／撮影同意

この順序は絶対固定ではありません。各能力は、目標への価値、衝突、証明コストを見て再評価します。ただし未完要求を黙って削除してはいけません。
Voiceを広げる時は、self-outputを新しいTurnInputへ戻さない境界を同時または先に閉じます。
HomeとEffectsは厳密な直列ではなく、最初の表示面を利用者が確認した後に価値の高い一能力を選びます。
Installability、maintainability、privacy、diagnostics、QA／Security、proof accountingは全Phaseを横断します。

## 16. 方針見直し時の主要な判断事項

1. minimal routeを最初の正式ユーザー面として継続するか。
2. provider attempt/authorshipを既存broker/Thought event family内でどう証明するか。
3. STTをai-talk-coreへ一本化するか、AITuber内蔵STTも維持するか。
4. tts-service→AIT playback adapterをどう完成させ、standalone local playback／AIT内蔵synthesisのcompatibility経路をどう退役させるか。
5. avatar-serviceを再採用するか、AITuber内runtimeを正とするか。
6. minimal pageと広いProjection Visualを二系統で保つか、後で統合するか。
7. HomeとEffectsのどちらを最初の行動／身体表現として戻すか。
8. Fire/Thunderをproduction stageへ昇格するか。
9. Memory Coreへ統合する際のJSONL retirementとprivacy policyをどうするか。
10. installability、physical proof、U1を誰がどの環境で実施するか。

## 17. 受入条件と禁止事項

- 「起動した」ではなく、何がReadyかをservice identityで示す。
- 「AI応答」ではなく、同じ入力／turnに結び付くprovider-backed messageを示す。
- 固定文を成功応答にしない。
- 「Stopした」ではなく、presentation、upstream、process、listener、private artifactを別々に示す。
- source/static、focused test、runtime、browser、physical、U1を分ける。
- candidate、published、selected、reconciled、runnableを分ける。
- private dataをproofのために公開しない。
- sanitized current tree、reachable history、license／provenance、publication authorization、pushed reachability、Parent selection、nested reconciliation、runtime、physical proof、U1を別々に扱う。
- 一つのHOLDを全体停止へ広げない。
- 名前の大きさに合わせて実装済みと見なさない。
- 新構造を増やす前に既存構造で閉じられないか確認する。
- Stop、Stage Reset、Effect Reset、Emergency、process shutdownを一語の「終了」に潰さない。

本文書は、selected pin、Parent／Control／Integration authority、Memory／Environment等の
state authority、service family、accepted requirement、またはproof layerが変わった時点で
再照合が必要です。新しい証拠は該当layerだけを更新し、他layerを自動的にgreenへしません。

## 18. 参照の優先順位

新環境では、質問ごとに正本を分けます。

引継ぎ作成時のrole境界は次の通りです。本文書を読んだだけでは権限は移転せず、新プロジェクトで利用者の直接appointmentが必要です。

| Role | 引継ぎ時の責務 | 所有しないこと |
|---|---|---|
| Manager7 | 目的、優先、時間、release、completion、利用者報告 | source／path／test原因の重複技術判定 |
| Integration7 | Git／manifest、技術分類、adoption、runtime sequencing、collision管理 | 製品価値、最終優先、U1 |
| Coordination Admin4 | private compact ledger、routing hygiene、delivery exception | 製品／技術の採否、公開 |
| QA4 / Security3 | 同一byteの独立品質／安全review | 他reviewerの結論による代替、release権限 |
| 利用者 | 目的変更、physical／publication consent、主観的U1 | source/test/runtime proofの代替 |

1. **作業を続ける／止める権限**: 最新の利用者指示と、有効なGoalTransitionReceipt。
2. **製品の目的・未完要求**: 最新のGoal文書、accepted requirement、canonical requirement trace。台帳内の古いpinや期限は現行技術選択に使いません。
3. **現在選択されたsource**: Parent manifest、direct remote ref、実checkout。古いGoal／台帳のpinより優先します。
4. **何が証明されたか**: 採用済みcontracts、policies、source、同一byte tests、保存済みruntime結果をproof layerごとに確認します。
5. **入口と再構築方針**: 本文書。正本の代替ではなく、上記を結ぶindexです。
6. **設計経緯と失敗防止**: 過去の日誌、review packet、候補branch。現行権限や採用を付与しません。

Goal／requirement／歴史意図は、旧作業ディレクトリに残すaccepted requirement records、current Goal文書、canonical requirement trace、north-star／世代交代引継ぎから確認します。これらはprivate/reference資料であり、具体的なlocal path、task ID、message、raw packetをGitHubへ複製しません。必要な確定事項とrequirement IDだけを本文書へ反映します。

## 19. 最後に

Sword Agent OSで守るべき中心は、機能数ではありません。

利用者の自然な願いをAIが本当に考え、安全な決定論的境界を通して一つの応答・行動・身体表現へ変え、結果を観測し、間違いを訂正でき、最後に何が止まり何が残ったかを正直に言えることです。

新しい環境では、現在の構造を無条件に維持する必要はありません。しかし、各構成名が表していた責務、AIと決定論的層の分離、証明層、privacy、Stop/cleanupの真実性、未完要求は失わないでください。
