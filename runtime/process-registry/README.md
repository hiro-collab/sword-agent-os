# Process Registry

Process registry tracks managed runtime processes for start, stop, status, and
handoff between launch surfaces. It records process identity and ownership; it
does not define service contracts or decide whether an operation is allowed.

## Responsibilities

- Record managed process IDs and service names.
- Distinguish OS-owned processes from external dependencies.
- Support start, stop, status, dry-run, and manifest-only checks.
- Feed current process projections into status-store.
- Append lifecycle events to event-journal after redaction.
- Preserve compatibility with old `.cache/home-control-stack/pids.json` during
  migration.

## Boundaries

- Service meaning lives in manifests and contracts.
- Approval state lives in approval-queue.
- Durable memory and forgetting live in memory-core.
- Local secrets are injected by ops or adapters and must not be written here.

## Initial Compatibility Targets

The first compatibility profile is `thought-core-v0-compat`. Its process set is
defined in:

```text
manifests/services/thought-core-v0-compat.json
```

