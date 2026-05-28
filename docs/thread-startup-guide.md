# Thread Startup Guide

Use this when starting a Codex thread for Sword Agent OS.

## First Thread

Start with `integration-main` unless a specific area thread is being created.

```text
C:\Users\kawai\works\sword-agent-os-workspace\sword-agent-os
```

Read, in this order:

1. `AGENTS.md`
2. `governance/development/`
3. `..\coordination\shared\registry\`
4. `..\coordination\shared\messages\`
5. `..\coordination\shared\tasks\`
6. `..\coordination\shared\handoffs\`

## Reference Boundary

The old system is read-only reference:

```text
C:\Users\kawai\works\sword-agent-system
```

Do not edit legacy repositories unless the user explicitly asks for it. Pull
knowledge forward by creating inventories, tasks, decisions, manifests, or
policies in the new workspace.

## Expected First Moves

1. Confirm both repositories are clean.
2. Check coordination registry for role definitions.
3. Review the latest handoff.
4. Create or claim a task before broad work.
5. Use reservations for shared files or cross-area work.
6. Leave a handoff when stopping or when another thread needs context.

Small related edits outside a task are allowed, but shared-surface changes
should be mentioned in the handoff.

