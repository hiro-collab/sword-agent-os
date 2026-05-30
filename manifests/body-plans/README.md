# Body Plans

Body Plans describe the static body structure for one Agent OS organism.

They do not contain launch-time port choices, process ids, local paths, or
driver implementation internals. Launch configuration belongs to the launcher
and process observation belongs to runtime diagnostics.

## v0 Rules

- `organism_id` identifies the active system organism.
- `organism_name` is the human-facing name.
- `agency_profile_id` is optional and may remain `null`; a body can be used as
  an autonomous agent body or as a cyborg-like shell without assuming desire or
  personality.
- `organ_id` names body roles, not implementation repositories.
- Legacy service names stay in `legacy_aliases`.
