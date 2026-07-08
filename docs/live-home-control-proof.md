# Live Home Control Proof

Live Home Control proof requires a bounded exact route. Do not infer proof from
README examples, local config, or a successful no-live readiness check.
When an exact route has selected target, action, count, command path, and
evidence rows, ordinary Home Assistant appliance operation does not need a
separate manager confirmation loop. Block only on concrete technical failure,
unclear target/action, unavailable bridge/tool/config/credential, raw/private
publication risk, non-route persistent mutation, or false
readiness/final/proof-upgrade claims.

A live route should name:

| Item | Required content |
| --- | --- |
| target | Redacted target class, not private entity ids |
| action | Allowed action id and expected result class |
| count | Number of executions |
| wait window | Settle and timeout seconds |
| restore | Optional route-owned restore action or terminal state |
| stop condition | What stops the route immediately |
| observation | HA state, external observer, or physical proof layer |
| redaction | Confirmation that raw/private data will not be published |

Use this ladder:

1. Confirm the selected config context is the intended live/full-schema context,
   not demo/default/template.
2. Read tracking metadata when HA-visible proof is needed.
3. Preview the action.
4. Run dry-run execute only when the route shape explicitly includes it.
5. Execute only the selected action count.
6. Wait the declared window.
7. Check HA state if the target is HA-readable.
8. Restore or stop only if that is part of the selected route.
9. Record external or physical observation only if that proof layer was opened.

`/actions/<allowed-action-id>/preview` and dry-run execute can prove command
shape and local bridge acceptance. They do not prove device movement.

`CheckTracking` is pre-execution metadata. `CheckState` is post-action or
post-restore HA state matching. Keep those rows separate.

For actions that issue a bridge confirmation challenge, the returned token is a
one-time execution credential. A token used for dry-run confirmation is consumed
and cannot be reused for live submit. Either preview again immediately before
live to obtain a fresh token, or use a route shape that explicitly relies on an
earlier dry-run and sets the fresh dry-run count to zero. Do not silently retry,
regenerate tokens, or perform a second live submit outside the selected route.

For lights or fans that do not expose trustworthy current state, do not claim
HA-state proof. Use command acknowledgement and an opened external/physical
observation route if needed.

Toggle-only devices should not be rewritten as deterministic `turn_on` or
`turn_off` proof. Report the submitted command class and the opened observation
layer. For example, a light can use camera-derived brightness movement if that
observation route is selected; a fan can remain command-submission-only when no
reliable observation method exists.

For climate, cover/door, and vacuum targets with readable HA state, report the
state class, freshness class, and proof ceiling. State visibility is still not
physical proof.
