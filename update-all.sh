#!/usr/bin/env bash
# update-all.sh
#
# Scope (only):
#   1) Homebrew:
#        - brew update
#        - (optional) brew bundle (install missing items from a Brewfile)
#        - (optional) ensure specific casks are installed (and optionally "adopt" existing /Applications apps)
#        - upgrade formulae
#        - upgrade casks (greedy mode configurable: latest|all|off)
#        - cleanup
#        - (optional) doctor
#   2) npm globals: force @latest for all top-level global packages
#   3) App Store: check-only. Enumerates apps with a _MASReceipt and compares local
#      versions against the iTunes Lookup API (mas-independent; 'mas upgrade' is
#      unreliable on recent macOS). Optionally opens the App Store Updates page.
#   4) (optional) Self-updaters: detect Sparkle/Squirrel apps, check their appcast
#      feeds for newer versions, and report apps that must be opened to update.
#   5) (optional) Inventory /Applications and suggest matching brew casks for unmanaged apps
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
REPAIR_CASK_DRIFT=0
RUN_INVENTORY=0
RUN_SUGGEST_CASKS=0
SUGGEST_LIMIT=30

# Cask greedy mode: latest (--greedy-latest), all (--greedy), off (no flag).
# Default 'latest': auto-updating casks (Chrome, etc.) update themselves and are
# covered by the self-updater check instead of being reinstalled by brew.
GREEDY_MODE="latest"
RUN_SELF_UPDATERS=0
OPEN_SELF_UPDATERS=0
OPEN_APPSTORE=0
ONLY_SECTIONS=""
SKIP_SECTIONS=""
JSON_OUTPUT=0
NOTIFY=0

STATUS_BREW="SKIPPED"
STATUS_BREW_BUNDLE="SKIPPED"
STATUS_BREW_DOCTOR="SKIPPED"
STATUS_NPM="SKIPPED"
STATUS_MAS="SKIPPED"
STATUS_SELFUPDATE="SKIPPED"
STATUS_INVENTORY="SKIPPED"

MAS_OUTDATED_COUNT=0
APPSTORE_STALE_LOOKUP_COUNT=0
SELF_OUTDATED_COUNT=0
SELF_UNKNOWN_COUNT=0
CASK_DRIFT_DETECTED=0
CASK_DRIFT_REPAIRED=0
CASK_DRIFT_FAILED=0

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
  --only CSV                Run only these sections (brew,npm,mas,selfupdate,inventory)
  --skip CSV                Skip these sections (same names as --only)
  --json                    Print a machine-readable JSON summary to stdout at the end
  --notify                  Show a macOS notification with the summary when finished

Homebrew coverage boosters:
  --bundle                  If a Brewfile is found (or provided), run 'brew bundle' to install missing items
  --brewfile PATH           Explicit Brewfile path (used with --bundle)
  --ensure-casks CSV        Ensure these casks are installed (comma-separated), e.g. "dropbox,github,whatsapp"
  --adopt-casks             When ensuring casks, use '--force' if needed to overwrite existing /Applications apps
  --repair-cask-drift       Reinstall installed casks when Homebrew's version is newer than the actual .app bundle
  --greedy-mode MODE        Cask greedy mode: latest (default; --greedy-latest), all (--greedy), off

App Store / self-updaters:
  --open-appstore           If outdated App Store apps are found, open the App Store Updates page
  --check-self-updaters     Detect Sparkle/Squirrel self-updating apps and check their feeds for updates
  --open-self-updaters      Open outdated self-updating apps so their built-in updaters can run (implies --check-self-updaters)

Inventory / suggestions:
  --inventory               List apps in /Applications and ~/Applications and classify (MAS / brew-cask / self-updater / unmanaged)
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
  ./$SCRIPT_NAME --check-self-updaters --open-appstore
  ./$SCRIPT_NAME --only brew,npm
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
    --repair-cask-drift) REPAIR_CASK_DRIFT=1; shift ;;

    --inventory) RUN_INVENTORY=1; shift ;;
    --suggest-casks) RUN_SUGGEST_CASKS=1; shift ;;
    --suggest-limit) SUGGEST_LIMIT="${2:-30}"; shift 2 ;;

    --only) ONLY_SECTIONS="${2:-}"; shift 2 ;;
    --skip) SKIP_SECTIONS="${2:-}"; shift 2 ;;
    --json) JSON_OUTPUT=1; shift ;;
    --notify) NOTIFY=1; shift ;;
    --greedy-mode)
      GREEDY_MODE="${2:-}"
      case "$GREEDY_MODE" in
        all|latest|off) ;;
        *) printf "Invalid --greedy-mode: '%s' (use: latest, all, off)\n" "$GREEDY_MODE"; exit 2 ;;
      esac
      shift 2 ;;
    --open-appstore) OPEN_APPSTORE=1; shift ;;
    --check-self-updaters) RUN_SELF_UPDATERS=1; shift ;;
    --open-self-updaters) RUN_SELF_UPDATERS=1; OPEN_SELF_UPDATERS=1; shift ;;

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
log "Options: dry-run=$DRY_RUN quiet=$QUIET doctor=$RUN_BREW_DOCTOR fund=$RUN_NPM_FUND bundle=$RUN_BREW_BUNDLE ensure-casks='${ENSURE_CASKS_CSV}' adopt-casks=$ADOPT_CASKS repair-cask-drift=$REPAIR_CASK_DRIFT inventory=$RUN_INVENTORY suggest-casks=$RUN_SUGGEST_CASKS greedy-mode=$GREEDY_MODE self-updaters=$RUN_SELF_UPDATERS only='${ONLY_SECTIONS}' skip='${SKIP_SECTIONS}'"
hr

########################################
# Lock file (prevent concurrent runs) + keep the Mac awake
########################################
LOCK_DIR="${TMPDIR:-/tmp}/update-all.lock"

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local old_pid
    old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      log "Another $SCRIPT_NAME run (pid $old_pid) is in progress. Exiting."
      exit 3
    fi
    log "Removing stale lock left by pid '${old_pid:-unknown}'."
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      log "Could not acquire lock at $LOCK_DIR. Exiting."
      exit 3
    fi
  fi
  printf "%s" "$$" > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

acquire_lock

# Prevent idle sleep while updates run; caffeinate exits when this script does.
if have_cmd caffeinate && [[ "$DRY_RUN" -eq 0 ]]; then
  caffeinate -i -w $$ &
  log "caffeinate: preventing idle sleep for the duration of this run."
fi

########################################
# Shared helpers: sections, versions, bundle metadata
########################################
section_enabled() {
  # Usage: section_enabled <brew|npm|mas|selfupdate|inventory>
  local name="$1"
  local csv
  if [[ -n "${ONLY_SECTIONS//[[:space:]]/}" ]]; then
    csv=",${ONLY_SECTIONS// /},"
    [[ "$csv" == *",${name},"* ]] || return 1
  fi
  if [[ -n "${SKIP_SECTIONS//[[:space:]]/}" ]]; then
    csv=",${SKIP_SECTIONS// /},"
    [[ "$csv" == *",${name},"* ]] && return 1
  fi
  return 0
}

ver_gt() {
  # Returns 0 if version $1 is strictly greater than $2.
  # Trailing .0 segments are insignificant (26 == 26.0).
  local a="$1" b="$2"
  while [[ "$a" == *.0 ]]; do a="${a%.0}"; done
  while [[ "$b" == *.0 ]]; do b="${b%.0}"; done
  [[ "$a" == "$b" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)" == "$a" ]]
}

ver_comparable() {
  # Both versions must start with a digit for sort -V to mean anything
  # (guards against formats like 'Build 5898' vs '2025.9.2').
  printf "%s" "$1" | grep -qE '^[0-9]' && printf "%s" "$2" | grep -qE '^[0-9]'
}

get_bundle_id() {
  /usr/libexec/PlistBuddy -c "Print:CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true
}

appstore_country() {
  # Two-letter storefront country from the system locale; fallback 'us'.
  local locale region
  locale="$(defaults read -g AppleLocale 2>/dev/null || true)"
  region="${locale#*_}"
  region="${region%%@*}"
  if printf "%s" "$region" | grep -Eq '^[A-Za-z]{2}$'; then
    printf "%s" "$region" | tr '[:upper:]' '[:lower:]'
  else
    printf "us"
  fi
}

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

brew_greedy_args() {
  # Echo the greedy flag for the configured mode (empty for 'off').
  case "$GREEDY_MODE" in
    all) printf -- "--greedy" ;;
    latest) printf -- "--greedy-latest" ;;
    *) printf "" ;;
  esac
}

brew_outdated_casks() {
  # Best-effort across brew versions
  case "$GREEDY_MODE" in
    all)
      brew outdated --cask --greedy 2>/dev/null \
        || brew outdated --cask 2>/dev/null \
        || true ;;
    latest)
      brew outdated --cask --greedy-latest 2>/dev/null \
        || brew outdated --cask --greedy 2>/dev/null \
        || brew outdated --cask 2>/dev/null \
        || true ;;
    *)
      brew outdated --cask 2>/dev/null || true ;;
  esac
}

warn_running_cask_apps() {
  # Upgrading a cask while its app is running can leave the app broken until relaunch.
  local list
  list="$(brew_outdated_casks)"
  [[ -z "${list//[[:space:]]/}" ]] && return 0

  local prefix caskroom
  prefix="$(brew_prefix)"
  caskroom="$prefix/Caskroom"
  [[ -d "$caskroom" ]] || return 0

  local c cdir ver ap name
  while IFS= read -r c; do
    c="$(trim "${c%% *}")"
    [[ -z "$c" ]] && continue
    cdir="$caskroom/$c"
    [[ -d "$cdir" ]] || continue
    ver="$(ls -1t "$cdir" 2>/dev/null | head -n 1 || true)"
    [[ -z "$ver" ]] && continue
    while IFS= read -r ap; do
      name="$(basename "$ap")"
      name="${name%.app}"
      if pgrep -qf "${name}.app/Contents/MacOS" 2>/dev/null; then
        log "Homebrew: WARNING: '$name' (cask '$c') appears to be running; quit it before the upgrade to avoid a broken app until relaunch."
      fi
    done < <(find "$cdir/$ver" -maxdepth 3 -type d -name "*.app" 2>/dev/null)
  done <<< "$list"
}

cask_receipt_path() {
  local cask="$1"
  local prefix
  prefix="$(brew_prefix)"
  [[ -z "${prefix//[[:space:]]/}" ]] && return 0
  printf "%s/Caskroom/%s/.metadata/INSTALL_RECEIPT.json" "$prefix" "$cask"
}

plist_raw() {
  # Usage: plist_raw key.path file
  plutil -extract "$1" raw -o - "$2" 2>/dev/null || true
}

cask_receipt_version() {
  local receipt="$1"
  [[ -f "$receipt" ]] || return 0
  plist_raw "source.version" "$receipt"
}

cask_receipt_app_names() {
  local receipt="$1"
  local count i app_count j app_name

  [[ -f "$receipt" ]] || return 0
  count="$(plist_raw "uninstall_artifacts" "$receipt")"
  case "$count" in
    ""|*[!0-9]*) return 0 ;;
  esac

  i=0
  while [[ "$i" -lt "$count" ]]; do
    if [[ "$(plutil -type "uninstall_artifacts.$i.app" "$receipt" 2>/dev/null || true)" == "array" ]]; then
      app_count="$(plist_raw "uninstall_artifacts.$i.app" "$receipt")"
      case "$app_count" in
        ""|*[!0-9]*) app_count=0 ;;
      esac
      j=0
      while [[ "$j" -lt "$app_count" ]]; do
        app_name="$(plist_raw "uninstall_artifacts.$i.app.$j" "$receipt")"
        [[ "$app_name" == *.app ]] && printf "%s\n" "$app_name"
        j=$((j + 1))
      done
    fi
    i=$((i + 1))
  done
}

cask_app_target() {
  local cask="$1" cask_ver="$2" app_name="$3"
  local prefix caskroom candidate target

  prefix="$(brew_prefix)"
  caskroom="$prefix/Caskroom"
  candidate="$caskroom/$cask/$cask_ver/$app_name"

  if [[ -L "$candidate" ]]; then
    target="$(readlink "$candidate" 2>/dev/null || true)"
    if [[ "$target" == /* && -d "$target" ]]; then
      printf "%s" "$target"
      return 0
    fi
  fi

  if [[ -d "/Applications/$app_name" ]]; then
    printf "%s" "/Applications/$app_name"
  elif [[ -d "${HOME}/Applications/$app_name" ]]; then
    printf "%s" "${HOME}/Applications/$app_name"
  elif [[ -d "$candidate" ]]; then
    printf "%s" "$candidate"
  fi
}

ver_drift_comparable() {
  local a="$1" b="$2" a_parts=1 b_parts=1 rest
  printf "%s" "$1" | grep -qE '^[0-9][0-9A-Za-z._+-]*$' \
    && printf "%s" "$2" | grep -qE '^[0-9][0-9A-Za-z._+-]*$' \
    || return 1

  rest="$a"
  while [[ "$rest" == *.* ]]; do
    a_parts=$((a_parts + 1))
    rest="${rest#*.}"
  done

  rest="$b"
  while [[ "$rest" == *.* ]]; do
    b_parts=$((b_parts + 1))
    rest="${rest#*.}"
  done

  [[ "$a_parts" -eq "$b_parts" ]]
}

cask_has_version_drift() {
  local cask="$1"
  local receipt cask_ver app_names app_name app_path local_ver found

  receipt="$(cask_receipt_path "$cask")"
  cask_ver="$(cask_receipt_version "$receipt")"
  [[ -z "${cask_ver//[[:space:]]/}" ]] && return 1

  app_names="$(cask_receipt_app_names "$receipt")"
  [[ -z "${app_names//[[:space:]]/}" ]] && return 1

  found=0
  while IFS= read -r app_name; do
    [[ -z "$app_name" ]] && continue
    app_path="$(cask_app_target "$cask" "$cask_ver" "$app_name")"
    [[ -z "$app_path" || ! -d "$app_path" ]] && continue

    local_ver="$(get_app_version "$app_path")"
    [[ -z "${local_ver//[[:space:]]/}" ]] && continue
    ver_drift_comparable "$cask_ver" "$local_ver" || continue

    if ver_gt "$cask_ver" "$local_ver"; then
      log "Homebrew: CASK-DRIFT $cask app=$app_name cask=$cask_ver bundle=$local_ver path=$app_path"
      found=1
    fi
  done <<< "$app_names"

  [[ "$found" -eq 1 ]]
}

cask_has_running_app() {
  local cask="$1"
  local receipt cask_ver app_names app_name app_path app_base running

  receipt="$(cask_receipt_path "$cask")"
  cask_ver="$(cask_receipt_version "$receipt")"
  app_names="$(cask_receipt_app_names "$receipt")"
  running=1

  while IFS= read -r app_name; do
    [[ -z "$app_name" ]] && continue
    app_path="$(cask_app_target "$cask" "$cask_ver" "$app_name")"
    [[ -z "$app_path" ]] && continue
    app_base="$(basename "$app_path")"
    if pgrep -qf "${app_base}/Contents/MacOS" 2>/dev/null; then
      log "Homebrew: CASK-DRIFT repair skipped for '$cask' because '$app_base' appears to be running."
      running=0
    fi
  done <<< "$app_names"

  return "$running"
}

restore_staged_cask_apps() {
  local staged="$1"
  local backup original

  while IFS='|' read -r backup original; do
    [[ -z "$backup" || -z "$original" ]] && continue
    if [[ -d "$backup" && ! -e "$original" ]]; then
      if mv "$backup" "$original" 2>/dev/null; then
        log "Homebrew: restored staged app '$original' after failed repair."
      else
        log "Homebrew: WARNING: could not restore staged app '$backup' to '$original'."
      fi
    elif [[ -d "$backup" ]]; then
      log "Homebrew: staged app remains at '$backup'."
    fi
  done <<< "$staged"
}

stage_unwritable_cask_apps() {
  local cask="$1"
  local receipt cask_ver app_names app_name app_path app_parent trash backup n staged

  receipt="$(cask_receipt_path "$cask")"
  cask_ver="$(cask_receipt_version "$receipt")"
  app_names="$(cask_receipt_app_names "$receipt")"
  staged=""

  while IFS= read -r app_name; do
    [[ -z "$app_name" ]] && continue
    app_path="$(cask_app_target "$cask" "$cask_ver" "$app_name")"
    [[ -z "$app_path" || ! -d "$app_path" ]] && continue
    if [[ ! -w "$app_path" ]]; then
      app_parent="$(dirname "$app_path")"
      if [[ ! -w "$app_parent" ]]; then
        log "Homebrew: CASK-DRIFT repair skipped for '$cask' because '$app_path' is not movable without sudo."
        restore_staged_cask_apps "$staged"
        return 1
      fi

      trash="${HOME}/.Trash"
      if ! mkdir -p "$trash" 2>/dev/null; then
        log "Homebrew: CASK-DRIFT repair skipped for '$cask' because '$trash' could not be created."
        restore_staged_cask_apps "$staged"
        return 1
      fi

      backup="$trash/${app_name}.update-all-backup-${START_TS}"
      n=1
      while [[ -e "$backup" ]]; do
        backup="$trash/${app_name}.update-all-backup-${START_TS}.$n"
        n=$((n + 1))
      done

      if mv "$app_path" "$backup" 2>/dev/null; then
        log "Homebrew: staged unwritable app '$app_path' at '$backup' before repair."
        staged="${staged}${backup}|${app_path}"$'\n'
      else
        log "Homebrew: CASK-DRIFT repair skipped for '$cask' because '$app_path' could not be moved without sudo."
        restore_staged_cask_apps "$staged"
        return 1
      fi
    fi
  done <<< "$app_names"

  STAGED_CASK_APP_BACKUPS="$staged"
  return 0
}

check_cask_drift() {
  if ! have_cmd plutil; then
    log "Homebrew: plutil not found; skipping cask drift check."
    return 0
  fi

  local casks cask any_unrepaired=0
  casks="$(brew list --cask 2>/dev/null || true)"
  if [[ -z "${casks//[[:space:]]/}" ]]; then
    log "Homebrew: no installed casks found for drift check."
    return 0
  fi

  hr
  log "Homebrew: checking installed cask app versions for drift"

  while IFS= read -r cask; do
    cask="$(trim "$cask")"
    [[ -z "$cask" ]] && continue

    if cask_has_version_drift "$cask"; then
      CASK_DRIFT_DETECTED=$((CASK_DRIFT_DETECTED + 1))

      if [[ "$REPAIR_CASK_DRIFT" -ne 1 ]]; then
        log "Homebrew: CASK-DRIFT repair available for '$cask'; rerun with --repair-cask-drift to reinstall this cask."
        any_unrepaired=1
        continue
      fi

      if cask_has_running_app "$cask"; then
        CASK_DRIFT_FAILED=$((CASK_DRIFT_FAILED + 1))
        any_unrepaired=1
        continue
      fi

      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "Homebrew: DRY-RUN: would repair cask drift with: brew reinstall --cask --force --no-ask $cask"
        any_unrepaired=1
        continue
      fi

      STAGED_CASK_APP_BACKUPS=""
      if ! stage_unwritable_cask_apps "$cask"; then
        CASK_DRIFT_FAILED=$((CASK_DRIFT_FAILED + 1))
        any_unrepaired=1
        continue
      fi

      if run_cmd "Homebrew: repair cask drift for '$cask'" brew reinstall --cask --force --no-ask "$cask"; then
        if cask_has_version_drift "$cask"; then
          log "Homebrew: CASK-DRIFT repair did not resolve '$cask'."
          restore_staged_cask_apps "$STAGED_CASK_APP_BACKUPS"
          CASK_DRIFT_FAILED=$((CASK_DRIFT_FAILED + 1))
          any_unrepaired=1
        else
          log "Homebrew: CASK-DRIFT repaired '$cask'."
          restore_staged_cask_apps "$STAGED_CASK_APP_BACKUPS"
          CASK_DRIFT_REPAIRED=$((CASK_DRIFT_REPAIRED + 1))
        fi
      else
        log "Homebrew: CASK-DRIFT repair failed for '$cask'."
        restore_staged_cask_apps "$STAGED_CASK_APP_BACKUPS"
        CASK_DRIFT_FAILED=$((CASK_DRIFT_FAILED + 1))
        any_unrepaired=1
      fi
    fi
  done <<< "$casks"

  log "Homebrew: cask drift detected=$CASK_DRIFT_DETECTED repaired=$CASK_DRIFT_REPAIRED failed=$CASK_DRIFT_FAILED"
  return "$any_unrepaired"
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

  local greedy_flag
  greedy_flag="$(brew_greedy_args)"
  local -a greedy_args=()
  [[ -n "$greedy_flag" ]] && greedy_args=("$greedy_flag")

  local list
  list="$(brew_outdated_casks)"
  if [[ -z "${list//[[:space:]]/}" ]]; then
    log "Homebrew: no outdated casks detected (greedy-mode: $GREEDY_MODE)."
    return 0
  fi

  log "Homebrew: upgrading casks one-by-one (best effort)..."
  while IFS= read -r c; do
    c="$(trim "$c")"
    [[ -z "$c" ]] && continue
    if run_cmd "Homebrew: brew upgrade --cask ${greedy_flag} $c" brew upgrade --cask ${greedy_args[@]+"${greedy_args[@]}"} "$c"; then
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
  warn_running_cask_apps || true

  local greedy_flag
  greedy_flag="$(brew_greedy_args)"
  local -a greedy_args=()
  [[ -n "$greedy_flag" ]] && greedy_args=("$greedy_flag")

  if run_cmd "Homebrew: brew upgrade --cask ${greedy_flag} (casks; bulk)" brew upgrade --cask ${greedy_args[@]+"${greedy_args[@]}"}; then
    any_success=1
  else
    log "Homebrew: bulk cask upgrade failed; falling back to one-by-one."
    if brew_upgrade_casks_one_by_one; then
      any_success=1
    else
      any_fail=1
    fi
  fi

  if check_cask_drift; then
    :
  else
    any_fail=1
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
# 3) App Store (check-only; mas-independent)
########################################
list_mas_apps() {
  # Newline-separated paths of apps with an App Store receipt.
  local app
  while IFS= read -r app; do
    [[ -d "$app/Contents/_MASReceipt" ]] && printf "%s\n" "$app"
  done < <(find /Applications "${HOME}/Applications" -maxdepth 1 -type d -name "*.app" 2>/dev/null | sort)
}

itunes_latest_version() {
  # $1 = bundle id, $2 = storefront country. Prints latest version or nothing.
  local json
  json="$(curl -fsS --max-time 15 "https://itunes.apple.com/lookup?bundleId=${1}&country=${2}" 2>/dev/null || true)"
  if [[ -z "$json" ]] || printf "%s" "$json" | grep -Eq '"resultCount" *: *0'; then
    if [[ "$2" != "us" ]]; then
      json="$(curl -fsS --max-time 15 "https://itunes.apple.com/lookup?bundleId=${1}&country=us" 2>/dev/null || true)"
    fi
  fi
  printf "%s" "$json" | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' | head -n 1
}

update_mas() {
  # 'mas upgrade'/'mas outdated' are unreliable on recent macOS (Apple removed the
  # private hooks mas relied on), so the primary check compares local receipts
  # against the iTunes Lookup API. Check-only: installs still go through App Store.
  hr
  log "App Store: checking installed apps against the iTunes Lookup API"

  local mas_apps
  mas_apps="$(list_mas_apps)"
  if [[ -z "${mas_apps//[[:space:]]/}" ]]; then
    log "App Store: no apps with an App Store receipt found."
    STATUS_MAS="OK"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    local n
    n="$(printf "%s\n" "$mas_apps" | grep -c . || true)"
    log "App Store: DRY-RUN: would check $n apps via the iTunes Lookup API."
    STATUS_MAS="OK"
    return 0
  fi

  local country
  country="$(appstore_country)"
  log "App Store: storefront country: $country"

  local app name bid local_ver remote_ver
  local checked=0 outdated=0 notfound=0 stale_lookup=0
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    name="$(basename "$app")"
    name="${name%.app}"
    bid="$(get_bundle_id "$app")"
    local_ver="$(get_app_version "$app")"
    [[ -z "$bid" ]] && continue

    remote_ver="$(itunes_latest_version "$bid" "$country")"
    checked=$((checked + 1))
    if [[ -z "$remote_ver" ]]; then
      log "App Store: ?          $name ($bid) local=$local_ver — not found in storefront (delisted or region-locked)"
      notfound=$((notfound + 1))
    elif ver_gt "$remote_ver" "$local_ver"; then
      log "App Store: OUTDATED   $name local=$local_ver latest=$remote_ver"
      outdated=$((outdated + 1))
    elif ver_comparable "$local_ver" "$remote_ver" && ver_gt "$local_ver" "$remote_ver"; then
      log "App Store: STALE-LOOKUP $name local=$local_ver lookup=$remote_ver — iTunes Lookup is behind the installed version"
      stale_lookup=$((stale_lookup + 1))
    else
      log "App Store: up-to-date $name ($local_ver)"
    fi
    sleep 0.3  # be polite to the lookup API
  done <<< "$mas_apps"

  MAS_OUTDATED_COUNT="$outdated"
  APPSTORE_STALE_LOOKUP_COUNT="$stale_lookup"
  log "App Store: $checked checked, $outdated outdated, $notfound not found, $stale_lookup stale lookup."

  local auto_upd
  auto_upd="$(defaults read com.apple.commerce AutoUpdate 2>/dev/null || true)"
  if [[ "$auto_upd" != "1" ]]; then
    log "App Store: automatic updates appear to be OFF (App Store > Settings > Automatic Updates)."
  fi

  if [[ "$outdated" -gt 0 ]]; then
    if [[ "$OPEN_APPSTORE" -eq 1 ]]; then
      run_cmd "App Store: opening the Updates page" open "macappstore://showUpdatesPage" || true
    else
      log "App Store: to install updates, rerun with --open-appstore or run: open 'macappstore://showUpdatesPage'"
    fi
  fi

  # Cross-check with mas when present (informational only; do not install with it).
  if have_cmd mas; then
    run_cmd "mas: outdated (cross-check; may be unreliable on recent macOS)" mas outdated || true
  fi

  if [[ "$checked" -gt 0 && "$checked" -eq "$notfound" ]]; then
    STATUS_MAS="WARN"
  elif [[ "$stale_lookup" -gt 0 ]]; then
    STATUS_MAS="WARN"
  else
    STATUS_MAS="OK"
  fi
}

########################################
# 4) Self-updating apps (Sparkle/Squirrel; optional)
########################################
sparkle_feed_url() {
  # $1 = app path, $2 = bundle id. Feed may be in Info.plist or set at runtime in defaults.
  local feed
  feed="$(/usr/libexec/PlistBuddy -c "Print:SUFeedURL" "$1/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -z "${feed//[[:space:]]/}" && -n "$2" ]]; then
    feed="$(defaults read "$2" SUFeedURL 2>/dev/null || true)"
  fi
  printf "%s" "$(trim "$feed")"
}

appcast_latest_version() {
  # Fetch a Sparkle appcast and print the highest sparkle:shortVersionString
  # (fallback: sparkle:version). Entries are not guaranteed newest-first.
  local xml versions
  xml="$(curl -fsSL --max-time 15 "$1" 2>/dev/null || true)"
  [[ -z "$xml" ]] && return 0

  versions="$(printf "%s" "$xml" \
    | grep -oE 'sparkle:shortVersionString="[^"]+"|<sparkle:shortVersionString>[^<]+<' \
    | sed -e 's/sparkle:shortVersionString="//' -e 's/"$//' -e 's/<sparkle:shortVersionString>//' -e 's/<$//' \
    || true)"
  if [[ -z "${versions//[[:space:]]/}" ]]; then
    versions="$(printf "%s" "$xml" \
      | grep -oE 'sparkle:version="[^"]+"|<sparkle:version>[^<]+<' \
      | sed -e 's/sparkle:version="//' -e 's/"$//' -e 's/<sparkle:version>//' -e 's/<$//' \
      || true)"
  fi
  [[ -z "${versions//[[:space:]]/}" ]] && return 0

  # Prefer stable-looking versions: drop prerelease markers and entries with
  # whitespace, unless that would leave nothing.
  local stable
  stable="$(printf "%s\n" "$versions" \
    | grep -ivE 'beta|alpha|daily|nightly|preview|-rc' \
    | grep -vE '[[:space:]]' \
    || true)"
  [[ -n "${stable//[[:space:]]/}" ]] && versions="$stable"

  printf "%s\n" "$versions" | sort -V | tail -n 1
}

check_self_updaters() {
  if [[ "$RUN_SELF_UPDATERS" -ne 1 ]]; then
    STATUS_SELFUPDATE="SKIPPED"
    return 0
  fi

  hr
  log "Self-updaters: scanning /Applications and ~/Applications for Sparkle/Squirrel apps"

  local app name bid local_ver feed remote_ver kind
  local checked=0 outdated=0 unknown=0
  local outdated_apps=""

  while IFS= read -r app; do
    kind=""
    [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] && kind="sparkle"
    [[ -z "$kind" && -d "$app/Contents/Frameworks/Squirrel.framework" ]] && kind="squirrel"
    [[ -z "$kind" ]] && continue
    # MAS builds update through the App Store, not their bundled updater.
    [[ -d "$app/Contents/_MASReceipt" ]] && continue

    name="$(basename "$app")"
    name="${name%.app}"
    bid="$(get_bundle_id "$app")"
    local_ver="$(get_app_version "$app")"
    [[ -z "$local_ver" ]] && local_ver="?"

    if [[ "$kind" == "squirrel" ]]; then
      log "Self-updaters: UNKNOWN    $name ($local_ver) — Squirrel/Electron updater; open the app to update."
      unknown=$((unknown + 1))
      continue
    fi

    feed="$(sparkle_feed_url "$app" "$bid")"
    if [[ -z "$feed" ]]; then
      log "Self-updaters: UNKNOWN    $name ($local_ver) — no discoverable Sparkle feed; open the app to update."
      unknown=$((unknown + 1))
      continue
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "Self-updaters: DRY-RUN: would check '$name' against feed: $feed"
      continue
    fi

    remote_ver="$(appcast_latest_version "$feed")"
    checked=$((checked + 1))
    if [[ -z "$remote_ver" ]]; then
      log "Self-updaters: ?          $name ($local_ver) — could not read appcast: $feed"
      unknown=$((unknown + 1))
    elif ! ver_comparable "$remote_ver" "$local_ver"; then
      log "Self-updaters: ?          $name local=$local_ver feed=$remote_ver — version formats not comparable; open the app to check."
      unknown=$((unknown + 1))
    elif ver_gt "$remote_ver" "$local_ver"; then
      log "Self-updaters: OUTDATED   $name local=$local_ver latest=$remote_ver — open the app to update."
      outdated=$((outdated + 1))
      outdated_apps="${outdated_apps}${app}"$'\n'
    else
      log "Self-updaters: up-to-date $name ($local_ver)"
    fi
  done < <(find /Applications "${HOME}/Applications" -maxdepth 1 -type d -name "*.app" 2>/dev/null | sort)

  SELF_OUTDATED_COUNT="$outdated"
  SELF_UNKNOWN_COUNT="$unknown"
  log "Self-updaters: $checked checked, $outdated outdated, $unknown need the app opened to check/update."

  if [[ "$OPEN_SELF_UPDATERS" -eq 1 && "$DRY_RUN" -eq 0 && -n "${outdated_apps//[[:space:]]/}" ]]; then
    while IFS= read -r app; do
      [[ -z "$app" ]] && continue
      run_cmd "Self-updaters: opening $(basename "$app") so its updater can run" open "$app" || true
    done <<< "$outdated_apps"
  fi

  STATUS_SELFUPDATE="OK"
}

########################################
# 5) Inventory /Applications (optional)
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

    # Only top-level .app bundles (process substitution keeps counters in this shell)
    while IFS= read -r -d '' app; do
          local name
          name="$(basename "$app")"
          name="${name%.app}"

          local src="UNMANAGED"
          if [[ -d "$app/Contents/_MASReceipt" ]]; then
            src="MAS"
          elif [[ -n "$brew_appnames" ]] && printf "%s\n" "$brew_appnames" | grep -Fxq "$name"; then
            src="BREW-CASK"
          elif [[ -d "$app/Contents/Frameworks/Sparkle.framework" || -d "$app/Contents/Frameworks/Squirrel.framework" ]]; then
            src="SELF-UPDATER"
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
        done < <(find "$d" -maxdepth 1 -type d -name "*.app" -print0 2>/dev/null)
  done

  log "Inventory: $unmanaged_count unmanaged app(s) found."
  STATUS_INVENTORY="OK"
}

########################################
# Run all sections
########################################
if section_enabled brew; then update_brew; fi
if section_enabled npm; then update_npm_globals; fi
if section_enabled mas; then update_mas; fi
if section_enabled selfupdate; then check_self_updaters; fi
if section_enabled inventory; then inventory_apps; fi

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
log "  App Store:       $STATUS_MAS (outdated: $MAS_OUTDATED_COUNT, stale lookup: $APPSTORE_STALE_LOOKUP_COUNT)"
log "  self-updaters:   $STATUS_SELFUPDATE (outdated: $SELF_OUTDATED_COUNT, open-to-update: $SELF_UNKNOWN_COUNT)"
log "  cask drift:      detected=$CASK_DRIFT_DETECTED repaired=$CASK_DRIFT_REPAIRED failed=$CASK_DRIFT_FAILED"
log "  inventory:       $STATUS_INVENTORY"
hr
log "Full log: $LOG_FILE"
hr

if [[ "$JSON_OUTPUT" -eq 1 ]]; then
  printf '{"brew":"%s","brew_bundle":"%s","brew_doctor":"%s","npm":"%s","app_store":"%s","self_updaters":"%s","inventory":"%s","app_store_outdated":%d,"app_store_stale_lookup":%d,"self_updaters_outdated":%d,"self_updaters_open_to_update":%d,"cask_drift_detected":%d,"cask_drift_repaired":%d,"cask_drift_failed":%d,"log_file":"%s"}\n' \
    "$STATUS_BREW" "$STATUS_BREW_BUNDLE" "$STATUS_BREW_DOCTOR" "$STATUS_NPM" "$STATUS_MAS" "$STATUS_SELFUPDATE" "$STATUS_INVENTORY" \
    "$MAS_OUTDATED_COUNT" "$APPSTORE_STALE_LOOKUP_COUNT" "$SELF_OUTDATED_COUNT" "$SELF_UNKNOWN_COUNT" \
    "$CASK_DRIFT_DETECTED" "$CASK_DRIFT_REPAIRED" "$CASK_DRIFT_FAILED" "$LOG_FILE"
fi

if [[ "$NOTIFY" -eq 1 ]] && have_cmd osascript; then
  osascript -e "display notification \"brew: $STATUS_BREW, npm: $STATUS_NPM, App Store outdated: $MAS_OUTDATED_COUNT, cask drift: $CASK_DRIFT_DETECTED\" with title \"update-all finished\"" >/dev/null 2>&1 || true
fi

EXIT_CODE=0
for st in "$STATUS_BREW" "$STATUS_NPM" "$STATUS_MAS"; do
  if [[ "$st" == "FAILED" ]]; then
    EXIT_CODE=1
  fi
done

exit "$EXIT_CODE"
