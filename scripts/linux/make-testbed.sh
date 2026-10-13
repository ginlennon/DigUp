#!/bin/bash
# Builds the testbed on Linux: a deletable sandbox for trying DigUp on realistic files, with the same relative paths as
# the macOS testbed (scripts/make-testbed.sh), so `digup eval evals/*.json` works on it.
#   synthetic/  generated media with known content: the ground truth for evals
#   traps/      cases the crawler must get right (TypeScript .ts, code projects, datasets, icons, bundles, odd names)
#   code/       small git repos with known functions, for code search (evals/code.json)
#   real/       only with --with-real: a seeded random sample of your own files (see testbed/sample_real.py)
#
#   scripts/linux/make-testbed.sh [--with-real [--hardlinks]] [dir]        default: ~/DigUpTestbed
# Delete it any time: rm -rf ~/DigUpTestbed. Needs uv, ffmpeg, git and Ubuntu's Noto fonts; downloads ~110 MB of
# pictures and ~200 MB of voices once (kept in ~/.cache/digup-testbed). See scripts/linux/README.md.
set -euo pipefail
WITH_REAL=0; REAL_ARGS=(); TB=""
for arg in "$@"; do
  case "$arg" in
    --with-real) WITH_REAL=1 ;;
    --hardlinks) REAL_ARGS+=(--hardlinks) ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "unknown option $arg"; exit 1 ;;
    *) TB="$arg" ;;
  esac
done
TB="${TB:-$HOME/DigUpTestbed}"
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"; G="$HERE/testbed"
for tool in uv ffmpeg ffprobe git; do command -v $tool >/dev/null || { echo "needs $tool"; exit 1; }; done
[[ -e "$TB" ]] && { echo "$TB already exists; delete it first (rm -rf \"$TB\")"; exit 1; }
py() { uv run --locked --project "$G" python -I "$@"; }
# Fails early, with the apt package to install, when a font is missing.
py -c "import sys; sys.path.insert(0, '$G'); import draw; [draw.font_path(f) for f in list(draw.FACES.values()) + draw.FALLBACK + [draw.EMOJI]]"
mkdir -p "$TB"
TB="$(cd "$TB" && pwd)"

if [[ $WITH_REAL == 1 ]]; then
  echo "== real/: sampling your files =="
  py "$G/sample_real.py" "$TB" "${REAL_ARGS[@]}"
fi

echo "== synthetic/ =="
S="$TB/synthetic"
"$G/make_media.sh" "$S" >/dev/null
rm -rf "$S/audio_trunc" "$S/audio/bench_60s.wav" "$S/video/bench_45s.mp4" "$S/video"/seg_*.mp4
mv "$S/shots" "$S/screenshots"
# macOS marks these with the kMDItemIsScreenCapture attribute; Linux has no such mark, and DigUp's Linux build knows
# screenshots by name only ("Screenshot…"), so shot_*.png are plain pictures there.
py "$G/make_docs.py" "$S/docs" >/dev/null
py "$G/make_long.py" "$S/long" >/dev/null   # deep pages: read after the first pass
"$G/make_lang.sh" "$S/lang"   # Bengali and Arabic (evals/multilingual.json)

echo "== traps/ =="
T="$TB/traps"; mkdir -p "$T"
cp_() { cp --reflink=auto "$@"; }   # macOS: cp -c (an APFS clone); a reflink where the file system has them
# TypeScript files that Spotlight types as MPEG-2 video; and one real MPEG-TS video that must still be indexed.
mkdir -p "$T/ts-code" "$T/real-mpeg-ts"
printf 'export const greet = (name: string): string => `hello ${name}`;\n' > "$T/ts-code/app.ts"
printf 'import { greet } from "./app";\nconsole.log(greet("zebra"));\n' > "$T/ts-code/main.mts"
ffmpeg -loglevel error -i "$S/video/penguin_zebra_parrot_18s.mp4" -c copy -f mpegts "$T/real-mpeg-ts/zoo clip.ts"
# A code project: only its screenshot should be indexed.
P="$T/MyProject"; mkdir -p "$P/.git" "$P/assets" "$P/node_modules/lib" "$P/screenshots"
echo '{"name": "my-project"}' > "$P/package.json"
cp_ "$S/img/Animals-Owl.jpg" "$P/assets/hero.jpg"
cp_ "$S/img/Animals-Eagle.jpg" "$P/node_modules/lib/logo.jpg"
cp_ -p "$S/screenshots/shot_weather.png" "$P/screenshots/Screenshot 2026-10-02 at 8.15.40 AM.png"
# node_modules outside a project, a hidden folder, and an app bundle: all skipped.
mkdir -p "$T/node_modules/pkg" "$T/.hidden" "$T/Fake.app/Contents/Resources"
cp_ "$S/img/Nature-Leaf.jpg" "$T/node_modules/pkg/leaf.jpg"
cp_ "$S/img/Nature-Zen.jpg" "$T/.hidden/zen.jpg"
cp_ "$S/img/Fun-Medal.jpg" "$T/Fake.app/Contents/Resources/medal.jpg"
# Icons below the 256 px minimum: skipped. (macOS: sips -Z, the long side scaled to px.)
mkdir -p "$T/icons"
for px in 32 64 128; do
  ffmpeg -loglevel error -i "$S/img/Sports-Target.jpg" -vf "scale=$px:$px:force_original_aspect_ratio=decrease" "$T/icons/target-$px.png"
done
# A dataset: 600 machine-named clips in one folder -> the detector should flag it.
mkdir -p "$T/dataset_clips"
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -ac 1 -ar 16000 "$T/dataset_clips/clip_000000.wav"
for i in $(seq -f "%06g" 1 599); do cp_ "$T/dataset_clips/clip_000000.wav" "$T/dataset_clips/clip_$i.wav"; done
# Odd names: spaces, non-ASCII, and the narrow no-break space (U+202F) macOS puts before AM/PM.
N="$T/Names with spaces & ünïcödé"; mkdir -p "$N"
cp_ -p "$S/screenshots/shot_chat_meeting.png" "$N/Screenshot 2026-10-05 at 9.41.07$(printf '\xe2\x80\xaf')PM.png"
cp_ "$S/img/Flowers-Sunflower.jpg" "$N/Café menü — 日本語.jpg"
# Duplicates: the same photo under two names.
mkdir -p "$T/duplicates"
cp_ "$S/img/Animals-Penguin.jpg" "$T/duplicates/penguin.jpg"
cp_ "$S/img/Animals-Penguin.jpg" "$T/duplicates/penguin copy.jpg"

echo "== code/ =="
py "$REPO/scripts/testbed/make_code.py" "$TB/code"

cat > "$TB/README.md" <<'EOF'
# DigUp testbed (Linux)

A sandbox for testing DigUp. Delete it whenever you like: `rm -rf ~/DigUpTestbed`.
Rebuild it with `scripts/linux/make-testbed.sh` in the DigUp repo (macOS: `scripts/make-testbed.sh`).

- `synthetic/`: generated media with known content (freely licensed stand-ins for macOS's sample pictures, from
  Wikimedia Commons; synthetic UI screenshots; Piper TTS speech; a penguin/zebra/parrot video; PDFs and notes; `lang/`
  has Bengali and Arabic ones; `long/` a 120-page PDF, long notes and a dump of numbers). This is the ground truth for
  automated evals.
- `traps/`: cases the crawler must handle: TypeScript `.ts` files (not videos), a real MPEG-TS video (is a video),
  a code project (only its screenshot counts), `node_modules`, hidden folders, an app bundle, tiny icons, a
  600-clip dataset, odd file names, and duplicates.
- `code/`: four small git repos (Python, Swift, TypeScript, notebooks) and loose scripts with known functions, for
  code search (`evals/code.json`); each repo also holds what code search must leave out (vendored and built copies,
  generated and minified code, a private key, data).
- `real/` (only with `--with-real`): a sample of your own files (reflinks where the file system has them, otherwise
  copies or, with `--hardlinks`, hard links); `real/MANIFEST.tsv` lists where each came from. Personal files: never
  commit or upload them.
EOF
echo "== done: $TB =="
du -sh "$TB" 2>/dev/null | sed 's/^/size: /'
