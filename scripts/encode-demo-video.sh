#!/bin/bash
#
# Encode a sizzle recording into docs/demo.mp4, the clip the website autoplays,
# and the poster frame the page shows before playback. Sizzle records at native
# resolution and frame rate, which is far too heavy to serve: the first reel was
# 130 MB at 2456x1730 and ~57fps, past GitHub's 100 MB file limit.
#
#   width 1328  Twice the 660px box the video occupies in docs/styles.css, so it
#               stays sharp on a 2x display and no sharper.
#   fps 30      The reel is screen-recorded UI, not motion footage.
#   crf 22      Beat 26 and 30, which soften the small type, and 20, which cost
#               ~25% more bytes for no visible gain. Dark, mostly static UI
#               compresses well, so 45 seconds lands near 5 MB.
#   -an         The recordings carry no audio at all, so the page can autoplay
#               the clip muted without losing anything.
#   +faststart  Playback can begin before the whole file has arrived.
#
# scale=1328:-2 preserves the source aspect ratio and rounds to the even height
# H.264 needs. docs/index.html and docs/styles.css hardcode the resulting
# 1328x936 so the layout cannot jump while the video loads, so a recording shot
# at a different shape has to update both or it will letterbox. The poster is
# the first frame, which makes the handover invisible when playback starts.
#
# Usage: ./scripts/encode-demo-video.sh [recording.mp4]   # or: make demo-video
# With no argument it takes the newest recording make sizzle produced.
#
set -euo pipefail
cd "$(dirname "$0")/.."

INPUT="${1:-$(ls -t "${NIGHTDRIVE_DEMO_OUTPUT_DIR:-$HOME/Movies/Nightdrive Demos}"/*.mp4 | head -1)}"

ffmpeg -v error -stats -i "$INPUT" -an -vf "scale=1328:-2:flags=lanczos,fps=30" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -preset slow -crf 22 \
  -movflags +faststart -y docs/demo.mp4

ffmpeg -v error -i "$INPUT" -frames:v 1 -vf "scale=1328:-2:flags=lanczos" \
  -q:v 6 -y docs/demo-poster.jpg

ls -lh docs/demo.mp4 docs/demo-poster.jpg
