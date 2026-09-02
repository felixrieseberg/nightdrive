#!/bin/bash
#
# Encode a demo recording into the clip the website autoplays.
#
# `make sizzle` records at the display's native resolution and frame rate,
# which is far too heavy to serve: the first reel was 130 MB at 2456x1730 and
# ~57fps, well past GitHub's 100 MB per-file limit. This re-encodes it to
# docs/demo.mp4 and writes the poster frame the page shows before playback.
#
# The defaults below were chosen for that first reel:
#
#   WIDTH=1328   Twice the 660px box the video occupies in docs/styles.css, so
#                it stays sharp on a 2x display and no sharper.
#   FPS=30       The reel is screen-recorded UI, not motion footage.
#   CRF=22       Compared against 20/26/30 on a frame of the track listing.
#                26 and 30 are markedly smaller but soften the small type; 20
#                costs ~25% more bytes for no visible gain. Dark, mostly static
#                UI compresses well, so 22 lands near 5 MB for 45 seconds.
#
# The reels carry no audio track, so the output is encoded with -an and the
# page can autoplay it muted without losing anything.
#
# Usage:
#   ./scripts/encode-demo-video.sh [input.mp4]     # or: make demo-video
#
# With no argument it takes the newest recording out of the sizzle output
# directory, so `make sizzle && make demo-video` does the right thing.
#
set -euo pipefail
cd "$(dirname "$0")/.."

WIDTH="${WIDTH:-1328}"
FPS="${FPS:-30}"
CRF="${CRF:-22}"
POSTER_TIME="${POSTER_TIME:-0}"

OUTPUT_VIDEO="docs/demo.mp4"
OUTPUT_POSTER="docs/demo-poster.jpg"

# GitHub rejects pushes carrying a file this large. Staying well under it is
# also just good manners for a page that autoplays.
GITHUB_FILE_LIMIT=$((100 * 1024 * 1024))
BUDGET=$((12 * 1024 * 1024))

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
  echo "FAIL: ffmpeg and ffprobe are required (brew install ffmpeg)" >&2
  exit 1
fi

INPUT="${1:-}"
if [ -z "$INPUT" ]; then
  SIZZLE_DIR="${NIGHTDRIVE_DEMO_OUTPUT_DIR:-$HOME/Movies/Nightdrive Demos}"
  INPUT="$(ls -t "$SIZZLE_DIR"/*.mp4 2>/dev/null | head -1 || true)"
  if [ -z "$INPUT" ]; then
    echo "FAIL: no recording found in $SIZZLE_DIR" >&2
    echo "  Run make sizzle first, or pass a file: $0 path/to/recording.mp4" >&2
    exit 1
  fi
  echo "== demo-video: using newest recording =="
fi

if [ ! -f "$INPUT" ]; then
  echo "FAIL: $INPUT is not a file" >&2
  exit 1
fi

probe() {
  ffprobe -v error -select_streams v:0 -show_entries "stream=$1" -of csv=p=0 "$2" | head -1
}

megabytes() {
  awk -v bytes="$1" 'BEGIN { printf "%.1f MB", bytes / 1048576 }'
}

kilobytes() {
  awk -v bytes="$1" 'BEGIN { printf "%.0f KB", bytes / 1024 }'
}

IN_SIZE="$(stat -f %z "$INPUT")"
IN_W="$(probe width "$INPUT")"
IN_H="$(probe height "$INPUT")"
echo "   input:  $INPUT"
echo "           ${IN_W}x${IN_H}, $(megabytes "$IN_SIZE")"

echo "== demo-video: encoding to ${WIDTH}px wide, ${FPS}fps, CRF ${CRF} =="
# -2 keeps the source aspect ratio and rounds to an even height, which H.264
# requires. +faststart moves the index to the front so playback can begin
# before the whole file has arrived.
ffmpeg -v error -stats -i "$INPUT" \
  -an \
  -vf "scale=${WIDTH}:-2:flags=lanczos,fps=${FPS}" \
  -c:v libx264 \
  -profile:v high \
  -pix_fmt yuv420p \
  -preset slow \
  -crf "$CRF" \
  -movflags +faststart \
  -y "$OUTPUT_VIDEO"

echo "== demo-video: writing poster frame at ${POSTER_TIME}s =="
# Matching the first frame of playback keeps the handover invisible when the
# video starts, and gives reduced-motion visitors a still worth looking at.
ffmpeg -v error -ss "$POSTER_TIME" -i "$INPUT" \
  -frames:v 1 \
  -vf "scale=${WIDTH}:-2:flags=lanczos" \
  -q:v 6 \
  -y "$OUTPUT_POSTER"

OUT_SIZE="$(stat -f %z "$OUTPUT_VIDEO")"
POSTER_SIZE="$(stat -f %z "$OUTPUT_POSTER")"
OUT_W="$(probe width "$OUTPUT_VIDEO")"
OUT_H="$(probe height "$OUTPUT_VIDEO")"

echo
echo "   $OUTPUT_VIDEO   ${OUT_W}x${OUT_H}, $(megabytes "$OUT_SIZE")"
echo "   $OUTPUT_POSTER  $(kilobytes "$POSTER_SIZE")"

if [ "$OUT_SIZE" -ge "$GITHUB_FILE_LIMIT" ]; then
  echo "FAIL: $OUTPUT_VIDEO is over GitHub's 100 MB file limit and cannot be pushed." >&2
  echo "  Raise CRF (CRF=26) or lower WIDTH, then run again." >&2
  exit 1
fi
if [ "$OUT_SIZE" -gt "$BUDGET" ]; then
  echo "WARNING: $OUTPUT_VIDEO is over the ${BUDGET} byte budget for a clip that" >&2
  echo "  autoplays on the landing page. Consider CRF=26 or a shorter reel." >&2
fi

# The page declares the aspect ratio in two places so the layout does not jump
# while the video loads. A recording shot at a different shape has to update
# both, so say so plainly rather than letting the video letterbox.
if ! grep -q "aspect-ratio: ${OUT_W} / ${OUT_H};" docs/styles.css \
  || ! grep -q "width=\"${OUT_W}\"" docs/index.html \
  || ! grep -q "height=\"${OUT_H}\"" docs/index.html; then
  echo
  echo "WARNING: the site still declares a different size for this video." >&2
  echo "  Set 'aspect-ratio: ${OUT_W} / ${OUT_H};' in .demo-video (docs/styles.css)" >&2
  echo "  and width=\"${OUT_W}\" height=\"${OUT_H}\" on the <video> (docs/index.html)." >&2
fi
