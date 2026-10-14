<!-- ===== Linux fork section (ginlennon/DigUp-Linux). Upstream's README follows unchanged below the line. ===== -->

# DigUp for Linux (tested on Ubuntu 24.04): an unofficial port

This fork of [ARahim3/DigUp](https://github.com/ARahim3/DigUp) brings DigUp to **Linux**: Ubuntu 24.04 on GNOME and
Wayland, with the embedding model running on an **AMD iGPU through llama.cpp's Vulkan backend**. It builds on the
Linux groundwork upstream added in October 2026 (a portable engine and a Tauri shell) and finishes it into an app you
can use day to day. It's a work in progress: a developer build that you build from source, not a package yet.

Same model, same vectors as the Mac app. The reference-vector test that guards every upstream llama.cpp update
passes here on both the CPU and the Vulkan GPU, so an index means the same thing on both systems.

## Status (2026-10-14)

| Part | State on Linux |
|---|---|
| Engine and `digup` CLI (crawl, read, index, hybrid search) | ✅ builds with Swift 6.4.1; 96 engine + 8 runtime tests pass (shell: 44 Rust tests) |
| Embedder (EmbeddingGemma 2 on llama.cpp b11461) | ✅ Vulkan (AMD/Intel GPUs), CPU fallback (`DIGUP_GPU=0`); CUDA builds where `nvcc` is found |
| Pictures (JPEG, PNG, HEIC, AVIF, WebP, TIFF …), PDFs, docs (txt, md, rtf, docx, odt, html), audio, video | ✅ (stb, PDFium, a pinned ffmpeg 8.1) |
| Text in screenshots and scanned PDFs (OCR, for exact words) | ✅ tesseract (English + German here; more with language packs) |
| Desktop app: tray, setup, search panel, open, show in Files | ✅ Tauri shell; the hotkey is a GNOME custom shortcut (Ctrl+Alt+Space) |
| Open PDFs at the page (Evince, Okular), videos and recordings at the moment (Totem, VLC, mpv); settings window, pause, GPU switch, start at login | ✅ (PDF pages and VLC moments tried by hand) |
| Search inside folders (`in:Documents …`, `--in`), more like this (Ctrl+L, `digup similar`), `digup doctor` | ✅ |
| Code search in the app (`code:`, opens your editor at the line), Files right-click scripts | ✅ |
| Control from outside (`digup-shell --toggle/--pause/--resume/--quit …`), turn off, GPU→CPU fallback, helper restarts | ✅ new |
| MCP server (Claude Code, Cursor, VS Code, Zed) and a localhost HTTP API for RAG apps | ✅ [`integrations/`](integrations/README.md) |
| Install without the checkout: `scripts/linux/install-user.sh` (~/.local/opt/digup + app menu) | ✅ |
| Packages (.deb / AppImage), updates | ⏳ not yet |
| RAW photos, legacy .doc, SVG | ⏳ not yet |

## Tested on

| | |
|---|---|
| OS | Ubuntu 24.04.5 LTS, GNOME Shell 46 on Wayland, kernel 6.17 (OEM) |
| CPU | AMD Ryzen AI 7 PRO 350 (8 cores / 16 threads) |
| GPU | AMD Radeon 860M iGPU (RDNA 3.5, gfx1152), Mesa 25.2.8 RADV, Vulkan 1.4 |
| Memory | 54 GB (the iGPU shares it) |
| Toolchain | Swift 6.4.1 (swiftly), Rust 1.99, CMake 3.28, GCC 13.3 |

## Benchmarks

**Indexing speed, CPU vs Vulkan.** 116 generated files (`scripts/linux/make-bench-corpus.sh`), each folder
indexed into a fresh index (`scripts/linux/bench-embed.sh`), model load included. CPU = 8 threads (DigUp's default).

| Folder | Files | CPU | Vulkan (860M) | Speed-up |
|---|---|---|---|---|
| Audio (2 min each) | 6 | 42.2 s | 19.2 s | 2.2× |
| Text notes (~2,500 words) | 30 | 113.2 s | 40.8 s | 2.8× |
| PDFs (114 pages) | 6 | 85.1 s | 27.5 s | 3.1× |
| Photos | 40 | 52.5 s | 22.8 s | 2.3× |
| Screenshots | 30 | 94.8 s | 33.4 s | 2.8× |
| Video (1 min each) | 4 | 60.9 s | 21.1 s | 2.9× |
| **Total** | **116** | **448.7 s** | **164.8 s** | **2.7×** |

The GPU peaked at about 1.45 GB of (shared) memory, and every llama.cpp context stays at 2,048 tokens or less. In
real use, a first pass over 482 files in Documents, Pictures and Desktop took about 10 minutes on the 860M.

**Search quality.** `digup eval` on the Linux testbed (`scripts/linux/make-testbed.sh`: the eval files re-created
with free Wikimedia Commons photos and piper voices instead of Apple's sample pictures and voices, so the numbers are
comparable to the Mac's, not identical):

| Eval | Queries | R@1 | R@5 | MRR |
|---|---|---|---|---|
| synthetic (images, audio, video moments, PDF pages, screenshots, long files, exact strings) | 37 | 0.97 | 1.00 | 0.99 |
| multilingual (Bengali, Arabic, English, and across them) | 48 | 0.94 | 0.98 | 0.95 |
| code | 41 | 1.00 | 1.00 | 1.00 |

Details: [docs/linux-port/VULKAN_RESULTS.md](docs/linux-port/VULKAN_RESULTS.md),
[docs/linux-port/EVAL_RESULTS.md](docs/linux-port/EVAL_RESULTS.md).

## Set it up

**Guided:** `scripts/linux/setup.sh` walks through every step below. It checks what's already there, shows each
command before it runs it, and asks first (`--dry-run` only prints the plan). Nothing is installed without a yes.

**Supported:** Ubuntu 24.04 (other Debian/Ubuntu-based systems will likely work with the same packages). Other
distributions aren't supported by the scripts: the package list below is the map, and the rest of the steps are
the same everywhere.

**By hand**, on Ubuntu 24.04:

1. System packages (the only step that needs `sudo`):
   ```sh
   sudo apt install build-essential cmake ninja-build pkg-config git curl ca-certificates xz-utils bc \
     libz3-dev gnupg2 \
     libvulkan-dev glslc spirv-headers mesa-vulkan-drivers vulkan-tools \
     libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev libsoup-3.0-dev \
     libssl-dev patchelf \
     tesseract-ocr            # plus tesseract-ocr-<lang> for more OCR languages, e.g. tesseract-ocr-fra
   ```
   (The Vulkan line is for AMD and Intel GPUs. With an NVIDIA GPU and the CUDA toolkit installed, `nvcc` on PATH makes
   the build use CUDA instead. Without a GPU, DigUp runs on the CPU.)
2. Toolchains, in your home folder, no `sudo`:
   - **uv** (Python 3.13 for the eval testbed generator): `curl -LsSf https://astral.sh/uv/install.sh | sh`
   - **Swift 6.4.1** via [swiftly](https://swift.org/install/linux/) (don't `apt install swift`, that's OpenStack's):
     ```sh
     curl -O "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" && tar zxf swiftly-*.tar.gz
     ./swiftly init --quiet-shell-followup && . ~/.local/share/swiftly/env.sh && swiftly install --use 6.4.1
     ```
   - **Rust** via [rustup](https://rustup.rs): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --profile minimal`
3. Build (a few minutes; all of it lands in `Vendor/`, `.build/` and `shell/src-tauri/target/`):
   ```sh
   git clone https://github.com/ginlennon/DigUp-Linux && cd DigUp-Linux
   scripts/fetch-vendor.sh               # SQLite (FTS5), stb, miniz, PDFium
   scripts/linux/fetch-ffmpeg.sh         # a pinned static ffmpeg 8.1 (LGPL): Ubuntu's 6.1 can't read HEIC
   scripts/build-llama.sh                # llama.cpp b11461: Vulkan if glslc is there, CUDA if nvcc, else CPU
   swift build -c release --product digup && git checkout -- Package.resolved
   (cd shell/src-tauri && cargo build)
   .build/release/digup download-model   # the model, 865 MB, once (to ~/.local/share/digup/Models)
   ```
   (`swift build` on Linux drops `Package.resolved`, whose only pin is the Mac app's updater; the checkout puts it back.)

   To install it (optional): `scripts/linux/install-user.sh` puts DigUp in `~/.local/opt/digup` with an app-menu
   entry, no sudo, and offers to point the hotkey at it; `--uninstall` removes it again.
4. Run it and add the hotkey:
   ```sh
   scripts/linux/gnome-shortcut.sh       # Ctrl+Alt+Space opens the panel (GNOME custom shortcut)
   scripts/linux/dev-run-shell.sh        # first launch: pick folders, indexing starts
   ```

Optional check that your GPU makes the same vectors as the Mac:
`DIGUP_BACKENDS=$PWD/Vendor/llama/lib swift test --filter ReferenceVectorTests`.

## Using it

Ctrl+Alt+Space, describe what you're looking for, ↩ to open it at the page or moment. The
[user guide](docs/USER_GUIDE_LINUX.md) has 19 ways to use it, from screenshots of error messages to recordings,
languages, code and scripts.

## How it differs from the Mac app

- **The hotkey.** Wayland doesn't let apps grab keys globally, and GNOME 46 has no shortcut portal yet, so the hotkey
  is a GNOME custom shortcut that runs the shell again with `--toggle`; the running one shows its panel, or hides it.
  On other desktops, bind `scripts/linux/dev-run-shell.sh --toggle` to a key in their keyboard settings. The same
  way, `--show`, `--hide`, `--pause`, `--resume`, `--index-now`, `--settings` and `--quit` control a running DigUp
  from scripts (without one running, `--quit`/`--hide` just say so, and `--pause`/`--resume` apply at its next start).
- **The tray** needs an AppIndicator host. Ubuntu's GNOME has one built in; plain GNOME needs the AppIndicator
  extension.
- **OCR** is tesseract, not Apple's Vision: fine on clean screenshots, weaker on blurry text, and only in the
  languages whose packs are installed.
- **What it skips** besides upstream's rules: Trash, caches (`~/.cache`, `CACHEDIR.TAG` folders), `~/snap`,
  Flatpak data, and network or FUSE mounts reached from a chosen folder.
- Where things live: index `~/.local/share/digup/index`, model `~/.local/share/digup/Models`, settings
  `~/.config/com.abdurrahim.DigUp/settings.json`. Remove those to remove all of DigUp's data.

## For contributors

The port's design notes, plan and logs: [LINUX_PORT.md](LINUX_PORT.md) (goals and decisions),
[PLANS/LINUX_PORT_PLAN.md](PLANS/LINUX_PORT_PLAN.md), [docs/linux-port/](docs/linux-port/) (analysis, research,
results), [SETUP.md](SETUP.md), [scripts/linux/README.md](scripts/linux/README.md). Linux code lives in
`Sources/DigUpKit/Platform/Portable/`, `#if os(Linux)` branches, `shell/` and `scripts/linux/`, so upstream's changes
keep merging. DigUp itself is by Abdur Rahim ([ARahim3](https://github.com/ARahim3)), MIT; this fork keeps its licence.

---

<p align="center"><img src="docs/logo.png" width="96" alt=""></p>

<h1 align="center">DigUp</h1>

<p align="center"><b>Describe it. Dig it up.</b><br>
Search the files on your Mac by what's in them, with Google DeepMind's
<a href="https://huggingface.co/google/embeddinggemma-2">EmbeddingGemma 2</a>.</p>

<p align="center"><a href="https://github.com/ARahim3/DigUp/releases/latest"><b>Download for Mac</b></a> · Apple Silicon,
macOS 14 or later · Free and open source<br>
<sub>Windows and Linux versions are on the way.</sub></p>

<p align="center"><img src="docs/demo.gif" width="800" alt="DigUp's search panel finding a zebra in a video, a podcast moment, a clause in a lease, a dog on the beach in English, Bengali and Arabic, and code that opens in Zed"></p>

EmbeddingGemma 2 is the multimodal embedding model Google DeepMind released in October 2026. It puts text, images,
audio and video into one shared space: a photo of a dog on a beach lands next to the words "a dog on the beach", and a
recording of someone talking about sleep lands next to "where they talk about sleep". It understands more than 100
languages, it's open (Apache 2.0), and at 740M parameters it's small enough to run comfortably on a laptop.

DigUp brings that to the files on your Mac. Pick the folders to search, and it reads the pictures, PDFs, documents,
recordings and videos in them. Then describe what you're looking for, in your own words, and it finds the match,
whatever kind of file it is. All of it happens on your Mac.

## What you can find

- "zebra in a video" opens the clip at the moment the zebra shows up
- "where they talk about sleep" jumps to that minute of a podcast
- "the clause about pets in the lease" shows the PDF page, with the words marked
- "a dog on the beach" finds the photo, and "payment declined error" the screenshot
- a search in English can find a note written in Bengali, Arabic or any of the model's 100+ languages, and the other
  way around
- "code: retry a failed call with backoff" finds the function in your projects, if you turn on code search

Exact words count too. Invoice numbers, error codes and names are matched as written, in file names, document text
and the text inside screenshots, so a search gets both the meaning and the exact string.

## Private

Nothing you index leaves your Mac. DigUp goes online only to download the model once and to check for updates once a
day. The update check sends nothing about your files, and you can turn it off. No account, no telemetry.

## Install

1. Download the DMG from [Releases](https://github.com/ARahim3/DigUp/releases) and drag DigUp to Applications, or use
   Homebrew: `brew install --cask arahim3/tap/digup`.
2. Open it. While the model downloads (865 MB, once), pick the folders to search: whole folders, or only some of their
   subfolders. DigUp shows how long the first pass will take for each.
3. Press **⇧⌘Space** in any app and describe what you're looking for.

DigUp needs an Apple Silicon Mac with macOS 14 or later (it's tested on macOS 26), and it keeps itself up to date.

## Using it

| Key | What it does |
|---|---|
| ⇧⌘Space | Opens the search panel from any app (you can change it in Settings) |
| ↓ ↑ | Moves through the results |
| ↩ | Opens the result: videos and recordings at the moment, PDFs with your words in Preview's search, code in your editor at the line |
| Space | Quick Look, at the page or moment (once you've moved to a result) |
| ⌘↩ | Shows it in Finder |
| ⌘C | Copies the file, to paste anywhere |
| ⌘O | The same search in a bigger window, with a picture grid and filters |

DigUp lives in the menu bar, where you can see how indexing is going, pause it, or open Settings. The first time a
video opens at its moment, macOS asks whether DigUp may control QuickTime Player; that's how it jumps there.

## What it reads

Only the folders you choose:

- pictures and screenshots (HEIC, JPEG, PNG, RAW, WebP and more), by what they show, and screenshots by their text too
- PDFs, page by page, scans included. A long one gets its first 30 pages right away and the rest once everything
  else is in (up to 5,000 pages a file)
- documents: txt, md, rtf, doc, docx, odt, html, long ones the same way. Text that's mostly numbers, like a data
  export, is matched by its exact text only
- audio of any length: the model listens to 30 seconds at a time, so DigUp takes overlapping 30-second windows and a
  match points to its moment
- video of any length: a frame every few seconds, one per shot, plus the soundtrack the same way as audio

Outside the folders you pick for code search, it never reads code, and inside a code project (a folder with `.git`,
`package.json` and the like) it reads only screenshots. It never reads keys, certificates, password files, hidden
folders like `~/.ssh`, app bundles or caches. It skips folders that look like datasets, and never downloads iCloud
files that only live in the cloud. You can skip more folders or file types in Settings. DigUp only reads your files;
it never changes, moves or uploads them.

The first pass takes a few minutes for a few hundred files and can take an hour for a big Downloads folder. That
happens once, on battery too unless you tell it to wait for a charger, and it pauses in Low Power Mode. After that, a
new file is searchable a second or two after it lands.

## Code

EmbeddingGemma 2 reads code too, so DigUp can search your projects. Code search is off until you turn it on, in
Settings → Code or during setup, for the folders you pick. Each repo shows how long reading it takes and how much room
its index needs. Then start a search with `code:` and say what the code does, or type a name that's in it:

- "code: retry a failed call with backoff" finds the function, whatever it's called
- "code: refreshAccessToken" goes to the line that defines it, not the places that call it
- "code: plot how many examples each class has" finds the notebook cell

Results open in your editor at the line: Zed, VS Code, Cursor, Xcode, Sublime Text, JetBrains IDEs and a few more
(pick one in Settings). Code has an index of its own and never shows up in other searches. DigUp reads source files,
notebooks (without their outputs) and a repo's own docs. It skips what git ignores, vendored and generated code, data
files, and anything that looks like a key or a password. While you're working on code, the index catches up a minute
after things go quiet.

Reading code takes about 20 seconds for a small app, and about 20 minutes and 130 MB of index for all of llama.cpp.

## How it works

```
your folders ─► readers (ImageIO, PDFKit, AVFoundation, and Vision for the text in screenshots)
             ─► EmbeddingGemma 2 on llama.cpp (Metal), in a helper process that quits when it's done
             ─► one SQLite file: a vector for every picture, page, passage, video frame and 30 s of sound,
                plus a keyword index (code search keeps a second one, for code)
your words   ─► the same model's text part (~250 MB, only while you search) ─► nearest vectors + exact words
```

DigUp runs ggml-org's 8-bit build of EmbeddingGemma 2 through [llama.cpp](https://github.com/ggml-org/llama.cpp) on
the Mac's GPU. Every vector lives in the same 768-dimensional space, which is why one query can rank a video frame
against a PDF page. A search embeds your words in milliseconds and compares them with everything in the index.
Exact-word matches get a boost, because no embedding holds an invoice number exactly.

The index remembers which model version made its vectors. An update that leaves the vectors unchanged keeps your
index, and a test checks every llama.cpp update against stored reference vectors before it ships.

## Build from source

You'll need Xcode 26, git, and CMake (or `uv`) for llama.cpp. If `xcode-select -p` shows the Command Line Tools,
switch to Xcode first (`sudo xcode-select -s /Applications/Xcode.app`): they lack the SwiftUI and Swift Testing
macros the build needs.

```sh
git clone https://github.com/ARahim3/DigUp && cd DigUp
scripts/build-llama.sh            # llama.cpp at a pinned tag, with a one-line patch (a few minutes)
swift build -c release && swift test
./build.sh                        # → build.noindex/DigUp.app
```

There's also a command-line tool, `.build/release/digup`, that indexes, searches and runs the evals from the terminal
(`digup --help`). `scripts/make-testbed.sh` builds a folder of test files to try it on (it needs ffmpeg), and `evals/`
holds the queries ranking changes are measured with.

## FAQ

**How is this different from Spotlight?** Spotlight finds files by their names, text and metadata. DigUp also finds
them by what they show or say, and takes you to the page or moment. The two work fine side by side.

**Windows or Linux?** Both are on the way.

**Why is the download 865 MB?** That's the model: the text part (310 MB) and the image and audio encoders (555 MB).
The app itself is about 20 MB.

**Will it slow my Mac down?** Only the first pass is heavy. After that it reads new files only. The model runs in a
separate process that quits when it's done, and the search side only loads while you're searching.

**Which languages?** The model knows more than 100, and DigUp searches in all of them, across languages too. The evals
cover only English, Bengali and Arabic because those are the languages of the files DigUp was tested on, and Google
notes that the model isn't equally strong in every language. Two limits apply to exact words, not to meaning: inside
screenshots they're read by Apple's text recognition, which knows about 25 languages, and languages written without
spaces, like Chinese, Japanese and Thai, aren't split into words.

**How do I remove it?** Quit it, then delete DigUp.app and `~/Library/Application Support/DigUp`, which holds the
model and the indexes. Its settings are in `~/Library/Preferences/com.abdurrahim.DigUp.plist`. With Homebrew,
`brew uninstall --cask --zap digup` removes all of it.

## Support

DigUp is free and open source, and it stays that way. If it helps you and you'd like to support it, you can
[buy me a coffee](https://arahim3.gumroad.com/l/support).

## Thanks

DigUp is built on [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) by Google DeepMind (Apache 2.0),
[llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) and [Sparkle](https://sparkle-project.org) (MIT). Their
license notices ship inside the app, in `DigUp.app/Contents/Resources/Acknowledgements.txt`.

DigUp isn't affiliated with Google or Apple. Gemma is a trademark of Google LLC; Mac and Spotlight are trademarks of
Apple Inc.

## License

MIT
