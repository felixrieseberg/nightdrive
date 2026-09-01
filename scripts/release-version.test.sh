#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
PARSER="$PWD/scripts/release-version.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nightdrive-release-version.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT
FIXTURE_REPO="$FIXTURE_ROOT/repo"

git init -q "$FIXTURE_REPO"
git -C "$FIXTURE_REPO" config user.name "Release Version Test"
git -C "$FIXTURE_REPO" config user.email "release-version@example.invalid"
git -C "$FIXTURE_REPO" config commit.gpgSign false
git -C "$FIXTURE_REPO" config tag.gpgSign false
git -C "$FIXTURE_REPO" commit -q --allow-empty -m "Initial"

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "Expected failure containing '$expected', got: $output" >&2
    exit 1
  fi
}

run_parser() {
  NIGHTDRIVE_RELEASE_REPO_ROOT="$FIXTURE_REPO" "$PARSER"
}

[[ "$("$PARSER" --parse v1.2.3+4)" == $'v1.2.3+4\t1.2.3\t4' ]]
expect_failure "must look like" "$PARSER" --parse v1.2.3
expect_failure "requires exactly one tag" "$PARSER" --parse

expect_failure "HEAD has no release tag" run_parser
[[ "$(env NIGHTDRIVE_RELEASE_REPO_ROOT="$FIXTURE_REPO" NIGHTDRIVE_RELEASE_CANDIDATE=1 \
  NIGHTDRIVE_TAG=v1.2.3+4 "$PARSER")" == $'v1.2.3+4\t1.2.3\t4' ]]
expect_failure "must be annotated" env NIGHTDRIVE_RELEASE_REPO_ROOT="$FIXTURE_REPO" \
  NIGHTDRIVE_TAG=v1.2.3+4 "$PARSER"
expect_failure "must look like" env NIGHTDRIVE_RELEASE_REPO_ROOT="$FIXTURE_REPO" \
  NIGHTDRIVE_RELEASE_CANDIDATE=1 NIGHTDRIVE_TAG=1.2.3 "$PARSER"
expect_failure "conflicts" env NIGHTDRIVE_RELEASE_REPO_ROOT="$FIXTURE_REPO" \
  NIGHTDRIVE_RELEASE_CANDIDATE=1 NIGHTDRIVE_TAG=v1.2.3+4 NIGHTDRIVE_BUILD=5 "$PARSER"

git -C "$FIXTURE_REPO" tag v1.2.3+4
expect_failure "must be annotated" run_parser
git -C "$FIXTURE_REPO" tag -d v1.2.3+4 >/dev/null

git -C "$FIXTURE_REPO" tag -a v1.2.3+4 -m "Release 1.2.3 (build 4)"
[[ "$(run_parser)" == $'v1.2.3+4\t1.2.3\t4' ]]
expect_failure "conflicts" env NIGHTDRIVE_RELEASE_REPO_ROOT="$FIXTURE_REPO" \
  NIGHTDRIVE_VERSION=1.2.4 "$PARSER"

git -C "$FIXTURE_REPO" tag -a v1.2.3+5 -m "Release 1.2.3 (build 5)"
expect_failure "multiple release tags" run_parser
[[ "$(NIGHTDRIVE_TAG=v1.2.3+4 run_parser)" == $'v1.2.3+4\t1.2.3\t4' ]]

git -C "$FIXTURE_REPO" commit -q --allow-empty -m "Next"
expect_failure "HEAD has no release tag" run_parser
expect_failure "does not point at HEAD" env NIGHTDRIVE_RELEASE_REPO_ROOT="$FIXTURE_REPO" \
  NIGHTDRIVE_TAG=v1.2.3+4 "$PARSER"

# Appcast readers: both the attribute and element spellings Sparkle has used.
APPCAST="$FIXTURE_ROOT/appcast.xml"
cat >"$APPCAST" <<'XML'
<rss><channel><item>
<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
<enclosure sparkle:version="7" />
</item></channel></rss>
XML
[[ "$(scripts/appcast-marketing-version.sh "$APPCAST")" == "1.2.3" ]]
[[ "$(scripts/appcast-build-number.sh "$APPCAST")" == "7" ]]

[[ "$(scripts/compare-marketing-versions.sh 1.2.4 1.2.3)" == "1" ]]
[[ "$(scripts/compare-marketing-versions.sh 1.2.3 1.2.3)" == "0" ]]
[[ "$(scripts/compare-marketing-versions.sh 1.9.0 1.10.0)" == "-1" ]]

echo "Release tag and appcast parsing tests passed."
