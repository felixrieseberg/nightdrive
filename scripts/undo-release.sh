#!/usr/bin/env bash
# Undo a published release: the reverse of scripts/release.sh, step by step.
# Deletes the public GitHub release (which rolls the Sparkle feed back to the
# previous release's appcast), deletes the tag from the dev repo and locally,
# and removes the local artifacts.
#
#   scripts/undo-release.sh <release-tag> [flags]
#   RELEASE_TAG=v1.0.0+2 scripts/undo-release.sh [flags]
#
# Flags:
#   --dry-run  Inspect everything and print the plan, undo nothing.
#   --yes      Skip the interactive confirmation.
#
# What undo cannot do:
#   - downgrade users who already updated (Sparkle never offers a lower build;
#     they stay on the pulled version until the next release ships a higher
#     build number);
#   - revoke a notarization ticket (harmless — Gatekeeper still trusts copies
#     already downloaded; revocation is for actual malware and blocks *every*
#     copy).
#
# Safe to run repeatedly; every step is skipped when there is nothing to do.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd -P)"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/undo-release.sh <release-tag> [--dry-run] [--yes]

  <release-tag>  The tag to undo, e.g. v1.0.0+2
                 (also accepted as RELEASE_TAG in the environment).
EOF
  exit 2
}

DRY_RUN=0
ASSUME_YES=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) usage ;;
    -*)
      echo "Unknown flag: $arg" >&2
      usage
      ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

RELEASE_TAG="${POSITIONAL[0]:-${RELEASE_TAG:-}}"
if [[ ${#POSITIONAL[@]} -gt 1 ]]; then
  echo "Unexpected argument: ${POSITIONAL[1]}" >&2
  usage
fi
if [[ -z "$RELEASE_TAG" ]]; then
  echo "Missing release tag." >&2
  usage
fi
release_metadata="$(scripts/release-version.sh --parse "$RELEASE_TAG")"
IFS=$'\t' read -r TAG VERSION BUILD <<<"$release_metadata"

# Shared release env defaults, step/ok/warn/fail, and validate_updates_dir.
. scripts/release-common.sh
ZIP_NAME="Nightdrive-$VERSION.zip"

# Artifacts are deleted by path; validated again immediately before deleting.
validate_updates_dir

step "Inspecting $TAG (version $VERSION, build $BUILD)"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated." "Run: gh auth login"
gh repo view "$RELEASES_REPO" --json name >/dev/null 2>&1 \
  || fail "gh cannot access $RELEASES_REPO." \
    "Check the repo name and your token scopes; undo must not mistake an" \
    "unreachable repository for one that has no release."

# Absence and failure look alike to `gh release view`, and the difference
# decides whether the public release stays live while everything else is torn
# down. Only a genuine not-found may be read as absence.
PUBLIC_RELEASE_EXISTS=0
if release_lookup="$(gh release view "$TAG" --repo "$RELEASES_REPO" --json tagName 2>&1)"; then
  PUBLIC_RELEASE_EXISTS=1
  ok "Public release $TAG exists on $RELEASES_REPO"
elif [[ "$release_lookup" == *"release not found"* ]]; then
  warn "No public release $TAG on $RELEASES_REPO"
else
  fail "Could not determine whether $TAG exists on $RELEASES_REPO: $release_lookup" \
    "Nothing was deleted. Resolve the GitHub error and rerun."
fi

DEV_TAG_EXISTS=0
if [[ "$(git ls-remote --tags origin "refs/tags/$TAG" | grep -c . || true)" != "0" ]]; then
  DEV_TAG_EXISTS=1
  ok "Tag $TAG exists on origin ($DEV_REPO)"
else
  warn "No tag $TAG on origin"
fi

LOCAL_TAG_EXISTS=0
if git show-ref --verify --quiet "refs/tags/$TAG"; then
  LOCAL_TAG_EXISTS=1
  ok "Tag $TAG exists locally"
else
  warn "No local tag $TAG"
fi

LOCAL_ARTIFACTS=()
[[ -f "$UPDATES_DIR/$ZIP_NAME" ]] && LOCAL_ARTIFACTS+=("$UPDATES_DIR/$ZIP_NAME")
[[ -f "$UPDATES_DIR/appcast.xml" ]] && LOCAL_ARTIFACTS+=("$UPDATES_DIR/appcast.xml")
[[ -f "$UPDATES_DIR/Nightdrive-$VERSION.md" ]] && LOCAL_ARTIFACTS+=("$UPDATES_DIR/Nightdrive-$VERSION.md")
if [[ ${#LOCAL_ARTIFACTS[@]} -gt 0 ]]; then
  ok "Local artifacts: ${LOCAL_ARTIFACTS[*]}"
else
  warn "No local artifacts for $VERSION"
fi

if [[ "$PUBLIC_RELEASE_EXISTS" == 0 && "$DEV_TAG_EXISTS" == 0 && "$LOCAL_TAG_EXISTS" == 0 \
  && ${#LOCAL_ARTIFACTS[@]} -eq 0 ]]; then
  step "Nothing to undo for $TAG"
  exit 0
fi

if [[ "$DRY_RUN" == 1 ]]; then
  step "Dry run complete — nothing was deleted"
  exit 0
fi

if [[ "$ASSUME_YES" != 1 ]]; then
  # A controlling terminal, not merely the /dev/tty device node.
  ( exec 3</dev/tty ) 2>/dev/null \
    || fail "Cannot confirm from non-interactive input." "Pass --yes intentionally."
  printf '\nType %s to pull this release (Ctrl-C aborts): ' "$TAG"
  IFS= read -r CONFIRMATION </dev/tty
  [[ "$CONFIRMATION" == "$TAG" ]] || fail "Confirmation did not match $TAG." "Nothing was deleted."
fi

# Delete the public release first: it is what users' updaters read. Removing
# it points releases/latest — and with it the Sparkle feed — at the previous
# release. `--cleanup-tag` removes the tag the release created in that repo.
if [[ "$PUBLIC_RELEASE_EXISTS" == 1 ]]; then
  step "Deleting the public release $TAG from $RELEASES_REPO"
  gh release delete "$TAG" --repo "$RELEASES_REPO" --cleanup-tag --yes
  ok "Deleted"

  step "Verifying the appcast rolled back"
  ROLLED_BACK=0
  for attempt in 1 2 3 4 5; do
    STATUS="$(curl -sSL --max-time 30 -o /dev/null -w '%{http_code}' "$APPCAST_URL" || true)"
    if [[ "$STATUS" == "404" ]]; then
      ROLLED_BACK=1
      ok "No published appcast remains (this was the only release)"
      break
    fi
    PREVIOUS="$(mktemp "${TMPDIR:-/tmp}/nightdrive-appcast.XXXXXX")"
    if curl -fsSL --max-time 30 -o "$PREVIOUS" "$APPCAST_URL" 2>/dev/null \
      && ! grep -q "$ZIP_NAME" "$PREVIOUS"; then
      ok "Live appcast now offers build $(scripts/appcast-build-number.sh "$PREVIOUS" || echo unknown)"
      rm -f "$PREVIOUS"
      ROLLED_BACK=1
      break
    fi
    rm -f "$PREVIOUS"
    sleep $((attempt * 5))
  done
  [[ "$ROLLED_BACK" == 1 ]] \
    || fail "$APPCAST_URL still offers $ZIP_NAME." \
      "Check https://github.com/$RELEASES_REPO/releases — which release is marked latest?"
fi

if [[ "$DEV_TAG_EXISTS" == 1 ]]; then
  step "Deleting tag $TAG from origin ($DEV_REPO)"
  git push origin ":refs/tags/$TAG"
  ok "Deleted"
fi

if [[ "$LOCAL_TAG_EXISTS" == 1 ]]; then
  step "Deleting the local tag $TAG"
  git tag -d "$TAG" >/dev/null
  ok "Deleted"
fi

if [[ ${#LOCAL_ARTIFACTS[@]} -gt 0 ]]; then
  step "Removing local artifacts"
  validate_updates_dir
  rm -f "${LOCAL_ARTIFACTS[@]}"
  ok "Removed ${#LOCAL_ARTIFACTS[@]} file(s)"
fi

step "Pulled $VERSION (build $BUILD)"
echo "  Users who already updated stay on $VERSION; ship a higher build to move them off it."
echo "  Fix the problem, then release again with a new tag."
