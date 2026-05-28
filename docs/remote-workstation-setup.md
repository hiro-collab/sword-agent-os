# Remote Workstation Setup

Use this guide when setting up Sword Agent OS on another PC.

## Clone

```powershell
cd C:\Users\kawai\works
New-Item -ItemType Directory -Force sword-agent-os-workspace
cd sword-agent-os-workspace
git clone https://github.com/hiro-collab/sword-agent-os.git sword-agent-os
cd sword-agent-os
.\scripts\bootstrap-workspace.ps1 -CloneCoordination
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

