# macOS App Updater

A comprehensive bash script to update all your macOS applications and packages in one go.

## Overview

`update-all.sh` is a robust automation script that updates:
- **Homebrew** packages and casks (greedy mode configurable)
- **npm** global packages (forces latest versions)
- **Mac App Store** applications — check-only, via the iTunes Lookup API (works even where `mas` is broken on recent macOS)
- **Self-updating apps** (Sparkle/Squirrel) — detects them, checks their appcast feeds, and reports apps that must be opened to update
- **Brewfile** support for reproducible setups
- **Application inventory** with cask suggestions

## Features

- ✅ Works on macOS default `/bin/bash` (bash 3.2+)
- ✅ No `sudo` required (avoids repeated prompts)
- ✅ Robust logging with timestamped log files
- ✅ Continues on failures with clear summary report
- ✅ Dry-run mode for testing
- ✅ Quiet mode for minimal console output
- ✅ Optional `brew doctor` and `npm fund` diagnostics
- ✅ Brewfile support for reproducible package management
- ✅ Application inventory with cask suggestions
- ✅ Ensure specific casks are installed
- ✅ App Store update detection without `mas` (iTunes Lookup API)
- ✅ Sparkle/Squirrel self-updater detection with appcast version checks
- ✅ Section filters (`--only` / `--skip`), JSON summary, macOS notifications
- ✅ Lock file against concurrent runs; keeps the Mac awake via `caffeinate`
- ✅ Warns when a cask about to be upgraded has its app running

## Prerequisites

Install required tools:
```bash
# Install Homebrew if not present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install mas (Mac App Store CLI)
brew install mas

# Install npm if not present (comes with Node.js)
brew install node
```

## Installation

```bash
git clone https://github.com/ThalesMMS/macOS-app-updater.git
cd macOS-app-updater
chmod +x update-all.sh
./update-all.sh --help
```

## Usage

```bash
# Basic usage
./update-all.sh

# Dry run (preview what would be updated)
./update-all.sh --dry-run

# Quiet mode with brew doctor
./update-all.sh --quiet --doctor

# Use Brewfile for reproducible setup
./update-all.sh --bundle
./update-all.sh --bundle --brewfile ~/.Brewfile

# Ensure specific casks are installed
./update-all.sh --ensure-casks "dropbox,github,whatsapp" --adopt-casks

# Inventory applications and suggest casks
./update-all.sh --inventory --suggest-casks

# Check App Store + self-updating apps, open the App Store Updates page if needed
./update-all.sh --check-self-updaters --open-appstore

# Run only some sections, with a JSON summary and a notification
./update-all.sh --only brew,npm --json --notify

# Show help
./update-all.sh --help
```

## Options

### Core Options
- `--dry-run`: Print commands without executing them
- `--quiet`: Minimal console output (still logs to file)
- `--doctor`: Run `brew doctor` for diagnostics
- `--fund`: Run `npm fund` to check package funding
- `--only CSV`: Run only these sections (`brew,npm,mas,selfupdate,inventory`)
- `--skip CSV`: Skip these sections (same names as `--only`)
- `--json`: Print a machine-readable JSON summary to stdout at the end
- `--notify`: Show a macOS notification with the summary when finished
- `-h, --help`: Show help message

### Homebrew Options
- `--bundle`: Run `brew bundle` to install missing items from Brewfile
- `--brewfile PATH`: Explicit Brewfile path (used with --bundle)
- `--ensure-casks CSV`: Ensure these casks are installed (comma-separated)
- `--adopt-casks`: When ensuring casks, use `--force` if needed to overwrite existing apps
- `--greedy-mode MODE`: Cask greedy mode — `latest` (default, `--greedy-latest`), `all` (`--greedy`), or `off`. The default no longer reinstalls auto-updating casks; those are covered by the self-updater check instead.

### App Store / Self-Updater Options
- `--open-appstore`: If outdated App Store apps are found, open the App Store Updates page
- `--check-self-updaters`: Detect Sparkle/Squirrel self-updating apps and check their appcast feeds for newer versions
- `--open-self-updaters`: Open outdated self-updating apps so their built-in updaters can run (implies `--check-self-updaters`)

The App Store check is `mas`-independent: it enumerates apps with an App Store receipt and compares local versions against the iTunes Lookup API. It is check-only — `mas upgrade` is unreliable on recent macOS, so installs still go through the App Store app (use `--open-appstore` to jump straight to the Updates page).

### Inventory Options
- `--inventory`: List apps in /Applications and ~/Applications and classify (MAS / brew-cask / self-updater / unmanaged)
- `--suggest-casks`: (Requires --inventory) For unmanaged apps, try `brew search --cask` and suggest candidates
- `--suggest-limit N`: Max unmanaged apps to query for suggestions (default: 30)

## Logging

All operations are logged to `~/Library/Logs/update-all/update-all_YYYY-MM-DD_HH-MM-SS.log`

## Versioning & Releases

This repository does not have tagged releases yet.

To keep release claims honest, the recommended policy is:
- use **Semantic Versioning** tags (`vMAJOR.MINOR.PATCH`)
- stay on **`v0.x` prereleases / early releases** until the script has stronger release confidence
- use prerelease identifiers such as `v0.1.0-beta.1` or `v0.1.0-rc.1` for opt-in testing
- treat any tag that contains `-` as a GitHub **prerelease**
- attach source archives (`.tar.gz`, `.zip`) plus SHA256 sums to each tagged release

Before tagging, update [CHANGELOG.md](CHANGELOG.md) and follow [docs/release-checklist.md](docs/release-checklist.md).

## Security & Privacy

This script:
- Does not collect or transmit personal data
- Logs are stored locally in your user directory
- Network requests are limited to: package manager updates, the iTunes Lookup API (bundle IDs of installed App Store apps are sent to Apple to look up latest versions), and — with `--check-self-updaters` — the Sparkle appcast URLs declared by your installed apps

## Community Health

For a small utility repo, the goal is lightweight but clear collaboration:

- [Contributing guide](CONTRIBUTING.md)
- [Support and FAQ](SUPPORT.md)
- [Security policy](SECURITY.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
- issue forms and pull request template under `.github/`

Please redact usernames, tokens, private paths, and other sensitive machine details before posting logs publicly.

## License

MIT License - see [LICENSE](LICENSE) file for details.
