# Standard Distribution Map

この文書は、Sword Agent OS の標準ディストリビューションを初めて読む人向けに、
README より少し詳しく整理した地図です。

README は最初の入口です。この文書は、README を読んだ後に
「標準構成とは何か」「何が GitHub に含まれ、何がローカル準備なのか」
「どこまで動けば何を証明したことになるのか」を確認するために使います。
利用者から見える機能単位は `docs/capability-packs.md` を入口にします。
Front Door / Configuration / Runtime Control / Proof / Module / Coordination
の責任分界や用語の定義は `docs/architecture.md` を正本にします。

## Mainline At A Glance

Sword Agent OS の標準構成は、次の mainline を持つ cyber-system です。

```text
input / observation
-> state understanding
-> Thought Core or Reflex decision
-> guarded action or expression
-> environment / avatar / voice / HUD / projection output
-> observation, self-observation, event/status/memory feedback
```

この文書では、この mainline を読むために必要なものだけを扱います。
debug tree や coordination history ではなく、標準構成の地図です。

| 初見の問い | まず見る場所 |
| --- | --- |
| 何を入れれば標準構成になるか | `What The Standard Distribution Is` |
| 最初にどこまで動けばよいか | `First Success` |
| 代表 loop は何か | `Representative Standard Loop` |
| 機能単位で何を選ぶか | `docs/capability-packs.md` |
| 構成 plane と用語は何か | `docs/architecture.md` |
| 家電 action を 1 つ増やすには | `docs/add-home-device.md` |
| Home Assistant を no-live で確認するには | `examples/starter-profiles/home-control-preview/README.md` |
| 実装はどこに入るか | `Organ Checkout Map` |
| 何が正本か | `Manifest And Pin Authority` |
| 何を証明していないか | `Proof Layers` |

標準構成の mainline ではないもの:

- `coordination/` の長い作業履歴や thread message。
- 一回限りの helper/browser/debug 証跡。
- `local/`、cache、raw media、private config、machine-specific log。
- nested checkout 内の未採用差分を親 manifest pin 更新なしに正本扱いすること。

これらは検証や開発には重要ですが、標準構成を理解する入口ではありません。

## What The Standard Distribution Is

標準ディストリビューションは、家の中で使う AI エージェントを例にした
Sword Agent OS の concrete profile です。

標準構成は次をまとめて扱います。

- Thought Core / control plane
- speech input
- camera / gesture reflex
- environment state
- Home Assistant action bridge
- speech / avatar / projection expression
- display / diagnostics
- OS runtime contracts, manifests, policies, and test packs

標準構成は「小さな demo」ではありません。一方で、clone 直後に全ての live 機能を
証明するものでもありません。最初は no-live / mock / device-free の確認から入り、
実カメラ、実マイク、Home Assistant live 操作、物理家電 proof は別の proof layer として
段階的に扱います。

Current source anchors:

- `sword.ps1`
- `manifests/distributions/standard.json`
- `manifests/releases/standard.json`
- `manifests/organs/legacy-github.json`
- `manifests/tests/organ-test-packs/standard.json`
- `scripts/install-distribution.ps1`
- `scripts/check-launch-readiness.ps1`
- `scripts/run-organ-test-packs.ps1`
- `scripts/run-compat-smoke.ps1`

## First Success vs Representative Standard Loop

### First Success

First Success は、初回 clone から安全に確認できる最初の成功です。

目安:

```text
fresh clone
-> standard distribution install
-> central env render
-> launch readiness check
-> organ test packs
-> no-live / no-camera compatibility smoke
```

代表的なコマンド:

<!-- standard-map:first-success-front-door -->

最初は root の front door で、状態確認と no-live 検証を揃えます。
`status` / `verify` は既定で no-live / no-device です。`-NoLive` は明示用に
付けても構いませんが、live 操作の許可ではありません。

```powershell
.\sword.ps1 status
.\sword.ps1 verify
```

<!-- standard-map:verify-overlap -->

その後、標準ディストリビューションの install / env render / detailed smoke を
必要に応じて直接 script で確認します。`sword.ps1` が入口、各 script が詳細工具です。
`.\sword.ps1 verify` は manifest validation、strict pin check、no-live launch
readiness をまとめる最小 front-door check です。下の script 群は、個別結果を
読みたい時、install/env render まで進める時、または smoke 範囲を広げる時に
使います。

```powershell
pwsh -NoProfile -File .\scripts\show-version.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard -DryRun
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard -Force
pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1
pwsh -NoProfile -File .\scripts\run-organ-test-packs.ps1
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc -RunManualTurn -RunSafeIntegrationProbes
```

First Success だけでは、次は証明されません。

- real camera gesture detection
- real microphone / STT
- gesture-to-voice gate
- live AITuber browser behavior
- Home Assistant live action
- physical appliance state change
- long-run stability
- representative standard loop

### Representative Standard Loop

Representative Standard Loop は、標準構成の価値が見える一連の流れです。

```text
input or observation
-> Thought Core / Reflex reasoning
-> environment or body state context
-> Action Boundary / preview / execution or expression request
-> voice / avatar / HUD / display expression
-> verification / state check / trace
```

この loop は、利用者の環境に合わせて organ、device、model、provider を差し替えても
成立するべき OS 的な形です。

Home Assistant live proof は重要な具体例ですが、clone 直後の最小成功条件ではありません。

## Runtime Flow

標準構成の典型的な runtime flow:

```text
camera / browser / microphone / local input
-> reflex organ or speech input
-> Thought Core / control plane
-> environment state and body state
-> Action Boundary or expression route
-> Home Assistant bridge, avatar, voice, Projection Visual, TouchDesigner
-> status, event, diagnostics, and safe display projections
```

重要な境界:

- Thought Core は意味判断と会話文脈を扱う。
- Action Boundary は外部 action の deterministic guardrail を扱う。
- Home Assistant bridge は許可された action だけを preview / dry-run / execute する。
- Avatar / HUD / motion は表示や body expression であり、家電 action そのものではない。
- Status Store は current projection、Event Journal は append-only history、Memory Core は
  durable memory candidate / commit の別 layer として扱う。

詳しい module 配置は `docs/module-usage-index.md` を参照してください。

## Organ Checkout Map

トップレベルの `sword-agent-os` repo は、OS 全体の正本です。

ここに置くもの:

- README / docs
- manifests
- runtime contracts and skeletons
- policies
- safe scripts
- test pack definitions

標準 organ の実装は、manifest に従って local nested checkout として取得します。

| Organ | Role | Local target |
| --- | --- | --- |
| control plane | Thought Core / system control | `control-plane/sword-voice-agent/` |
| `ai-talk-core` | speech input | `organs/speech-input/ai-talk-core/` |
| `mediapipe-sword-sign` | reflex / gesture | `organs/reflex/mediapipe-sword-sign/` |
| `environment-state-server` | environment state | `organs/environment/environment-state-server/` |
| `vision-snapshot-processor` | low-frequency vision state | `organs/environment/vision-snapshot-processor/` |
| `home-assistant-server` | action bridge | `organs/action/home-assistant-server/` |
| `tts-service` | speech expression | `organs/expression/tts-service/` |
| `aituber-kit` | avatar / Projection Visual | `organs/expression/aituber-kit/` |
| `touchdesigner-ai-controller` | display runtime | `organs/display/touchdesigner-ai-controller/` |
| `system-house-renderer` | diagnostics / topology view | `organs/diagnostics/system-house-renderer/` |

These target paths are checkout slots. They are ignored by the parent repo by
default. The source repo, branch, and commit are described in
`manifests/organs/legacy-github.json`.

## Manifest And Pin Authority

Use this authority model:

| Question | Source |
| --- | --- |
| What is the standard distribution? | `manifests/distributions/standard.json` |
| What human-facing release is this? | `manifests/releases/standard.json` |
| Which organ source commits are selected? | `manifests/organs/legacy-github.json` |
| Which local env templates are rendered? | `manifests/distributions/standard.json` |
| Which test packs belong to the profile? | `manifests/tests/organ-test-packs/standard.json` |
| Where should a module change go? | `docs/module-usage-index.md` |

Nested checkout state and parent manifest pin state are separate.

An organ checkout may be locally present, locally edited, or ahead of its manifest pin.
That does not mean the parent standard distribution has adopted that state.
For release/fresh-install claims, check manifest pins explicitly.

Useful commands:

```powershell
pwsh -NoProfile -File .\scripts\show-version.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\validate-manifests.ps1
pwsh -NoProfile -File .\scripts\check-distribution-pins.ps1 -Profile standard -Strict -Json
pwsh -NoProfile -File .\scripts\doctor-distribution.ps1 -Profile standard
```

## Local-Only Asset Slots

The public repository must not contain private secrets, local configs, raw media,
private proof artifacts, or license-sensitive assets.

| Slot | Purpose | Required when | Public repo posture |
| --- | --- | --- | --- |
| central env | local keys and config | most runtime lanes | template only; actual env is local-only |
| Home Assistant token | state and action bridge | Home Assistant dry-run/live | token never committed or printed |
| local API token | local bridge auth | Home Assistant live bridge | token never committed or printed |
| LLM API key | Thought Core real LLM response | LLM lane | key never committed or printed |
| `gesture_model.pkl` | gesture classification | camera / gesture lane | local-only model; do not publish without provenance/license review |
| custom VRM / Live2D | avatar display | custom avatar lane | only licensed local asset; do not publish casually |
| VOICEVOX | voice synthesis | voice output lane | install/run separately |
| TouchDesigner | external projection | display/projection lane | install/run separately |
| local media | replay verification | local replay lane | local-only; report redacted summaries only |

`_secret_inputs` is not a product convention. It can exist in a verification
environment as a local helper, but public setup should describe the actual target
slots, not that helper directory.

## Proof Layers

Keep proof labels separate.

| Layer | Typical check | What it proves | What it does not prove |
| --- | --- | --- | --- |
| source/static | manifest validation, docs/scripts inspection | files are present and internally consistent | runtime behavior |
| install/readiness | install, env render, readiness | standard setup can prepare the repo | live runtime behavior |
| no-live/mock | organ tests and compat smoke with mock/safe probes | safe service compatibility | real camera/mic/live device behavior |
| runtime/browser | launcher and UI reachability | local runtime can open and respond | physical device action unless separately checked |
| local media replay | replay from local media index | repeatable media-lane behavior on supplied assets | general real-world robustness |
| real camera | camera service / gesture observation | camera path works in current environment | voice or action behavior |
| speech/STT | microphone or virtual audio input | speech input path works | gesture gate or device action |
| Home Assistant dry-run | preview and dry-run | action route and config can be checked without side effect | physical state change |
| Home Assistant live | bounded execute and restore with state check | one scoped live action worked | broad appliance coverage or long-run safety |

Do not upgrade a lower proof layer into a higher claim.

## Safe No-Live Setup

Use no-live/mock as the default first lane.

Recommended shape:

```powershell
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard -DryRun
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard
notepad local\env\sword-agent-os.env
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard -Force
pwsh -NoProfile -File .\scripts\check-launch-readiness.ps1
pwsh -NoProfile -File .\scripts\run-organ-test-packs.ps1
pwsh -NoProfile -File .\scripts\run-compat-smoke.ps1 -UseIsolatedPorts -MediapipeVideoSource testsrc -RunManualTurn -RunSafeIntegrationProbes
```

If `gesture_model.pkl`, VRM, Home Assistant, camera, microphone, or VOICEVOX is
not available yet, keep those as held lanes instead of treating no-live setup as
failed.

## Runtime / Browser Setup

After no-live readiness, start the launcher:

```powershell
.\start-home-control-launcher.bat
```

Then use Launch Manager to wait for expected services and open Projection Visual
or AITuber UI.

Runtime/browser proof should report:

- which profile was used;
- whether the launcher belongs to the current workspace;
- which services reached ready/degraded/blocked;
- whether UI routes opened;
- what was not tested.

Do not include private absolute paths, secret values, raw screenshots with
private data, raw logs, or provider payloads in public reports.

## Local Media Replay

Local media replay is for repeatable checks from local-only media assets.

It may help test camera-hub or room-light lanes without using a live camera in
the moment. It is not a substitute for general real-world robustness.

Public-safe report shape:

```text
asset id:
mode:
status:
redacted summary:
known gaps:
```

Do not publish raw videos, raw audio, frames, transcripts, or private local paths.

## Camera / Gesture Lane

Camera and gesture checks require a camera source and, for classification,
`gesture_model.pkl`.

If the model is missing:

- install and no-live setup may still proceed;
- camera/gesture readiness can remain held;
- do not claim gesture-positive detection.

If the model is present:

- keep the model local-only;
- confirm readiness before claiming gesture proof;
- separate camera service readiness from gesture-positive detection;
- separate gesture-positive detection from gesture-to-voice gate transition.

## Speech / STT Lane

Speech input may use real microphone input or a controlled virtual-audio path.

Keep these separate:

- microphone device availability;
- STT service readiness;
- transcript generation;
- handoff into Thought Core;
- gesture-to-voice gate transition;
- voice output / TTS.

Do not publish raw audio or raw transcripts unless explicitly cleared.

## Home Assistant Dry-Run And Live Pilot Lane

Home Assistant live work must be bounded.
First-time external Home Assistant setup starts at `docs/home-assistant-setup.md`.
Do not treat this map, README examples, or a rendered demo/default/template
config as the live proof authority.

Before live execute, require:

- Home Assistant host is powered on and reachable;
- selected `HOME_CONTROL_CONFIG` is an ignored private full-schema config or a
  reviewed clone-local equivalent, not a public demo/default/template or
  short/minimal action-only override;
- allowed action id;
- restore action id when restoration is part of the pilot;
- expected states;
- current and restore-side states are readable, not `unavailable`;
- preview pass;
- dry-run pass;
- maximum action count;
- stop conditions;
- state check after execute;
- cleanup / restore check.

Default safe order:

```text
config/readiness
-> action catalog
-> preview
-> dry-run
-> execute exactly the ticketed action
-> state check
-> restore if scoped
-> final state check
```

Do not use a successful one-light on/off pilot to claim broad appliance coverage,
locks/heaters/curtains safety, fuzz/stress coverage, or long-run reliability.

If the Home Assistant host is off, unreachable, or returns `unavailable` for the
expected restore-side state, hold the live pilot. That is an environment
precondition failure for the run, not a reason to execute anyway.

## Developer / Codex Workspace Boundary

Normal runtime users need only the product repo plus nested checkouts created by
the installer/update scripts.

Developer/Codex workspace surfaces are separate:

- `coordination/`
- `worktrees/`
- `_codex/`
- workspace-level `local/`
- thread messages and task outputs

These are not part of the public runtime package. Internal coordination may be
summarized into public docs only after redaction and review.

## What Is Not Included

The public product repo should not include:

- API keys or `.env` values;
- Home Assistant URLs, tokens, or private entity details;
- raw camera/audio/video;
- raw screenshots containing private context;
- raw logs, provider payloads, transcripts, or local paths;
- custom licensed VRM/Live2D assets unless publication is explicitly allowed;
- internal Codex coordination history;
- local caches or worktrees.

## Current Known Gaps / Non-Claims

This document is a map. It is not proof that the current checkout passed all
lanes.

For the current local proof state, run the relevant scripts in a fresh clone or
check the current coordination/test output. Do not infer live proof from this
document.

Non-claims:

- no fresh-clone verification was performed by creating this document;
- no live Home Assistant action was performed;
- no camera, microphone, or browser runtime proof was performed;
- no manifest pin was changed;
- no organ source was updated;
- no README content was removed.
