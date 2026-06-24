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
- Read the selected stack PID registry when present.

## Boundaries

- Service meaning lives in manifests and contracts.
- Approval state lives in approval-queue.
- Durable memory and forgetting live in memory-core.
- Local secrets are injected by ops or adapters and must not be written here.

## Current Status Probe

The selected process set is defined in:

```text
manifests/services/standard.json
```

For a non-starting status probe, use the front door or the profile health
helper:

```powershell
.\sword.ps1 status
.\scripts\check-profile-health.ps1 -ManifestOnly
```

Profile health labels WebSocket services as process-registry evidence without a
routine WebSocket probe. Strict WebSocket capability truth belongs to
diagnostics/status-store or an explicit deep check, while routine diagnostics
can use process evidence to avoid making monitor UIs look unstable.

Before real launch attempts, run:

```powershell
.\scripts\check-launch-readiness.ps1
```

This reports missing local-only inputs such as secrets, Home Assistant config,
VRM assets, tool availability, and native delegate layout assumptions.
