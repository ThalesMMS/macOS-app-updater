#!/usr/bin/env bash
# update-all.sh
#
# Scope (only):
#   1) Homebrew:
#        - brew update
#        - (optional) brew bundle (install missing items from a Brewfile)
#        - (optional) ensure specific casks are installed (and optionally "adopt" existing /Applications apps)
#        - upgrade formulae
#        - upgrade casks (--greedy)
#        - cleanup
#        - (optional) doctor
#   2) npm globals: force @latest for all top-level global packages
#   3) mas (Mac App Store): update all apps; if it fails, try mas reset and retry once
#   4) (optional) Inventory /Applications and suggest matching brew casks for unmanaged apps
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

# New options
RUN_BREW_BUNDLE=0
BREWFILE_PATH=""
ENSURE_CASKS_CSV=""
ADOPT_CASKS=0
RUN_INVENTORY=0
RUN_SUGGEST_CASKS=0
SUGGEST_LIMIT=30

STATUS_BREW="SKIPPED"
STATUS_BREW_BUNDLE="SKIPPED"
STATUS_BREW_DOCTOR="SKIPPED"
STATUS_NPM="SKIPPED"
STATUS_MAS="SKIPPED"
STATUS_INVENTORY="SKIPPED"

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

trim() {
  # Trim leading/trailing whitespace (bash 3.2 compatible)
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

run_cmd() {
  # Usage: run_cmd "Description" cmd arg1 arg2 ...
  local desc="$1"; shift
  local rc=0

  hr
  log "$desc"
  log "CMD: $*"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: command not executed."
    return 0
  fi

  if [[ "$QUIET" -eq 1 ]]; then
    "$@" >>"$LOG_FILE" 2>&1
    rc=$?
  else
    "$@" 2>&1 | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]:-0}"
  fi

  return "$rc"
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Core options:
  --dry-run                 Print what would run, but do not execute commands
  --quiet                   Minimal console output (still logs to file)
  --doctor                  Run 'brew doctor' (off by default)
  --fund                    Run 'npm fund' at the end of npm section (off by default)

Homebrew coverage boosters:
  --bundle                  If a Brewfile is found (or provided), run 'brew bundle' to install missing items
  --brewfile PATH           Explicit Brewfile path (used with --bundle)
  --ensure-casks CSV        Ensure these casks are installed (comma-separated), e.g. "dropbox,github,whatsapp"
  --adopt-casks             When ensuring casks, use '--force' if needed to overwrite existing /Applications apps

Inventory / suggestions:
  --inventory               List apps in /Applications and ~/Applications and classify (MAS / brew-cask / unmanaged)
  --suggest-casks           (Requires --inventory) For unmanaged apps, try 'brew search --cask' and suggest candidates
  --suggest-limit N         Max unmanaged apps to query for suggestions (default: $SUGGEST_LIMIT)

  -h, --help                Show help

Log file:
  $LOG_FILE

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --doctor --fund
  ./$SCRIPT_NAME --bundle
  ./$SCRIPT_NAME --bundle --brewfile ~/.Brewfile
  ./$SCRIPT_NAME --ensure-casks "dropbox,github,whatsapp" --adopt-casks
  ./$SCRIPT_NAME --inventory --suggest-casks
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --doctor) RUN_BREW_DOCTOR=1; shift ;;
    --fund) RUN_NPM_FUND=1; shift ;;

    --bundle) RUN_BREW_BUNDLE=1; shift ;;
    --brewfile) BREWFILE_PATH="${2:-}"; shift 2 ;;
    --ensure-casks) ENSURE_CASKS_CSV="${2:-}"; shift 2 ;;
    --adopt-casks) ADOPT_CASKS=1; shift ;;

    --inventory) RUN_INVENTORY=1; shift ;;
    --suggest-casks) RUN_SUGGEST_CASKS=1; shift ;;
    --suggest-limit) SUGGEST_LIMIT="${2:-30}"; shift 2 ;;

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
log "Options: dry-run=$DRY_RUN quiet=$QUIET doctor=$RUN_BREW_DOCTOR fund=$RUN_NPM_FUND bundle=$RUN_BREW_BUNDLE ensure-casks='${ENSURE_CASKS_CSV}' adopt-casks=$ADOPT_CASKS inventory=$RUN_INVENTORY suggest-casks=$RUN_SUGGEST_CASKS"
hr

########################################
# Helpers: Brewfile discovery, brew outdated lists
########################################
detect_brewfile() {
  local f=""
  if [[ -n "${BREWFILE_PATH//[[:space:]]/}" ]]; then
    if [[ -f "$BREWFILE_PATH" ]]; then
      printf "%s" "$BREWFILE_PATH"
      return 0
    fi
    return 1
  fi

  # Common locations
  if [[ -f "${HOME}/.Brewfile" ]]; then f="${HOME}/.Brewfile"
  elif [[ -f "${HOME}/Brewfile" ]]; then f="${HOME}/Brewfile"
  elif [[ -f "${HOME}/.config/homebrew/Brewfile" ]]; then f="${HOME}/.config/homebrew/Brewfile"
  fi

  [[ -n "$f" ]] && printf "%s" "$f"
}

brew_outdated_formulae() {
  # Best-effort across brew versions
  brew outdated --formula 2>/dev/null || brew outdated --formulae 2>/dev/null || brew outdated 2>/dev/null || true
}

brew_outdated_casks() {
  # Best-effort across brew versions
  brew outdated --cask --greedy 2>/dev/null \
    || brew outdated --casks --greedy 2>/dev/null \
    || brew outdated --cask 2>/dev/null \
    || brew outdated --casks 2>/dev/null \
    || true
}

########################################
# 1) Homebrew
########################################
brew_bundle_step() {
  if [[ "$RUN_BREW_BUNDLE" -ne 1 ]]; then
    STATUS_BREW_BUNDLE="SKIPPED"
    return 0
  fi

  local brewfile
  brewfile="$(detect_brewfile || true)"
  if [[ -z "${brewfile//[[:space:]]/}" ]]; then
    log "Homebrew: --bundle enabled but no Brewfile found. (Use --brewfile PATH)"
    STATUS_BREW_BUNDLE="SKIPPED"
    return 0
  fi

  # Prefer --no-upgrade if supported; we'll run upgrades explicitly afterward.
  local no_upg=0
  if brew bundle --help 2>/dev/null | grep -q -- "--no-upgrade"; then
    no_upg=1
  fi

  if [[ "$no_upg" -eq 1 ]]; then
    if run_cmd "Homebrew: brew bundle --file '$brewfile' --no-upgrade (install missing items)" brew bundle --file "$brewfile" --no-upgrade; then
      STATUS_BREW_BUNDLE="OK"
    else
      STATUS_BREW_BUNDLE="WARN"
    fi
  else
    if run_cmd "Homebrew: brew bundle --file '$brewfile' (install missing items)" brew bundle --file "$brewfile"; then
      STATUS_BREW_BUNDLE="OK"
    else
      STATUS_BREW_BUNDLE="WARN"
    fi
  fi
}

brew_ensure_casks_step() {
  local csv="${ENSURE_CASKS_CSV:-}"
  csv="$(trim "$csv")"
  if [[ -z "${csv//[[:space:]]/}" ]]; then
    return 0
  fi

  local IFS=,
  local -a casks
  read -r -a casks <<< "$csv"

  local cask
  for cask in "${casks[@]}"; do
    cask="$(trim "$cask")"
    [[ -z "$cask" ]] && continue

    # If already installed, nothing to do.
    if brew list --cask "$cask" >/dev/null 2>&1; then
      log "Homebrew: ensure cask '$cask' -> already installed"
      continue
    fi

    # Try install; if it fails because an app already exists, optionally force.
    if [[ "$ADOPT_CASKS" -eq 1 ]]; then
      run_cmd "Homebrew: ensure cask '$cask' (adopt/overwrite if needed)" brew install --cask --force "$cask" || true
    else
      if run_cmd "Homebrew: ensure cask '$cask' (install if missing)" brew install --cask "$cask"; then
        :
      else
        log "Homebrew: ensure cask '$cask' failed."
        log "Homebrew: If the app already exists in /Applications, rerun with --adopt-casks to overwrite/adopt it."
      fi
    fi
  done
}

brew_upgrade_formulae_one_by_one() {
  local any_fail=0
  local f

  local list
  list="$(brew_outdated_formulae)"
  if [[ -z "${list//[[:space:]]/}" ]]; then
    log "Homebrew: no outdated formulae detected."
    return 0
  fi

  log "Homebrew: upgrading formulae one-by-one (best effort)..."
  while IFS= read -r f; do
    f="$(trim "$f")"
    [[ -z "$f" ]] && continue
    if run_cmd "Homebrew: brew upgrade $f" brew upgrade "$f"; then
      :
    else
      log "Homebrew: FAILED to upgrade formula '$f'"
      any_fail=1
    fi
  done <<< "$list"

  return "$any_fail"
}

brew_upgrade_casks_one_by_one() {
  local any_fail=0
  local c

  local list
  list="$(brew_outdated_casks)"
  if [[ -z "${list//[[:space:]]/}" ]]; then
    log "Homebrew: no outdated casks detected (including greedy)."
    return 0
  fi

  log "Homebrew: upgrading casks one-by-one (best effort)..."
  while IFS= read -r c; do
    c="$(trim "$c")"
    [[ -z "$c" ]] && continue
    if run_cmd "Homebrew: brew upgrade --cask --greedy $c" brew upgrade --cask --greedy "$c"; then
      :
    else
      log "Homebrew: FAILED to upgrade cask '$c'"
      any_fail=1
    fi
  done <<< "$list"

  return "$any_fail"
}

update_brew() {
  if ! have_cmd brew; then
    log "Homebrew not found (brew). Skipping."
    STATUS_BREW="MISSING"
    return 0
  fi

  local any_fail=0
  local any_success=0

  run_cmd "Homebrew: brew update" brew update || any_fail=1

  # Optional: install missing items from Brewfile (recommended if you want max coverage via brew)
  brew_bundle_step || true

  # Optional: ensure/adopt casks explicitly
  brew_ensure_casks_step || true

  # Upgrade formulae (bulk; fallback one-by-one on failure)
  if run_cmd "Homebrew: brew upgrade (formulae; bulk)" brew upgrade; then
    any_success=1
  else
    log "Homebrew: bulk formulae upgrade failed; falling back to one-by-one."
    if brew_upgrade_formulae_one_by_one; then
      any_success=1
    else
      any_fail=1
    fi
  fi

  # Upgrade casks (bulk; fallback one-by-one on failure)
  if run_cmd "Homebrew: brew upgrade --cask --greedy (casks; bulk)" brew upgrade --cask --greedy; then
    any_success=1
  else
    log "Homebrew: bulk cask upgrade failed; falling back to one-by-one."
    if brew_upgrade_casks_one_by_one; then
      any_success=1
    else
      any_fail=1
    fi
  fi

  run_cmd "Homebrew: brew cleanup" brew cleanup || true

  if [[ "$RUN_BREW_DOCTOR" -eq 1 ]]; then
    if run_cmd "Homebrew: brew doctor" brew doctor; then
      STATUS_BREW_DOCTOR="OK"
    else
      STATUS_BREW_DOCTOR="WARN"
    fi
  fi

  if [[ "$any_fail" -eq 0 ]]; then
    STATUS_BREW="OK"
  else
    if [[ "$any_success" -eq 1 ]]; then
      STATUS_BREW="WARN"
    else
      STATUS_BREW="FAILED"
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

  run_cmd "npm: update npm itself to latest" npm install -g npm@latest || true
  run_cmd "npm: outdated globals (diagnostic)" npm outdated -g --depth=0 || true

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

  if mas_has_subcommand "account"; then
    run_cmd "mas: account (diagnostic; requires App Store sign-in)" mas account || true
  else
    log "mas: 'account' subcommand not supported by this mas version; skipping diagnostic."
  fi

  run_cmd "mas: outdated (pre-update; diagnostic)" mas outdated || true

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
# 4) Inventory /Applications (optional)
########################################
get_app_version() {
  # Best effort: CFBundleShortVersionString or CFBundleVersion
  local app_path="$1"
  local plist="$app_path/Contents/Info.plist"
  local v=""

  if [[ -f "$plist" ]]; then
    v=$(/usr/libexec/PlistBuddy -c "Print:CFBundleShortVersionString" "$plist" 2>/dev/null || true)
    v="$(trim "$v")"
    if [[ -z "$v" ]]; then
      v=$(/usr/libexec/PlistBuddy -c "Print:CFBundleVersion" "$plist" 2>/dev/null || true)
      v="$(trim "$v")"
    fi
  fi
  printf "%s" "$v"
}

brew_prefix() {
  brew --prefix 2>/dev/null || true
}

build_brew_cask_appnames() {
  # Build a newline-separated set of app base names installed via brew casks by scanning Caskroom.
  # This is heuristic but works well for most .app-based casks.
  local prefix
  prefix="$(brew_prefix)"
  if [[ -z "${prefix//[[:space:]]/}" ]]; then
    return 0
  fi

  local caskroom="$prefix/Caskroom"
  [[ -d "$caskroom" ]] || return 0

  local casks
  casks="$(brew list --cask 2>/dev/null || true)"
  [[ -z "${casks//[[:space:]]/}" ]] && return 0

  local c
  while IFS= read -r c; do
    c="$(trim "$c")"
    [[ -z "$c" ]] && continue
    local cdir="$caskroom/$c"
    [[ -d "$cdir" ]] || continue

    # Pick the most recently modified version dir
    local ver
    ver="$(ls -1t "$cdir" 2>/dev/null | head -n 1 || true)"
    [[ -z "$ver" ]] && continue

    # Find .app artifacts under that version
    find "$cdir/$ver" -maxdepth 3 -type d -name "*.app" 2>/dev/null \
      | while IFS= read -r ap; do
          local bn
          bn="$(basename "$ap")"
          bn="${bn%.app}"
          [[ -n "$bn" ]] && printf "%s\n" "$bn"
        done
  done <<< "$casks"
}

inventory_apps() {
  if [[ "$RUN_INVENTORY" -ne 1 ]]; then
    STATUS_INVENTORY="SKIPPED"
    return 0
  fi

  if ! have_cmd brew; then
    log "Inventory: brew not found; classification of brew-cask apps will be limited."
  fi

  hr
  log "Inventory: scanning /Applications and ~/Applications"

  local brew_appnames=""
  if have_cmd brew; then
    brew_appnames="$(build_brew_cask_appnames | sort -u || true)"
  fi

  local unmanaged_count=0
  local suggested_count=0

  local dirs=("/Applications" "${HOME}/Applications")
  local d
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue

    # Only top-level .app bundles
    find "$d" -maxdepth 1 -type d -name "*.app" -print0 2>/dev/null \
      | while IFS= read -r -d '' app; do
          local name
          name="$(basename "$app")"
          name="${name%.app}"

          local src="UNMANAGED"
          if [[ -d "$app/Contents/_MASReceipt" ]]; then
            src="MAS"
          elif [[ -n "$brew_appnames" ]] && printf "%s\n" "$brew_appnames" | grep -Fxq "$name"; then
            src="BREW-CASK"
          fi

          local ver
          ver="$(get_app_version "$app")"
          [[ -z "$ver" ]] && ver="?"

          log "Inventory: $src | $name | $ver | $app"

          if [[ "$src" == "UNMANAGED" ]]; then
            unmanaged_count=$((unmanaged_count + 1))

            if [[ "$RUN_SUGGEST_CASKS" -eq 1 && "$suggested_count" -lt "$SUGGEST_LIMIT" && -n "$(trim "${name}")" && -n "$(trim "${name// /}")" ]]; then
              if have_cmd brew; then
                # Best-effort: query brew search
                local q="$name"
                local res
                res="$(brew search --cask "$q" 2>/dev/null | head -n 20 || true)"
                if [[ -n "${res//[[:space:]]/}" ]]; then
                  log "Inventory: suggest cask(s) for '$name':"
                  printf "%s\n" "$res" | while IFS= read -r line; do
                    line="$(trim "$line")"
                    [[ -n "$line" ]] && log "  - $line"
                  done
                else
                  log "Inventory: no obvious cask match for '$name' via brew search."
                fi
                suggested_count=$((suggested_count + 1))
              fi
            fi
          fi
        done
  done

  STATUS_INVENTORY="OK"
}

########################################
# Run all sections
########################################
update_brew
update_npm_globals
update_mas
inventory_apps

########################################
# Summary + exit code
########################################
END_TS="$(date '+%Y-%m-%d_%H-%M-%S')"
hr
log "Finished at $END_TS"
log "Summary:"
log "  Homebrew:        $STATUS_BREW"
log "  brew bundle:     $STATUS_BREW_BUNDLE"
log "  brew doctor:     $STATUS_BREW_DOCTOR"
log "  npm globals:     $STATUS_NPM"
log "  mas (App Store): $STATUS_MAS"
log "  inventory:       $STATUS_INVENTORY"
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
