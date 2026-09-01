#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-dist/Nightdrive.app}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

invalid_entries="$(
  find "$APP_PATH" \
    \( \( -type f ! -perm -004 \) -o \( -type d ! -perm -005 \) \) \
    -print
)"

if [[ -n "$invalid_entries" ]]; then
  echo "App bundle contains entries that non-root users cannot read:" >&2
  printf '%s\n' "$invalid_entries" >&2
  exit 1
fi

invalid_executables="$(
  find "$APP_PATH/Contents/MacOS" -type f ! -perm -005 -print
)"

if [[ -n "$invalid_executables" ]]; then
  echo "App bundle contains executables that other users cannot run:" >&2
  printf '%s\n' "$invalid_executables" >&2
  exit 1
fi
