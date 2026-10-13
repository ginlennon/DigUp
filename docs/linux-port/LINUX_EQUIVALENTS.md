<!-- Research 2026-10-14 on the dev laptop (Ubuntu 24.04.5, GNOME 46 Wayland, Radeon 860M). Test venv: uv, Python 3.13 (rapidocr, onnxruntime, pillow-heif); scripts were scratch, not committed. Personal paths generalised for the public fork. -->
# DigUp: Linux equivalents for the macOS-only parts (verified on this machine, 2026-10-14)

Machine: Ubuntu 24.04.5, GNOME Shell 46.0 on Wayland, glibc 2.39, GTK 3.24.41, WebKitGTK 4.1 2.52.6, Mesa 25.2.8 RADV, 16 cores, 54 GB RAM.
Venv used: `scratchpad/research/ocrvenv` (uv, **Python 3.13**), containing rapidocr 3.10.0, onnxruntime 1.31.0, pillow, pillow-heif 1.8.1. Scripts are in `research/scripts/` and test data in `research/data/`.
**Swift is not installed on this machine** (`swift`/`swiftc` are not on PATH, and there is no swiftly or /opt toolchain), so nothing Swift-side was compiled here.

Notation: "sudo" means the package needs `sudo apt install`. The candidate version is from `apt-cache policy`.

---

## 1. OCR (replaces Vision)
- **Recommendation: RapidOCR (PaddleOCR PP-OCRv6 models on ONNX Runtime), CPU only.** The default `PP-OCRv6_det_small` + `rec_small` (~30 MB) is a single *multilingual* model covering ~50 Latin-script languages plus Chinese and Japanese, so you don't have to choose a language up front. `return_word_box=True` returns word-level boxes, which keyword search needs. Arabic, Cyrillic, Korean, Devanagari, Thai, Greek, Tamil and Telugu each need their own PP-OCRv5 rec model (`LangRec`). **Bengali isn't covered.**
- **Fallback / complement: tesseract 5.3.4.** It handles clean text and the scripts RapidOCR lacks (ben). TSV output gives words with confidences.
- **Measured** on a 1440×900 synthetic screenshot (7 lines, 12–28 px, EN+DE, codes such as `E-4021` and `INV-2026-00871`), on CPU:

| | clean: time / word recall | degraded (0.55× scale, blur, 1.5° rotation, JPEG q35) | degraded, upscaled 2× |
|---|---|---|---|
| tesseract eng+deu | 0.28 s / **1.000** | 0.21 s / **0.228** | 0.28 s / 0.386 |
| RapidOCR v6 small | 0.43 s warm, 0.64 s cold / **1.000** | 0.35 s / **0.649** | 0.45 s / 0.632 |

  Tesseract falls apart on small or blurry UI text. RapidOCR held up much better and kept all the codes exact.
- **Present on this machine:** `tesseract` 5.3.4 and `libtesseract5` (runtime only). Installed traineddata: only **eng, deu, osd**. Not installed: `libtesseract-dev` (sudo, 5.3.4-1build5), `libleptonica-dev` (sudo), and `tesseract-ocr-{fra,ara,ben,chi-sim,jpn,...}` (sudo, 4.1.0 tessdata_fast) or `tesseract-ocr-all`. ONNX Runtime is **not in Ubuntu's apt** (`libonnxruntime*` has no candidate).
- **C path from Swift:**
  - (a) ONNX Runtime C API: Microsoft's prebuilt `onnxruntime-linux-x64-<ver>.tgz` provides `libonnxruntime.so` plus `onnxruntime_c_api.h`. Vendor it the way pdfium is vendored and port RapidOCR's pre/post-processing; RapidAI/RapidOcrOnnx (C++) is a reference implementation. DB detection post-processing needs a contour step: OpenCV, or a small hand-written one.
  - (b) libtesseract's C API (`capi.h`: `TessBaseAPICreate`, `TessBaseAPIGetIterator`, RIL_WORD). It needs `-dev` headers to build, or a hand-written module map plus `dlopen` of `libtesseract.so.5`, which avoids the sudo requirement.
  - Interim option: shell out to `tesseract img - -l eng+deu tsv`, matching how ffmpeg is already used.
- **Caveats:**
  - RapidOCR's Python wheel pulls in OpenCV and Shapely, so don't ship Python. Use the C API, or run it as a sidecar only for prototyping.
  - The ORT GPU providers here are Azure and CPU only. That's fine: stay on CPU, especially given the past Vulkan crash.
  - Tesseract's speed scales with the number of languages, and it needs `-l` chosen per file.
  - EasyOCR (Torch, ~1 GB) and docTR (Torch/TF) are too heavy to ship. They weren't tested.
- Sources: https://github.com/RapidAI/RapidOCR, https://github.com/RapidAI/RapidOcrOnnx, https://onnxruntime.ai/docs/get-started/with-c.html, https://tesseract-ocr.github.io/tessdoc/APIExample.html

## 2. Image decoding beyond stb
- **What the repo does now** (`Images+Portable.swift`):
  - stb handles JPEG, PNG, BMP, GIF, PSD, TGA and PNM.
  - HEIC, WebP, TIFF and AVIF go through `ffmpeg` (PPM over a pipe).
  - RAW returns "not read yet". SVG isn't supported (`drawsVectorPictures = false`).
  - OCR is a stub: `text(ofImageAt:)` returns `""`.
- **Verified:** Ubuntu's **ffmpeg 6.1 cannot open HEIC at all**. A pillow-heif-made `.heic` fails with "moov atom not found". WebP, TIFF, AVIF (dav1d/libaom) and JPEG XL decoders are present.
- **Recommendation:** link **libheif** for HEIC/AVIF, **libraw** for RAW, and **libwebp/libtiff** directly, and use **resvg** for SVG. resvg is a Rust crate with a C API that can be vendored statically, so it needs no system dependency.
  - Currently installed runtimes: libheif1 1.17.6 (+ libde265, aom plugins), libraw23t64 0.21.2, libwebp7, libtiff6, librsvg2-2 2.58, libdav1d7.
  - Installed `-dev` packages: libwebp-dev and libtiff-dev.
  - sudo: `libheif-dev`, `libraw-dev`, `libavif-dev`, `librsvg2-dev`, `libvips-dev` 8.15 (all have candidates). libvips would cover everything in one dependency.
- **Zero-sudo fallback available today:** ImageMagick 6.9.12 is installed and its coders link `libheif.so.1` and `libraw_r.so.23`. **Verified:** `convert x.heic -resize 512x512 out.png` works (0.06 s), and `rsvg-convert -w 400 t.svg` works. This is a drop-in second CLI path beside ffmpeg (HEIC, AVIF, CR2/CR3/NEF/ARW/DNG and other RAW formats, SVG).
- **Caveats:**
  - ImageMagick and rsvg-convert aren't guaranteed on other distros.
  - ImageMagick has a policy.xml with resource limits.
  - Tiled HEIC needs libheif ≥1.x, which is fine here.
- Sources: https://github.com/strukturag/libheif, https://www.libraw.org/docs, https://github.com/linebender/resvg

## 3. Audio/video (replaces AVFoundation)
- **What the repo does now** (`Media+Portable.swift`):
  - `ffprobe` gives duration and streams.
  - `ffmpeg -vn -ac 1 -ar 16000 -f s16le -` streams PCM into windowed WAVs.
  - ffmpeg is searched for beside the binary, then on PATH.
- **Recommendation: keep the ffmpeg/ffprobe CLI.** It's simple, crash-isolated and already done.
  - Frames: `-vf fps=1/2,scale=-2:224`.
  - Shots: `-vf "select='gt(scene,0.3)',showinfo" -f null -`, then parse `pts_time`.
  - **Verified** on a synthetic 3-segment clip: the cuts were found at exactly 4.0 s and 8.0 s in 0.09 s, and fps sampling produced 6 frames.
- **Fallback:** the libav* C libraries. `libavcodec-dev`, `libavformat-dev`, `libswresample-dev`, `libavutil-dev` and `libswscale-dev` 6.1.1 are **already installed**. They're only worth it if per-process overhead matters.
- **Caveats:**
  - Bundling ffmpeg has codec and patent licensing issues (H.264/HEVC). Depending on the distro's ffmpeg (a .deb `Depends: ffmpeg`) is the clean route.
  - The scene threshold of 0.3 needs tuning, or use `scdet`.
- Source: https://ffmpeg.org/ffmpeg-filters.html#select_002c-aselect

## 4. Open video/audio at a timestamp
- **Present:** the default handler for video/mp4, mkv, mp3 and m4a is **org.gnome.Totem** (43.0). VLC 3.0.20 is installed. mpv (0.37) and Celluloid (0.26) are sudo-installable.
- **Totem has no start-time option.** Its `--help` shows only `--seek-fwd/--seek-bwd`, `--enqueue` and `--replace`. Its **mpris plugin is installed**, so the workaround is to `totem file`, wait for `org.mpris.MediaPlayer2.totem`, then call `Player.SetPosition(trackid, µs)` or `Seek`.
- **Recommendation:** read `xdg-mime query default video/mp4` and map the handler to the right flags:
  - mpv: `--start=SS`
  - VLC: `--start-time=SS` (verified in `vlc -H`)
  - Celluloid: `--mpv-start=SS`
  - Totem: MPRIS seek
  - Anything else: plain open plus a "starts at 12:34" toast.
- **Fallback:** play inside the panel with HTML5 `<video>`, setting `currentTime` in WebKitGTK. gstreamer1.0-libav, -good and -ugly are installed, so H.264/AAC plays.
- **Caveats:** the MPRIS approach is racy, so poll until `CanSeek`. Flatpak players need `flatpak run` and may not see the path.
- Sources: https://mpv.io/manual/master/#options-start, https://wiki.videolan.org/VLC_command-line_help/, https://specifications.freedesktop.org/mpris-spec/latest/Player_Interface.html

## 5. PDF at a page with terms highlighted
- **Present:** the default handler is **org.gnome.Evince** 46.3.1. Okular 23.08 and Firefox 156 are also installed. Papers isn't available on 24.04.
- **Recommendation:**
  - Evince: `evince -i <index> -l "<terms>"` (`--page-index`, 1-based, and `--find`; `-p` takes a page *label*).
  - Okular: `okular -p N --find "<terms>" --unique`.
  - Firefox (pdf.js): `firefox 'file:///x.pdf#page=N&search=term'`.
- **Fallback:** the in-panel page render that pdfium already provides, with highlight boxes drawn from pdfium's text rects. This works with any viewer.
- **Caveat:** in Evince, `--find` can move away from the requested page to the first hit, depending on version. Pass one phrase only.
- Source: `evince --help`, `okular --help` (run locally), https://github.com/mozilla/pdf.js/wiki/Debugging-PDF.js#url-parameters

## 6. Quick Look
- **Not installed:** `gnome-sushi` 46.0 is sudo-installable. `org.gnome.NautilusPreviewer` isn't activatable here (ServiceUnknown).
- **Recommendation:** an **in-panel preview** (image, PDF page via pdfium, video/audio element, text/code), which works everywhere. If Sushi is present, call `org.gnome.NautilusPreviewer2.ShowFile(uri, windowHandle, closeIfShown[, activationToken])` on `/org/gnome/NautilusPreviewer`. The signature varies by version, so introspect first.
- Source: https://gitlab.gnome.org/GNOME/sushi/-/blob/main/data/org.gnome.NautilusPreviewer2.xml

## 7. Reveal in Finder
- **Verified working:** `gdbus call --session --dest org.freedesktop.FileManager1 --object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems "['file:///…/reveal_me.txt']" ""` returned `()`. Nautilus opened with the file selected.
- **Fallback:** `xdg-open` on the parent folder (the inode/directory handler is Nautilus).
- **Caveats:**
  - Pass a startup or activation id as the second argument so the Nautilus window gets focus on Wayland.
  - Other file managers (Dolphin, Nemo) implement the same interface.
- Source: https://www.freedesktop.org/wiki/Specifications/file-manager-interface/

## 8. Copy file to clipboard
- **Recommendation:** set the clipboard **from the Tauri process itself** (GTK3 `gtk_clipboard_set_with_data`) with several targets at once:
  - `x-special/gnome-copied-files` (`copy\nfile:///…`, which Nautilus and Nemo read)
  - `text/uri-list` (`file:///…\r\n`, used by GTK4 and Dolphin)
  - `text/plain` (the path)

  The panel has keyboard focus when ⌘C/Ctrl+C is pressed, which Wayland requires in order to set the selection.
- **Verified:** `wl-copy -t text/uri-list` (wl-clipboard 2.2.1 is installed) offered `text/uri-list` correctly, and `wl-paste` read it back. The user's clipboard was restored afterwards. **Limitation:** one `wl-copy` call offers only **one** MIME type (plus text aliases), so it can't offer gnome-copied-files and uri-list at the same time. Paste into Nautilus wasn't tested interactively.
- **Caveat:** the clipboard-indicator extension is enabled. It usually preserves non-text targets, but check.
- Source: https://github.com/bugaevc/wl-clipboard

## 9. Global hotkey on GNOME 46 Wayland
- **`global-hotkey` (the crate behind tauri-plugin-global-shortcut 2.4.1, as in shell/Cargo.toml) supports "Linux (X11 Only)".** On Wayland it doesn't fire while native Wayland windows have focus. XGrabKey through XWayland only sees XWayland clients.
- **The GlobalShortcuts portal is NOT available here.** Introspecting the portal shows only `Background` and `Settings` matching, and xdg-desktop-portal-gnome is 46.2. GNOME added GlobalShortcuts in **GNOME 48** (Ubuntu 25.04+).
- **Recommendation (works on 24.04):**
  - Install a GNOME **custom keybinding** that runs `digup-shell --toggle`. The single-instance plugin forwards it to the running instance.
  - Set it via `gsettings` under `org.gnome.settings-daemon.plugins.media-keys custom-keybindings` (append to the existing list rather than overwrite it).
  - On GNOME 48+, prefer the portal (the `ashpd` crate's `GlobalShortcuts`).
- **Key conflict found:** **`<Shift><Super>space` is GNOME's `switch-input-source-backward`** (bound by default). ⇧⌘Space maps to Shift+Super+Space, so choose another default, for example `<Super><Alt>space` or `<Ctrl><Alt>space`.
- **Focus and positioning on Wayland:**
  - Clients can't set their own position, so Tauri `set_position` is a no-op. Use `center-new-windows`, which is false here, or accept mutter's placement. Alternatively, make the panel a fixed-size, undecorated window and let mutter place it.
  - With `focus-new-windows='smart'`, re-showing a hidden window without an **xdg-activation token** often yields an "is ready" notification instead of focus.
  - Fix: the launcher process reads `XDG_ACTIVATION_TOKEN` (or `DESKTOP_STARTUP_ID`) from its env, forwards it through single-instance, and the primary calls `gdk_wayland_window_set_startup_notification_id` / `gtk_window_present`. Not verified: whether gsd-media-keys passes a token. Destroying and recreating the window, rather than hide/show, also usually gets focus.
- **GDK_BACKEND=x11 (XWayland):** this gives back positioning, the X11 global hotkey (only while an X client has focus, so not really global) and more lenient focus. It's a reasonable *dev* workaround, but it doesn't fix the hotkey. XWayland has blurry fractional scaling, and you may also need `WEBKIT_DISABLE_DMABUF_RENDERER=1` for WebKitGTK quirks.
- Sources: https://github.com/tauri-apps/global-hotkey (README: "Linux (X11 Only)"), https://release.gnome.org/48/developers/, https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html, https://wayland.app/protocols/xdg-activation-v1

## 10. Menu bar item → tray
- **Present:** **`ubuntu-appindicators@ubuntu.com` is enabled** (gnome-shell-extension-appindicator 58) and libayatana-appindicator3-1 is installed. `libayatana-appindicator3-dev` is sudo, needed only for building. Tauri's `tray-icon` feature uses it.
- **Caveats:**
  - On vanilla GNOME (Fedora), there's no tray without the extension, so the hotkey and an app-grid launcher have to be the primary entry points.
  - AppIndicator gives a menu only: no left-click popover anchored to the icon, and no positioning.
- Source: https://v2.tauri.app/learn/system-tray/

## 11. Folder watching (replaces FSEvents)
- **Present:** `max_user_watches = 65536`, set by `/usr/lib/sysctl.d/30-tracker.conf`. That *lowers* the kernel's RAM-scaled default, which would be about 1M with 54 GB. `max_user_instances = 128`, `max_queued_events = 16384`. `fanotify max_user_marks = 468785`.
- **Measured:** `~` contains **302,095 directories** (63,638 excluding dot-dirs, node_modules and snap). Watching all of home recursively would exhaust the limit, and the limit is shared with other apps.
- **Recommendation:**
  - Use `notify` 8 (inotify) only on the user-chosen folders, minus the skip list (item 15), counting dirs before watching.
  - When over budget, fall back to periodic rescans (mtime/size diff), as `notify`'s `PollWatcher` does, and show this in the UI.
  - Handle `IN_Q_OVERFLOW` with a rescan.
  - Optionally document `sysctl fs.inotify.max_user_watches=524288` as an opt-in.
- **fanotify:** whole-filesystem marks (`FAN_MARK_FILESYSTEM`) need CAP_SYS_ADMIN. Unprivileged fanotify (kernel ≥5.13) allows inode marks only, which gives no recursion advantage, so it's not useful without root.
- Sources: https://docs.rs/notify, https://man7.org/linux/man-pages/man7/inotify.7.html, https://man7.org/linux/man-pages/man7/fanotify.7.html

## 12. Login item
- **Recommendation:** write `~/.config/autostart/digup.desktop` (`Exec=digup-shell --background`, `X-GNOME-Autostart-enabled=true`). The directory exists. The Tauri `autostart` plugin does exactly this.
- **Flatpak alternative:** `org.freedesktop.portal.Background.RequestBackground(autostart=true)`. That portal *is* available here.
- Source: https://specifications.freedesktop.org/autostart-spec/latest/

## 13. Power
- **Verified:**
  - UPower 1.90.3: `OnBattery` = false (charging, 38%). Devices: BAT0, AC and two USB-C sources.
  - `powerprofilesctl get` = `balanced`, with profiles performance, balanced and power-saver (amd_pstate).
- **Recommendation:**
  - Read `org.freedesktop.UPower` `OnBattery` on the system bus, plus DisplayDevice `Percentage`, and subscribe to PropertiesChanged.
  - Treat `net.hadess.PowerProfiles` / `org.freedesktop.UPower.PowerProfiles` `ActiveProfile == "power-saver"` as Low Power Mode.
  - Throttle the indexer accordingly.
- **Caveat:** on desktops without a battery, `OnBattery` is always false. Older systems with TLP have no ppd.
- Source: https://upower.freedesktop.org/docs/UPower.html, https://gitlab.freedesktop.org/upower/power-profiles-daemon

## 14. Auto-update (replaces Sparkle)
- **Options:**
  - (a) **AppImage with Tauri's updater plugin.** It's officially supported on Linux for AppImage only, with a mandatory signature, so it's the closest to Sparkle.
  - (b) A .deb plus a "new version" notification from a GitHub-releases check that opens the download page. The existing daily appcast check can be reused.
  - (c) An apt repo or PPA for real `apt upgrade` updates, at higher maintenance cost.
  - (d) Flatpak/Flathub, where updates are free. But the **sandbox conflicts with indexing arbitrary folders**: it needs `--filesystem=home`/`host`, which Flathub reviewers scrutinize. The document portal hands out per-file FUSE paths (`/run/user/$UID/doc` is mounted here) that aren't suitable for a recursive indexer, and inotify on host paths only works with static filesystem permissions.
  - AppImageUpdate/zsync: `zsync` is sudo and `appimageupdatetool` has no apt candidate, so it would need to be bundled.
- **Recommendation:** ship both AppImage (self-update) and .deb (notify only) from the same CI.
- Sources: https://v2.tauri.app/plugin/updater/, https://docs.flatpak.org/en/latest/sandbox-permissions.html

## 15. Paths to skip (Spotlight-isms)
- **Present here:** `~/.local/share/Trash`, `~/.cache`, `~/snap`, `~/.var/app` (Flatpak data), a sync-client folder, the gvfs FUSE mount at `/run/user/$UID/gvfs` and the portal FUSE mount at `/run/user/$UID/doc`.
- **Recommendation:**
  - Skip:
    - Trash, `~/.cache`, `~/.local/share/{Trash,flatpak}`, `~/snap/*/common/.cache`, `~/.var/app/*/cache`, `.git`, `node_modules` and `__pycache__`.
    - `/run/user/*/{gvfs,doc}`, plus anything whose `findmnt` FSTYPE is fuse.*, nfs, cifs, sshfs or rclone (by default, or opt-in "network folder, slow").
    - Directories containing `.nomedia`, `.noindex` (keep the macOS convention) or `CACHEDIR.TAG`.
  - Cloud placeholders:
    - Nextcloud virtual files use the `.nextcloud` suffix: skip those, since they're 0-byte stubs.
    - rclone/OneDrive mounts show up as fuse mounts, so skip them by FSTYPE.
    - Sync clients that keep real files on disk (e.g. Dropbox on Linux) need no special handling.
  - Use `-xdev`-like behaviour: don't cross mount points unless the user chose them.
- Source: https://bford.info/cachedir/, https://docs.nextcloud.com/desktop/latest/architecture.html#virtual-files-on-linux

## 16. Packaging
- **Recommendation:** use the Tauri bundler (`targets: "all"` already yields deb, rpm and AppImage), with `digup` added as a sidecar (`externalBin`). Put the `.so` files (libllama, libggml, libggml-cpu-*, **libggml-vulkan**, libpdfium) in `resources`/`lib/`.
  - `Package.swift` already adds `-rpath $ORIGIN`, so put the `.so` files beside `digup`. Strip the absolute `Vendor/` rpaths from release builds.
  - .deb `Depends: ffmpeg, libvulkan1, mesa-vulkan-drivers | vulkan-icd, libwebkit2gtk-4.1-0, libayatana-appindicator3-1, libcurl4t64`.
- **Swift runtime:** `swift build -c release --static-swift-stdlib` statically links the stdlib and Foundation on Linux, so no `libswiftCore.so`/`libFoundation.so` needs shipping.
  - **`FileFetcher.swift` imports FoundationNetworking, which still dynamically needs libcurl** (`libcurl4t64` 8.5 is present here). FoundationXML would need libxml2.
  - A fully static musl build (Swift 6 Static Linux SDK) is possible, but llama.cpp and pdfium are glibc `.so` files and ggml backends are dlopened, so stay on glibc.
- **AppImage caveats:**
  - Build on the oldest target (Ubuntu 22.04) because of glibc.
  - The size grows to 70 MB or more.
  - The Vulkan loader and ICDs must come from the host. Never bundle Mesa.
- **Tarball:** fine for power users. It has no desktop integration and no updates.
- Sources: https://v2.tauri.app/distribute/appimage/, https://v2.tauri.app/develop/sidecar/, https://www.swift.org/documentation/articles/static-linux-getting-started.html

## 17. Editors at a line
- **Present here:**
  - `code` 1.139.0 (`code -g file:line[:col]`)
  - geany, which is the **default handler for text/plain and text/x-python**: `geany --line=N file`, or `+N`
  - gnome-text-editor 46.3, which has **no line option**
  - OpenCode (a .desktop file)
- Not installed: zed, subl, JetBrains, kate.
- **Recommendation:** a table keyed on the configured editor or the default handler:
  - VS Code / Cursor / Windsurf: `-g f:l`
  - Zed: `zed f:l`
  - Sublime: `subl f:l`
  - JetBrains: `idea --line N f`
  - geany: `--line=N`
  - kate: `-l N`
  - gedit: `+N`
  - gnome-text-editor and anything else: open the file plainly.
- Sources: https://code.visualstudio.com/docs/editor/command-line, https://zed.dev/docs/command-line, https://www.geany.org/manual/current/#command-line-options

---

## Summary

| # | macOS | Linux pick | Fallback | Here (verified) |
|---|---|---|---|---|
| 1 | Vision OCR | RapidOCR PP-OCRv6 (ORT C API) | tesseract (TSV, ben) | tesseract 5.3.4 eng/deu only; RapidOCR clean 1.00, degraded 0.65 vs tess 0.23 recall |
| 2 | ImageIO | libheif/libraw/libwebp/libtiff + resvg | ImageMagick `convert`, `rsvg-convert` | ffmpeg 6.1 **can't read HEIC**; IM6 reads HEIC+RAW (verified HEIC); -dev libs sudo |
| 3 | AVFoundation | ffmpeg/ffprobe CLI (current) | libav* (dev installed) | scene cuts exact, 0.09 s |
| 4 | QuickTime at time | handler-specific flags | MPRIS seek / in-panel `<video>` | default **Totem (no start flag)**, VLC present |
| 5 | Preview + find | evince `-i N -l`, okular `-p N --find` | pdf.js `#page=&search=`, in-panel pdfium | default Evince 46 |
| 6 | Quick Look | in-panel preview | Sushi `NautilusPreviewer2.ShowFile` | Sushi not installed (sudo) |
| 7 | Reveal | FileManager1.ShowItems | xdg-open parent | **works** |
| 8 | Copy file | GTK clipboard, 3 targets | wl-copy (1 type) | wl-copy uri-list works |
| 9 | Global hotkey | gsettings custom keybinding → single-instance | GlobalShortcuts portal (GNOME ≥48) | **global-hotkey X11-only; no portal on 46; Shift+Super+Space taken** |
| 10 | Status item | AppIndicator tray | hotkey + launcher | extension enabled |
| 11 | FSEvents | inotify (notify), budgeted | PollWatcher rescans | limit 65,536 vs 302k dirs in ~ |
| 12 | Login item | ~/.config/autostart | Background portal | dir exists |
| 13 | Power | UPower OnBattery + ppd power-saver | — | both work |
| 14 | Sparkle | AppImage + Tauri updater | .deb + release-check notify | zsync/AppImageUpdate absent |
| 15 | iCloud/.noindex | skip list + fuse/network mounts | — | Trash, snap, .var/app, gvfs, doc present |
| 16 | .app/DMG | deb + AppImage, sidecar, `--static-swift-stdlib` | tarball | Swift toolchain not installed here |
| 17 | Editors | per-editor line flags | plain open | code, geany (default), gnome-text-editor |
