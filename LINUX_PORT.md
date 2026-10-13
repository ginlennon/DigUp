# DigUp for Linux — goals and durable decisions (ginlennon fork)

This fork ports DigUp (semantic search over your own files with EmbeddingGemma 2 on llama.cpp) to **Ubuntu 24.04 on
GNOME/Wayland**, with the embedder running on an **AMD iGPU through llama.cpp's Vulkan backend**. The upstream
`README.md` carries a Linux-fork section at its top (user request, 2026-10-14) and upstream's text unchanged below
it, so a merge conflicts only there; this file is the port's "why".
Rarely changes. Status is in the README's Linux section, the plan in `PLANS/LINUX_PORT_PLAN.md`, the
evidence in `docs/linux-port/`.

## Goal
A Linux DigUp that a person on Ubuntu 24.04 GNOME can install, point at folders, and then search from a hotkey,
finding pictures, PDFs, documents, recordings and videos by meaning and by exact words, with search quality equal to
the Mac app (same model, same vectors), and indexing that uses the Radeon iGPU when it actually helps.

## Success bar
1. **Vectors are the Mac's vectors:** `ReferenceVectorTests` (cosine ≥ 0.999 vs the macOS reference) passes on Linux
   with the **CPU** backend *and* the **Vulkan** backend on the Radeon 860M. An index is then portable across machines.
2. **The embedder does not hurt the machine:** a full index pass of the testbed and of a real ~1 k-file folder on Vulkan
   with no `DeviceLost`, no desktop freeze, memory within the watchdog limits.
3. **Vulkan is the default only if it pays:** ≥ 1.5× CPU throughput on the indexing mix (text, image, audio) — else
   CPU is the default and Vulkan an option.
4. **Search quality parity:** `digup eval evals/synthetic.json` (+ multilingual, code) on Linux within noise of the Mac
   numbers for the same testbed (exact parity expected when (1) holds; differences then come from extractors —
   OCR, image decoding — and are reported per kind).
5. **Usable desktop app:** hotkey → panel with focus on GNOME Wayland, results open at the right page/moment where the
   default app allows, tray status, setup + minimal settings, survives logout/login (autostart), installable from one
   artifact.

## Durable decisions (2026-10-14; see PLANS for the reasoning)
- **Build on upstream's own port** (Platform/Portable + vendored C libs + Tauri `shell/`). Not a rewrite, not the
  conflicting community PR #6 (ideas may be harvested from it, e.g. LibreOffice for decks).
- **Do not port the SwiftUI app.** `Sources/DigUpApp` (macOS-only, ~9.7 k lines) is the *behaviour spec*; the Tauri
  shell re-creates what matters, and features are explicitly tiered keep / re-create / strip (PLANS §A4).
- **One codebase with upstream for now** (user, 2026-10-14): Mac code stays in the tree, never built on Linux. Later
  options kept open: a Linux-only packaging/branch ("middle way") or a hard Linux fork that deletes the Mac parts.
- **Embedder = LlamaRuntime in-process** with llama.cpp b11461 built `GGML_VULKAN` + CPU variants as runtime-loaded
  backend modules (upstream's design). No separate llama-server: DigUp needs mtmd image/audio embedding and its own
  prompts in-process. The reference-vector test is the correctness gate for every backend and every llama.cpp bump.
- **Stay mergeable with upstream:** Linux code in `Platform/Portable/*`, `#if os(Linux)` or `shell/`; small focused
  commits; anything generally useful offered upstream later (their CONTRIBUTING wants an issue first).
- **Toolchain:** Swift via swiftly (≥ 6.2), Rust via rustup, both user-level. Python only through **uv venvs on
  Python 3.13** (research/eval sidecars), never system Python.
- **No root assumptions at run time.** Anything needing `sudo apt` is either optional or listed in SETUP.md for the
  user to run once.

## Known hard constraints of the dev machine (from earlier projects on this laptop)
- RADV/860M: llama.cpp Vulkan context ≥ 16384 crashed the whole machine (DigUp uses ≤ 2048 — keep it so); a single
  Vulkan allocation is capped at 4 GB.
- GNOME 46: no GlobalShortcuts portal (arrives in GNOME 48); Wayland forbids global key grabs and app-chosen window
  positions, and focus-stealing prevention can refuse focus without an activation token.
- inotify budget 65,536 watches; a home folder can hold far more directories.
- Ubuntu's ffmpeg 6.1 can't read HEIC.
