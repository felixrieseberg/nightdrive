#!/usr/bin/env bash
# Ship a Nightdrive release: preflight, build and notarize the direct download,
# generate the Sparkle appcast, pause for a local test, then create the
# authoritative tag and publish the public GitHub release.
#
#   SPARKLE_PUBLIC_ED_KEY=… RELEASE_TAG=v1.0.0+2 scripts/release.sh --dry-run
#   SPARKLE_PUBLIC_ED_KEY=… RELEASE_TAG=v1.0.0+2 scripts/release.sh
#
# Flags:
#   --dry-run      run the preflight only; build nothing, publish nothing
#   --allow-dirty  tolerate a dirty tree or non-main branch (dry runs only)
#   --force        clear unexpected files out of dist/updates
#   --yes          skip the interactive test gate (unattended releases only)
#
# The proposed tag does not exist while artifacts are built and validated; it
# is created and pushed only after they pass and the candidate is accepted.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"

DRY_RUN=0
ALLOW_DIRTY=0
ASSUME_YES=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --yes) ASSUME_YES=1 ;;
    --force) FORCE=1 ;;
    -h | --help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# Shared release env defaults, step/ok/warn/fail, and validate_updates_dir.
. scripts/release-common.sh
RELEASE_NOTES_DIR="${RELEASE_NOTES_DIR:-ReleaseNotes}"
DEVELOPER_ID_APP_IDENTITY="${DEVELOPER_ID_APP_IDENTITY:-Developer ID Application: Felix Rieseberg (LT94ZKYDCJ)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-nightdrive-notary}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

[[ -n "${RELEASE_TAG:-}" ]] \
  || fail "RELEASE_TAG is required." "Propose one, for example: make ship RELEASE_TAG=v1.0.0+2"
release_metadata="$(scripts/release-version.sh --parse "$RELEASE_TAG")"
IFS=$'\t' read -r TAG VERSION BUILD <<<"$release_metadata"
RELEASE_COMMIT="$(git rev-parse HEAD)"
ZIP_NAME="Nightdrive-$VERSION.zip"
RELEASE_NOTES_PATH="$RELEASE_NOTES_DIR/$VERSION.md"

# --- Preflight ---------------------------------------------------------------
# Everything here is fast and read-only; all slow or mutating work comes after.

step "Preflight: release $TAG (version $VERSION, build $BUILD)"

# This directory is emptied with `find -delete`; validated again after mkdir.
validate_updates_dir

# Untracked files can reach the release where SwiftPM compiles and bundles them
# (Sources/, Resources/), where they are the build itself (the manifests,
# scripts/), and where they are published verbatim (ReleaseNotes/) — an
# uncommitted notes file would ship copy the tagged commit does not contain.
# The match is case-insensitive because the default macOS filesystem is.
BUNDLED_UNTRACKED_PATTERN='^(Sources|Resources|scripts|ReleaseNotes)/|^Package\.(swift|resolved)$'

# Working-tree changes that can affect the artifacts: every change to a tracked
# file, plus untracked files under bundled paths. Used by preflight and by the
# pre-tag guard so both apply the same policy, and a tree that passes preflight
# cannot surprise the release at publication time.
blocking_tree_changes() {
  git status --porcelain | grep -v '^??' || true
  git status --porcelain | sed -n 's/^?? //p' | grep -iE "$BUNDLED_UNTRACKED_PATTERN" || true
}

# Artifacts must come byte-for-byte from the commit that will receive the tag,
# so --allow-dirty is deliberately limited to dry-run diagnostics.
DIRTY_TRACKED="$(git status --porcelain | grep -v '^??' || true)"
UNTRACKED_BUNDLED="$(git status --porcelain | sed -n 's/^?? //p' \
  | grep -iE "$BUNDLED_UNTRACKED_PATTERN" || true)"
if [[ -n "$DIRTY_TRACKED" || -n "$UNTRACKED_BUNDLED" ]]; then
  if [[ "$ALLOW_DIRTY" == 1 && "$DRY_RUN" == 1 ]]; then
    warn "Working tree is dirty (allowed for this dry run only)."
  elif [[ "$ALLOW_DIRTY" == 1 ]]; then
    fail "--allow-dirty is only available with --dry-run." \
      "Commit or stash every change before building release artifacts."
  elif [[ -n "$DIRTY_TRACKED" ]]; then
    fail "Working tree has uncommitted changes to tracked files." \
      "Commit or stash them. For preflight diagnostics only: --dry-run --allow-dirty."
  else
    fail "Untracked files under bundled paths: $(echo "$UNTRACKED_BUNDLED" | tr '\n' ' ')" \
      "These would ship inside the release artifacts. Remove or move them out of the repository."
  fi
else
  ok "Working tree clean"
fi

BRANCH="$(git branch --show-current)"
REMOTE_MAIN_COMMIT="$(git ls-remote origin refs/heads/main | awk 'NR == 1 {print $1}')"
[[ -n "$REMOTE_MAIN_COMMIT" ]] \
  || fail "Could not resolve origin/main." "Check the origin remote and network access."
if [[ "$BRANCH" == "main" && "$RELEASE_COMMIT" == "$REMOTE_MAIN_COMMIT" ]]; then
  ok "On main, in sync with origin/main"
elif [[ "$DRY_RUN" == 1 ]]; then
  warn "HEAD is not the current origin/main commit (allowed for this dry run only)."
else
  fail "A real release must run from main, exactly at origin/main (on '$BRANCH')." \
    "Merge and pull the release commit, then run make ship there."
fi

if ! gh auth status >/dev/null 2>&1; then
  fail "gh is not authenticated." "Run: gh auth login"
fi
for repo in "$DEV_REPO" "$RELEASES_REPO"; do
  gh repo view "$repo" --json name >/dev/null 2>&1 \
    || fail "gh cannot access $repo." "Check the repo name and your token scopes (gh auth status)."
done
ok "gh authenticated with access to $DEV_REPO and $RELEASES_REPO"

# The proposed tag must be entirely new; it becomes authoritative only after
# the artifacts validate.
if git show-ref --verify --quiet "refs/tags/$TAG"; then
  fail "Tag $TAG already exists locally." "Choose a new release tag; make ship creates tags itself."
fi
if [[ "$(git ls-remote --tags origin "refs/tags/$TAG" | grep -c . || true)" != "0" ]]; then
  fail "Tag $TAG already exists on origin ($DEV_REPO)." "Pick a new version."
fi
if gh release view "$TAG" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  fail "Release $TAG already exists on $RELEASES_REPO." "Pick a new version."
fi
ok "Release tag $TAG is unused locally and remotely"

[[ -s "$RELEASE_NOTES_PATH" ]] \
  || fail "Missing or empty release notes: $RELEASE_NOTES_PATH" \
    "Write the user-facing notes for $VERSION; they become the appcast description and the GitHub release body."
ok "Release notes present: $RELEASE_NOTES_PATH"

# Signing identity, notary credentials, and the Sparkle key pair.
# `grep -c` rather than `grep -q`: a short-circuiting reader can SIGPIPE the
# producer and, under pipefail, turn a match into a spurious failure.
if [[ "$(security find-identity -v -p basic 2>/dev/null \
  | grep -cF "$DEVELOPER_ID_APP_IDENTITY" || true)" == "0" ]]; then
  fail "Signing identity not found in the keychain: $DEVELOPER_ID_APP_IDENTITY" \
    "Install the Developer ID Application certificate, or set DEVELOPER_ID_APP_IDENTITY."
fi
ok "Signing identity available"
[[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] \
  || fail "SPARKLE_PUBLIC_ED_KEY is not set." \
    "Pass the public key from generate_keys, e.g. SPARKLE_PUBLIC_ED_KEY=… make ship …"
# The key stamped into the app must be the counterpart of the private key
# generate_appcast will sign with, or shipped apps reject every update.
[[ -x "$SPARKLE_BIN/generate_keys" ]] \
  || fail "Sparkle tools are missing at $SPARKLE_BIN." \
    "Run: node scripts/run-swiftpm.mjs package resolve"
if ! KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)"; then
  fail "No Sparkle EdDSA key pair in the login keychain." \
    "Generate one once with: $SPARKLE_BIN/generate_keys"
fi
[[ "$KEYCHAIN_PUBLIC_KEY" == "$SPARKLE_PUBLIC_ED_KEY" ]] \
  || fail "SPARKLE_PUBLIC_ED_KEY does not match the keychain key ($KEYCHAIN_PUBLIC_KEY)." \
    "Shipped apps could not verify updates. Pass the key printed by generate_keys -p."
ok "Sparkle key in the keychain matches SPARKLE_PUBLIC_ED_KEY"
# `notarytool history` fails fast when the profile is missing or stale.
if ! NOTARY_OUT="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1 >/dev/null)"; then
  fail "Notary profile '$NOTARY_PROFILE' is unusable: $NOTARY_OUT" \
    "Create it once with: xcrun notarytool store-credentials $NOTARY_PROFILE"
fi
ok "Notary credentials '$NOTARY_PROFILE' usable"

# The published feed decides what is newer. Both the marketing version and the
# build number must strictly increase: Sparkle compares CFBundleVersion, and
# requiring a new marketing version keeps an unused build from publishing the
# same user-facing version twice.
PUBLISHED_APPCAST="$(mktemp "${TMPDIR:-/tmp}/nightdrive-appcast.XXXXXX")"
trap 'rm -f "$PUBLISHED_APPCAST"' EXIT
PUBLISHED_STATUS="$(
  curl -sSL --retry 2 --retry-delay 1 --max-time 30 \
    -o "$PUBLISHED_APPCAST" -w '%{http_code}' "$APPCAST_URL"
)" || fail "Could not fetch the published appcast from $APPCAST_URL." "Check the network, then retry."
if [[ "$PUBLISHED_STATUS" == "200" ]]; then
  PUBLISHED_BUILD="$(scripts/appcast-build-number.sh "$PUBLISHED_APPCAST")"
  PUBLISHED_VERSION="$(scripts/appcast-marketing-version.sh "$PUBLISHED_APPCAST")"
  [[ "$BUILD" -gt "$PUBLISHED_BUILD" ]] \
    || fail "Build $BUILD is not greater than the published build $PUBLISHED_BUILD." \
      "Sparkle compares build numbers; pick a higher one."
  [[ "$(scripts/compare-marketing-versions.sh "$VERSION" "$PUBLISHED_VERSION")" == "1" ]] \
    || fail "Version $VERSION is not newer than the published version $PUBLISHED_VERSION." \
      "Pick a higher marketing version."
  ok "Newer than the published $PUBLISHED_VERSION (build $PUBLISHED_BUILD)"
elif [[ "$PUBLISHED_STATUS" == "404" ]]; then
  if gh release list --repo "$RELEASES_REPO" --limit 1 | grep -q .; then
    fail "$RELEASES_REPO has releases but no readable appcast at $APPCAST_URL." \
      "Inspect the latest release's assets before publishing over it."
  fi
  ok "No public release yet; this is the first one"
else
  fail "Unexpected HTTP $PUBLISHED_STATUS fetching $APPCAST_URL." "Retry once GitHub responds normally."
fi

# generate_appcast reads every archive in the directory and applies this tag's
# download prefix to all of them, so the directory must hold only this release
# by the time it runs. The previous release's own artifacts are expected to
# still be here — every successful ship leaves them — and are cleaned up
# silently below. Anything else is unexplained, and removing it needs --force.
if [[ -d "$UPDATES_DIR" ]]; then
  UNEXPECTED="$(find "$UPDATES_DIR" -mindepth 1 \
    ! \( -type f \( -name 'Nightdrive-*.zip' -o -name 'Nightdrive-*.md' -o -name 'appcast.xml' \) \) \
    -print)"
  if [[ -n "$UNEXPECTED" && "$FORCE" != 1 ]]; then
    fail "$UPDATES_DIR holds unexpected files: $(echo "$UNEXPECTED" | tr '\n' ' ')" \
      "Inspect them, then rerun with --force to remove them."
  fi
fi

if [[ "$DRY_RUN" == 1 ]]; then
  step "Dry run complete — nothing was built, tagged, or published"
  echo "  Rerun without --dry-run to release $TAG."
  exit 0
fi

# --- 1. Build, sign, notarize, and describe the release ----------------------

step "Cleaning $UPDATES_DIR"
mkdir -p "$UPDATES_DIR"
validate_updates_dir
find "$UPDATES_DIR" -mindepth 1 -delete

step "Building, signing, and notarizing $ZIP_NAME"
NIGHTDRIVE_RELEASE_CANDIDATE=1 NIGHTDRIVE_TAG="$TAG" \
APP_SIGN_IDENTITY="$DEVELOPER_ID_APP_IDENTITY" \
NOTARY_PROFILE="$NOTARY_PROFILE" \
SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
UPDATES_DIR="$UPDATES_DIR" \
  scripts/package-developer-id.sh

step "Generating the Sparkle appcast"
NIGHTDRIVE_RELEASE_CANDIDATE=1 NIGHTDRIVE_TAG="$TAG" \
UPDATES_DIR="$UPDATES_DIR" RELEASES_REPO="$RELEASES_REPO" \
RELEASE_NOTES_PATH="$RELEASE_NOTES_PATH" \
  scripts/generate-appcast.sh

# publish-release.sh re-checks the enclosure, but verify the build number
# before pushing the tag: after that the release identity is public-facing.
APPCAST_BUILD="$(scripts/appcast-build-number.sh "$UPDATES_DIR/appcast.xml" 2>/dev/null || true)"
[[ "$APPCAST_BUILD" == "$BUILD" ]] \
  || fail "The generated appcast carries build '$APPCAST_BUILD', not $BUILD." \
    "Inspect $UPDATES_DIR/appcast.xml before publishing."

# --- 2. Local test and confirmation gate ------------------------------------
# Everything exists locally and nothing is public yet. Keep the process alive
# while the exact notarized candidate is tested, then require the full tag
# before crossing the publication boundary.

step "Release candidate ready for local testing"
echo "  Runnable app: $REPO_ROOT/dist/Nightdrive.app"
echo "  Open it with: open \"$REPO_ROOT/dist/Nightdrive.app\""
echo "  Zip:          $UPDATES_DIR/$ZIP_NAME"
echo "  No tag, GitHub release, or Sparkle rollout exists yet."

if [[ "$ASSUME_YES" == 1 ]]; then
  warn "--yes supplied — skipping the local test-and-confirm gate."
else
  # A controlling terminal, not merely the /dev/tty device node (which always
  # exists): without one the confirmation read below cannot be answered.
  ( exec 3</dev/tty ) 2>/dev/null \
    || fail "Cannot confirm a release from non-interactive input." \
      "Run make ship from a terminal, or pass SHIP_FLAGS=--yes intentionally."
  while true; do
    printf '\nTest the candidate, then type %s to publish (Ctrl-C aborts): ' "$TAG"
    # Read from the terminal directly: notarization subprocesses can leave
    # stdin non-blocking, which makes a plain read fail with EAGAIN.
    IFS= read -r CONFIRMATION </dev/tty
    [[ "$CONFIRMATION" == "$TAG" ]] && break
    warn "Confirmation did not match $TAG. Nothing was published; try again."
  done
  ok "Confirmed $TAG for publication"
fi

# --- 3. Create and push the authoritative tag -------------------------------
# Re-check the refs so a concurrent change cannot attach validated artifacts to
# a different release identity.

step "Creating and pushing $TAG to $DEV_REPO"
[[ "$(git rev-parse HEAD)" == "$RELEASE_COMMIT" ]] \
  || fail "HEAD changed while the release was being built." \
    "No tag was created. Inspect the new commit and run the release again."
BLOCKING_TREE_CHANGES="$(blocking_tree_changes)"
[[ -z "$BLOCKING_TREE_CHANGES" ]] \
  || fail "The working tree changed while the release was being built: $(echo "$BLOCKING_TREE_CHANGES" | tr '\n' ' ')" \
    "No tag was created. Inspect the changes, commit anything generated, and retry."
[[ "$(git ls-remote origin refs/heads/main | awk 'NR == 1 {print $1}')" == "$RELEASE_COMMIT" ]] \
  || fail "origin/main changed while the release was being built." \
    "No tag was created. Update main, rebuild, and retry."
if git show-ref --verify --quiet "refs/tags/$TAG"; then
  fail "Tag $TAG appeared locally during the build." "Inspect it before retrying."
fi

git -c tag.gpgSign=false tag -a "$TAG" -m "Release $VERSION (build $BUILD)" "$RELEASE_COMMIT"
if ! git push origin "refs/tags/$TAG:refs/tags/$TAG"; then
  if [[ "$(git ls-remote --tags origin "refs/tags/$TAG" | grep -c . || true)" == "0" ]]; then
    git tag -d "$TAG" >/dev/null
    fail "Could not push tag $TAG to $DEV_REPO." \
      "The unpushed local tag was removed; fix GitHub access and retry."
  fi
  fail "The tag push reported an error, but $TAG now exists on origin." \
    "Inspect GitHub before retrying."
fi
ok "Created and pushed annotated tag $TAG"

# --- 4. Publish the public release (this is the Sparkle rollout) -------------

step "Publishing $TAG on $RELEASES_REPO"
NIGHTDRIVE_RELEASE_CANDIDATE=1 NIGHTDRIVE_TAG="$TAG" \
RELEASES_REPO="$RELEASES_REPO" UPDATES_DIR="$UPDATES_DIR" \
RELEASE_NOTES_PATH="$RELEASE_NOTES_PATH" \
  scripts/publish-release.sh

# --- 5. Verify what users' updaters will actually read -----------------------

step "Verifying the published appcast"
VERIFIED=0
for attempt in 1 2 3 4 5; do
  # releases/latest can lag a few seconds behind `gh release create`.
  if curl -fsSL --max-time 30 -o "$PUBLISHED_APPCAST" "$APPCAST_URL" 2>/dev/null; then
    if grep -q "$ZIP_NAME" "$PUBLISHED_APPCAST" \
      && [[ "$(scripts/appcast-build-number.sh "$PUBLISHED_APPCAST" 2>/dev/null || true)" == "$BUILD" ]]; then
      VERIFIED=1
      break
    fi
  fi
  sleep $((attempt * 5))
done
[[ "$VERIFIED" == 1 ]] \
  || fail "The appcast at $APPCAST_URL does not reference $ZIP_NAME (build $BUILD) yet." \
    "Check https://github.com/$RELEASES_REPO/releases — is $TAG the latest release?"
ok "Published appcast references $ZIP_NAME with build $BUILD"

step "Released $VERSION (build $BUILD)"
echo "  Tag:      $TAG → https://github.com/$DEV_REPO/tree/$TAG"
echo "  Release:  https://github.com/$RELEASES_REPO/releases/tag/$TAG"
echo "  Download: https://github.com/$RELEASES_REPO/releases/latest/download/Nightdrive.zip"
echo "  Appcast:  $APPCAST_URL"
echo
echo "  Remaining human step:"
echo "    - Launch a previous build and confirm Sparkle offers $VERSION."
