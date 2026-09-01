#!/usr/bin/env bash
# Print the highest Sparkle build number in an appcast. Sparkle has emitted
# this metadata in both attribute and element form across tool versions:
#
#   sparkle:version="1"
#   <sparkle:version>1</sparkle:version>
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: scripts/appcast-build-number.sh <appcast.xml>" >&2
  exit 2
fi

BUILDS="$({
  sed -En 's/.*sparkle:version="([0-9]+)".*/\1/p' "$1"
  sed -En 's@.*<sparkle:version>([0-9]+)</sparkle:version>.*@\1@p' "$1"
} | sort -n -u)"

if [[ -z "$BUILDS" ]]; then
  echo "No numeric Sparkle build number found in $1" >&2
  exit 1
fi

printf '%s\n' "$BUILDS" | tail -1
