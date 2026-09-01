#!/bin/bash
# The complete gate: formatting, tooling tests, unit tests, the CLI end-to-end
# sync checks, and the GUI snapshot tour.
#
# The three heavy stages only depend on the binaries, so this builds once and
# then runs them at the same time, printing their captured output one stage at
# a time. Set VERIFY_SERIAL=1 to run them in order instead.
set -uo pipefail
cd "$(dirname "$0")/.."

LOGS=".scratch/verify-full-$$"
mkdir -p "$LOGS"
trap 'rm -rf "$LOGS"' EXIT

fail=0

echo "== verify-full: lint =="
if ! make lint; then
  echo "verify-full: lint failed" >&2
  exit 1
fi

echo "== verify-full: tooling tests =="
if ! make verification-tooling-test; then
  echo "verify-full: tooling tests failed" >&2
  exit 1
fi

echo "== verify-full: localization catalog =="
if ! make verify-localizations; then
  echo "verify-full: localization catalog is stale" >&2
  exit 1
fi

# One build for all three stages, so they don't queue on the wrapper's slots.
echo "== verify-full: build =="
if ! node scripts/run-swiftpm.mjs build --build-tests -c debug; then
  echo "verify-full: build failed" >&2
  exit 1
fi

run_stage() {
  local name="$1"
  shift
  if "$@" >"$LOGS/$name" 2>&1; then
    echo "$name: PASS"
    : >"$LOGS/$name.passed"
  fi
}

STAGES=(unit e2e snapshots)
stage_command() {
  case "$1" in
    unit) echo "make unit-test" ;;
    e2e) echo "make e2e" ;;
    snapshots) echo "make snapshots" ;;
  esac
}

if [ "${VERIFY_SERIAL:-0}" = "1" ]; then
  echo "== verify-full: unit, e2e, snapshots (in order) =="
  for stage in "${STAGES[@]}"; do
    run_stage "$stage" bash -c "$(stage_command "$stage")"
  done
else
  echo "== verify-full: unit, e2e, snapshots (together) =="
  pids=()
  for stage in "${STAGES[@]}"; do
    run_stage "$stage" bash -c "$(stage_command "$stage")" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
fi

# Print each stage whole, so a failure reads as one transcript.
for stage in "${STAGES[@]}"; do
  # A stage counts as passing only if it said so: a worker killed outright
  # writes nothing, and absence has to read as failure.
  if [ ! -f "$LOGS/$stage.passed" ]; then
    fail=1
    echo
    echo "===== $stage FAILED ====="
    cat "$LOGS/$stage" 2>/dev/null
  fi
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "verify-full: FAILED" >&2
  exit 1
fi

for stage in "${STAGES[@]}"; do
  echo
  echo "===== $stage ====="
  tail -n 20 "$LOGS/$stage"
done

echo
echo "verify-full: PASS"
