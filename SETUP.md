# SETUP — DigUp Linux port (ginlennon fork)

How to operate this fork on the dev laptop. The upstream README's "Build from source" is macOS-only; this file is the
Linux counterpart. Durable goals/decisions: `LINUX_PORT.md`. Plan: `PLANS/LINUX_PORT_PLAN.md`.

## Machine
- **The dev laptop**: Ubuntu 24.04.5, GNOME Shell 46 on **Wayland**, AMD Ryzen AI 7 PRO 350 (16 threads),
  54 GB RAM, **Radeon 860M iGPU (RADV gfx1152, Vulkan 1.4, Mesa 25.2.8)**, XDNA2 NPU (not used here).
- **Disk: /home had 34 GB free (93 %) on 2026-10-13.** Budget ≈ 8–10 GB for toolchains + builds + model. Check `df -h /home` before big builds.
- GPU safety (learned on this laptop in earlier work): llama.cpp Vulkan **ctx ≥ 16384 → vk::DeviceLost crashed the whole
  machine**; RADV caps a single allocation at **4 GB**. Save work before the first GPU run of any new build.
- No passwordless sudo: every `apt install` below is for the user to run (`! sudo apt install …`).

## Git
- `origin` = `git@github.com:ginlennon/DigUp-Linux.git` (the fork, renamed from DigUp on 2026-10-14; PUBLIC — GitHub forks of public repos can't be private).
- `upstream` = `https://github.com/ARahim3/DigUp.git`. Sync: `git fetch upstream && git merge upstream/main`.
- Repo-local identity: `ginlennon <580583+ginlennon@users.noreply.github.com>` — never the global (work) identity.

## Toolchain status (2026-10-14) — guided install for others: `scripts/linux/setup.sh`
| Need | Status here | Install |
|---|---|---|
| Swift ≥ 6.2 (Package.swift tools-version 6.2) | **6.4.1** via swiftly 1.2.0 (adds a line to ~/.zprofile) | swiftly, user-level: see below |
| Rust (Tauri 2.12) | **1.99.0** via rustup (`~/.cargo/bin`, profile untouched) | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` (user-level) |
| cmake / gcc | cmake 3.28, gcc 13.3 | — |
| ninja | installed | `sudo apt install ninja-build` |
| Vulkan build deps | glslc, libvulkan-dev, spirv-headers present | — |
| Tauri Linux deps | installed (2026-10-14) | `sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev libsoup-3.0-dev patchelf` |
| ffmpeg / ffprobe | apt 6.1.1 can't read HEIC → `scripts/linux/fetch-ffmpeg.sh` (8.1.3 LGPL in Vendor/ffmpeg, found automatically by dev builds) | — |
| tesseract | 5.3.4 CLI, eng+deu+osd (used as a subprocess for OCR) | `tesseract-ocr-<lang>` for more languages |
| whisper.cpp (optional: transcripts, off by default) | `whisper-cli` v1.9.5, static, Vulkan → `Vendor/whisper/bin` | `scripts/linux/build-whisper.sh`; models `digup download-model --transcripts [--small]` |
| Python | uv 0.12.2; **always uv venvs on Python 3.13** | `uv venv --python 3.13` |

### Swift via swiftly (user-level, no sudo)
```sh
curl -O "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" && tar zxf swiftly-*.tar.gz \
  && ./swiftly init --quiet-shell-followup && . ~/.local/share/swiftly/env.sh
swiftly install 6.2   # 6.4.1 is what this port is tested with
```
(Do NOT `apt install swift` — that's OpenStack Swift.)

## Build (engine + CLI)
```sh
scripts/fetch-vendor.sh      # SQLite+FTS5, stb, miniz, PDFium → Vendor/
scripts/build-llama.sh       # llama.cpp b11461 + no-logits patch; picks Vulkan here because glslc is on PATH
swift build -c release --product digup && swift test
.build/release/digup --help
```
Optional, for transcripts of recordings (not used for indexing yet; PLANS/TRANSCRIPTS_PLAN.md):
`scripts/linux/build-whisper.sh` (fetch-vendor.sh runs it too) and `.build/release/digup download-model --transcripts`
(large-v3-turbo q5_0 + Silero VAD, 575 MB; `--small` for the CPU) into `~/.local/share/digup/Models/whisper`.
`digup doctor` shows both.
Vendor/ and .build/ are gitignored. llama.cpp's backend modules load at run time from `Vendor/llama/lib` (rpath).

## Shell (Tauri UI) — dev run: `scripts/linux/dev-run-shell.sh` (+ `scripts/linux/gnome-shortcut.sh` for Ctrl+Alt+Space)
```sh
cd shell/src-tauri && cargo run -- --helper ../../.build/release/digup --index ~/DigUpTestbed/.index --roots ~/DigUpTestbed
```

## Data locations (Linux, engine defaults — verify in Stage 1)
- Index: `$XDG_DATA_HOME/digup/index` (≈ `~/.local/share/digup/index`)
- Shell settings: `~/.config/com.abdurrahim.DigUp/settings.json`; shell logs: Tauri's app_log_dir.
- Model: see `docs/linux-port/ANALYSIS.md` (DIGUP_MODELS overrides).
