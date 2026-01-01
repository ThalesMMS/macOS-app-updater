#!/usr/bin/env bash
# update-all.sh
#
# Scope (only):
#   1) Homebrew: update + upgrade --greedy + cleanup
#   2) npm globals: force @latest for all top-level global packages
#   3) mas (Mac App Store): update all apps; if it fails, try mas reset and retry once
#
# Design goals:
# - Works on macOS default /bin/bash (bash 3.2).
# - No sudo (to avoid repeated prompts and system-level side effects).
# - Robust logging to a timestamped logfile.
# - Continue on failures and report a clear summary at the end.

set -u
set -o pipefail
# Intentionally not using `set -e`.

SCRIPT_NAME="$(basename "$0")"
START_TS="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG_DIR="${HOME}/Library/Logs/update-all"
LOG_FILE="${LOG_DIR}/update-all_${START_TS}.log"

DRY_RUN=0
QUIET=0
RUN_BREW_DOCTOR=0
RUN_NPM_FUND=0

STATUS_BREW="SKIPPED"
STATUS_NPM="SKIPPED"
STATUS_MAS="SKIPPED"
STATUS_BREW_DOCTOR="SKIPPED"

mkdir -p "$LOG_DIR" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  local msg="$*"
  printf "[%s] %s\n" "$(ts)" "$msg" >> "$LOG_FILE"
  if [[ "$QUIET" -eq 0 ]]; then
    printf "%s\n" "$msg"
  fi
}

hr() { log "------------------------------------------------------------"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

run_cmd() {
  # Usage: run_cmd "Description" cmd arg1 arg2 ...
  local desc="$1"; shift
  hr
  log "$desc"
  log "CMD: $*"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: command not executed."
    return 0
  fi

  if [[ "$QUIET" -eq 1 ]]; then
    "$@" >>"$LOG_FILE" 2>&1
  else
    "$@" 2>&1 | tee -a "$LOG_FILE"
  fi

  return "${PIPESTATUS[0]:-0}"
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --dry-run        Print what would run, but do not execute commands
  --quiet          Minimal console output (still logs to file)
  --doctor         Run 'brew doctor' (off by default)
  --fund           Run 'npm fund' at the end of npm section (off by default)
  -h, --help       Show help

Log file:
  $LOG_FILE

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --dry-run
  ./$SCRIPT_NAME --quiet --doctor
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --doctor) RUN_BREW_DOCTOR=1; shift ;;
    --fund) RUN_NPM_FUND=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      hr
      log "Unknown option: $1"
      hr
      usage
      exit 2
      ;;
  esac
done

hr
log "$SCRIPT_NAME started at $START_TS"
log "Log file: $LOG_FILE"
log "Options: dry-run=$DRY_RUN quiet=$QUIET doctor=$RUN_BREW_DOCTOR fund=$RUN_NPM_FUND"
hr

########################################
# 1) Homebrew
########################################
update_brew() {
  if ! have_cmd brew; then
    log "Homebrew not found (brew). Skipping."
    STATUS_BREW="MISSING"
    return 0
  fi

  run_cmd "Homebrew: brew update" brew update || true

  if run_cmd "Homebrew: brew upgrade --greedy (formulae + casks; best-effort latest)" brew upgrade --greedy; then
    STATUS_BREW="OK"
  else
    STATUS_BREW="FAILED"
  fi

  run_cmd "Homebrew: brew cleanup" brew cleanup || true

  if [[ "$RUN_BREW_DOCTOR" -eq 1 ]]; then
    if run_cmd "Homebrew: brew doctor" brew doctor; then
      STATUS_BREW_DOCTOR="OK"
    else
      STATUS_BREW_DOCTOR="WARN"
    fi
  fi
}

########################################
# 2) npm globals (force @latest for installed top-level globals)
########################################
update_npm_globals() {
  if ! have_cmd npm; then
    log "npm not found. Skipping."
    STATUS_NPM="MISSING"
    return 0
  fi

  # Update npm itself to latest first (mirrors your previous workflow).
  run_cmd "npm: update npm itself to latest" npm install -g npm@latest || true

  run_cmd "npm: outdated globals (diagnostic)" npm outdated -g --depth=0 || true

  # Get top-level global packages via JSON + node (robust parsing).
  # npm implies node is present.
  local globals
  globals="$(
    npm ls -g --depth=0 --json 2>/dev/null \
      | node -e '
        const fs=require("fs");
        const data=JSON.parse(fs.readFileSync(0,"utf8"));
        const deps=(data && data.dependencies) ? data.dependencies : {};
        Object.keys(deps).sort().forEach(n => console.log(n));
      ' 2>/dev/null
  )"

  if [[ -z "${globals//[[:space:]]/}" ]]; then
    log "npm: could not read global package list (or list is empty)."
    STATUS_NPM="FAILED"
    return 0
  fi

  # Build @latest list; skip core entries that can be problematic.
  local pkgs=()
  local pkg=""
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    case "$pkg" in
      npm|npx|corepack) continue ;;
    esac
    pkgs+=("${pkg}@latest")
  done <<< "$globals"

  if [[ "${#pkgs[@]}" -eq 0 ]]; then
    log "npm: no eligible global packages found after filters."
    STATUS_NPM="OK"
    return 0
  fi

  log "npm: forcing @latest for ${#pkgs[@]} global packages:"
  for pkg in "${pkgs[@]}"; do log "  - $pkg"; done

  # Try bulk install first; if it fails, fall back to per-package to isolate failures.
  if run_cmd "npm: install -g <all>@latest (bulk)" npm install -g "${pkgs[@]}"; then
    STATUS_NPM="OK"
  else
    log "npm: bulk update failed; retrying one-by-one to isolate failures."
    local any_fail=0
    for pkg in "${pkgs[@]}"; do
      if run_cmd "npm: install -g $pkg" npm install -g "$pkg"; then
        :
      else
        log "npm: FAILED to update $pkg"
        any_fail=1
      fi
    done
    if [[ "$any_fail" -eq 0 ]]; then
      STATUS_NPM="OK"
    else
      STATUS_NPM="FAILED"
    fi
  fi

  if [[ "$RUN_NPM_FUND" -eq 1 ]]; then
    run_cmd "npm: npm fund (diagnostic)" npm fund || true
  fi
}

########################################
# 3) mas (Mac App Store)
########################################
mas_has_subcommand() {
  local sub="$1"
  mas --help 2>/dev/null | grep -Eq "^[[:space:]]*${sub}[[:space:]]"
}

update_mas() {
  if ! have_cmd mas; then
    log "mas not found. (Install with: brew install mas). Skipping."
    STATUS_MAS="MISSING"
    return 0
  fi

  # Optional diagnostic if available.
  if mas_has_subcommand "account"; then
    run_cmd "mas: account (diagnostic; requires App Store sign-in)" mas account || true
  else
    log "mas: 'account' subcommand not supported by this mas version; skipping diagnostic."
  fi

  run_cmd "mas: outdated (pre-update; diagnostic)" mas outdated || true

  # Try update once; if it fails, reset and retry once.
  if run_cmd "mas: update (updates all App Store apps to latest available)" mas update; then
    STATUS_MAS="OK"
  else
    log "mas: update failed. Attempting 'mas reset' and retrying once..."
    if mas_has_subcommand "reset"; then
      run_cmd "mas: reset (restart App Store services / clear cached downloads)" mas reset || true
      if run_cmd "mas: update (retry after reset)" mas update; then
        STATUS_MAS="OK"
      else
        STATUS_MAS="FAILED"
        log "mas: still failing. Common causes: App Store sign-in/2FA/terms prompt pending, or App Store stuck."
        log "mas: suggested manual fix: open App Store.app, confirm sign-in and any prompts, then rerun."
      fi
    else
      STATUS_MAS="FAILED"
      log "mas: 'reset' subcommand not available; cannot auto-recover."
    fi
  fi

  run_cmd "mas: outdated (post-update; diagnostic)" mas outdated || true
}

########################################
# Run all sections
########################################
update_brew
update_npm_globals
update_mas

########################################
# Summary + exit code
########################################
END_TS="$(date '+%Y-%m-%d_%H-%M-%S')"
hr
log "Finished at $END_TS"
log "Summary:"
log "  Homebrew:        $STATUS_BREW"
log "  brew doctor:     $STATUS_BREW_DOCTOR"
log "  npm globals:     $STATUS_NPM"
log "  mas (App Store): $STATUS_MAS"
hr
log "Full log: $LOG_FILE"
hr

EXIT_CODE=0
for st in "$STATUS_BREW" "$STATUS_NPM" "$STATUS_MAS"; do
  if [[ "$st" == "FAILED" ]]; then
    EXIT_CODE=1
  fi
done

exit "$EXIT_CODE"
