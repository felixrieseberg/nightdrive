#!/usr/bin/env bash
# Create and verify a Sparkle archive without ever exposing a partial ZIP.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <app-path> <zip-path>" >&2
  exit 2
fi

APP_PATH="$1"
ZIP_PATH="$2"
DITTO_BIN="${DITTO_BIN:-ditto}"
UNZIP_BIN="${UNZIP_BIN:-unzip}"
PARTIAL_PATH="$ZIP_PATH.partial"
VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nightdrive-app-archive.XXXXXX")"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$ZIP_PATH")"
cleanup() {
  rm -f "$PARTIAL_PATH"
  rm -rf "$VERIFY_ROOT"
}
trap cleanup EXIT

# `ditto` occasionally returns a truncated archive while walking an app bundle.
# Preserve extended attributes: signatures for non-Mach-O code live there.
# Verify both the ZIP and the extracted app signature,
# and retry once before failing. Keep the destination untouched until a complete
# archive is ready.
for attempt in 1 2; do
  rm -f "$PARTIAL_PATH"
  rm -rf "$VERIFY_ROOT/extracted"
  mkdir -p "$VERIFY_ROOT/extracted"
  if "$DITTO_BIN" --noqtn --noacl \
      -c -k --keepParent "$APP_PATH" "$PARTIAL_PATH" \
      && "$UNZIP_BIN" -tq "$PARTIAL_PATH" >/dev/null \
      && "$DITTO_BIN" -x -k "$PARTIAL_PATH" "$VERIFY_ROOT/extracted" \
      && codesign --verify --deep --strict \
        "$VERIFY_ROOT/extracted/$(basename "$APP_PATH")"; then
    mv -f "$PARTIAL_PATH" "$ZIP_PATH"
    cleanup
    trap - EXIT
    exit 0
  fi

  if [[ "$attempt" == 1 ]]; then
    echo "Archive creation failed validation; retrying once..." >&2
  fi
done

echo "Could not create a complete app archive at $ZIP_PATH" >&2
exit 1
