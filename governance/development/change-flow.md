# Change Flow

## OS-Specific Changes

Changes needed only for the standard Agent OS distribution belong in
`sword-agent-os` or in OS-specific branches/forks of organ repositories.

## Generic Organ Improvements

If an organ change is useful outside Sword Agent OS, separate it from OS
integration work and prepare it for the organ's generic repository.

## Cross-Area Changes

Cross-area changes should be coordinated through messages, reservations, and
handoffs. The central implementation thread usually integrates changes that
touch standard manifests, policies, runtime structure, or multiple organs.

## Standard Distribution Adoption

Development inside a nested organ checkout is not automatically adopted into
the standard distribution. Adoption is a two-step state:

1. The organ/control-plane checkout has the desired commit and its own tests or
   review evidence.
2. The parent `sword-agent-os` manifest pin is updated, validated, and proven
   through distribution checks.

If a checkout is ahead of the parent manifest, treat it as `ahead_of_manifest`:
the work may be useful, but it is not part of the installable standard
distribution yet. Do not report it as distributed, review-ready, or
fresh-install proven until the parent manifest pin has been updated and the
distribution proof is rerun.

Required checks for standard distribution adoption:

- `scripts/check-distribution-pins.ps1 -Profile standard`
- `scripts/check-distribution-pins.ps1 -Profile standard -Strict` before
  release, fresh-install, or user-review gates
- `scripts/doctor-distribution.ps1 -Profile standard` when diagnosing a local
  assembled workspace
- `scripts/validate-manifests.ps1` after any manifest, release, profile, or
  source-pin edit
- the focused organ/control-plane tests that justify the new nested commit

When a strict pin check fails, the next action is not to loosen the gate. Decide
whether the nested commit should be formally adopted, then either update the
parent manifest pin and rerun the checks, or return the checkout to the current
manifest pin.
