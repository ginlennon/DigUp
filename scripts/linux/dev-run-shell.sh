#!/bin/bash
# Linux dev run of the Tauri shell (shell/) over this checkout's `digup` helper: the helper from .build/release, the
# llama.cpp backends (Vulkan + CPU) from Vendor/llama/lib, the model from ~/.local/share/digup/Models. Without
# arguments it's a real first launch: setup asks for folders, the index goes to ~/.local/share/digup/index and the
# settings to ~/.config/com.abdurrahim.DigUp/settings.json. Extra arguments pass through to digup-shell, e.g.
#   scripts/linux/dev-run-shell.sh --index "$PWD/.dev/eval-idx-before" --roots ~/DigUpTestbed/synthetic:~/DigUpTestbed/traps
# DIGUP_GPU=0 keeps the model on the CPU (once the helper knows DIGUP_GPU).
#
# Wayland has no global key grabs for apps: the hotkey is a GNOME custom shortcut that runs digup-shell again, and the
# running shell (single instance) shows its panel. scripts/linux/gnome-shortcut.sh sets it up.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SHELL_BIN="$REPO/shell/src-tauri/target/debug/digup-shell"
[[ -x "$SHELL_BIN" ]] || { echo "build it first: (cd shell/src-tauri && cargo build)"; exit 1; }
[[ -x "$REPO/.build/release/digup" ]] || { echo "build the helper first: swift build -c release --product digup"; exit 1; }
export DIGUP_BACKENDS="${DIGUP_BACKENDS:-$REPO/Vendor/llama/lib}"
[[ -x "$REPO/Vendor/ffmpeg/ffmpeg" ]] && export DIGUP_FFMPEG="${DIGUP_FFMPEG:-$REPO/Vendor/ffmpeg/ffmpeg}"
exec "$SHELL_BIN" --helper "$REPO/.build/release/digup" --hotkey "Control+Alt+Space" "$@"
