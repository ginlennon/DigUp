# Linux scripts

## Install: `install-user.sh`

```sh
scripts/linux/install-user.sh [--prefix DIR] [--dry-run] [--yes] [--no-desktop] [--no-shortcut]
scripts/linux/install-user.sh --uninstall       # removes what it put in place, never your data
```

Puts a DigUp that runs without the checkout in `~/.local/opt/digup` (no sudo), after the build steps of `setup.sh`:
release builds (`swift build -c release --product digup --static-swift-stdlib`, `cargo build --release`), then

```
digup-shell                 the desktop shell; it finds its helper in helper/ by itself
helper/digup                the engine, Swift's libraries (Foundation, ICU) built in
helper/lib{llama,mtmd,ggml,ggml-base}.so*, libggml-cpu-*.so, libggml-vulkan.so, libpdfium.so
helper/ffmpeg, ffprobe      8.1 from fetch-ffmpeg.sh, with its licence
helper/whisper-cli          when build-whisper.sh built it (transcripts, optional): static, no patchelf
share/icons, share/licenses
```

with `$ORIGIN` as the libraries' search path (patchelf drops the dev builds' absolute `Vendor/` paths), so `digup`
finds its backends and ffmpeg beside itself without any `DIGUP_*` variable. From the system it takes glibc,
libstdc++, libgomp (llama.cpp's CPU backends), libcurl (only `digup download-model`) and the Vulkan loader with the
GPU's driver, which are never bundled; tesseract is looked for on PATH. ~420 MB, two thirds of it ffmpeg and ffprobe
(2026-10-14). It adds an app-menu entry (`~/.local/share/applications/digup.desktop`, the icon in
`~/.local/share/icons/hicolor`) and offers to point the GNOME shortcut (with `--toggle` once the shell has it) and an
existing login entry (`~/.config/autostart/digup.desktop`) at the installed shell. Run it again to update: the folder
is built as `<prefix>.new` and swapped in. The model, the index (`~/.local/share/digup`) and the settings
(`~/.config/com.abdurrahim.DigUp`) are shared with dev runs and never touched; `--uninstall` says how to remove them.

## A newer ffmpeg: `fetch-ffmpeg.sh`

```sh
scripts/linux/fetch-ffmpeg.sh       # → Vendor/ffmpeg/{ffmpeg,ffprobe,LICENSE.txt}, ~280 MB unpacked
```

Ubuntu 24.04's ffmpeg 6.1 reads no HEIC and leaves WebP and TIFF pictures unturned; DigUp needs 8.1. The script puts
BtbN/FFmpeg-Builds' static **LGPL** build of 8.1.3 (the last autobuild of September 2026, kept by BtbN for two years;
x86_64 and arm64, pinned by sha256) in `Vendor/ffmpeg/`. Dev builds and the tests find it there by themselves (they run
from the checkout's `.build/`); an installed `digup` looks in `$DIGUP_FFMPEG` (a folder), beside itself, then on PATH.

## Transcripts (optional): `build-whisper.sh`

```sh
scripts/linux/build-whisper.sh                    # → Vendor/whisper/bin/whisper-cli (+ BUILD, LICENSE), ~1 min
.build/release/digup download-model --transcripts [--small]   # → ~/.local/share/digup/Models/whisper
```

Transcripts of recordings are off by default (and not used for indexing yet: `PLANS/TRANSCRIPTS_PLAN.md`). The
script builds whisper.cpp v1.9.5 (pinned by commit) as one **static** program, so it never loads llama.cpp's
`libggml*.so` beside `digup` (a one-line patch also stops it from looking for backends in its folder): Vulkan when
glslc and the Vulkan headers are there, else the CPU (`WHISPER_FLAVOR=cpu` forces it); CPU code for x86-64-v3
(AVX2/FMA/F16C), not `-march=native`. `fetch-vendor.sh` runs it too. `digup` looks for `whisper-cli` in
`$DIGUP_WHISPER` (the program or its folder), beside itself, in a dev build's `Vendor/whisper/bin`, then on PATH. The
models, pinned by Hugging Face revision and sha256: `ggml-large-v3-turbo-q5_0.bin` (574 MB, the default, for the
GPU) or with `--small` `ggml-small.bin` (488 MB, for the CPU), plus the Silero VAD `ggml-silero-v6.2.0.bin`
(0.9 MB). `digup doctor` shows what's there (`--deep` checks the sha256); nothing missing is an error.

## OCR: tesseract

Screenshots and scanned PDF pages get their words (for keyword search) from `tesseract`, run like ffmpeg: from
`$DIGUP_TESSERACT` (the program or its folder), beside `digup`, or on PATH (`sudo apt install tesseract-ocr`). It reads
in the installed languages named by `DIGUP_OCR_LANGS` (`eng+deu`), else in up to three of the system's language,
English, German, French, Spanish, Italian, Portuguese and Arabic that are installed (`tesseract --list-langs`; more:
`sudo apt install tesseract-ocr-fra`…; each language makes it slower). ~0.2–0.7 s per 1440×900 screenshot with eng+deu
(2026-10-14), pages at 300 dpi. An index made before tesseract was there reads its screenshots and scans once more.

## The eval testbed: `make-testbed.sh`

```sh
scripts/linux/make-testbed.sh [--with-real [--hardlinks]] [dir]     # default dir: ~/DigUpTestbed
uv run --project scripts/linux/testbed python -I scripts/linux/testbed/check_eval_paths.py ~/DigUpTestbed [--content]
digup eval evals/synthetic.json      # and evals/multilingual.json, evals/code.json
```

This is the Linux port of `scripts/make-testbed.sh`. It builds `synthetic/`, `traps/` and `code/` with the **same
relative paths** the evals name, so `evals/*.json` (base `~/DigUpTestbed`) run unchanged. `check_eval_paths.py` checks
that every expected path exists (the `@a-b` ranges stripped; PDFs have the pages, videos the length); `--content` also
shows whether the words that the exact and word queries look for are in the text DigUp reads. It takes about 35 s
once the downloads are cached and needs no GPU.

**Needs:** `uv` (Python 3.13 from `testbed/pyproject.toml` + `uv.lock`; never the system Python), `ffmpeg`/`ffprobe`
(6.1), `git`, and Ubuntu's fonts: `fonts-noto-core` (Noto Sans, Sans Mono, Sans Bengali, Naskh Arabic, Symbols),
`fonts-noto-color-emoji`, `fonts-dejavu-core`. The script stops with the `apt install` line if a font is missing.
First run downloads ~110 MB of pictures (Wikimedia Commons) and ~200 MB of Piper voices (Hugging Face) into
`~/.cache/digup-testbed` (`DIGUP_TESTBED_CACHE` moves it); both are pinned by sha256.

| macOS | Linux |
|---|---|
| `/Library/User Pictures/*/*.heic` through `sips -Z 768` | `testbed/pictures.json`: 35 photos from Wikimedia Commons (CC0, CC BY, CC BY-SA, public domain; URL, author, license and sha256 each), at most 768 px. Never committed. |
| `say -v Samantha` / `Piya` / `Majed` | Piper (CPU): `en_US-lessac-medium`, `bn_BD-google-medium`, `ar_JO-kareem-medium` |
| `make_screenshots.swift`, `make_docs.swift`, `make_long.swift`, `make_lang.swift` (AppKit, CoreText, WebKit) | `make_screenshots.py`, `make_docs.py`, `make_long.py`, `make_lang.py` (Pillow with HarfBuzz via raqm, fpdf2 with HarfBuzz, python-docx, a Cocoa-style RTF writer): same names, same text, same formats (PDF, PNG, txt, md, rtf, docx) |
| `cp -c` (APFS clone) | `cp --reflink=auto` |
| the `kMDItemIsScreenCapture` attribute | names and the `screenshots/` folder (see below) |
| `/System/Library/Sounds` effects (`sfx_*.wav`) | left out: no eval asks for them |
| `real/` always (Spotlight sample, clones) | opt-in `--with-real`: reflinks where the file system has them (Btrfs, XFS), else copies (stops above 5 GB), or hard links with `--hardlinks` (no space, but a hard link *is* your file). Originals are only read. |
| `code/` by `scripts/testbed/make_code.py` | the same script, run with the uv Python |

The text of every note, PDF page, screenshot and speech clip is the macOS text (checked string for string against the
Swift sources), and the logbook and team notes use the same seeded generator, so they're the same pages.

### Eval numbers: comparable, not identical

- **Pictures and voices differ.** The photos show the same subjects (a zebra, a bald eagle, the Earth from space…), but
  they're other photos, and the speech is another voice. Image, video and audio queries can rank differently. The
  distractor pictures (cat, dog, dahlia, piano, sports balls…) are a best guess at the macOS set; there's no baseball.
- **Most screenshots are screenshots on Linux too, by name or folder.** macOS knows `synthetic/screenshots/shot_*.png`
  and `lang/*/wallet_failed_bn.png`, `payment_error_ar.png` as screenshots by their Spotlight attribute. Linux has no
  marker; DigUp's Linux build (`Platform/Portable/Files+Portable.swift`: `hasScreenshotMarker`) knows a screenshot by
  its name, whatever its case and in the common GNOME/KDE languages ("Screenshot from …", "Bildschirmfoto vom …"), or by
  a folder named like GNOME's `Screenshots`. So the six `shot_*.png` are screenshots, but the two `lang/` ones are
  indexed as **pictures** (photo budget, 1024 px instead of 1536 px, no OCR, no "screenshot" kind boost). The testbed
  keeps the eval paths, so it can't rename them. OCR is tesseract (see above): the exact queries on screenshots
  (`card_declined`, `INV-2041`, `K7Q2LM`, `externally-managed-environment`) match its words; the Bengali and Arabic
  screenshot queries would need those two to be screenshots and `tesseract-ocr-ben` / `-ara` installed.
- **PDF text layers.** fpdf2 makes them; DigUp reads them with PDFium. Arabic reads back exactly; Bengali reads
  garbled where a cluster takes several glyphs (a vowel sign drawn before its consonant, conjuncts), which is how macOS
  reads its WebKit-made Bengali PDFs too. Most whole words survive (`ধানমন্ডি` is found).
- The video's frames are the pictures cropped to fill 768×768 (macOS's are square and get stretched).
