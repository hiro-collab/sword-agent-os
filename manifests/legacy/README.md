# Legacy Source Manifests

Legacy source manifests record reproducible reference points from the old
`sword-agent-system` workspace. They are not authority by themselves; they are
evidence used to migrate contracts, profiles, runtime behavior, and organ
integration into Agent OS.

Do not clone runtime data, caches, local configuration, secrets, or old
compatibility stacks from legacy source paths.

`recovery-candidates.json` records old branches that should be inspected for
specific recoverable features. These branches are not adoption baselines and
should not be checked out wholesale over the selected organ branch without a new
integration decision.
