#!/bin/bash
# Installs DigUp for you alone, no sudo, so it runs without this checkout: release builds of the engine (digup) and
# the desktop shell, with llama.cpp's backends, PDFium, ffmpeg, whisper-cli when it's built (transcripts, optional)
# and the licences, in one folder (default ~/.local/opt/digup), plus an app-menu entry and icon. It offers to point the
# GNOME shortcut and starting at login at the installed DigUp. Each step says what it does, shows its commands and asks
# [Y/n/s(kip)/q(uit)]. Run it again to update: the folder is rebuilt beside the old one and swapped in. The model,
# the index and the settings (~/.local/share/digup, ~/.config/com.abdurrahim.DigUp) are never touched, not even by
# --uninstall.
#   scripts/linux/install-user.sh [--prefix DIR] [--dry-run] [--yes] [--no-desktop] [--no-shortcut] [--uninstall]
#     --prefix DIR   where DigUp goes (default ~/.local/opt/digup)
#     --dry-run      show every step and its commands; only the read-only checks run
#     --yes          answer yes to every question
#     --no-desktop   leave the app-menu entry and the icon alone
#     --no-shortcut  leave the GNOME shortcut and the login entry alone
#     --uninstall    remove the folder, the menu entry, the icon, our shortcut and our login entry
set -euo pipefail
shopt -s nullglob
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
SWIFTLY_ENV="${SWIFTLY_HOME_DIR:-$DATA/swiftly}/env.sh"
APPS="$DATA/applications"
ICONS="$DATA/icons/hicolor"
ICON_SIZES=(32 128 256 512)                     # shell/src-tauri/icons: 32x32, 128x128, 128x128@2x, icon.png
AUTOSTART="$CONFIG/autostart/digup.desktop"     # what Settings → "Start at login" writes (desktop.rs)
MODELS="${DIGUP_MODELS:-$DATA/digup/Models}"
MODEL_FILES=(embeddinggemma-2-Q8_0.gguf mmproj-embeddinggemma-2-Q8_0.gguf)   # Sources/DigUpKit/ModelFiles.swift
SCHEMA=org.gnome.settings-daemon.plugins.media-keys
KEYBINDING=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/digup/   # gnome-shortcut.sh's
MARK=.digup-install                             # in the prefix: this folder is ours to replace or remove

PREFIX="$HOME/.local/opt/digup"
DRY=0; YES=0; UNINSTALL=0; DESKTOP=1; SHORTCUT=1
while (( $# )); do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a folder}"; shift ;;
    --prefix=*) PREFIX="${1#--prefix=}" ;;
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --no-desktop) DESKTOP=0 ;;
    --no-shortcut) SHORTCUT=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1 (see --help)"; exit 1 ;;
  esac
  shift
done
PREFIX="$(realpath -m -- "$PREFIX")"
case "$PREFIX" in
  /|"$HOME"|"$REPO"|"$REPO"/*) echo "not a folder to install into: $PREFIX"; exit 1 ;;
esac
case "$HOME/" in
  "$PREFIX"/*) echo "not a folder to install into (your home is inside it): $PREFIX"; exit 1 ;;
esac
SHELL_BIN="$PREFIX/digup-shell"

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' OFF=$'\e[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' CYAN='' OFF=''
fi

# --- Helpers (as in setup.sh) ------------------------------------------------------------------------------------------

section() { printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$OFF"; }
say() { printf '  %s\n' "$*"; }
good() { printf '  %s✓ %s%s\n' "$GREEN" "$*" "$OFF"; }
warn() { printf '  %s! %s%s\n' "$YELLOW" "$*" "$OFF"; }
bad() { printf '  %s✗ %s%s\n' "$RED" "$*" "$OFF"; }
have() { command -v "$1" > /dev/null 2>&1; }

NAMES=(); STATES=()
record() { NAMES+=("$1"); STATES+=("$2"); }

# ask QUESTION: 0 for yes, 1 for no or skip; q prints the summary and stops. --yes says yes.
ask() {
  if (( YES )); then say "${DIM}--yes: yes${OFF}"; return 0; fi
  local answer
  while true; do
    printf '  %s%s%s [Y/n/s(kip)/q(uit)] ' "$BOLD" "$1" "$OFF"
    if ! read -r answer; then answer=s; echo; fi   # no more input: skip
    [[ -t 0 ]] || echo "$answer"                   # answers from a pipe, shown in the log
    case "${answer,,}" in
      ''|y|yes) return 0 ;;
      n|no|s|skip) return 1 ;;
      q|quit) finish stopped ;;
      *) say "y, n, s or q" ;;
    esac
  done
}

# show COMMAND: the command as it will run, one "$ " line per line.
show() {
  local line
  while IFS= read -r line; do printf '    %s$ %s%s\n' "$CYAN" "$line" "$OFF"; done <<< "$1"
}

# offer NAME QUESTION COMMAND: shows the command, asks, runs it in a fresh bash with set -euo pipefail (not with
# --dry-run) and records how it went, also in STATE. 0 when it ran and worked.
offer() {
  show "$3"
  if (( DRY )); then
    say "${DIM}(dry run: not run)${OFF}"; STATE="would run"
  elif ! ask "$2"; then
    say "skipped"; STATE=skipped
  elif bash -c "set -euo pipefail
$3"; then
    STATE="done"; good "done"
  else
    STATE="failed (exit $?)"; bad "$STATE"
  fi
  record "$1" "$STATE"
  [[ "$STATE" == "done" ]]
}

# A word for a shell command line (the commands shown, GNOME's shortcut command): quoted only when needed.
word() {
  if [[ "$1" =~ ^[A-Za-z0-9/._+,:@=-]+$ ]]; then printf '%s' "$1"; else printf '%q' "$1"; fi
}
# A word in single quotes, always.
sq() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
# A word of a .desktop Exec line: in double quotes with " ` $ \ escaped, unless plain (desktop.rs's exec_word).
exec_word() {
  if [[ "$1" =~ ^[A-Za-z0-9/._+,:@-]+$ ]]; then printf '%s' "$1"; return; fi
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\`/\\\`}; s=${s//\$/\\\$}
  printf '"%s"' "$s"
}

P=$(word "$PREFIX")           # the prefix as the shown commands write it
is_gnome() { [[ ":${XDG_CURRENT_DESKTOP:-}:" == *:[Gg][Nn][Oo][Mm][Ee]:* ]] && have gsettings; }

# The running DigUp shells started from this prefix, if any (their pids).
running() {
  local pattern
  # shellcheck disable=SC2001  # one sed is clearer than eleven substitutions
  pattern=$(sed 's/[][\.*^$+?(){}|]/\\&/g' <<< "$SHELL_BIN")
  pgrep -u "$(id -u)" -f -- "^$pattern( |\$)" 2> /dev/null || true
}

# The Exec line of a .desktop file ("" if there's none).
exec_line() { sed -n 's/^Exec=//p' "$1" 2> /dev/null | head -n 1; }
# Does this .desktop file start DigUp from this prefix?
ours() { [[ -f "$1" && "$(exec_line "$1")" == *"$PREFIX/digup-shell"* ]]; }

# --- Uninstall ---------------------------------------------------------------------------------------------------------

uninstall() {
  section "Uninstall DigUp from $PREFIX"
  if [[ -n "$(running)" ]]; then
    warn "DigUp from this folder is running: quit it first (tray icon → Quit), then run this again."
    (( DRY )) || exit 1
  fi

  if (( SHORTCUT )); then
    printf '\n  %sThe GNOME shortcut%s\n' "$BOLD" "$OFF"
    local command=""
    if have gsettings && [[ "$(gsettings get $SCHEMA custom-keybindings 2> /dev/null || true)" == *"'$KEYBINDING'"* ]]; then
      command=$(gsettings get "$SCHEMA.custom-keybinding:$KEYBINDING" command)
    fi
    if [[ "$command" == *"$PREFIX/digup-shell"* ]]; then
      say "Ours: $command. Only DigUp's custom shortcut goes; your others stay."
      offer "remove the GNOME shortcut" "Remove it?" "scripts/linux/gnome-shortcut.sh --remove" || true
    elif [[ -n "$command" ]]; then
      say "The DigUp shortcut runs $command, not this install: left alone."
      record "GNOME shortcut" "left alone (not this install's)"
    else
      record "GNOME shortcut" "none"
    fi

    printf '\n  %sStarting at login%s\n' "$BOLD" "$OFF"
    if ours "$AUTOSTART"; then
      offer "remove the login entry" "Remove ${AUTOSTART/#$HOME/\~}?" "rm -f $(word "$AUTOSTART")" || true
    elif [[ -f "$AUTOSTART" ]]; then
      say "${AUTOSTART/#$HOME/\~} starts $(exec_line "$AUTOSTART"), not this install: left alone."
      record "login entry" "left alone (not this install's)"
    else
      record "login entry" "none"
    fi
  fi

  if (( DESKTOP )); then
    printf '\n  %sApp menu entry and icon%s\n' "$BOLD" "$OFF"
    if ours "$APPS/digup.desktop"; then
      local icons=() size cmd
      for size in "${ICON_SIZES[@]}"; do
        if [[ -f "$ICONS/${size}x$size/apps/digup.png" ]]; then icons+=("$(word "$ICONS/${size}x$size/apps/digup.png")"); fi
      done
      cmd="rm -f $(word "$APPS/digup.desktop") ${icons[*]}"
      if have update-desktop-database; then cmd+=$'\n'"update-desktop-database -q $(word "$APPS")"; fi
      offer "remove the menu entry and icon" "Remove them?" "$cmd" || true
    elif [[ -f "$APPS/digup.desktop" ]]; then
      say "${APPS/#$HOME/\~}/digup.desktop starts $(exec_line "$APPS/digup.desktop"), not this install: left alone."
      record "menu entry" "left alone (not this install's)"
    else
      record "menu entry" "none"
    fi
  fi

  printf '\n  %sThe program folder%s\n' "$BOLD" "$OFF"
  if [[ -f "$PREFIX/$MARK" ]]; then
    say "$PREFIX: the shell, the helper and its libraries, ffmpeg, the licences ($(du -sh "$PREFIX" | cut -f1))."
    offer "remove the program folder" "Remove it?" "rm -rf $P $(word "$PREFIX.new") $(word "$PREFIX.old")" || true
  elif [[ -e "$PREFIX" ]]; then
    bad "$PREFIX has no $MARK: not a folder this script installed, left alone"
    record "program folder" "left alone (not ours)"
  else
    record "program folder" "not there"
  fi

  printf '\n  %sYour data stays%s\n' "$BOLD" "$OFF"
  say "The model and the index: ${DATA/#$HOME/\~}/digup (Models/, index/)"
  say "The settings:            ${CONFIG/#$HOME/\~}/com.abdurrahim.DigUp"
  say "To remove them too (the model is 865 MB to download again):"
  show "rm -rf $(word "$DATA/digup") $(word "$CONFIG/com.abdurrahim.DigUp")"
  finish
}

# --- 1. Check ----------------------------------------------------------------------------------------------------------

load_toolchains() {
  # shellcheck source=/dev/null
  if [[ -f "$SWIFTLY_ENV" ]] && ! have swiftly; then . "$SWIFTLY_ENV"; fi
  if [[ -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" ]] && ! have cargo; then PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"; fi
}

# host_lib SONAME WHAT PACKAGE: is a library the installed DigUp takes from the system there?
host_lib() {
  if ! have ldconfig; then return 0; fi
  if ldconfig -p | awk -v lib="$1" '$1 == lib && $2 ~ /x86-64|AArch64/ { found = 1 } END { exit !found }'; then
    good "$1 ($2)"
  else
    warn "no $1 ($2): sudo apt install $3"
  fi
}

step_check() {
  section "1. Check (read-only)"
  say "Installs into: $PREFIX"
  if [[ -e "$PREFIX" && ! -f "$PREFIX/$MARK" && -n "$(ls -A "$PREFIX" 2> /dev/null)" ]]; then
    bad "$PREFIX exists and isn't a DigUp install (no $MARK): pick another --prefix"
    exit 1
  fi
  if [[ -f "$PREFIX/$MARK" ]]; then say "An install is there: it's rebuilt beside it and swapped in."; fi
  local missing=0 f
  if have swift; then good "Swift: $(swift --version 2> /dev/null | sed -n '/Swift version/{s/.*Swift version \([0-9.]*\).*/\1/p;q;}')"
  else warn "no Swift: builds of digup can't be made (scripts/linux/setup.sh, step 4)"; fi
  if have cargo; then good "Rust: $(cargo --version)"
  else warn "no cargo: builds of the shell can't be made (scripts/linux/setup.sh, step 5)"; fi
  if have patchelf; then good "patchelf (sets the libraries' search path to their own folder)"
  else bad "no patchelf: sudo apt install patchelf"; missing=1; fi
  for f in Vendor/llama/lib/libllama.so Vendor/llama/lib/libmtmd.so Vendor/pdfium/lib/libpdfium.so \
    Vendor/ffmpeg/ffmpeg Vendor/ffmpeg/ffprobe; do
    if [[ -e "$f" ]]; then good "$f"; else bad "no $f (scripts/linux/setup.sh, step 6)"; missing=1; fi
  done
  if [[ -f Vendor/llama/BUILD ]]; then say "llama.cpp: $(< Vendor/llama/BUILD)"; fi
  if (( missing )); then
    if (( DRY )); then warn "the install would stop here"; else bad "set these up first (scripts/linux/setup.sh)"; exit 1; fi
  fi
  say "From the system, as every program has them (not copied in):"
  host_lib libstdc++.so.6 "C++ runtime: llama.cpp" libstdc++6
  host_lib libgomp.so.1 "OpenMP: llama.cpp's CPU backends" libgomp1
  host_lib libcurl.so.4 "downloads: digup download-model" libcurl4t64
  host_lib libvulkan.so.1 "the Vulkan loader: the model on the GPU; without it, the CPU" libvulkan1
  if have tesseract; then good "tesseract (OCR) on PATH"; else say "no tesseract: no OCR (sudo apt install tesseract-ocr)"; fi
  if [[ -x Vendor/whisper/bin/whisper-cli ]]; then good "Vendor/whisper/bin/whisper-cli (transcripts, optional): $(< Vendor/whisper/BUILD)"
  else say "no whisper-cli: no transcripts (optional; scripts/linux/build-whisper.sh builds it)"; fi
  record "1 check" "done"
}

# --- 2. Build ----------------------------------------------------------------------------------------------------------

restore_resolved() {
  if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then return 0; fi
  if ! git ls-files --error-unmatch Package.resolved > /dev/null 2>&1; then return 0; fi
  if [[ -f Package.resolved ]] && (( ! DRY )); then return 0; fi
  say "On Linux, swift build deletes Package.resolved (it pins only macOS packages); git gives it back."
  offer "2 restore Package.resolved" "Restore Package.resolved?" "git checkout -- Package.resolved" || true
}

DIGUP_BUILT=.build/release/digup
SHELL_BUILT=shell/src-tauri/target/release/digup-shell

step_build() {
  section "2. Release builds (in this checkout)"
  printf '\n  %sThe engine and CLI (digup)%s\n' "$BOLD" "$OFF"
  local newer
  newer=$(find Sources Package.swift Vendor/VENDOR Vendor/llama/BUILD -newer "$DIGUP_BUILT" -print -quit 2> /dev/null || true)
  if [[ -x "$DIGUP_BUILT" && -z "$newer" ]] && ! readelf -d "$DIGUP_BUILT" | grep -q 'libswiftCore\.so'; then
    good "already there, with Swift's libraries built in, and newer than the sources: $DIGUP_BUILT"
    record "2 digup (swift build)" "already there"
  else
    say "A release build with Swift's own libraries built in (--static-swift-stdlib: the standard library, Foundation"
    say "and its ICU), so the installed digup needs no Swift. A few minutes the first time; dev runs use it too."
    offer "2 digup (swift build)" "Build it?" "swift build -c release --product digup --static-swift-stdlib" || true
    built
    restore_resolved
  fi
  printf '\n  %sThe desktop shell (digup-shell)%s\n' "$BOLD" "$OFF"
  newer=$(cd shell && find src-tauri/src src-tauri/build.rs src-tauri/Cargo.toml src-tauri/Cargo.lock \
    src-tauri/tauri.conf.json src-tauri/capabilities src-tauri/icons ui -newer "src-tauri/target/release/digup-shell" \
    -print -quit 2> /dev/null || true)
  if [[ -x "$SHELL_BUILT" && -z "$newer" ]]; then
    good "already there and newer than the sources: $SHELL_BUILT"
    record "2 digup-shell (cargo build)" "already there"
  else
    say "A release build of the shell (its web pages are built in). The first one takes a few minutes."
    offer "2 digup-shell (cargo build)" "Build it?" "(cd shell/src-tauri && cargo build --release)" || true
    built
  fi
  if (( ! DRY )) && [[ ! -x "$DIGUP_BUILT" || ! -x "$SHELL_BUILT" ]]; then
    bad "no release build to install: $DIGUP_BUILT and $SHELL_BUILT are both needed"
    finish
  fi
}

# After a build: a failed one stops the install (else it would install the build before it); a skipped one leaves
# the build that's there.
built() {
  case "$STATE" in
    failed*) restore_resolved; bad "the build failed: nothing installed"; finish ;;
    skipped) warn "not rebuilt: the build that's there (if any) gets installed" ;;
  esac
}

# --- 3. Install the folder ---------------------------------------------------------------------------------------------

step_install() {
  section "3. The program folder"
  say "The shell goes into the folder; helper/ gets digup with what it loads from its own folder (llama.cpp and"
  say "ggml with every CPU backend and Vulkan, PDFium, ffmpeg and ffprobe); share/ the icon and the licences."
  say "Their library search path becomes \$ORIGIN (their own folder) instead of this checkout's Vendor/. It's built"
  say "as <folder>.new and then swapped in: a running DigUp keeps going until you restart it."
  local new old size icon_cmds="" s
  new=$(word "$PREFIX.new"); old=$(word "$PREFIX.old")
  for size in "${ICON_SIZES[@]}"; do
    case $size in
      32) s=32x32.png ;; 128) s=128x128.png ;; 256) s=128x128@2x.png ;; 512) s=icon.png ;;
    esac
    icon_cmds+=$'\n'"install -Dm644 shell/src-tauri/icons/$s $new/share/icons/hicolor/${size}x$size/apps/digup.png"
  done
  local ffmpeg_version whisper="" whisper_version=""
  ffmpeg_version=$(cat Vendor/ffmpeg/VENDOR 2> /dev/null || echo "?")
  # whisper-cli (transcripts, optional) when it's built: static, with no library search path to change.
  if [[ -x Vendor/whisper/bin/whisper-cli ]]; then
    say "whisper-cli (transcripts, optional) goes into helper/ too; it's static (its own ggml), so no patchelf."
    whisper=$'\n'"install -m755 Vendor/whisper/bin/whisper-cli $new/helper/"
    whisper+=$'\n'"install -m644 Vendor/whisper/LICENSE $new/share/licenses/whisper.cpp-LICENSE.txt"
    whisper_version="whisper.cpp: $(cat Vendor/whisper/BUILD 2> /dev/null || echo "?")\\n"
  fi
  local cmd="rm -rf $new $old
mkdir -p $new/helper $new/share/licenses
install -m755 $SHELL_BUILT $new/digup-shell
install -m755 $DIGUP_BUILT $new/helper/digup
cp -P Vendor/llama/lib/lib*.so* $new/helper/
install -m644 Vendor/pdfium/lib/libpdfium.so $new/helper/
install -m755 Vendor/ffmpeg/ffmpeg Vendor/ffmpeg/ffprobe $new/helper/
install -m644 Vendor/ffmpeg/LICENSE.txt $new/helper/ffmpeg-LICENSE.txt$whisper
patchelf --set-rpath '\$ORIGIN' $new/helper/digup
find $new/helper -name 'lib*.so*' -type f -exec patchelf --set-rpath '\$ORIGIN' {} +$icon_cmds
install -m644 LICENSE $new/share/licenses/DigUp-LICENSE.txt
install -m644 Resources/Acknowledgements.txt $new/share/licenses/Acknowledgements.txt
install -m644 Vendor/ffmpeg/LICENSE.txt $new/share/licenses/ffmpeg-LICENSE.txt
mkdir -p $new/share/licenses/pdfium && cp -r Vendor/pdfium/LICENSE Vendor/pdfium/licenses $new/share/licenses/pdfium/
printf 'DigUp, installed by scripts/linux/install-user.sh\nsource: %s\nllama.cpp: %s\nffmpeg: %s\n$whisper_version' \\
  \"\$(git describe --always --dirty 2> /dev/null || echo ?)\" \"\$(cat Vendor/llama/BUILD)\" '$ffmpeg_version' > $new/$MARK
if [[ -e $P ]]; then mv $P $old; fi
mv $new $P && rm -rf $old"
  if offer "3 program folder" "Install it?" "$cmd"; then
    if [[ -n "$(running)" ]]; then
      warn "DigUp from $PREFIX is running the old version: quit it (tray → Quit) and start it again."
    fi
    check_install
  elif (( ! DRY )) && [[ ! -f "$PREFIX/$MARK" ]]; then
    finish
  fi
}

# What the installed helper loads: everything from its own folder or from the system, nothing from this checkout.
check_install() {
  local f out bad_libs="" outside="" system
  # The system's library folders: those in ld.so's cache (/usr/lib/…, and any a driver package adds).
  system=$(ldconfig -p 2> /dev/null | awk '$NF ~ /^\// { sub(/\/[^\/]*$/, "", $NF); print $NF "/" }' | sort -u)
  # (whisper-cl[i]: a pattern, so that nullglob leaves it out when it isn't there.)
  for f in "$PREFIX/helper/digup" "$PREFIX"/helper/lib*.so "$PREFIX"/helper/whisper-cl[i] "$PREFIX/digup-shell"; do
    out=$(ldd "$f" 2> /dev/null || true)
    if [[ "$out" == *"not found"* ]]; then bad_libs+=" ${f##*/}:$(awk '/not found/ { printf " %s", $1 }' <<< "$out")"; fi
    outside+=$(awk -v p="$PREFIX/" -v sys="$system" 'BEGIN { n = split(sys, dirs, "\n"); for (i = 1; i <= n; i++) known[dirs[i]] = 1 }
      $2 == "=>" && $3 ~ /^\// && index($3, p) != 1 { d = $3; sub(/[^\/]*$/, "", d); if (!(d in known)) printf " %s", $3 }' <<< "$out")
  done
  if [[ -n "$bad_libs" ]]; then bad "missing libraries:$bad_libs"; else good "ldd: every library is found"; fi
  if [[ -n "$outside" ]]; then warn "loaded from outside $PREFIX and the system:$outside"; fi
  if env -i PATH=/usr/bin:/bin HOME="$HOME" "$PREFIX/helper/digup" --help > /dev/null 2>&1; then
    good "helper/digup runs without this checkout's environment"
  else
    bad "helper/digup --help failed in a clean environment"
  fi
  if [[ -x "$PREFIX/helper/whisper-cli" ]]; then
    if env -i PATH=/usr/bin:/bin HOME="$HOME" "$PREFIX/helper/whisper-cli" --help > /dev/null 2>&1; then
      good "helper/whisper-cli runs too (transcripts, optional): $("$PREFIX/helper/whisper-cli" --version 2>&1 || true)"
    else
      bad "helper/whisper-cli --help failed in a clean environment"
    fi
  fi
  say "$(du -sh "$PREFIX" | cut -f1) in $PREFIX"
}

# --- 4. App menu entry and icon ----------------------------------------------------------------------------------------

desktop_entry() {
  printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=DigUp" "GenericName=File search" \
    "Comment=Search your files by what's in them" "Exec=$(exec_word "$SHELL_BIN")" "Icon=digup" "Terminal=false" \
    "Categories=Utility;" "Keywords=search;find;files;documents;pictures;" "StartupWMClass=digup-shell" \
    "X-DigUp-Prefix=$PREFIX"
}

step_desktop() {
  section "4. App menu entry and icon"
  if (( ! DESKTOP )); then say "--no-desktop: left alone"; record "4 menu entry" "skipped (--no-desktop)"; return 0; fi
  local file="$APPS/digup.desktop" entry
  entry=$(desktop_entry)
  if [[ -f "$file" && "$(< "$file")" == "$entry" ]] && [[ -f "$ICONS/512x512/apps/digup.png" ]] \
    && cmp -s "$ICONS/512x512/apps/digup.png" "$PREFIX/share/icons/hicolor/512x512/apps/digup.png"; then
    good "already there: ${file/#$HOME/\~}"
    record "4 menu entry" "already there"
    return 0
  fi
  if [[ -f "$file" ]] && ! ours "$file"; then warn "${file/#$HOME/\~} starts $(exec_line "$file"): it's replaced"; fi
  say "${file/#$HOME/\~} puts DigUp in the app menu (Activities, the app grid); the icon goes into"
  say "${ICONS/#$HOME/\~} at ${ICON_SIZES[*]} px."
  local cmd size
  cmd="mkdir -p $(word "$APPS")"
  for size in "${ICON_SIZES[@]}"; do
    cmd+=$'\n'"install -Dm644 $P/share/icons/hicolor/${size}x$size/apps/digup.png $(word "$ICONS/${size}x$size/apps/digup.png")"
  done
  cmd+=$'\n'"cat > $(word "$file") << 'EOF'"$'\n'"$entry"$'\n'"EOF"
  if have update-desktop-database; then cmd+=$'\n'"update-desktop-database -q $(word "$APPS")"; fi
  offer "4 menu entry" "Add it?" "$cmd" || true
}

# --- 5. Shortcut and starting at login ---------------------------------------------------------------------------------

step_shortcut() {
  section "5. The shortcut and starting at login"
  if (( ! SHORTCUT )); then say "--no-shortcut: left alone"; record "5 shortcut, login" "skipped (--no-shortcut)"; return 0; fi
  # A shell that knows --toggle hides an open panel too; an older one would refuse the argument, so it gets none and
  # a second launch just shows the panel.
  local command shell=$SHELL_BIN
  command=$(word "$SHELL_BIN")
  if [[ ! -f "$shell" ]]; then shell=$SHELL_BUILT; fi   # a dry run
  if grep -aq -- '--toggle' "$shell" 2> /dev/null; then
    command+=" --toggle"
  else
    say "${DIM}This shell has no --toggle yet: the shortcut starts it plain (a second launch shows the panel).${OFF}"
  fi

  printf '\n  %sThe GNOME shortcut%s\n' "$BOLD" "$OFF"
  if ! is_gnome; then
    say "Not GNOME (${XDG_CURRENT_DESKTOP:-unknown}): bind this in your desktop's keyboard settings: $command"
    record "5 GNOME shortcut" "n/a (not GNOME)"
  else
    local binding="<Control><Alt>space" current=""
    if [[ "$(gsettings get $SCHEMA custom-keybindings 2> /dev/null || true)" == *"'$KEYBINDING'"* ]]; then
      current=$(gsettings get "$SCHEMA.custom-keybinding:$KEYBINDING" command)
      binding=$(gsettings get "$SCHEMA.custom-keybinding:$KEYBINDING" binding | sed "s/^'//; s/'$//")
    fi
    if [[ "$current" == "'$command'" ]]; then
      good "already there: $binding → $command"
      record "5 GNOME shortcut" "already there"
    else
      if [[ -n "$current" ]]; then say "Now $binding runs $current."; fi
      say "Point $binding at the installed DigUp (your other custom shortcuts stay)?"
      offer "5 GNOME shortcut" "Set it?" "scripts/linux/gnome-shortcut.sh $(sq "$binding") $(sq "$command")" || true
    fi
  fi

  printf '\n  %sStarting at login%s\n' "$BOLD" "$OFF"
  local exec replacement
  exec="Exec=$(exec_word "$SHELL_BIN") --background"
  replacement=${exec//\\/\\\\}; replacement=${replacement//|/\\|}; replacement=${replacement//&/\\&}
  if [[ ! -f "$AUTOSTART" ]]; then
    say "Not set up: DigUp's Settings → \"Start at login\" adds it for the installed DigUp."
    record "5 login entry" "not set up"
  elif grep -qxF -- "$exec" "$AUTOSTART"; then
    good "already there: ${AUTOSTART/#$HOME/\~} starts the installed DigUp"
    record "5 login entry" "already there"
  else
    say "${AUTOSTART/#$HOME/\~} starts $(exec_line "$AUTOSTART")."
    # Only its Exec line changes: whether it's switched off stays.
    offer "5 login entry" "Start the installed DigUp at login instead?" \
      "sed -i $(sq "s|^Exec=.*|$replacement|") $(word "$AUTOSTART")" || true
  fi
}

# --- 6. The model ------------------------------------------------------------------------------------------------------

step_model() {
  section "6. The model"
  local f missing=0
  for f in "${MODEL_FILES[@]}"; do
    if [[ ! -f "$MODELS/$f" ]]; then missing=1; fi
  done
  if (( ! missing )); then
    good "already there: ${MODELS/#$HOME/\~} (shared with dev runs; the install doesn't touch it)"
    record "6 model" "already there"
  else
    say "EmbeddingGemma 2 (865 MB, once) into ${MODELS/#$HOME/\~}, where every DigUp looks."
    offer "6 model" "Download it?" "$P/helper/digup download-model" || true
  fi
  if [[ -x "$PREFIX/helper/whisper-cli" && ! -f "$MODELS/whisper/ggml-silero-v6.2.0.bin" ]]; then
    say "Transcripts (optional, off unless turned on) need their models too (575 MB, or 489 MB with --small):"
    show "$P/helper/digup download-model --transcripts"
  fi
}

# --- Summary -----------------------------------------------------------------------------------------------------------

finish() {
  section "Summary"
  if [[ "${1:-}" == stopped ]]; then warn "stopped (q); run it again to carry on, the done steps are left alone"; fi
  if (( DRY )); then say "${DIM}dry run: nothing was changed${OFF}"; fi
  local i colour
  for i in "${!NAMES[@]}"; do
    case "${STATES[i]}" in
      done|"already there"*) colour=$GREEN ;;
      failed*) colour=$RED ;;
      *) colour=$YELLOW ;;
    esac
    printf '  %-36s %s%s%s\n' "${NAMES[i]}" "$colour" "${STATES[i]}" "$OFF"
  done
  if (( ! UNINSTALL )); then
    printf '\n  %sNext%s\n' "$BOLD" "$OFF"
    say "DigUp in the app menu, or: $P/digup-shell"
    say "$P/helper/digup doctor            checks the model, the GPU and the index"
    say "scripts/linux/install-user.sh --uninstall   removes it again (not your data)"
  fi
  exit 0
}

load_toolchains
if (( UNINSTALL )); then uninstall; fi
step_check
step_build
step_install
step_desktop
step_shortcut
step_model
finish
