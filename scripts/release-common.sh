# shellcheck shell=bash
# Shared helpers and env defaults for release.sh and undo-release.sh. Sourced,
# not executed: sets no shell options and installs no traps, so each caller
# keeps its own `set -euo pipefail`. Callers set REPO_ROOT and cd there first.

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mok\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mwarning\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31mfailed\033[0m %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '          %s\n' "$line" >&2; done
  exit 1
}

# The dev repo is only named for access checks and messages, so read it from
# the origin remote rather than hardcoding a name that a rename would stale.
default_dev_repo() {
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  case "$url" in
    *github.com[:/]*) printf '%s\n' "${url#*github.com}" | sed 's#^[:/]##; s#\.git$##' ;;
    *) printf '%s\n' "felixrieseberg/nightdrive" ;;
  esac
}
DEV_REPO="${DEV_REPO:-$(default_dev_repo)}"
RELEASES_REPO="${RELEASES_REPO:-felixrieseberg/nightdrive}"
UPDATES_DIR="${UPDATES_DIR:-dist/updates}"
APPCAST_URL="https://github.com/$RELEASES_REPO/releases/latest/download/appcast.xml"

# The updates directory is emptied and deleted by path, so validate the path
# it really resolves to, not just how it is spelled. Call again immediately
# before anything is removed, because a symlink can appear in between.
validate_updates_dir() {
  local existing="$UPDATES_DIR" resolved
  case "$UPDATES_DIR" in
    *..*) fail "Updates directory may not contain '..': $UPDATES_DIR" ;;
    dist/?* | "$REPO_ROOT"/dist/?*) ;;
    *) fail "Unsafe updates directory: $UPDATES_DIR" "It must live beneath $REPO_ROOT/dist/." ;;
  esac
  if [[ -e "$UPDATES_DIR" ]]; then
    # Resolve what the path actually points at: a symlink here would send
    # `find -delete` somewhere else entirely.
    resolved="$(cd "$UPDATES_DIR" 2>/dev/null && pwd -P)" \
      || fail "Updates directory is not a usable directory: $UPDATES_DIR"
    case "$resolved" in
      "$REPO_ROOT"/dist/?*) ;;
      *)
        fail "Unsafe resolved updates directory: $resolved" \
          "UPDATES_DIR must resolve beneath $REPO_ROOT/dist/."
        ;;
    esac
    return
  fi
  # Not created yet: resolve the nearest existing ancestor instead, so a
  # symlinked dist/ cannot let it be created outside the repository.
  while [[ ! -e "$existing" ]]; do
    existing="$(dirname "$existing")"
  done
  resolved="$(cd "$existing" && pwd -P)"
  case "$resolved" in
    "$REPO_ROOT" | "$REPO_ROOT"/dist | "$REPO_ROOT"/dist/?*) ;;
    *)
      fail "Unsafe resolved updates directory ancestor: $resolved" \
        "UPDATES_DIR must resolve beneath $REPO_ROOT/dist/."
      ;;
  esac
}
