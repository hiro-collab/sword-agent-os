# Remote Workstation Setup

Use this guide when setting up Sword Agent OS on another PC.

## User / Runtime Install

For a normal runtime install, keep the checkout simple. You only need the main
`sword-agent-os` repository plus the nested control-plane and organ checkouts.

```powershell
cd $HOME\works
New-Item -ItemType Directory -Force sword-agent-os-runtime
cd sword-agent-os-runtime
git clone https://github.com/hiro-collab/sword-agent-os.git
cd sword-agent-os
.\scripts\bootstrap-workspace.ps1
.\scripts\bootstrap-control-plane.ps1 -DryRun
.\scripts\bootstrap-organs.ps1 -DryRun
.\scripts\bootstrap-control-plane.ps1
.\scripts\bootstrap-organs.ps1
```

The default `bootstrap-workspace.ps1` command only prints the resolved
workspace paths. It does not create Codex, coordination, worktree, or cache
directories.

## Developer / Codex Workspace Install

Use this only when this PC will run multi-thread Codex development,
coordination handoffs, worktrees, and local artifact caches.

```powershell
cd $HOME\works
New-Item -ItemType Directory -Force sword-agent-os-workspace
cd sword-agent-os-workspace
git clone https://github.com/hiro-collab/sword-agent-os.git
cd sword-agent-os
$RepoRoot = (Resolve-Path .).Path
.\scripts\bootstrap-workspace.ps1 -DeveloperWorkspace
```

If the private coordination repository is available on this PC, clone it as a
workspace sibling. Do not add `-CloneCoordination` when the private repository
is not accessible.

```powershell
.\scripts\bootstrap-workspace.ps1 -DeveloperWorkspace -CloneCoordination
```

Control-plane and organ checkout setup is the same as a runtime install.
Preview first, then run the real checkout commands.

```powershell
Set-Location $RepoRoot

.\scripts\bootstrap-control-plane.ps1 -DryRun
.\scripts\bootstrap-organs.ps1 -DryRun

.\scripts\bootstrap-control-plane.ps1
.\scripts\bootstrap-organs.ps1
```

Install dependencies inside the relevant checkouts and return to the main repo
after each one.

```powershell
Push-Location (Join-Path $RepoRoot "control-plane\sword-voice-agent")
uv sync
Pop-Location

Push-Location (Join-Path $RepoRoot "organs\expression\aituber-kit")
npm install
Pop-Location
```

In a developer workspace, these directories sit beside `sword-agent-os/`. They
are not part of the public runtime package and should not be pushed as one repo:

```text
coordination/
local/
worktrees/
_codex/
```

## Local-Only State

The following does not transfer automatically:

- secrets and `.env` files
- runtime logs, caches, generated artifacts, audio, screenshots, and local paths
- thread-private worklogs under `coordination\local`
- organ-specific large/generated dependencies

## Coordination

Shared development coordination lives in the private
`sword-agent-os-coordination` repository. Only share summarized coordination
state there: decisions, handoffs, active messages, reservations, registry data,
and shared notes.

Do not publish a whole developer workspace directory as one repository. The
workspace-level `coordination`, `local`, `worktrees`, and `_codex` directories
are local/development surfaces, not the Sword Agent OS runtime package.
