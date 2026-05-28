# Repository Boundaries

## Main Repository

`sword-agent-os` owns the Agent OS standard distribution:

- manifests
- policies
- runtime orchestration
- organ placement rules
- development governance
- bootstrap and setup scripts

## Coordination Repository

`sword-agent-os-coordination` owns shared development coordination:

- active messages
- reservations
- handoffs
- decisions
- shared notes
- thread registry

It does not own source code, runtime logs, secrets, or thread-private worklogs.

## Legacy Sources

`sword-agent-system` and `sword-voice-agent` are reference sources. Do not edit
them as part of the new Agent OS build unless explicitly requested.

## Organ Repositories

Organs may remain separate repositories nested under `organs/`. OS-specific
adaptation can live on OS branches or forks. Generally useful changes should be
separated so they can be proposed back to the organ's generic upstream.

