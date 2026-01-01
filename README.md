# macOS App Updater

A comprehensive bash script to update all your macOS applications and packages in one go.

## Overview

`update-all.sh` is a robust automation script that updates:
- **Homebrew** packages and casks (with `--greedy` flag)
- **npm** global packages (forces latest versions)
- **Mac App Store** applications (via `mas`)

## Features

- ✅ Works on macOS default `/bin/bash` (bash 3.2+)
- ✅ No `sudo` required (avoids repeated prompts)
- ✅ Robust logging with timestamped log files
- ✅ Continues on failures with clear summary report
- ✅ Dry-run mode for testing
- ✅ Quiet mode for minimal console output
- ✅ Optional `brew doctor` and `npm fund` diagnostics

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

## Usage

```bash
# Basic usage
./update-all.sh

# Dry run (preview what would be updated)
./update-all.sh --dry-run

# Quiet mode with brew doctor
./update-all.sh --quiet --doctor

# Show help
./update-all.sh --help
```

## Options

- `--dry-run`: Print commands without executing them
- `--quiet`: Minimal console output (still logs to file)
- `--doctor`: Run `brew doctor` for diagnostics
- `--fund`: Run `npm fund` to check package funding
- `-h, --help`: Show help message

## Logging

All operations are logged to `~/Library/Logs/update-all/update-all_YYYY-MM-DD_HH-MM-SS.log`

## Security & Privacy

This script:
- Does not collect or transmit personal data
- Only uses local package managers
- Logs are stored locally in your user directory
- No network requests except package manager updates

## Contributing

Feel free to submit issues and pull requests to improve this script.

## License

MIT License - see [LICENSE](LICENSE) file for details.
