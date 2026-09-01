#!/usr/bin/env bash
# Generate the Sparkle appcast for the direct-download update channel.
#
#   scripts/generate-appcast.sh
#
# Reads notarized archives from dist/updates (see package-developer-id.sh) and
# writes dist/updates/appcast.xml, signing each entry with the Sparkle EdDSA
# private key stored in the login keychain by generate_keys. Enclosure URLs
# point at the release tag in the public releases repo;
# `scripts/publish-release.sh` uploads both the zip and this appcast there, and
# the app reads releases/latest/download/appcast.xml (AppLinks.swift), so the
# newest release is always the feed.
#
# Note: generate_appcast applies one URL prefix to every archive in the
# directory. With per-version download URLs (GitHub release tags), keep only
# the release being published in dist/updates — Sparkle only needs the newest
# entry to offer an update.
set -euo pipefail

cd "$(dirname "$0")/.."

UPDATES_DIR="${UPDATES_DIR:-dist/updates}"
RELEASES_REPO="${RELEASES_REPO:-felixrieseberg/nightdrive}"
release_metadata="$(scripts/release-version.sh)"
IFS=$'\t' read -r NIGHTDRIVE_TAG NIGHTDRIVE_VERSION NIGHTDRIVE_BUILD <<<"$release_metadata"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$RELEASES_REPO/releases/download/$NIGHTDRIVE_TAG/}"
RELEASE_NOTES_DIR="${RELEASE_NOTES_DIR:-ReleaseNotes}"
RELEASE_NOTES_PATH="${RELEASE_NOTES_PATH:-$RELEASE_NOTES_DIR/$NIGHTDRIVE_VERSION.md}"
STAGED_RELEASE_NOTES="$UPDATES_DIR/Nightdrive-$NIGHTDRIVE_VERSION.md"

# The Sparkle SwiftPM artifact ships the command-line tools alongside the
# framework, so the pinned tools version always matches the linked framework.
TOOLS_BIN=".build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST_BIN="${GENERATE_APPCAST_BIN:-$TOOLS_BIN/generate_appcast}"
if [[ ! -x "$GENERATE_APPCAST_BIN" ]]; then
  echo "Sparkle appcast generator not found at $GENERATE_APPCAST_BIN;" \
    "run 'node scripts/run-swiftpm.mjs package resolve' first." >&2
  exit 1
fi

if ! ls "$UPDATES_DIR"/*.zip >/dev/null 2>&1; then
  echo "No archives in $UPDATES_DIR; run 'make developerid' first." >&2
  exit 1
fi
if [[ ! -s "$RELEASE_NOTES_PATH" ]]; then
  echo "Missing or empty release notes: $RELEASE_NOTES_PATH" >&2
  echo "Write the user-facing notes for $NIGHTDRIVE_VERSION before generating its appcast." >&2
  exit 1
fi

cp "$RELEASE_NOTES_PATH" "$STAGED_RELEASE_NOTES"

"$GENERATE_APPCAST_BIN" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  --link "https://github.com/$RELEASES_REPO" \
  "$UPDATES_DIR"

if ! grep -q '<description' "$UPDATES_DIR/appcast.xml" \
  || ! grep -q 'sparkle:format="markdown"' "$UPDATES_DIR/appcast.xml"; then
  echo "$UPDATES_DIR/appcast.xml does not contain embedded Markdown release notes." >&2
  exit 1
fi

echo "Wrote $UPDATES_DIR/appcast.xml"
echo "Embedded release notes from $RELEASE_NOTES_PATH"
echo "Next: scripts/publish-release.sh uploads the zip and appcast to $RELEASES_REPO"
