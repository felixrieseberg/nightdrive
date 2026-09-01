#!/usr/bin/env bash
# Resolve the release identity for HEAD.
#
# Release tags are annotated Git tags named v<marketing-version>+<build>, for
# example v1.0.0+3. Published releases derive both bundle versions from that
# immutable tag. The release orchestrator may opt into candidate mode so it can
# build and validate those exact values before creating the tag; lower-level
# commands still require the annotated tag by default.
set -euo pipefail

REPO_ROOT="${NIGHTDRIVE_RELEASE_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}"
cd "$REPO_ROOT"

fail() {
  echo "release-version: $*" >&2
  exit 1
}

TAG_PATTERN='^v([0-9]+\.[0-9]+\.[0-9]+)\+([1-9][0-9]*)$'

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/release-version.sh [--parse TAG]

Print the release tag, its marketing version, and its build number as one
tab-separated line. Release tags must look like v1.0.0+3.

With --parse, validate and print an explicit tag without requiring it at HEAD.
Recovery commands use this mode because they operate on historical or failed
release tags rather than the current commit.

Set NIGHTDRIVE_TAG to select an exact tag when diagnosing an ambiguous commit.
NIGHTDRIVE_VERSION and NIGHTDRIVE_BUILD are accepted only as consistency
checks.

Release orchestration may set NIGHTDRIVE_RELEASE_CANDIDATE=1 together with
NIGHTDRIVE_TAG to resolve a proposed tag that does not exist yet, so the tag
can be created only after the artifacts have passed validation.
EOF
  exit 0
fi

if [[ "${1:-}" == "--parse" ]]; then
  [[ $# -eq 2 ]] || fail "--parse requires exactly one tag"
  parsed_tag="$2"
  if [[ ! "$parsed_tag" =~ $TAG_PATTERN ]]; then
    fail "tag '$parsed_tag' must look like v1.0.0+3"
  fi
  printf '%s\t%s\t%s\n' "$parsed_tag" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  exit 0
fi
[[ $# -eq 0 ]] || fail "unexpected argument: $1"

requested_tag="${NIGHTDRIVE_TAG:-}"
requested_version="${NIGHTDRIVE_VERSION:-}"
requested_build="${NIGHTDRIVE_BUILD:-}"
candidate_mode="${NIGHTDRIVE_RELEASE_CANDIDATE:-0}"
[[ "$candidate_mode" == 0 || "$candidate_mode" == 1 ]] \
  || fail "NIGHTDRIVE_RELEASE_CANDIDATE must be 0 or 1"

if [[ -n "$requested_tag" ]]; then
  tags=("$requested_tag")
else
  tags=()
  while IFS= read -r candidate; do
    if [[ "$candidate" =~ $TAG_PATTERN ]]; then
      tags+=("$candidate")
    fi
  done < <(git tag --points-at HEAD)
fi

if [[ ${#tags[@]} -eq 0 ]]; then
  fail "HEAD has no release tag; create one with: git tag -a v1.0.0+3 -m 'Release 1.0.0 (build 3)'"
fi
if [[ ${#tags[@]} -gt 1 ]]; then
  fail "HEAD has multiple release tags (${tags[*]}); set NIGHTDRIVE_TAG to select one"
fi

NIGHTDRIVE_TAG="${tags[0]}"
if [[ ! "$NIGHTDRIVE_TAG" =~ $TAG_PATTERN ]]; then
  fail "tag '$NIGHTDRIVE_TAG' must look like v1.0.0+3"
fi
NIGHTDRIVE_VERSION="${BASH_REMATCH[1]}"
NIGHTDRIVE_BUILD="${BASH_REMATCH[2]}"

tag_type="$(git cat-file -t "refs/tags/$NIGHTDRIVE_TAG" 2>/dev/null || true)"
if [[ -z "$tag_type" && "$candidate_mode" == 1 && -n "$requested_tag" ]]; then
  : # The release orchestrator creates this tag after artifact validation.
else
  [[ "$tag_type" == "tag" ]] \
    || fail "tag '$NIGHTDRIVE_TAG' must be annotated (create it with git tag -a)"
  tag_commit="$(git rev-parse "refs/tags/$NIGHTDRIVE_TAG^{}")"
  head_commit="$(git rev-parse HEAD)"
  [[ "$tag_commit" == "$head_commit" ]] \
    || fail "tag '$NIGHTDRIVE_TAG' does not point at HEAD"
fi

if [[ -n "$requested_version" && "$requested_version" != "$NIGHTDRIVE_VERSION" ]]; then
  fail "NIGHTDRIVE_VERSION=$requested_version conflicts with $NIGHTDRIVE_TAG (version $NIGHTDRIVE_VERSION)"
fi
if [[ -n "$requested_build" && "$requested_build" != "$NIGHTDRIVE_BUILD" ]]; then
  fail "NIGHTDRIVE_BUILD=$requested_build conflicts with $NIGHTDRIVE_TAG (build $NIGHTDRIVE_BUILD)"
fi

printf '%s\t%s\t%s\n' "$NIGHTDRIVE_TAG" "$NIGHTDRIVE_VERSION" "$NIGHTDRIVE_BUILD"
