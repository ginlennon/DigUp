# DigUp → Linux: code analysis (2026-10-13/14)

Snapshot of upstream `ARahim3/DigUp` at **f9b8106** (0.6.1 + 2 doc commits, 2026-10-12). Written for the Linux port in
the `ginlennon/DigUp` fork. Plan built on this: `PLANS/LINUX_PORT_PLAN.md`. Linux-equivalents research:
`docs/linux-port/LINUX_EQUIVALENTS.md`.

## 0. The one-paragraph answer

DigUp is ~15 k lines of Swift in four layers: **DigUpKit** (engine: crawl, extract, index in SQLite+FTS5, hybrid
search), **LlamaRuntime** (EmbeddingGemma 2 on llama.cpp, text + image + audio in one 768-d space), the **`digup` CLI**
(dev tool *and* the long-running helper processes), and **DigUpApp** (9.7 k lines of SwiftUI/AppKit, macOS only).
Upstream started the port itself on 2026-10-11/12: the engine and CLI **already build on Linux** (portable C libraries
instead of Apple frameworks, llama.cpp as shared libraries whose GPU backend — CUDA, **Vulkan** or CPU — loads at run
time), and a **Tauri shell** (`shell/`, Rust + HTML/JS, ~2 k lines) is the intended Linux/Windows UI. Nothing in the
repo records a Linux *run* (no CI, no Linux test results, README says "on the way"). So the port is: **(1) build and
verify the engine on Ubuntu with the Vulkan backend on the 860M, (2) fill the engine stubs that matter (OCR first),
(3) grow the Tauri shell from skeleton to a usable app on GNOME/Wayland, (4) package it.** The Mac-only Swift app is
not ported; its behaviour is the spec the shell re-creates, with deliberate cuts.

## 1. Architecture as found

```
DigUpApp (macOS only, SwiftUI/AppKit/Sparkle)        shell/ (Tauri 2: Rust + webview UI) — Linux/Windows target
   │ in-process: IndexStore + Searcher                 │ everything via helper processes (JSON lines on stdio)
   │ subprocess: digup index-service / worker / estimate│ digup search-service / index-service / download-model / estimate
   ▼                                                   ▼
digup CLI  ──────────────►  DigUpKit (engine)  ──────►  LlamaRuntime (llama.cpp + mtmd, EmbeddingGemma 2 Q8_0)
                             Platform/Apple/*  (macOS)     Linux: libllama/libmtmd/libggml*.so, backends loaded
                             Platform/Portable/* (Linux,    at run time (GGML_BACKEND_DL): cpu-variants + vulkan
                             Windows): stb, PDFium, miniz,
                             vendored SQLite+FTS5, ffmpeg/ffprobe via Process
```

Build pieces for Linux (Package.swift): targets `CSQLite`, `CStb`, `CMiniz`, `CPDFium` (from `Vendor/`, fetched by
`scripts/fetch-vendor.sh`), `CLlamaShared` module map, rpath `$ORIGIN` + `Vendor/llama/lib` + `Vendor/pdfium/lib`.
`scripts/build-llama.sh`: llama.cpp **b11461** (commit `4d756bc7…`) + `llama.cpp-no-logits.patch`; on Linux picks
CUDA if `nvcc`, else **Vulkan if `glslc`** (present here), else CPU; `-DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON
-DBUILD_SHARED_LIBS=ON`.

## 2. Embedder (LlamaRuntime) — the Vulkan question

- Backend loading (non-macOS): `ggml_backend_load_all_from_path($DIGUP_BACKENDS)`, then the executable's folder,
  stop at the first folder yielding a device; fallback `ggml_backend_load_all()` (LlamaEmbedder.swift:317-351).
- `n_gpu_layers = 999`; **no switch to force CPU** except pointing `DIGUP_BACKENDS` at a folder without the Vulkan
  module (all modules in a folder are loaded).
- Sizes: `n_ctx = n_batch = n_ubatch = 2048` (512 text-only query encoder), `n_seq_max = 16`, unified KV, mean
  pooling, L2-normalised in Swift. Image budgets 70–1120 tokens (photo 140, screenshot 280, page 280, frame 70);
  `image_max_tokens = 1120`, mtmd warmup on. Audio cut to 30 s at 16 kHz. Threads `DIGUP_THREADS` or min(cores, 8).
- **GPU safety on this laptop:** our known RADV walls are ctx ≥ 16384 (machine crash) and 4 GB per allocation.
  DigUp never exceeds ctx 2048 → expected safe; the mmproj warmup at 1120 image tokens is the largest single graph —
  unmeasured on RADV, test it first with work saved.
- Prompts: query `task: search result | query: …`, code query `task: code retrieval | query: …`, document
  `title: … | text: …` (Model.swift:89-100). (Our Dense-layer trap from EmbeddingGemma-300m does not apply: DigUp uses
  ggml-org's official EG2 GGUFs and has reference vectors to prove it.)
- **Correctness gate exists:** `ReferenceVectorTests` embeds 5 texts + screenshot@280 + photo@140/@70 + speech.wav
  and requires cosine ≥ 0.999 vs `Tests/LlamaRuntimeTests/Reference/vectors.json` (made on macOS/Metal). Runs only when
  both GGUFs are present. Not platform-gated → it is *the* Vulkan acceptance test. A community port (upstream PR #6)
  reported it passing on Linux **CPU**; Vulkan is unrecorded.
- Model: `ggml-org/embeddinggemma-2-GGUF` @ `bfcd2987…`: `embeddinggemma-2-Q8_0.gguf` (309,855,456 B) +
  `mmproj-embeddinggemma-2-Q8_0.gguf` (554,821,024 B), sha256-pinned. F16 unusable (activations overflow). Linux
  lookup: `$DIGUP_MODELS` exclusively, else `~/.local/share/digup/Models`, else the HF cache snapshot.
  `digup download-model` fetches with resume + sha256. Not yet in this machine's HF cache.
- **No-logits patch, verified by the llama.cpp session (2026-10-14):** gemma-embedding2 has no LM head (`model.output`
  is the 512→768 projection; graph sets only `t_embd`), so no vocab-sized GPU buffer. The only waste at b11461 is the
  host logits buffer (`has_logits = true` hardcoded, llama-context.cpp:2136 @4d756bc7): 262144 × n_outputs × 4 B =
  2 GiB at n_ubatch 2048, 512 MiB for the 512-token query encoder. DigUp's patch removes it. **From b11584 (#30255)
  upstream does `has_logits = !embeddings || graph_has_logits` → retire the patch when bumping the pin ≥ b11584.**
  Caution: `build-llama.sh` applies the patch only if `git apply --check` passes, so after a bump it is skipped
  silently — check the RSS/allocation instead of assuming.
- `worker/` (Python) is the **MLX** bf16 reference worker — Apple Silicon only, irrelevant for Linux.

## 3. Engine (DigUpKit) on Linux: capability matrix

| Capability | Linux implementation | Status |
|---|---|---|
| Classify / lstat metadata / git for code | extension sets, `lstat`, `git` on PATH | complete |
| JPEG/PNG/BMP/GIF/PSD/TGA/PNM | stb + own EXIF parser (orientation, date) | complete |
| HEIC/HEIF/WebP/TIFF/AVIF | `ffmpeg` subprocess → PPM | **partial: HEIC needs ffmpeg ≥ 8.1; Ubuntu 24.04 ships 6.1** (also WebP/TIFF rotation) |
| RAW | refused ("not read on this system yet") | stub |
| SVG | `drawsVectorPictures = false` | stub (re-read hook exists) |
| Screenshot OCR (keyword text in images) | `OCR.isAvailable = false` | **stub — biggest functional gap** |
| PDF text / render / page count | PDFium (bblanchon prebuilt) | complete |
| Scanned PDF page OCR | none (picture vector only) | stub (re-read hook `IndexStore.readAgainOnce` exists) |
| docx/odt | miniz + XML strip | complete (text) |
| rtf | hand-written reader (cp1252) | mostly complete |
| legacy .doc | throws → `failed` | stub |
| txt/md/html | shared code | complete |
| Audio → 16 kHz windows | ffmpeg + ffprobe | complete (**missing ffprobe ⇒ silently "silent"**) |
| Video frames / shots / soundtrack | one ffmpeg pass, average-hash dedup | complete (timestamps computed, approximate) |
| Preview renders | PDFium / ffmpeg / stb → JPEG in `<index>/previews` | complete |
| SHA-256, vector math, mmap vectors | pure Swift / SIMD | complete |
| Speed calibration | `Speed.measure() = nil` | stub (estimates use M4-Pro costs until measured) |
| Screenshot detection | file-name prefixes only, case-sensitive | partial |
| Cloud placeholders (iCloud) | `false` | n/a on Linux (rclone/Nextcloud/gvfs not detected) |
| Power/battery policy | not in engine (app's job; index-service has `backfill on/off`) | absent |

Linux skip-rule gaps (Rules.swift): only `~/Library` and `*.noindex` are special; dot-dirs rely on hidden-file
skipping (unverified on swift-corelibs-foundation); `~/snap`, Flatpak/Steam data, network/FUSE mounts are not skipped.
Stale macOS text: CLI usage says `~/Library/Application Support` (main.swift:50); "can't read" mentions macOS privacy
settings (main.swift:120, :229). FileFetcher: `waitsForConnectivity` is Darwin-only (offline → retry loop).

Linux data paths: index `~/.local/share/digup/index/{index.sqlite,code.sqlite,…}`, models
`~/.local/share/digup/Models`, scratch `$TMPDIR/DigUp-<pid>`. Shell settings
`~/.config/com.abdurrahim.DigUp/settings.json`.

Tests that won't pass/run as-is on Ubuntu: `ImageTests.preparedAsShown` / `smallPicturesAreSkipped` (unguarded; need
ffmpeg ≥ 8.1 for HEIC/WebP/TIFF/AVIF); Vision/AppKit-gated tests skip; `ReferenceVectorTests` needs the model.
No tests at all for docx/odt/rtf, audio/video extraction or previews (any platform).

## 4. The helper contract (what any Linux UI speaks)

All helpers: **JSON lines over stdin/stdout**, stderr = log. `ParentWatch` exits a helper when its parent dies
(Linux: polls `getppid()` 1 s). Watchdog: RSS from `/proc/self/statm` (GPU memory likely not counted), default
limit min(8 GB, max(4 GB, RAM/2)), 15 min/file; trips → `<index>/stopped-file.json`, **exit 75**.

- `digup search-service [--index] <roots> [--code-root …] [--exclude …] [--exclude-ext …] [--encoder-idle 300]`
  → first `{"event":"ready","index":…}`. Requests `{id, op, …}`: `search {q, code, kinds[], limit, meaning,
  prefix_last}` → `{hits[], strong, meaning, ms, warning?}`; `embed_ahead`; `text {segment, code}`;
  `render {path, kind:pdf|video|image, loc, pixels}` → `{image: <index>/previews/<uuid>.jpg}` (≤2 concurrent,
  out-of-order); `reload`; `folders {roots, skipped, types, code_roots, code_skipped}`; `prewarm`; `status`; `quit`.
  Hit fields: `path, kind, segment, segment_id, score, modified, size, info` + optional `z, cosine, keyword_rank, loc,
  loc_end, focus, excerpt`. Encoder events `{"event":"encoder","state":ready|unavailable|stopped}`; lazy text-only
  encoder, idles out after 300 s.
- `digup index-service [--index] [--backfill] [--prune] [--exclude…] [--exclude-ext…] [--code-root…]
  [--code-exclude…] [--memory-limit] [--time-limit] [--new-limit 50] [--linger 60] <roots>` — stdin **plain text**:
  `sync`, `sync code`, `backfill on|off`, `stop`; events `stopped, rescan, pruned, reindex, missing, sync, file,
  summary, rest, waiting{for:model} (then exits), idle, error, exit` + counts (`files, searchable, pending, vectors,
  unfinished, code_*`). Lingers 60 s warm after `idle`, then exits.
- `digup download-model [--to DIR]` → `file, progress{all_bytes, all_total…}, waiting, verifying, retry, done, error`.
- `digup estimate <folders> --json` → one line per folder (counts by kind, seconds, subfolders ≤500, bytes…).
- `digup worker [--text-only]` (Mac app's query encoder; the shell uses search-service instead).

## 5. The Tauri shell as found (`shell/`, Tauri 2.12)

Has: single instance (2nd launch → show panel), tray (status line, Search…, Choose Folders…, Index Now, Quit), global
shortcut via `tauri-plugin-global-shortcut` (default Ctrl+Shift+Space), borderless always-on-top panel (780 px,
grows to 640), setup window (offered XDG folders + picker, estimates, model download state), inotify watcher (2 s
debounce → index run), helper lifecycle with `nice(10)` for background helpers, asset-protocol scoping for previews,
debug flags (`--debug-query`, `--debug-setup`, …). Panel JS: keyword-then-meaning search on typing, grouped results,
thumbnails/previews via `render`, ↑↓ ↩ Esc, open = default app, reveal.

Missing vs the Mac app (see §6): settings window (hotkey, skips, battery, hours, code), pause/resume, power policy,
index hours, code search (`--code-root` never passed; no `code:` UI path to code folders), open-at-moment (video/audio
time, PDF page+search, code at line in editor), Quick Look, copy file, drag-out, search window (grid, filters), exit-75
restart, `--prune`, volume mount handling, autostart, updates, `Use Files…` for the model.

## 6. Mac app features → Linux decision input

The Mac app (Sources/DigUpApp, 9.7 k lines) is the behaviour spec. Full inventory distilled:

| Area | Mac mechanism | Linux route | Proposed tier |
|---|---|---|---|
| Global hotkey ⇧⌘Space | Carbon RegisterEventHotKey | **Wayland: no global grabs.** GNOME 46 has no GlobalShortcuts portal (verify) → GNOME custom keybinding (gsettings) running `digup-shell` (single-instance → toggle panel); portal when GNOME ≥ 48 | MVP |
| Tray status item + menu | NSStatusItem | Tauri tray (libayatana-appindicator; Ubuntu's AppIndicator extension) | MVP (exists) |
| Floating panel, fade, pointer screen | NSPanel | Tauri undecorated window; Wayland ignores positioning & may refuse focus → test; XWayland fallback | MVP (exists, verify) |
| Keyword-then-meaning typing | Engine in-process | search-service (exists) | MVP (exists) |
| Open default app / reveal | NSWorkspace | xdg-open / FileManager1 D-Bus | MVP (exists) |
| Open video/audio at moment | QuickTime AppleScript / IINA URL | mpv `--start=` / VLC `--start-time=` when default or installed, else plain open | MVP+ |
| PDF at page with search | Preview AppleEvent | Evince/Papers `--page-index --find`, Okular `-p --find` | MVP+ |
| Code at line | editor URL schemes/CLIs | `code -g f:l`, `zed f:l`, `subl f:l`, JetBrains `--line` | with code search |
| Quick Look (Space) | QLPreviewPanel | in-panel preview (exists) + optional GNOME Sushi | later / optional |
| Copy file ⌘C, drag out | NSPasteboard / NSDragging | wl-copy `text/uri-list` + `x-special/gnome-copied-files`; webview drag | later |
| Search window (grid, filters, ⌘O) | SwiftUI | second Tauri window reusing panel JS | later |
| Onboarding (folders, subfolders, estimates, code, shortcut, ready) | SwiftUI | setup window (partially exists) | MVP (folders+model), rest later |
| Settings (General/Folders/Code/Storage) | SwiftUI | new settings window | MVP (folders, skips, hotkey help, pause); rest later |
| Pause / resume | stop helper | `backfill off` / stop index-service | MVP |
| Power policy (battery, Low Power, thermal) | IOKit / ProcessInfo | UPower `OnBattery`, power-profiles-daemon `power-saver` → `backfill off` | later |
| Index hours | Timer | shell timer | later (cheap) |
| Code search | codeRoots → `--code-root` | settings + pass flags | later (phase 2) |
| Launch at login | SMAppService | `~/.config/autostart/*.desktop` | MVP (cheap) |
| Volume mount/unmount | NSWorkspace | gio/udisks2 | strip (re-sync on next run is enough) |
| Updates | Sparkle (EdDSA appcast) | none at first; GitHub-release check later; distro packaging | strip for now |
| Model download + Use Files… | URLSession / FileFetcher | `digup download-model` (exists); Use Files… | MVP (download), later (Use Files) |
| Hotkey conflict check | CopySymbolicHotKeys | gsettings read of GNOME bindings | later |
| Watchdog restart (exit 75, ≤3/10 min) | Engine | shell helper.rs | MVP (correctness) |
