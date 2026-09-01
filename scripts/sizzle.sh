#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TRACK="${1:-sizzle}"
OUTPUT_DIR="${NIGHTDRIVE_DEMO_OUTPUT_DIR:-$HOME/Movies/Nightdrive Demos}"
TIMEOUT=300

echo "== sizzle: building debug binary =="
node scripts/run-swiftpm.mjs build -c debug
BUILD_PRODUCTS_DIR="$(node scripts/run-swiftpm.mjs build -c debug --show-bin-path)"
BIN="$BUILD_PRODUCTS_DIR/Nightdrive"
if [[ ! -x "$BIN" ]]; then
  echo "FAIL: SwiftPM did not produce an executable at $BIN" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
BEFORE_NEWEST="$(ls -t "$OUTPUT_DIR"/*.mp4 2>/dev/null | head -1 || true)"

echo "== sizzle: recording track \"$TRACK\" against the real library (the app will appear on screen) =="
caffeinate -u -t 2 || true
sleep 1
if system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Display Asleep: Yes"; then
  echo "FAIL: the display is asleep and would not wake (locked session?)." >&2
  echo "  Wake and unlock the Mac, then run make sizzle again." >&2
  exit 1
fi
caffeinate -dus &
CAFFEINATE_PID=$!
NIGHTDRIVE_DEMO_TRACK="$TRACK" \
NIGHTDRIVE_DEMO_OUTPUT_DIR="$OUTPUT_DIR" \
"$BIN" &
APP_PID=$!
cleanup() {
  kill "$APP_PID" 2>/dev/null || true
  kill "$CAFFEINATE_PID" 2>/dev/null || true
}
trap cleanup EXIT

elapsed=0
while kill -0 "$APP_PID" 2>/dev/null && [ "$elapsed" -lt "$TIMEOUT" ]; do
  sleep 1
  elapsed=$((elapsed + 1))
done

if kill -0 "$APP_PID" 2>/dev/null; then
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  echo "FAIL: app did not exit within ${TIMEOUT}s (demo track hung?)" >&2
  exit 1
fi
wait "$APP_PID" || {
  echo "FAIL: app exited nonzero" >&2
  exit 1
}

NEWEST="$(ls -t "$OUTPUT_DIR"/*.mp4 2>/dev/null | head -1 || true)"
if [ -z "$NEWEST" ] || [ "$NEWEST" = "$BEFORE_NEWEST" ]; then
  echo "FAIL: no new recording appeared in $OUTPUT_DIR" >&2
  exit 1
fi
SIZE="$(stat -f %z "$NEWEST")"
if [ "$SIZE" -le 200000 ]; then
  echo "FAIL: $NEWEST is only ${SIZE} bytes" >&2
  exit 1
fi
echo "sizzle: $NEWEST (${SIZE} bytes)"
