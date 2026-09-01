#!/usr/bin/env bash
# Publish a packaged direct-download release to the public releases repo.
#
#   scripts/publish-release.sh
#
# Expects dist/updates to contain the notarized zip from `make developerid` and
# the appcast.xml from `make appcast`. Creates the authoritative release tag on
# the public repo with the versioned Sparkle zip, a stable Nightdrive.zip alias
# for the download link, and the appcast attached.
#
# The app reads
# https://github.com/felixrieseberg/nightdrive/releases/latest/download/appcast.xml,
# which GitHub redirects to this release's appcast asset — so publishing here is
# the whole update rollout.
set -euo pipefail

cd "$(dirname "$0")/.."

RELEASES_REPO="${RELEASES_REPO:-felixrieseberg/nightdrive}"
GH_BIN="${GH_BIN:-gh}"
release_metadata="$(scripts/release-version.sh)"
IFS=$'\t' read -r NIGHTDRIVE_TAG NIGHTDRIVE_VERSION NIGHTDRIVE_BUILD <<<"$release_metadata"
UPDATES_DIR="${UPDATES_DIR:-dist/updates}"
ZIP_PATH="$UPDATES_DIR/Nightdrive-$NIGHTDRIVE_VERSION.zip"
APPCAST_PATH="$UPDATES_DIR/appcast.xml"
RELEASE_NOTES_DIR="${RELEASE_NOTES_DIR:-ReleaseNotes}"
RELEASE_NOTES_PATH="${RELEASE_NOTES_PATH:-$RELEASE_NOTES_DIR/$NIGHTDRIVE_VERSION.md}"
TAG="$NIGHTDRIVE_TAG"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Missing $ZIP_PATH; run 'make developerid' first." >&2
  exit 1
fi
if [[ ! -f "$APPCAST_PATH" ]]; then
  echo "Missing $APPCAST_PATH; run 'make appcast' first." >&2
  exit 1
fi
if [[ ! -s "$RELEASE_NOTES_PATH" ]]; then
  echo "Missing or empty release notes: $RELEASE_NOTES_PATH" >&2
  exit 1
fi
# The appcast must reference the zip being published, or updaters would be
# pointed at a mismatched (or missing) enclosure.
if ! grep -q "Nightdrive-$NIGHTDRIVE_VERSION.zip" "$APPCAST_PATH"; then
  echo "$APPCAST_PATH does not reference Nightdrive-$NIGHTDRIVE_VERSION.zip;" \
    "regenerate it with 'make appcast'." >&2
  exit 1
fi
if ! grep -q '<description' "$APPCAST_PATH" \
  || ! grep -q 'sparkle:format="markdown"' "$APPCAST_PATH"; then
  echo "$APPCAST_PATH does not contain embedded Markdown release notes;" \
    "regenerate it with 'make appcast'." >&2
  exit 1
fi

# People downloading by hand want a stable filename while Sparkle keeps its
# immutable, versioned enclosure. Create the alias only for upload and let
# GitHub preserve its stable basename as a second release asset.
ALIAS_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/nightdrive-release-alias.XXXXXX")"
trap 'rm -rf "$ALIAS_STAGE"' EXIT
STABLE_ZIP_PATH="$ALIAS_STAGE/Nightdrive.zip"
cp "$ZIP_PATH" "$STABLE_ZIP_PATH"
if ! cmp -s "$ZIP_PATH" "$STABLE_ZIP_PATH"; then
  echo "Could not create the stable Nightdrive.zip release asset." >&2
  exit 1
fi

"$GH_BIN" release create "$TAG" \
  --repo "$RELEASES_REPO" \
  --title "v$NIGHTDRIVE_VERSION" \
  --notes-file "$RELEASE_NOTES_PATH" \
  --latest \
  "$ZIP_PATH" "$STABLE_ZIP_PATH" "$APPCAST_PATH"

echo "Published $TAG to https://github.com/$RELEASES_REPO/releases/tag/$TAG"
echo "Stable download: https://github.com/$RELEASES_REPO/releases/latest/download/Nightdrive.zip"
echo "Updaters pick it up via https://github.com/$RELEASES_REPO/releases/latest/download/appcast.xml"
