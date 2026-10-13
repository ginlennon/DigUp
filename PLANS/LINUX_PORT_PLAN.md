# PLAN — DigUp on Ubuntu 24.04 (GNOME/Wayland) with a Vulkan embedder on the Radeon iGPU

**Status: PLAN ONLY — nothing below is implemented yet (2026-10-14).** Evidence: `docs/linux-port/ANALYSIS.md`
(code analysis), `docs/linux-port/LINUX_EQUIVALENTS.md` (macOS → Linux research, verified on the dev laptop). Goals
and success bar: `LINUX_PORT.md`.

---

# Part A — Conceptual design

## A1. Why this is smaller than it looks

The worry was "too much Mac-specific Swift". The analysis says: **the Mac-specific Swift is almost all in the app
layer, and we don't port it.**

| Layer | Size | Linux state | What we do |
|---|---|---|---|
| DigUpKit engine | ~5 k lines | builds on Linux via `Platform/Portable/*` (upstream, 2026-10-11) | verify; fill stubs (OCR, HEIC, SVG, skip rules) |
| LlamaRuntime | ~0.6 k | Linux path exists (shared llama.cpp, runtime backends) | build with **Vulkan**, prove vectors, measure |
| `digup` CLI + services | ~1.8 k | Linux path exists (ParentWatch, Watchdog `/proc`) | verify; small fixes (stale macOS texts, ffprobe errors) |
| DigUpApp (SwiftUI/AppKit/Sparkle/Carbon/QuickLook/AVKit/PDFKit) | ~9.7 k | macOS-only, never compiled on Linux | **not ported** — it's the behaviour spec |
| Tauri shell (Rust + JS) | ~2 k | skeleton: tray, hotkey, panel, setup, watcher | grow into the Linux app |

So the "re-create or strip" question applies to *app features*, not to engine code (§A4).

## A2. Target architecture on Linux

```
GNOME custom shortcut ──► digup-shell --toggle ──(single-instance)──► running digup-shell (Tauri 2, WebKitGTK)
                                                                         │ tray (AppIndicator) · panel · setup · settings
                                                                         │ JSON lines over stdio
                    ┌──────────────────────────┬─────────────────────────┼───────────────────────┐
             digup search-service       digup index-service       digup download-model     digup estimate
             (query encoder, text-only)  (nice 10; backfill on/off)
                    └──────────── DigUpKit (Portable) ────────────┘
                                      │ ffmpeg/ffprobe ≥ 8.1 (static, beside digup) · PDFium · stb · miniz · SQLite FTS5
                                      │ OCR: tesseract CLI → (if it pays) RapidOCR via ONNX Runtime
                                      ▼
                              LlamaRuntime ─► libllama/libmtmd/libggml*.so
                                              backends loaded at run time: libggml-cpu-*.so + libggml-vulkan.so (RADV)
```

## A3. The Vulkan embedder (the user's first priority for this machine)

- **What "the embedder" is here:** DigUp's `LlamaEmbedder` (in-process, text + mtmd image/audio) linked against
  llama.cpp **b11461 + no-logits patch**, built `-DGGML_VULKAN=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON`.
  `scripts/build-llama.sh` already selects Vulkan when `glslc` is on PATH (it is). We do **not** reuse
  `~/git/llama.cpp` (b10331: predates EmbeddingGemma 2, needs ≥ b11452) — DigUp's pinned build in `Vendor/` is
  separate and reproducible.
- **Safety envelope (this laptop's known RADV walls):** DigUp's largest context is 2048 (query encoder 512), far below
  the ctx ≥ 16384 crash; unknown is the mmproj warmup/encode graph at `image_max_tokens = 1120` and audio — run those
  first, alone, with work saved. Watch single allocations vs the 4 GB cap (`GGML_VK` debug log / `vulkaninfo`).
- **CPU/GPU switch:** today only `DIGUP_BACKENDS=<folder without libggml-vulkan.so>` forces CPU. Add a small explicit
  knob (`DIGUP_GPU=0` → `n_gpu_layers = 0` and skip non-CPU devices) so the shell can offer "use GPU" and fall back
  automatically after a Vulkan failure.
- **Correctness gate:** `ReferenceVectorTests` (≥ 0.999 cosine vs the macOS/Metal reference, 9 inputs incl. image and
  audio) must pass on CPU and on Vulkan. Earlier measurements put this iGPU's run-to-run noise at ~1.5e-4, comfortably inside.
- **Honest null hypothesis:** *Vulkan on the 860M is not meaningfully faster than 16-thread CPU for this 740 M-param
  Q8_0 model + 555 MB mmproj.* Prior data on this box: 3.5× for a 300 M model, only 1.8× for a 0.6 B q8_0 model — the
  win shrinks with size, and the mmproj vision/audio encoders are the unknown.
- **Decision rule:** Vulkan becomes the default iff (a) the gate passes, (b) ≥ 1.5× files/s on the testbed indexing
  mix, (c) a ≥ 1 h indexing run has no DeviceLost / desktop stall. Otherwise CPU default, Vulkan opt-in. Per-modality
  routing (e.g. vision on GPU, text on CPU) only if the numbers clearly split.

## A4. Feature triage — keep / re-create / strip

Tiers: **MVP** = needed for a usable first Linux release; **v2** = after MVP; **strip** = deliberately not done
(revisit only on demand).

| Feature (Mac app) | Linux route | Tier |
|---|---|---|
| Hybrid search (keyword instantly, meaning after 120 ms) | search-service (exists) | MVP (exists) |
| Model download (865 MB, resume, sha256) | `digup download-model` (exists) | MVP (exists) |
| Setup: folders + estimates | setup window (exists, partial) | MVP |
| Tray status + Pause/Resume, Index now, Quit | Tauri tray (exists) + `backfill off`/stop | MVP |
| Global hotkey | GNOME custom keybinding (gsettings, set by setup) → `digup-shell --toggle`; Tauri global-shortcut kept for X11 sessions; GlobalShortcuts portal when GNOME ≥ 48 | MVP |
| Panel focus/position on Wayland | spike: forward `XDG_ACTIVATION_TOKEN` via single-instance; else re-create the window per show; centered is acceptable | MVP |
| Open result / reveal | xdg-open / `FileManager1.ShowItems` | MVP (exists; verify) |
| PDF at page + search terms | Evince `-i N -l terms` / Okular `-p N --find` per default handler | MVP |
| Video/audio at moment | VLC `--start-time`, mpv `--start`, Celluloid `--mpv-start`; Totem → open + MPRIS seek; else plain open (in-panel player as preview) | MVP |
| Watchdog exit 75 → restart (≤ 3 / 10 min) | shell helper.rs | MVP |
| Autostart at login | `~/.config/autostart/digup.desktop` (Tauri autostart plugin) | MVP |
| Settings: folders, skipped folders/types, hotkey (writes the GNOME binding), GPU on/off | new settings window | MVP |
| Folder watching | inotify with a watch budget (count dirs first), periodic rescan fallback | MVP |
| Screenshot + scanned-PDF OCR (keyword text) | tesseract CLI first; RapidOCR if it pays (A5) | MVP (tesseract) / v2 (RapidOCR) |
| HEIC / AVIF / WebP rotation | static ffmpeg ≥ 8.1 beside `digup` (engine already looks there) | MVP |
| Linux skip rules (Trash, ~/.cache, ~/snap, ~/.var/app, FUSE/network mounts, CACHEDIR.TAG) | Rules.swift Linux branch | MVP |
| Copy file (Ctrl+C) | GTK clipboard: `x-special/gnome-copied-files` + `text/uri-list` + text | v2 |
| Code search (`code:`), code folders, editor at line | pass `--code-root`; editor table (`code -g`, `zed f:l`, `subl f:l`, geany `--line`, JetBrains `--line`) | v2 |
| Search window (grid, kind filters, Ctrl+O) | second Tauri window reusing panel JS | v2 |
| Power policy (battery, power-saver profile) | UPower `OnBattery`, power-profiles-daemon → `backfill off` | v2 |
| Index only at set hours | shell timer | v2 (cheap) |
| SVG pictures | `rsvg-convert` subprocess (re-read hook exists) | v2 |
| Speed calibration for estimates | Vulkan/CPU micro-benchmark replacing the Metal one | v2 |
| Updates | none in MVP; v2: GitHub-release check + notify; AppImage + Tauri updater only if we ship AppImage | strip → v2 |
| Quick Look panel | in-panel preview is enough; GNOME Sushi via D-Bus if installed | strip (optional v2) |
| Drag result out | webview `text/uri-list` drag | strip |
| RAW photos, legacy .doc | libraw / LibreOffice (heavy deps) | strip |
| Volume mount/unmount handling | next sync handles it | strip |
| Hotkey conflict detection | read GNOME keybindings via gsettings | strip (warn on known ones only) |
| iCloud placeholder logic, Time Machine exclusion, Spotlight `.noindex` | n/a | strip |
| Sparkle, MLX Python reference worker | Apple-only | strip |

## A5. OCR decision (Vision replacement)

- Measured on a synthetic 1440×900 screenshot (research, 2026-10-14): clean text — tesseract and RapidOCR both 1.00
  word recall (0.28 s vs 0.43 s); degraded (blur, 0.55× scale, rotation, JPEG) — tesseract 0.23, RapidOCR 0.65.
- Plan: (1) ship tesseract via subprocess (`tesseract img - tsv`), same pattern as ffmpeg, behind an `OCR` backend
  interface in `Platform/Portable`; language list from settings (installed traineddata). (2) Evaluate RapidOCR on the
  testbed's real screenshots + scanned PDFs through a **uv/Python 3.13 sidecar** (fast to try, no C++). (3) Port to
  ONNX Runtime C API only if it pays.
- **Decision rule:** RapidOCR replaces tesseract iff it improves keyword-search hit rate on screenshot/scan queries by
  ≥ 10 points at ≤ 2× OCR time. Null hypothesis: real screenshots are clean, tesseract is enough. Bengali needs
  tesseract either way.

## A6. Evaluation

- Unit: `swift test` on Linux (expect HEIC/WebP/TIFF image tests to need ffmpeg ≥ 8.1; record which skip).
- Vectors: `ReferenceVectorTests` × {CPU, Vulkan}.
- Retrieval: `scripts/make-testbed.sh` → `digup index` → `digup eval evals/{synthetic,multilingual,code}.json`;
  report R@1/5/10 + MRR per backend and per kind; compare to the Mac app (ask upstream for reference numbers, or treat
  Linux-CPU as baseline). Note: make-testbed uses Swift scripts that may rely on AppKit (`make_*.swift`) — check in
  Stage 1; fall back to Python (uv, 3.13) generators if needed.
- Throughput: files/s and s/segment per modality (text chunk, photo, screenshot, PDF page, 30 s audio, video frame),
  CPU vs Vulkan; peak RSS + GPU memory (`amdgpu_top` or `/sys/class/drm/card1/device/mem_info_gtt_used`).
- Desktop: hotkey→focused panel latency, first-search latency, behaviour across suspend/resume (this laptop's amdgpu
  suspend history makes this worth a check).

## A7. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Vulkan mmproj encode hangs/crashes RADV (gfx1152 bugs, issue #24861 class) | medium | first runs alone, work saved; `DIGUP_GPU=0` fallback; CPU default if flaky |
| Vulkan vectors drift > 1e-3 | low–medium | gate test; if only one modality drifts, route it to CPU |
| Wayland focus refusal makes the hotkey panel useless | medium | activation-token forwarding; re-create window; XWayland as last resort |
| No tray on vanilla GNOME | low here (Ubuntu ext. enabled) | panel/hotkey still work; launcher entry opens settings |
| inotify exhaustion on big trees | high for $HOME | budget + rescan fallback; warn in settings |
| Swift on Linux Foundation differences (enumerator flags, Unicode, regex) | medium | tests + testbed; fix in Portable layer |
| Disk (34 GB free) | medium | build artefacts in one place, clean llama build dir after install |
| Upstream moves fast (many open PRs) | high | rebase/merge upstream weekly; keep our diff small and Linux-scoped |

---

# Part B — Staged implementation (each stage ends with a check and a WORKLOG entry)

Coding is delegated to Opus subagents with self-contained prompts and reviewed in the main loop; commits stay small
and Linux-scoped.

### Stage 0 — Toolchain & safety baseline (user + agent, ~1 h)
- User: `sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev
  libsoup-3.0-dev patchelf ninja-build` (+ optional `tesseract-ocr-{ara,ben,fra,ita,…}`, `mpv`).
- Agent: swiftly → Swift 6.2.x (or newest 6.x that builds); rustup stable; record versions in SETUP.md.
- `df -h /home` ≥ 15 GB free before continuing.
- **Check:** `swift --version`, `cargo --version`, `glslc --version`.

### Stage 1 — Engine + CLI on Ubuntu, CPU first
```sh
scripts/fetch-vendor.sh && scripts/build-llama.sh          # builds Vulkan + CPU variants (glslc present)
swift build -c release --product digup && swift test 2>&1 | tee .dev/test-linux.log
DIGUP_BACKENDS=Vendor/llama/cpu-only .build/release/digup download-model
DIGUP_BACKENDS=Vendor/llama/cpu-only swift test --filter ReferenceVectorTests
```
(`Vendor/llama/cpu-only` = a folder of symlinks to the `libggml-cpu-*.so` only.)
- Fix build breaks in Portable code; record failing/skipped tests with reasons.
- Testbed: `scripts/make-testbed.sh` (port generators if AppKit-bound); `digup index` + `digup eval` on CPU.
- **Check:** all non-media tests green; reference vectors pass on CPU; eval numbers recorded.

### Stage 2 — The Vulkan embedder on the 860M
- First Vulkan run = `ReferenceVectorTests` alone (work saved, nothing else on the GPU). Then text-only, then image
  @140/280/1120, then audio.
- Add `DIGUP_GPU=0|1` (LlamaEmbedder: `n_gpu_layers`, device filter) + log the chosen device at startup.
- Benchmark per modality CPU vs Vulkan (script under `scripts/linux/bench-embed.sh`, results in
  `docs/linux-port/VULKAN_RESULTS.md`), 1 h soak index run.
- Apply A3's decision rule; write it down.
- **Check:** gate passes on Vulkan; decision recorded with numbers.

### Stage 3 — Engine gaps that affect search quality
1. Static ffmpeg ≥ 8.1 (BtbN/johnvansickle build, pinned + sha256, fetched by a `scripts/linux/fetch-ffmpeg.sh`) placed
   beside `digup` / via `DIGUP_FFMPEG`; image tests go green.
2. Missing ffprobe/ffmpeg → explicit error event instead of "silent" (Media+Portable.swift).
3. OCR backend: tesseract subprocess (TSV → words/lines), `OCR.isAvailable` true when found; scanned-PDF pages via
   PDFium render → OCR; `readAgainOnce` re-queues old entries. Then the RapidOCR sidecar evaluation (A5).
4. Linux skip rules: Trash, `~/.cache`, `~/snap`, `~/.var/app`, `CACHEDIR.TAG`, FUSE/network mounts (via
   `/proc/self/mountinfo`), case-insensitive screenshot prefixes incl. GNOME's "Screenshot from …".
5. Stale macOS strings in the CLI (usage paths, "privacy settings").
- **Check:** tests + eval rerun; screenshot/scan keyword queries now hit.

### Stage 4 — Shell MVP on GNOME/Wayland
1. Build & run `shell/` against the Stage-1 binary and the testbed (`cargo run -- --helper … --index … --roots …`).
2. Spikes first (½ day): (a) tray via AppIndicator; (b) `digup-shell --toggle` + GNOME custom keybinding written via
   gsettings (append, don't overwrite), default **Ctrl+Alt+Space** (free in GNOME; Ctrl+Shift+Space clashes with app
   shortcuts — user to confirm); (c) panel focus with activation-token forwarding vs window re-creation.
3. Helper robustness: exit-75 restart policy, `--prune`, pass `--code-root` later.
4. Openers: per-default-handler table for PDF page/search and media moment (Evince, Okular, VLC, mpv, Celluloid,
   Totem+MPRIS); reveal via FileManager1.
5. Settings window (folders, skips, types, hotkey, GPU on/off, autostart, pause) + autostart `.desktop`.
6. Watcher budget (count dirs, cap at e.g. 50 % of `max_user_watches`, else periodic rescan).
- **Check:** hotkey → focused panel → search → open PDF at page / video at moment, on Wayland, from a cold login.

### Stage 5 — Packaging & install
- Release build: `swift build -c release --static-swift-stdlib`; drop absolute `Vendor/` rpaths (keep `$ORIGIN`).
- Layout: `digup-shell` + `helper/{digup, libllama*.so, libmtmd*.so, libggml*.so (cpu variants + vulkan),
  libpdfium.so, ffmpeg, ffprobe}`; Vulkan loader + Mesa from the host, never bundled.
- First artifact: `scripts/linux/install-user.sh` → `~/.local/opt/digup` + `.desktop` + icon (no root). Then Tauri
  `.deb` (and AppImage if updates are wanted), built on the oldest supported Ubuntu (22.04 container or CI).
- **Check:** fresh user account (or `HOME=` sandbox) install → setup → search works.

### Stage 6 — v2 features (pick by use)
Code search + editors; copy file; search window; power policy; index hours; SVG; speed calibration; update check;
RapidOCR port (if A5 says so); GitHub Actions Linux CI (build + `swift test` + vector gate on CPU).

### Ordering rationale
Stages 1–2 de-risk the two things that can sink the port (Swift-on-Linux engine behaviour, Vulkan on RADV) before any
UI work. Stage 3 before 4 because search quality is the product; the shell is a client of a working CLI and can be
developed against `digup search` output at any time.
