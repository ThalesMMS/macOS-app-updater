# Release checklist

Use this checklist before creating a Git tag or GitHub release for `macOS-app-updater`.

## Current recommendation

This project looks useful, but it does **not** yet present enough release hygiene to claim a stable `v1.0.0`.

For now, prefer:
- `v0.x.y` for early normal releases
- `v0.x.y-beta.N` or `v0.x.y-rc.N` for prereleases

## Pre-tag checks

- [ ] Read `README.md` and confirm prerequisites / examples still match the script.
- [ ] Update `CHANGELOG.md` with the user-visible changes in the release.
- [ ] Run `bash -n update-all.sh`.
- [ ] Run `./update-all.sh --help`.
- [ ] Run at least one manual smoke test on macOS:
  - [ ] `./update-all.sh --dry-run`
  - [ ] a basic run path that exercises the sections you changed
- [ ] Confirm the logging path and option descriptions are still accurate.
- [ ] Confirm the release notes do not overstate support, safety, or compatibility.

## Tagging guidance

Examples:
- prerelease: `v0.1.0-beta.1`
- release candidate: `v0.1.0-rc.1`
- early normal release: `v0.1.0`

The release workflow publishes:
- source `.tar.gz`
- source `.zip`
- `SHA256SUMS` file

Any tag containing `-` is published as a GitHub prerelease.

## Gates for the first stable release (`v1.0.0`)

Do **not** call the project stable until these are true:
- [ ] Core paths have been exercised on a real macOS machine, not only `--help`.
- [ ] The behavior for missing tools (`brew`, `npm`, `mas`) is documented and manually verified.
- [ ] Risky or surprising behaviors are documented clearly in the README and release notes.
- [ ] At least one release cycle has been tested with the automated packaging workflow.
- [ ] The maintainer is comfortable supporting the CLI surface as a stable contract.
