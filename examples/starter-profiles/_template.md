# Starter Profile Template

<!-- starter-profile:template -->

Use this template for new `examples/starter-profiles/<profile-id>/README.md`
files and for material rewrites of existing starter profiles.

A starter profile is a user journey and guide shape. It is not a proof claim,
not live authorization, and not automatically a new `sword.ps1` front-door
command. It should help a fresh operator understand the smallest safe route for
one capability without collapsing proof layers.

If a profile name or workflow uses the word `preview`, state whether it means a
read-only readiness route, a command preview, or a Home Assistant preview
endpoint. Read-only readiness is not Home Assistant preview endpoint proof.

## Goal

<!-- starter-profile:template-goal -->

State the outcome the operator should reach in one or two sentences.

Include:

- the capability being checked;
- the intended audience;
- the no-live/live boundary for the profile;
- the proof ceiling the profile can reach.

## Safe Route

<!-- starter-profile:template-safe-route -->

List the shortest safe commands or docs in execution order.

For every command, say whether it is:

- no-live/read-only;
- a command preview only;
- a dry-run;
- a live or external operation.

If the route depends on local/private inputs, say how the operator should
confirm that the selected context is intentional without publishing raw values.

## Result Fields

<!-- starter-profile:template-result-fields -->

Keep evidence fields separate. Prefer a table with these columns:

| Field | Meaning | Does not prove |
| --- | --- | --- |
| `<field>` | `<what was checked>` | `<proof layer not reached>` |

Do not merge helper reachability, preview, dry-run, command submission,
HA-visible state, external observation, and physical/device proof into one
status.

## Stop Conditions

<!-- starter-profile:template-stop-conditions -->

Name the exact conditions that stop the route before the next proof layer.

Include relevant stops for:

- missing or ambiguous local/private config;
- demo/default/template config where a real environment is required;
- `HOLD_LIVE` or approval markers;
- unavailable bridge/provider/browser/device surfaces;
- helper output that would require raw IDs, tokens, logs, media, screenshots, or
  private paths to explain;
- any route that would require preview/dry-run/live work outside this profile.

## Does Not Prove

<!-- starter-profile:template-does-not-prove -->

List the proof claims that this profile does not make.

At minimum, decide whether to exclude:

- provider response quality;
- Home Assistant preview acceptance;
- dry-run acceptance;
- live command submission;
- post-action HA-visible state;
- external/user observation;
- camera/media proof;
- physical/device proof;
- release/readiness.

## Optional Next Paths

<!-- starter-profile:template-next-paths -->

Link the next docs or profiles without making them implicit continuation routes.
If the next step is live, say that it needs a separate exact route/ticket.
