# README Assets

Put images and other small assets referenced by the top-level `README.md` here.

## Use

Reference files from the repository root with relative paths such as:

```md
![Launcher overview](docs/assets/readme/launcher-overview.png)
```

## Rules

- Commit only curated README assets that are safe to publish with the repository.
- Prefer `.png`, `.jpg`, `.webp`, or `.svg` for images.
- Use lowercase kebab-case filenames, for example `projection-visual-passive.png`.
- Do not commit raw logs, screenshots that expose secrets/local paths/user content, audio/video captures, cache files, or private media.
- Keep large local-only media under the workspace `local/` directory instead.
- If an asset is temporary, put it in `.cache/` or `local/`, not here.
