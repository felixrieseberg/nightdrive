#!/usr/bin/env bash
# Print the single marketing version in a one-release Sparkle appcast.
# Sparkle has emitted this metadata in both attribute and element form:
#
#   sparkle:shortVersionString="1.2.3"
#   <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: scripts/appcast-marketing-version.sh <appcast.xml>" >&2
  exit 2
fi

VERSIONS="$({
  sed -En 's/.*sparkle:shortVersionString="([^"]+)".*/\1/p' "$1"
  sed -En 's@.*<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>.*@\1@p' "$1"
} | sort -u)"

if [[ -z "$VERSIONS" ]]; then
  echo "No Sparkle marketing version found in $1" >&2
  exit 1
fi

VERSION_COUNT="$(printf '%s\n' "$VERSIONS" | wc -l | tr -d ' ')"
if [[ "$VERSION_COUNT" != "1" ]]; then
  echo "Expected one Sparkle marketing version in $1, found: $(printf '%s' "$VERSIONS" | tr '\n' ' ')" >&2
  exit 1
fi

VERSION_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "$VERSIONS" =~ $VERSION_PATTERN ]]; then
  echo "Sparkle marketing version '$VERSIONS' must look like 1.2.3" >&2
  exit 1
fi

printf '%s\n' "$VERSIONS"
