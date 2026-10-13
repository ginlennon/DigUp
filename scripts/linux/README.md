# Linux scripts

## A newer ffmpeg: `fetch-ffmpeg.sh`

```sh
scripts/linux/fetch-ffmpeg.sh       # → Vendor/ffmpeg/{ffmpeg,ffprobe,LICENSE.txt}, ~280 MB unpacked
```

Ubuntu 24.04's ffmpeg 6.1 reads no HEIC and leaves WebP and TIFF pictures unturned; DigUp needs 8.1. The script puts
BtbN/FFmpeg-Builds' static **LGPL** build of 8.1.3 (the last autobuild of September 2026, kept by BtbN for two years;
x86_64 and arm64, pinned by sha256) in `Vendor/ffmpeg/`. Dev builds and the tests find it there by themselves (they run
from the checkout's `.build/`); an installed `digup` looks in `$DIGUP_FFMPEG` (a folder), beside itself, then on PATH.

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
| the `kMDItemIsScreenCapture` attribute | nothing (see below) |
| `/System/Library/Sounds` effects (`sfx_*.wav`) | left out: no eval asks for them |
| `real/` always (Spotlight sample, clones) | opt-in `--with-real`: reflinks where the file system has them (Btrfs, XFS), else copies (stops above 5 GB), or hard links with `--hardlinks` (no space, but a hard link *is* your file). Originals are only read. |
| `code/` by `scripts/testbed/make_code.py` | the same script, run with the uv Python |

The text of every note, PDF page, screenshot and speech clip is the macOS text (checked string for string against the
Swift sources), and the logbook and team notes use the same seeded generator, so they're the same pages.

### Eval numbers: comparable, not identical

- **Pictures and voices differ.** The photos show the same subjects (a zebra, a bald eagle, the Earth from space…), but
  they're other photos, and the speech is another voice. Image, video and audio queries can rank differently. The
  distractor pictures (cat, dog, dahlia, piano, sports balls…) are a best guess at the macOS set; there's no baseball.
- **Screenshots aren't screenshots on Linux.** macOS knows `synthetic/screenshots/shot_*.png` and
  `lang/*/wallet_failed_bn.png`, `payment_error_ar.png` as screenshots by their Spotlight attribute. DigUp's Linux build
  (`Platform/Portable/Files+Portable.swift`: `hasScreenshotMarker` is `false`) knows them by name only
  (`Rules.screenshotPrefixes`: "Screenshot", "Screen Shot", "CleanShot", "SCR-"), so those eight are indexed as
  **pictures** (photo budget, 1024 px instead of 1536 px, no "screenshot" kind boost). Only the two trap copies named
  `Screenshot 2026-…` are screenshots, and the one in `MyProject/` is what keeps it indexed inside a code project.
  The testbed keeps the eval paths, so it can't rename them. OCR is tesseract (see above): the exact queries on
  screenshots (`card_declined`, `INV-2041`, `K7Q2LM`, `externally-managed-environment`) match its words; the Bengali
  and Arabic screenshot queries need `tesseract-ocr-ben` / `-ara` installed (Bengali also named in `DIGUP_OCR_LANGS`).
- **PDF text layers.** fpdf2 makes them; DigUp reads them with PDFium. Arabic reads back exactly; Bengali reads
  garbled where a cluster takes several glyphs (a vowel sign drawn before its consonant, conjuncts), which is how macOS
  reads its WebKit-made Bengali PDFs too. Most whole words survive (`ধানমন্ডি` is found).
- The video's frames are the pictures cropped to fill 768×768 (macOS's are square and get stretched).
