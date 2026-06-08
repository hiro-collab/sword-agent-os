# Distribution Maintenance

この文書は、Sword Agent OS の標準ディストリビューションについて、version、source pin、
diagnostics、update、installer/update maintenance smoke を確認するための運用メモです。

初回の最短導入は `README.md` を読んでください。標準構成の全体像と proof layer は
`docs/standard-distribution-map.md` を参照してください。

## Version Model

Sword Agent OS は、読めるバージョンと再現可能な source pin を分けて管理します。

| 種類 | 正本 | 役割 |
| --- | --- | --- |
| OS version | `manifests/releases/standard.json` | runtime contract、body plan、cross-organ compatibility の版 |
| Distribution version | `manifests/distributions/standard.json` | 標準インストール/更新 surface の版 |
| Organ component version | `manifests/releases/standard.json` と source manifest | 各 organ の人間向け semver |
| Source pin | `manifests/legacy/control-plane-reference.json` / `manifests/organs/legacy-github.json` | 実際に取得する Git commit |

標準構成では、installer 起動時に OS version、distribution version、release 名、
component 数、Git revision が表示されます。

```powershell
pwsh -NoProfile -File .\scripts\install-distribution.ps1 -Profile standard -DryRun
```

インストールや更新を行わず、バージョンだけ確認する場合は次を使います。

```powershell
pwsh -NoProfile -File .\scripts\show-version.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\show-version.ps1 -Profile standard -Json
```

各 organ は原則として `pyproject.toml` または `package.json` の version を優先します。
ただし、AITuberKit のように公式 release/tag と package metadata が一致しない外部
project は、公式 upstream の release tag を component version として扱います。実際に
取得する source は fork の Git commit pin で管理するため、正確な実装同一性は常に
manifest の commit pin で確認します。

## Distribution Diagnostics And Source Pins

初回導入、更新、レビュー前に「何が足りないのか」をまとめて見る場合は
`doctor-distribution.ps1` を使います。これは secret 値を表示せず、tool、source pin、
中央 env、生成 `.env`、local asset の有無を人間向けに整理します。

```powershell
pwsh -NoProfile -File .\scripts\doctor-distribution.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\doctor-distribution.ps1 -Profile standard -Json
```

source pin だけを機械的に確認したい場合は `check-distribution-pins.ps1` を使います。
通常モードでは、開発中に nested checkout が manifest より先へ進んでいる状態を
`ahead_of_manifest` として warning 表示します。これは「正式採用待ち」です。
配布前、fresh install gate、レビュー前の厳格確認では `-Strict` を付け、manifest
pin と checkout HEAD が一致しない状態を失敗にします。

```powershell
pwsh -NoProfile -File .\scripts\check-distribution-pins.ps1 -Profile standard
pwsh -NoProfile -File .\scripts\check-distribution-pins.ps1 -Profile standard -Strict
```

`ahead_of_manifest` は、対象 organ の作業自体が進んでいる可能性を示しますが、
標準 distribution に入ったことは意味しません。正式採用するには、該当 nested commit
の Test-QA / Security / Integration review を終え、親 manifest の commit pin を更新し、
必要なら distribution version を上げ、fresh install でその pin が再現されることを確認します。

`git_unreadable` は pin mismatch とは別です。制限付き環境、別ユーザー実行、Git の
`dubious ownership` などで checkout を読めない時に出ます。この場合は通常ユーザーの端末で
同じ command を再実行するか、診断目的で exact path の `safe.directory` override を使います。
一方で、`behind_manifest`、`ahead_of_manifest`、`pin_mismatch` は checkout HEAD と manifest
pin の関係を読めた上で出る結果です。配布確認ではこの区別を残して報告してください。

## Updating An Existing Install

既存のインストールを更新するときは、まずトップレベルの `sword-agent-os`
repo を更新し、その後で control plane と各 organ を distribution manifest
の pin に合わせます。

```powershell
cd <sword-agent-os のパス>
git status --short --branch
git pull --ff-only

pwsh -NoProfile -File .\scripts\update-distribution.ps1 -Profile standard -DryRun
pwsh -NoProfile -File .\scripts\update-distribution.ps1 -Profile standard
```

`update-distribution.ps1` は、`manifests/distributions/standard.json` から
control plane と organ manifest を読み、各 nested checkout を manifest に
書かれた commit へ `git fetch` + `git merge --ff-only` で更新します。
`reset`、`checkout`、`clean` は行いません。

依存関係の再導入まで一度に行いたくない場合は、先に source だけ更新します。

```powershell
pwsh -NoProfile -File .\scripts\update-distribution.ps1 -Profile standard -DryRun -NoDeps
pwsh -NoProfile -File .\scripts\update-distribution.ps1 -Profile standard -NoDeps
```

更新時に hold される代表例です。

| 状態 | 理由 / 対応 |
| --- | --- |
| dirty checkout | local 変更があるため自動更新しません。対象 repo の `git status --short` を確認します |
| branch mismatch | manifest と別 branch にいるため自動で branch 移動しません |
| non-fast-forward | local head から manifest pin へ安全に進められません |
| missing checkout | まだ clone されていません。`install-distribution.ps1` を実行します |
| non-git path | target path に Git checkout ではないフォルダがあります |

`uv.lock` や `*.egg-info/` など、依存導入で生成された未追跡 artifact だけの場合は、
更新を止めずに警告として表示します。tracked file の変更や通常の未追跡 source
file がある場合は hold します。hold された checkout の dependency install も
自動では行いません。

`.env` と local config はデフォルトでは上書きしません。中央 env template に
新しい項目が増えた場合は、`templates/env/sword-agent-os.env.example` を見て
`local/env/sword-agent-os.env` に必要な値を追記し、内容を確認してから反映します。

```powershell
notepad local\env\sword-agent-os.env
pwsh -NoProfile -File .\scripts\render-env-files.ps1 -Profile standard -Force
```

`-Force` は各 organ の既存 `.env` を中央 env から再生成します。実 token や
機器固有値を失わないよう、実行前に `local/env/sword-agent-os.env` 側へ必要な値が
入っていることを確認してください。

## Installer / Update Maintenance Smoke

インストーラー、更新スクリプト、README のセットアップ手順を変更した後に読む検証手順です。
軽量な maintenance smoke を使い、外部サービス起動、実 token、実機操作、
dependency install を要求しない範囲で確認します。

```powershell
pwsh -NoProfile -File .\scripts\test-distribution-maintenance.ps1
```

この smoke は次を確認します。

- `scripts/*.ps1` の構文
- root `.bat` wrapper が存在する target script を指していること
- manifest / version コマンド
- 組み立て済み checkout での update dry-run と env render dry-run
- fresh clone 相当の一時 workspace で、default bootstrap が `_codex` /
  `coordination` / `local` / `worktrees` を作らないこと
- fresh clone から `install-distribution.ps1 -DryRun -NoDeps` が落ちないこと
- organ checkout 前の fresh clone で `render-env-files.ps1 -DryRun` が
  missing-yet-planned template として扱われること

remote pin まで確認したい場合は次を使います。

```powershell
pwsh -NoProfile -File .\scripts\test-distribution-maintenance.ps1 -VerifyRemote
```

現在の checkout が control plane / organ をすべて含む assembled install であることを
必須にしたい場合は、次を使います。

```powershell
pwsh -NoProfile -File .\scripts\test-distribution-maintenance.ps1 -RequireAssembledCheckouts
```

`test-distribution-maintenance.ps1` は一時ディレクトリを作って local clone の dry-run を
行い、通常は最後に削除します。調査用に残す場合は `-KeepTemp` を使います。full clone /
dependency install / live runtime check は重い任意レーンとして扱い、通常の smoke gate には
含めません。
