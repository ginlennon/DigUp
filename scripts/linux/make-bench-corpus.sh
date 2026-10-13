#!/bin/bash
# Builds a synthetic corpus for embedding benchmarks (scripts/linux/bench-embed.sh): what it costs to embed depends on
# token budgets (a photo is 140 tokens, a screenshot 280, a PDF page 280 + its text, 30 s of sound, a frame every 3 s),
# not on what the files show, so generated files measure the same work as real ones. Needs ffmpeg and soffice.
#   scripts/linux/make-bench-corpus.sh [dir]     default: .dev/bench-corpus
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
C="${1:-$REPO/.dev/bench-corpus}"
[[ -e "$C" ]] && { echo "$C exists; delete it first"; exit 1; }
mkdir -p "$C"/{photos,screenshots,docs,pdfs,audio,video}
ff() { ffmpeg -loglevel error -y "$@"; }
SOURCES=(testsrc2 mandelbrot rgbtestsrc smptehdbars cellauto life)

echo "photos (40 × 1600×1200 JPEG)"
for i in $(seq 0 39); do
  src=${SOURCES[$((i % 6))]}
  ff -f lavfi -i "$src=size=1600x1200:rate=1" -vf "hue=h=$((i * 37 % 360)),noise=alls=$((i % 20)):allf=t" \
     -frames:v 1 -q:v 3 "$C/photos/photo_$(printf %02d $i).jpg"
done

echo "screenshots (30 × 1920×1080 PNG)"
for i in $(seq 0 29); do
  ff -f lavfi -i "testsrc2=size=1920x1080:rate=1" -vf "hue=h=$((i * 53 % 360))" -frames:v 1 \
     "$C/screenshots/Screenshot from 2026-10-14 $(printf '%02d-%02d-%02d' $((i / 10)) $((i % 60)) $i).png"
done

echo "docs (30 notes, ~2,500 words each)"
TEXT=$(cat "$REPO/README.md" "$REPO/CONTRIBUTING.md" "$REPO/LINUX_PORT.md" | tr -d '`#|*<>')
for i in $(seq 0 29); do
  { echo "Note $i"; for r in 1 2; do printf '%s\n' "$TEXT" | awk -v s=$((i * 7 + r)) 'NR % 3 == s % 3 || NR % 5 == s % 5'; done; } \
    > "$C/docs/note_$(printf %02d $i).txt"
done

echo "pdfs (6 × ~10 pages, text PDFs via LibreOffice)"
for i in $(seq 0 5); do
  { for r in 1 2 3; do printf '%s\n\n' "$TEXT"; done; } > "$C/pdfs/report_$i.txt"
done
soffice --headless --convert-to pdf --outdir "$C/pdfs" "$C"/pdfs/report_*.txt > /dev/null 2>&1
rm "$C"/pdfs/report_*.txt

echo "audio (6 × 120 s: speech + noise, so no window is dropped as silent)"
SPEECH="$REPO/Tests/LlamaRuntimeTests/Reference/speech.wav"
for i in $(seq 0 5); do
  ff -stream_loop -1 -i "$SPEECH" -f lavfi -i "anoisesrc=color=pink:amplitude=0.0$((i + 2)):sample_rate=16000" \
     -filter_complex "[0:a]aresample=16000[s];[s][1:a]amix=inputs=2:duration=shortest" -t 120 -ac 1 -ar 16000 \
     "$C/audio/talk_$i.wav"
done

echo "video (4 × 60 s, a cut every 10 s, with sound)"
for i in $(seq 0 3); do
  inputs=(); parts=""
  for k in $(seq 0 5); do
    inputs+=(-f lavfi -t 10 -i "${SOURCES[$(((i + k) % 6))]}=size=1280x720:rate=24")
    parts+="[$k:v]format=yuv420p,setsar=1[v$k];"
  done
  ff "${inputs[@]}" -stream_loop -1 -i "$SPEECH" \
     -filter_complex "${parts}[v0][v1][v2][v3][v4][v5]concat=n=6:v=1:a=0[v]" -map "[v]" -map 6:a -t 60 \
     -c:v libx264 -preset veryfast -c:a aac -shortest "$C/video/clip_$i.mp4"
done
du -sh "$C"/* | sed 's|'"$C"'/||'
