# Live Home Control Proof

Live Home Control proof requires a bounded ticket. Do not infer permission from
README examples, local config, or a successful no-live readiness check.

A live ticket should name:

| Item | Required content |
| --- | --- |
| target | Redacted target class, not private entity ids |
| action | Allowed action id and expected result class |
| count | Number of executions |
| wait window | Settle and timeout seconds |
| restore | Safe/original restore action or terminal state |
| stop condition | What stops the route immediately |
| observation | HA state, external observer, or physical proof layer |
| redaction | Confirmation that raw/private data will not be published |

Use this ladder:

1. Preview the action.
2. Run dry-run execute.
3. Confirm tracking/readiness metadata.
4. Execute only the ticketed action count.
5. Wait the declared window.
6. Check HA state if the target is HA-readable.
7. Restore or stop to the declared safe/original state.
8. Record external or physical observation only if that proof layer was opened.

`/actions/<allowed-action-id>/preview` and dry-run execute can prove command
shape and local bridge acceptance. They do not prove device movement.

`CheckTracking` is pre-execution metadata. `CheckState` is post-action or
post-restore HA state matching. Keep those rows separate.

For lights or fans that do not expose trustworthy current state, do not claim
HA-state proof. Use command acknowledgement and an opened external/physical
observation route if needed.

For climate, cover/door, and vacuum targets with readable HA state, report the
state class, freshness class, and proof ceiling. State visibility is still not
physical proof.
