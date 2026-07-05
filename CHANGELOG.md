# Changelog

All notable changes to this project will be documented in this file.

This repository currently has no tagged releases. Until release confidence is higher, prefer `v0.x` tags and prerelease identifiers for testable snapshots.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the versioning policy follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `mas`-independent App Store update detection: apps with an App Store receipt are compared against the iTunes Lookup API (with storefront-country detection and US fallback). Optional `--open-appstore` opens the App Store Updates page when outdated apps are found.
- Self-updater section (`--check-self-updaters`): detects Sparkle and Squirrel/Electron apps, checks Sparkle appcast feeds for newer stable versions, and reports apps that must be opened to update. `--open-self-updaters` launches outdated apps so their built-in updaters can run.
- Section filters `--only CSV` / `--skip CSV` (`brew,npm,mas,selfupdate,inventory`).
- `--json` machine-readable summary and `--notify` macOS notification on completion.
- `--greedy-mode latest|all|off` for cask upgrades.
- Lock file to prevent concurrent runs (with stale-lock recovery) and `caffeinate` to keep the Mac awake during a run.
- Warning when a cask about to be upgraded has its app currently running.
- `SELF-UPDATER` classification in the inventory (Sparkle/Squirrel apps).
- ShellCheck GitHub Actions workflow.
- Initial release-prep scaffolding for future tagged releases.
- A GitHub Actions workflow that validates the script and publishes source archives plus SHA256 checksums on tag pushes.
- A maintainer release checklist with explicit gating criteria for the first stable release.

### Changed
- The App Store section no longer requires `mas`; when `mas` is installed, `mas outdated` is still run as an informational cross-check only.
- Cask upgrades now default to `--greedy-latest` instead of `--greedy`: auto-updating casks are no longer reinstalled by brew (use `--greedy-mode all` to restore the old behavior).

### Fixed
- Inventory counters were computed in a pipeline subshell, so `--suggest-limit` was not enforced across directories and the unmanaged-app count was lost.
- Version comparisons treat trailing `.0` segments as insignificant (e.g. `26` == `26.0`), and prerelease appcast entries (beta/daily/nightly) no longer masquerade as the latest stable version.
