#!/usr/bin/env bash
# Compare two canonical major.minor.patch marketing versions without relying
# on platform-specific sort flags or fixed-width integer arithmetic.
#
# Prints 1 when the first version is newer, 0 when equal, and -1 when older.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: scripts/compare-marketing-versions.sh <candidate> <published>" >&2
  exit 2
fi

VERSION_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
for version in "$@"; do
  if [[ ! "$version" =~ $VERSION_PATTERN ]]; then
    echo "Marketing version '$version' must look like 1.2.3" >&2
    exit 1
  fi
done

IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$1"
IFS=. read -r published_major published_minor published_patch <<<"$2"
candidate_parts=("$candidate_major" "$candidate_minor" "$candidate_patch")
published_parts=("$published_major" "$published_minor" "$published_patch")

for index in 0 1 2; do
  candidate_part="${candidate_parts[$index]}"
  published_part="${published_parts[$index]}"
  if [[ ${#candidate_part} -gt ${#published_part} ]]; then
    printf '1\n'
    exit 0
  fi
  if [[ ${#candidate_part} -lt ${#published_part} ]]; then
    printf '%s\n' '-1'
    exit 0
  fi
  if [[ "$candidate_part" > "$published_part" ]]; then
    printf '1\n'
    exit 0
  fi
  if [[ "$candidate_part" < "$published_part" ]]; then
    printf '%s\n' '-1'
    exit 0
  fi
done

printf '0\n'
