#!/bin/bash
# Builds the testbed's synthetic media (no personal data) on Linux: a port of scripts/testbed/make_media.sh with the
# same names and timings. Sample pictures come from Wikimedia Commons (pictures.json) instead of macOS's
# /Library/User Pictures, speech from Piper instead of `say`, screenshots from Pillow instead of AppKit. macOS's system
# sounds (sfx_*.wav) have no stand-in: no eval asks for them.
#   scripts/linux/testbed/make_media.sh <out_dir>
set -euo pipefail
M="${1:?usage: make_media.sh <out_dir>}"; HERE="$(cd "$(dirname "$0")" && pwd)"
py() { uv run --locked --project "$HERE" python -I "$@"; }
mkdir -p "$M/img" "$M/shots" "$M/audio" "$M/audio_trunc" "$M/video"

py "$HERE/fetch_pictures.py" "$M/img"
py "$HERE/make_screenshots.py" "$M/shots" >/dev/null

# Samantha's stand-in: Piper's en_US lessac voice.
py "$HERE/speak.py" en \
  "$M/audio/speech_groceries.wav" "Don't forget to buy milk, eggs and bread on the way home tomorrow." \
  "$M/audio/speech_revenue.wav" "Our quarterly revenue grew by twenty percent, driven by strong sales in Europe." \
  "$M/audio/speech_flight_delay.wav" "Attention passengers. The flight to Tokyo has been delayed by two hours because of a storm." \
  "$M/audio/speech_cake_recipe.wav" "In this recipe we will bake a chocolate cake. First, preheat the oven to one hundred eighty degrees, then mix the flour, sugar and cocoa powder in a large bowl. Add the eggs, the melted butter and the milk, and stir until the batter is smooth. Pour it into a greased pan and bake for thirty five minutes. While the cake is baking, prepare the frosting by whipping cream with a little sugar and vanilla. When the cake has cooled down completely, spread the frosting on top and decorate it with fresh strawberries and some grated chocolate."
ffmpeg -loglevel error -y -stream_loop 5 -i "$M/audio/speech_cake_recipe.wav" -t 60 "$M/audio/bench_60s.wav"

# Audio length-cap test clips
A="$M/audio"; T="$M/audio_trunc"
ffmpeg -loglevel error -y -i "$A/bench_60s.wav" -t 11 "$T/bench_first11s.wav"
ffmpeg -loglevel error -y -i "$A/bench_60s.wav" -t 30 "$T/bench_first30s.wav"
ffmpeg -loglevel error -y -ss 30 -i "$A/bench_60s.wav" -t 30 "$T/bench_last30s.wav"
ffmpeg -loglevel error -y -i "$A/speech_flight_delay.wav" -i "$A/speech_flight_delay.wav" -f lavfi -t 1 -i anullsrc=r=16000:cl=mono \
  -i "$A/speech_revenue.wav" -i "$A/speech_revenue.wav" -i "$A/speech_revenue.wav" -i "$A/speech_revenue.wav" \
  -filter_complex "[0][1][2][3][4][5][6]concat=n=7:v=0:a=1" -ac 1 -ar 16000 "$T/flight_then_revenue_29s.wav"

# 18 s video = penguin | zebra | parrot (6 s each), cut into 6 s moments; plus a 45 s bench video. The pictures here
# aren't square as macOS's are, so each fills the 768×768 frame (scaled to cover, centre cropped) instead of stretching.
I="$M/img"; V="$M/video"
fill="scale=768:768:force_original_aspect_ratio=increase,crop=768:768,setsar=1"
ffmpeg -loglevel error -y -loop 1 -t 6 -i "$I/Animals-Penguin.jpg" -loop 1 -t 6 -i "$I/Animals-Zebra.jpg" -loop 1 -t 6 -i "$I/Animals-Parrot.jpg" \
  -filter_complex "[0:v]$fill[a];[1:v]$fill[b];[2:v]$fill[c];[a][b][c]concat=n=3:v=1:a=0,format=yuv420p" \
  -r 24 -c:v libx264 "$V/penguin_zebra_parrot_18s.mp4"
for s in 0 6 12; do ffmpeg -loglevel error -y -ss $s -t 6 -i "$V/penguin_zebra_parrot_18s.mp4" -c:v libx264 -pix_fmt yuv420p "$V/seg_${s}s.mp4"; done
ffmpeg -loglevel error -y -stream_loop 2 -i "$V/penguin_zebra_parrot_18s.mp4" -t 45 -c copy "$V/bench_45s.mp4"
echo "media in $M"
