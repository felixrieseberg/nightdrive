#!/bin/bash
# Reproducible large-library scan/index benchmark. The Swift fixture represents
# each track with a copy-on-write clone of one sparse MP3; a 400-GiB logical scenario
# consumes only directory entries, one small audio allocation, and its JSON cache.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
COUNTS="${LIBRARY_BENCHMARK_COUNTS:-20000,50000,100000}"
TRACK_MIB="${LIBRARY_BENCHMARK_LOGICAL_TRACK_MIB:-4}"
IMPORT_COUNT="${LIBRARY_BENCHMARK_IMPORT_COUNT:-1000}"
RUN_ROOT=".scratch/library-benchmark-$$"

# The benchmark-library subcommand is development-tools-only code; debug
# builds define the flag via Package.swift, release builds need it passed.
BENCHMARK_SWIFT_FLAGS=()
if [[ "$CONFIG" == "release" ]]; then
  BENCHMARK_SWIFT_FLAGS=(-Xswiftc -DNIGHTDRIVE_DEVELOPMENT_TOOLS)
fi

cleanup() {
  rm -rf "$RUN_ROOT"
}
trap cleanup EXIT
mkdir -p "$RUN_ROOT"

echo "== large-library benchmark: building $CONFIG binary =="
node scripts/run-swiftpm.mjs build -c "$CONFIG" \
  ${BENCHMARK_SWIFT_FLAGS[@]+"${BENCHMARK_SWIFT_FLAGS[@]}"}
BUILD_PRODUCTS_DIR="$(
  node scripts/run-swiftpm.mjs build -c "$CONFIG" \
    ${BENCHMARK_SWIFT_FLAGS[@]+"${BENCHMARK_SWIFT_FLAGS[@]}"} --show-bin-path
)"
BIN="$BUILD_PRODUCTS_DIR/Nightdrive"
if [[ ! -x "$BIN" ]]; then
  echo "FAIL: SwiftPM did not produce an executable at $BIN" >&2
  exit 1
fi

"$BIN" benchmark-library \
  --work-dir "$PWD/$RUN_ROOT/work" \
  --counts "$COUNTS" \
  --logical-track-mib "$TRACK_MIB" \
  --import-count "$IMPORT_COUNT"
