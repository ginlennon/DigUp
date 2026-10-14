#!/bin/bash
# Sets up a Linux machine to build and run DigUp from this checkout, one step at a time: system packages (apt), uv,
# Swift (swiftly), Rust (rustup), the vendored libraries, llama.cpp, the engine, the desktop shell and the model. Each
# step first checks whether it's done already; if not, it says what it does and why, shows the exact command and asks
# [Y/n/s(kip)/q(uit)]. Nothing is installed without a yes, and sudo is only ever used for apt. Run it again any time:
# what's there is left alone. Tested on Ubuntu 24.04; other apt systems should work, others get the package list.
#   scripts/linux/setup.sh [--dry-run] [--yes]
#     --dry-run   show every step and its commands; only the read-only checks run
#     --yes       answer yes for the steps that need no sudo (the apt steps still ask)
#   SWIFT_VERSION=6.x.y picks another Swift than the tested 6.4.1 (6.2 is the oldest that builds DigUp).
set -euo pipefail
shopt -s nullglob
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

SWIFT_VERSION="${SWIFT_VERSION:-6.4.1}"
SWIFT_MIN=6.2                                      # Package.swift's tools version
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
SWIFTLY_ENV="${SWIFTLY_HOME_DIR:-$DATA/swiftly}/env.sh"
CARGO_ENV="${CARGO_HOME:-$HOME/.cargo}/env"
MODELS="$DATA/digup/Models"                        # where `digup download-model` puts the model
MODEL_FILES=(embeddinggemma-2-Q8_0.gguf mmproj-embeddinggemma-2-Q8_0.gguf)   # Sources/DigUpKit/ModelFiles.swift
NEED_GB=15                                         # toolchains + builds + model take about 10 GB

DRY=0; YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $arg (see --help)"; exit 1 ;;
  esac
done

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' OFF=$'\e[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' CYAN='' OFF=''
fi

# --- Helpers -----------------------------------------------------------------------------------------------------------

section() { printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$OFF"; }
say() { printf '  %s\n' "$*"; }
good() { printf '  %s✓ %s%s\n' "$GREEN" "$*" "$OFF"; }
warn() { printf '  %s! %s%s\n' "$YELLOW" "$*" "$OFF"; }
bad() { printf '  %s✗ %s%s\n' "$RED" "$*" "$OFF"; }
have() { command -v "$1" > /dev/null 2>&1; }
# The value of a VAR=value line in one of the fetch/build scripts (their pins), so the checks here follow them.
pin() { sed -n "/^$2=/{s/^$2=\([^ ]*\).*/\1/p;q;}" "$1"; }
# Is version $1 at least $2?
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]; }

# The summary: one line per step (or part of a step) and how it went.
NAMES=(); STATES=()
record() { NAMES+=("$1"); STATES+=("$2"); }

# ask QUESTION [sudo]: 0 for yes, 1 for no or skip; q prints the summary and stops. --yes says yes, but not to sudo.
ask() {
  if (( YES )) && [[ "${2:-}" != sudo ]]; then
    say "${DIM}--yes: yes${OFF}"
    return 0
  fi
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

# run COMMAND: runs it in a fresh bash with set -euo pipefail, unless --dry-run. STATE says how it went; a failure is
# reported and the setup carries on.
run() {
  if (( DRY )); then STATE="would run"; return 0; fi
  if bash -c "set -euo pipefail
$1"; then
    STATE="done"; good "done"
  else
    STATE="failed (exit $?)"; bad "$STATE; carrying on with the next step"
  fi
}

# offer NAME QUESTION COMMAND [sudo]: shows the command, asks, runs it, records how it went (also in STATE).
offer() {
  show "$3"
  if (( DRY )); then
    say "${DIM}(dry run: not run)${OFF}"; STATE="would run"
  elif ask "$2" "${4:-}"; then
    run "$3"
  else
    say "skipped"; STATE=skipped
  fi
  record "$1" "$STATE"
}

# Puts the user-level toolchains on PATH for this run, where they are but the shell profile hasn't been read again.
load_toolchains() {
  # shellcheck source=/dev/null
  if [[ -f "$SWIFTLY_ENV" ]] && ! have swiftly; then . "$SWIFTLY_ENV"; fi
  if [[ -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" ]] && ! have cargo; then PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"; fi
  if [[ -x "$HOME/.local/bin/uv" ]] && ! have uv; then PATH="$HOME/.local/bin:$PATH"; fi
}

# The Swift on PATH, "" if there's none or it isn't Apple's (OpenStack's `swift` client has the same name).
swift_version() { swift --version 2> /dev/null | sed -n '/Swift version/{s/.*Swift version \([0-9][0-9.]*\).*/\1/p;q;}' || true; }

# --- 1. System check ---------------------------------------------------------------------------------------------------

FLAVOR=cpu; GPUS=""; OS_ID=""; OS_VERSION=""
step_system() {
  section "1. System check (read-only)"
  local distro="unknown (no /etc/os-release)"
  if [[ -r /etc/os-release ]]; then
    distro=$(. /etc/os-release && echo "${PRETTY_NAME:-${ID:-?}}")
    OS_ID=$(. /etc/os-release && echo "${ID:-}")
    OS_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-}")
  fi
  say "System:   $distro, $(uname -m), kernel $(uname -r)"
  if [[ "$OS_ID $OS_VERSION" != "ubuntu 24.04" ]]; then
    warn "tested on Ubuntu 24.04; elsewhere package names or versions can differ"
  fi
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) warn "PDFium and ffmpeg are fetched for x86_64 and aarch64 only: step 6 will stop here" ;;
  esac
  say "CPU:      $(nproc) threads"
  say "Memory:   $(awk '/MemTotal/ { printf "%.0f GB", $2 / 1048576 }' /proc/meminfo)"
  local dir free mount seen=""
  for dir in "$HOME" "$REPO"; do
    mount=$(df -P "$dir" | awk 'NR == 2 { print $6 }')
    if [[ " $seen " == *" $mount "* ]]; then continue; fi
    seen="$seen $mount"
    free=$(df -P "$dir" | awk 'NR == 2 { printf "%d", $4 / 1048576 }')
    if (( free < NEED_GB )); then
      warn "Disk:     $free GB free on $mount ($dir): less than $NEED_GB GB; toolchains, builds and the model take ~10 GB"
    else
      say "Disk:     $free GB free on $mount ($dir)"
    fi
  done

  # GPUs: the PCI vendor of each graphics card, then what Vulkan and NVIDIA's tools say.
  local card vendor list=()
  for card in /sys/class/drm/card*; do
    if [[ "${card##*/}" == *-* || ! -r "$card/device/vendor" ]]; then continue; fi   # card1-DP-1 is a connector
    case "$(< "$card/device/vendor")" in
      0x1002) vendor=AMD ;;
      0x10de) vendor=NVIDIA ;;
      0x8086) vendor=Intel ;;
      *) vendor="other ($(< "$card/device/vendor"))" ;;
    esac
    if [[ " ${list[*]-} " != *" $vendor "* ]]; then list+=("$vendor"); fi
  done
  GPUS="${list[*]-}"
  say "GPU:      ${GPUS:-none found in /sys/class/drm}"
  if have vulkaninfo; then
    local devices
    devices=$(timeout 20 vulkaninfo --summary 2> /dev/null | sed -n 's/^[[:space:]]*deviceName[[:space:]]*= //p' \
      | grep -v llvmpipe || true)
    if [[ -n "$devices" ]]; then
      while IFS= read -r line; do say "Vulkan:   $line"; done <<< "$devices"
    else
      say "Vulkan:   no GPU device (only the software renderer, or none)"
    fi
  else
    say "Vulkan:   vulkaninfo isn't installed (step 2's Vulkan group adds it)"
  fi
  if have nvidia-smi; then
    say "NVIDIA:   $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2> /dev/null | head -n 1 || echo "driver there")"
  fi
  local nvcc="${CUDACXX:-nvcc}"
  if have "$nvcc"; then say "CUDA:     $(command -v "$nvcc")"; fi

  # The same choice as scripts/build-llama.sh makes.
  if have "$nvcc"; then
    FLAVOR=cuda
  elif have glslc; then
    FLAVOR=vulkan
  else
    FLAVOR=cpu
  fi
  say "llama.cpp: scripts/build-llama.sh takes CUDA if nvcc is there, else Vulkan if glslc is, else the CPU only."
  case "$FLAVOR" in
    cuda) say "           Here: ${BOLD}CUDA${OFF} (nvcc found)." ;;
    vulkan) say "           Here: ${BOLD}Vulkan${OFF} (glslc found)." ;;
    cpu)
      if [[ -n "$GPUS" ]]; then
        say "           Here now: ${BOLD}CPU${OFF}; installing step 2's Vulkan group (glslc) makes it Vulkan, which runs"
        say "           the model on the GPU (AMD, Intel, and NVIDIA with its own driver)."
      else
        say "           Here: ${BOLD}CPU${OFF} (no GPU found; that works, only slower)."
      fi ;;
  esac
  if [[ "$GPUS" == *NVIDIA* && "$FLAVOR" != cuda ]]; then
    say "           For CUDA instead, install NVIDIA's CUDA toolkit (nvcc) yourself and build again; this script doesn't."
  fi
  if [[ -f Vendor/llama/BUILD ]]; then say "           Built already: $(< Vendor/llama/BUILD)"; fi

  say "Desktop:  ${XDG_CURRENT_DESKTOP:-unknown}, session ${XDG_SESSION_TYPE:-unknown}"
  if [[ "${XDG_SESSION_TYPE:-}" == wayland ]]; then
    say "          Wayland gives apps no global hotkeys: the panel's shortcut is a desktop shortcut (step 9 on GNOME)."
  fi
  record "1 system check" "done"
}

# --- 2. System packages ------------------------------------------------------------------------------------------------

HAVE_APT=0
if have apt-get && have dpkg-query; then HAVE_APT=1; fi

installed() {
  if [[ "$1" == gnupg2 ]] && installed gnupg; then return 0; fi   # on Ubuntu 24.04 gnupg2 is just another name
  [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2> /dev/null || true)" == ii* ]]
}
# (No `| grep -q` here and below: grep stops reading early, and with pipefail the cut-off command makes it a "no".)
available() {
  local policy
  policy=$(apt-cache policy "$1" 2> /dev/null || true)
  [[ "$policy" == *Candidate:* && "$policy" != *"Candidate: (none)"* ]]
}

# apt's package lists, refreshed once (asked) when they're more than a week old: else apt can miss today's versions.
APT_CHECKED=0
apt_refresh() {
  if (( APT_CHECKED )); then return 0; fi
  APT_CHECKED=1
  if [[ -n "$(find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' -mtime -7 -print -quit 2> /dev/null || true)" ]]; then
    return 0
  fi
  say "apt's package lists are more than a week old (or missing): refresh them first."
  offer "2 apt: refresh package lists" "Refresh them with sudo?" "sudo apt update" sudo
}

# apt_group NAME PACKAGE...: one sudo apt install (asked) for the packages that aren't there yet.
apt_group() {
  local name="$1" p
  shift
  local missing=() wanted=() unknown=()
  for p in "$@"; do
    if ! installed "$p"; then missing+=("$p"); fi
  done
  if (( ${#missing[@]} == 0 )); then
    good "already there: $*"
    record "2 apt: $name" "already there"
    return 0
  fi
  if (( ! HAVE_APT )); then
    say "install with your package manager (these are the Debian/Ubuntu names): ${missing[*]}"
    record "2 apt: $name" "skipped (no apt)"
    return 0
  fi
  for p in "${missing[@]}"; do
    if available "$p"; then wanted+=("$p"); else unknown+=("$p"); fi
  done
  if (( ${#unknown[@]} )); then warn "not in your apt sources, left out: ${unknown[*]}"; fi
  if (( ${#wanted[@]} == 0 )); then
    record "2 apt: $name" "failed (not in apt)"
    return 0
  fi
  apt_refresh
  say "apt shows what else it pulls in and asks once more before installing."
  offer "2 apt: $name" "Install with sudo?" "sudo apt install ${wanted[*]}" sudo
}

step_apt() {
  section "2. System packages (apt)"
  if (( ! HAVE_APT )); then
    warn "no apt here: each group below lists its Debian/Ubuntu package names; install the equivalents, then run this again"
  fi

  printf '\n  %sBuild tools%s\n' "$BOLD" "$OFF"
  say "Compilers, cmake and ninja (llama.cpp), git and curl (the downloads), xz (ffmpeg's archive), bc (the benchmark"
  say "script). libz3-dev and gnupg2 are on swiftly's list for Swift on Ubuntu (gnupg checks the toolchain's signature)."
  apt_group "build tools" build-essential cmake ninja-build pkg-config git curl ca-certificates xz-utils bc \
    libz3-dev gnupg2

  printf '\n  %sVulkan (the model on the GPU)%s\n' "$BOLD" "$OFF"
  say "glslc and the headers make build-llama.sh build llama.cpp's Vulkan backend; Mesa's drivers run it on AMD and"
  say "Intel GPUs; vulkan-tools gives vulkaninfo, to see what Vulkan finds."
  if [[ "$FLAVOR" == cuda ]]; then
    say "${YELLOW}Not needed here:${OFF} nvcc is there, so llama.cpp builds with CUDA. Skip unless you want Vulkan too."
  elif [[ -z "$GPUS" ]]; then
    say "${YELLOW}Not needed here:${OFF} no GPU was found, so llama.cpp runs on the CPU. Skip unless step 1 missed one."
  fi
  apt_group "Vulkan" libvulkan-dev glslc spirv-headers mesa-vulkan-drivers vulkan-tools

  printf '\n  %sDesktop shell (Tauri)%s\n' "$BOLD" "$OFF"
  say "The shell is a Tauri app: Rust over WebKitGTK. These are the headers it builds against (GTK, WebKit, the tray"
  say "icon, SVG icons, keyboard input, HTTP, TLS) and patchelf for its bundles."
  apt_group "desktop shell" libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev \
    libsoup-3.0-dev libssl-dev patchelf

  printf '\n  %sText in screenshots (OCR)%s\n' "$BOLD" "$OFF"
  say "DigUp reads the words in screenshots and scanned PDF pages with tesseract, for keyword search. It reads in up to"
  say "three installed languages (DIGUP_OCR_LANGS picks them); each extra language makes OCR a little slower."
  local langs=(tesseract-ocr) code answer
  if have tesseract; then
    say "Installed languages: $(tesseract --list-langs 2> /dev/null | tail -n +2 | grep -vx osd | tr '\n' ' ')"
  fi
  if (( DRY )); then
    say "${DIM}(dry run: would ask for extra language codes, e.g. ara ben fra → tesseract-ocr-ara …)${OFF}"
  elif (( HAVE_APT )); then
    printf '  Extra OCR languages, as codes (e.g. ara ben fra chi_sim; Enter for none): '
    if ! read -r answer; then answer=""; echo; fi
    [[ -t 0 ]] || echo "$answer"
    for code in ${answer,,}; do
      case "$code" in
        s|n|skip|no) ;;
        *[!a-z_]*) warn "not a language code, left out: $code" ;;
        *) langs+=("tesseract-ocr-${code//_/-}") ;;
      esac
    done
  fi
  apt_group "OCR" "${langs[@]}"

  printf '\n  %sOptional: clipboard%s\n' "$BOLD" "$OFF"
  say "wl-clipboard (wl-copy) lets the panel copy files to the clipboard on Wayland."
  apt_group "clipboard (optional)" wl-clipboard

  printf '\n  %sOptional: fonts for the eval testbed%s\n' "$BOLD" "$OFF"
  say "scripts/linux/make-testbed.sh draws its screenshots and PDFs with Noto (Latin, Bengali, Arabic, emoji) and DejaVu."
  apt_group "testbed fonts (optional)" fonts-noto-core fonts-noto-color-emoji fonts-dejavu-core

  say ""
  say "${DIM}Not installed here: ffmpeg from apt (6.1 reads no HEIC; step 6 fetches 8.1), and LibreOffice (large; only"
  say "scripts/linux/make-bench-corpus.sh needs it, for its PDFs: sudo apt install libreoffice-core libreoffice-writer).${OFF}"
}

# --- 3. uv -------------------------------------------------------------------------------------------------------------

step_uv() {
  section "3. uv (Python 3.13 for the eval testbed)"
  say "scripts/linux/make-testbed.sh builds the eval files with Python 3.13 from uv (never the system Python)."
  if have uv; then
    good "already there: $(uv --version)"
    record "3 uv" "already there"
  else
    say "uv's official installer puts uv in ~/.local/bin and, if that folder isn't on PATH yet, adds it in your shell's"
    say "profile (~/.bashrc, ~/.zshrc …). It's a script from astral.sh, run by sh:"
    offer "3 uv" "Install uv?" 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    load_toolchains
  fi
  if have uv && uv python find 3.13 > /dev/null 2>&1; then
    good "Python 3.13 already there: $(uv python find 3.13)"
    record "3 Python 3.13 (uv)" "already there"
  elif have uv || (( DRY )); then
    say "uv keeps its own Pythons in ~/.local/share/uv/python; this adds 3.13 there (~70 MB)."
    offer "3 Python 3.13 (uv)" "Install Python 3.13?" "uv python install 3.13"
  else
    record "3 Python 3.13 (uv)" "skipped (no uv)"
  fi
}

# --- 4. Swift ----------------------------------------------------------------------------------------------------------

step_swift() {
  section "4. Swift ≥ $SWIFT_MIN (swiftly, in your home folder)"
  say "DigUp's engine and CLI are Swift. swiftly is swift.org's toolchain manager: it installs Swift under"
  say "${SWIFTLY_ENV%/env.sh}, no sudo. Don't 'apt install swift': that's OpenStack's storage client."
  local version
  version=$(swift_version)
  if [[ -n "$version" ]] && version_ge "$version" "$SWIFT_MIN"; then
    good "already there: Swift $version ($(command -v swift))"
    if [[ "$version" != "$SWIFT_VERSION" ]]; then say "DigUp is tested with $SWIFT_VERSION; $version should do."; fi
    record "4 Swift" "already there ($version)"
    return 0
  fi
  if [[ -n "$version" ]]; then
    warn "the Swift on PATH is $version, older than $SWIFT_MIN ($(command -v swift))"
  elif have swift; then
    warn "the 'swift' on PATH isn't Apple's Swift ($(command -v swift); OpenStack's client?): swiftly's comes first on PATH"
  fi
  if ! have swiftly; then
    say "swiftly, from download.swift.org for $(uname -m), unpacked in a temporary folder. 'swiftly init' installs it"
    say "into your home and adds a line to your shell profile (~/.profile, ~/.zprofile …) that loads"
    say "$SWIFTLY_ENV, so new terminals find swift."
    # shellcheck disable=SC2016  # $t and $(uname -m) are for the command's own shell
    offer "4 swiftly" "Install swiftly?" 't=$(mktemp -d) && cd "$t"
curl -fsSLO "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
tar zxf "swiftly-$(uname -m).tar.gz"
./swiftly init --quiet-shell-followup --skip-install --assume-yes
cd / && rm -rf "$t"'
    load_toolchains
  else
    good "swiftly already there: $(swiftly --version 2> /dev/null)"
  fi
  if have swiftly || (( DRY )); then
    say "Swift $SWIFT_VERSION (the tested version; SWIFT_VERSION=… picks another), ~3.5 GB, checked against swift.org's"
    say "signature. If swiftly then lists system packages Swift wants, install them with sudo apt install."
    offer "4 Swift $SWIFT_VERSION" "Install Swift $SWIFT_VERSION?" \
      ". $SWIFTLY_ENV && swiftly install --use --assume-yes $SWIFT_VERSION"
    load_toolchains
    hash -r
  else
    record "4 Swift $SWIFT_VERSION" "skipped (no swiftly)"
  fi
}

# --- 5. Rust -----------------------------------------------------------------------------------------------------------

step_rust() {
  section "5. Rust (rustup, in your home folder)"
  say "The desktop shell (Tauri) is Rust. rustup is rust-lang.org's installer: no sudo, everything goes into ~/.rustup"
  say "and ~/.cargo."
  if have cargo; then
    good "already there: $(cargo --version) ($(command -v cargo))"
    record "5 Rust" "already there"
    return 0
  fi
  say "The official command, with the minimal profile (the compiler, cargo and the standard library; no docs). It adds"
  say "'. \"\$HOME/.cargo/env\"' to your shell profile (~/.profile, ~/.bashrc, ~/.zshenv), so new terminals find cargo;"
  say "this script puts ~/.cargo/bin on PATH for itself."
  offer "5 Rust" "Install Rust?" \
    "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal"
  load_toolchains
}

# --- 6. Fetch and build ------------------------------------------------------------------------------------------------

# swift build (and swift test) on Linux delete Package.resolved: no package there is needed on Linux (Sparkle is
# macOS-only). Getting it back from git keeps the checkout clean, so it's never committed deleted.
restore_resolved() {
  if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then return 0; fi
  if ! git ls-files --error-unmatch Package.resolved > /dev/null 2>&1; then return 0; fi
  if [[ -f Package.resolved ]] && (( ! DRY )); then return 0; fi
  say "On Linux, swift build deletes Package.resolved (it pins only macOS packages); git gives it back."
  offer "$1" "Restore Package.resolved?" "git checkout -- Package.resolved"
}

step_build() {
  section "6. Fetch and build DigUp (in this checkout, no sudo)"
  say "Downloads and builds stay in $REPO: Vendor/, .build/ and shell/src-tauri/target/ (all out of git)."

  printf '\n  %sC libraries%s\n' "$BOLD" "$OFF"
  local f=scripts/fetch-vendor.sh
  local stamp
  stamp="sqlite $(pin $f SQLITE_ZIP) stb $(pin $f STB_COMMIT) miniz $(pin $f MINIZ_VERSION) pdfium $(pin $f PDFIUM_TAG)"
  if [[ "$(cat Vendor/VENDOR 2> /dev/null || true)" == "$stamp" ]]; then
    good "already there: $stamp"
    record "6 C libraries (Vendor/)" "already there"
  else
    say "SQLite with FTS5 (the index), stb (pictures), miniz (docx/odt), PDFium (PDF text and pages; a prebuilt"
    say "library), at pinned versions, into Vendor/. A few MB of source and ~10 MB of PDFium. (It also builds the"
    say "optional whisper-cli, see below.)"
    offer "6 C libraries (Vendor/)" "Fetch them?" "scripts/fetch-vendor.sh"
  fi

  printf '\n  %sffmpeg 8.1%s\n' "$BOLD" "$OFF"
  f=scripts/linux/fetch-ffmpeg.sh
  local tag version
  tag=$(pin $f TAG); version=$(pin $f VERSION)
  if [[ -x Vendor/ffmpeg/ffmpeg ]] && grep -qF "$tag" Vendor/ffmpeg/VENDOR 2> /dev/null \
      && grep -qF "$version" Vendor/ffmpeg/VENDOR 2> /dev/null; then
    good "already there: ffmpeg $version"
    record "6 ffmpeg 8.1 (Vendor/ffmpeg)" "already there"
  else
    say "A static LGPL ffmpeg/ffprobe $version (~140 MB download, pinned by sha256) into Vendor/ffmpeg: audio, video"
    say "and HEIC/AVIF/WebP/TIFF pictures. Ubuntu's ffmpeg 6.1 reads no HEIC."
    offer "6 ffmpeg 8.1 (Vendor/ffmpeg)" "Fetch it?" "scripts/linux/fetch-ffmpeg.sh"
  fi

  printf '\n  %sllama.cpp%s\n' "$BOLD" "$OFF"
  f=scripts/build-llama.sh
  tag=$(pin $f TAG)
  stamp="$tag $(sha256sum scripts/llama.cpp-no-logits.patch | cut -c1-12) $FLAVOR"
  if [[ -f Vendor/llama/lib/libllama.so && "$(cat Vendor/llama/BUILD 2> /dev/null || true)" == "$stamp" ]]; then
    good "already there: llama.cpp $tag ($FLAVOR)"
    record "6 llama.cpp ($FLAVOR)" "already there"
  else
    if [[ -f Vendor/llama/BUILD ]]; then say "There's a build of another kind: $(< Vendor/llama/BUILD); this rebuilds it."; fi
    say "The model's runtime: llama.cpp $tag plus a small patch (scripts/llama.cpp-no-logits.patch), cloned into"
    say "Vendor/llama.cpp, built in Vendor/llama-build, libraries into Vendor/llama/lib. It picks ${BOLD}$FLAVOR${OFF} here"
    say "(step 1) and takes a few minutes on $(nproc) threads (more for CUDA); it prints little until it's done."
    offer "6 llama.cpp ($FLAVOR)" "Build it?" "scripts/build-llama.sh"
  fi

  printf '\n  %swhisper.cpp (optional: transcripts of recordings)%s\n' "$BOLD" "$OFF"
  f=scripts/linux/build-whisper.sh
  tag=$(pin $f TAG)
  if [[ -x Vendor/whisper/bin/whisper-cli && "$(cat Vendor/whisper/BUILD 2> /dev/null || true)" == "$tag "* ]]; then
    good "already there: whisper-cli $(< Vendor/whisper/BUILD)"
    record "6 whisper-cli (optional)" "already there"
  else
    say "Transcripts are off unless turned on; without whisper-cli DigUp works as it does now. This builds whisper.cpp"
    say "$tag's whisper-cli into Vendor/whisper/bin, static (its own ggml, apart from llama.cpp's), Vulkan if glslc is"
    say "there: about a minute. Its models (575 MB) come later with: .build/release/digup download-model --transcripts"
    offer "6 whisper-cli (optional)" "Build it?" "scripts/linux/build-whisper.sh"
  fi

  printf '\n  %sCPU-only backends%s\n' "$BOLD" "$OFF"
  local libs=(Vendor/llama/lib/libggml-cpu-*.so) lib links=1
  for lib in "${libs[@]}"; do
    if [[ ! -e "Vendor/llama/cpu-only/${lib##*/}" ]]; then links=0; fi
  done
  if (( ${#libs[@]} && links )); then
    good "already there: Vendor/llama/cpu-only (${#libs[@]} links)"
    record "6 cpu-only backend links" "already there"
  elif (( ${#libs[@]} == 0 && ! DRY )); then
    say "needs llama.cpp's libraries first"
    record "6 cpu-only backend links" "skipped (no llama.cpp)"
  else
    say "Vendor/llama/cpu-only links to llama.cpp's CPU backends only: DIGUP_BACKENDS=…/cpu-only runs digup without the"
    say "GPU (to compare, or when a GPU driver misbehaves)."
    # shellcheck disable=SC2016
    offer "6 cpu-only backend links" "Make the links?" \
      'mkdir -p Vendor/llama/cpu-only && cd Vendor/llama/cpu-only && for f in ../lib/libggml-cpu-*.so; do ln -sfn "$f" .; done'
  fi

  printf '\n  %sThe engine and CLI (Swift)%s\n' "$BOLD" "$OFF"
  local newer
  newer=$(find Sources Package.swift Vendor/VENDOR Vendor/llama/BUILD -newer .build/release/digup -print -quit \
    2> /dev/null || true)
  if [[ -x .build/release/digup && -z "$newer" ]]; then
    good "already there and newer than the sources: .build/release/digup"
    record "6 digup (swift build)" "already there"
  elif [[ -z "$(swift_version)" ]] && (( ! DRY )); then
    say "needs Swift (step 4)"
    record "6 digup (swift build)" "skipped (no Swift)"
  else
    say "A release build of digup (the engine, the CLI and the shell's helper), into .build/release. Several minutes the"
    say "first time, seconds after small changes."
    local env=""
    if [[ -f "$SWIFTLY_ENV" ]] || (( DRY )); then env=". $SWIFTLY_ENV && "; fi
    offer "6 digup (swift build)" "Build it?" "${env}swift build -c release --product digup"
    restore_resolved "6 restore Package.resolved"
  fi

  printf '\n  %sThe desktop shell (Tauri)%s\n' "$BOLD" "$OFF"
  local bin=shell/src-tauri/target/debug/digup-shell
  newer=$(cd shell && find src-tauri/src src-tauri/build.rs src-tauri/Cargo.toml src-tauri/Cargo.lock \
    src-tauri/tauri.conf.json src-tauri/capabilities src-tauri/icons ui -newer "src-tauri/target/debug/digup-shell" \
    -print -quit 2> /dev/null || true)
  if [[ -x "$bin" && -z "$newer" ]]; then
    good "already there and newer than the sources: $bin"
    record "6 digup-shell (cargo build)" "already there"
  elif ! have cargo && (( ! DRY )); then
    say "needs Rust (step 5)"
    record "6 digup-shell (cargo build)" "skipped (no Rust)"
  else
    say "A debug build of the shell (what scripts/linux/dev-run-shell.sh starts). The first one downloads its crates"
    say "and takes a few minutes; shell/src-tauri/target grows to ~3 GB."
    offer "6 digup-shell (cargo build)" "Build it?" "(cd shell/src-tauri && cargo build)"
  fi
}

# --- 7. The model ------------------------------------------------------------------------------------------------------

step_model() {
  section "7. The model (865 MB, once)"
  say "EmbeddingGemma 2 (Q8_0): the text part and the image/audio encoders, into $MODELS."
  if [[ -f "$MODELS/${MODEL_FILES[0]}" && -f "$MODELS/${MODEL_FILES[1]}" ]]; then
    good "already there: $MODELS"
    record "7 model" "already there"
    return 0
  fi
  if [[ ! -x .build/release/digup ]] && (( ! DRY )); then
    say "needs digup (step 6)"
    record "7 model" "skipped (no digup)"
    return 0
  fi
  say "From Hugging Face, or copied from your Hugging Face cache when it's there. A stopped download picks up where it"
  say "stopped next time; each file is checked (size, SHA-256) before it gets its name. It prints progress as JSON lines."
  offer "7 model" "Download it?" ".build/release/digup download-model"
}

# --- 8. Check the vectors ----------------------------------------------------------------------------------------------

step_test() {
  section "8. Optional: check the vectors on this GPU"
  say "ReferenceVectorTests embeds a few known inputs and compares them with the vectors the macOS build made: it"
  say "proves this llama.cpp build on this GPU gives the same search results. It builds the tests first (a few"
  say "minutes), then runs the model briefly on the GPU."
  if [[ "$GPUS" == *AMD* && "$FLAVOR" == vulkan ]]; then
    warn "On some AMD laptops a GPU fault (amdgpu/RADV) can take the whole machine down. This test is short and uses"
    warn "small contexts, but save your work first."
  fi
  if (( ! DRY )) && { [[ -z "$(swift_version)" ]] || [[ ! -f Vendor/llama/lib/libllama.so ]] \
      || [[ ! -f "$MODELS/${MODEL_FILES[1]}" ]]; }; then
    say "needs Swift, llama.cpp and the model (steps 4, 6, 7)"
    record "8 ReferenceVectorTests" "skipped (not built yet)"
    return 0
  fi
  local env=""
  if [[ -f "$SWIFTLY_ENV" ]] || (( DRY )); then env=". $SWIFTLY_ENV && "; fi
  offer "8 ReferenceVectorTests" "Run the test?" \
    "${env}DIGUP_BACKENDS=$REPO/Vendor/llama/lib swift test --filter ReferenceVectorTests"
  if [[ "$STATE" != skipped ]]; then restore_resolved "8 restore Package.resolved"; fi
}

# --- 9. GNOME shortcut -------------------------------------------------------------------------------------------------

step_shortcut() {
  section "9. Optional: the hotkey (GNOME)"
  if [[ "${XDG_CURRENT_DESKTOP:-}" != *GNOME* ]]; then
    say "Not GNOME (${XDG_CURRENT_DESKTOP:-unknown}): add a shortcut in your desktop's keyboard settings that runs"
    say "$REPO/scripts/linux/dev-run-shell.sh; a second start shows the running shell's panel."
    record "9 GNOME shortcut" "n/a (not GNOME)"
    return 0
  fi
  say "Wayland lets no app grab keys, so Ctrl+Alt+Space is a GNOME custom shortcut that starts the shell; the running"
  say "shell (one at a time) then shows its panel. Your other custom shortcuts are kept."
  local schema=org.gnome.settings-daemon.plugins.media-keys
  local key=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/digup/
  local launcher="$REPO/scripts/linux/dev-run-shell.sh"
  if [[ "$(gsettings get $schema custom-keybindings 2> /dev/null || true)" == *"'$key'"* ]]; then
    local binding command
    binding=$(gsettings get "$schema.custom-keybinding:$key" binding)
    command=$(gsettings get "$schema.custom-keybinding:$key" command)
    if [[ "$command" == "'$launcher'" ]]; then
      good "already there: $binding → $command"
      record "9 GNOME shortcut" "already there"
      return 0
    fi
    warn "there's a DigUp shortcut ($binding → $command), but not for this checkout"
  fi
  offer "9 GNOME shortcut" "Set it up?" "scripts/linux/gnome-shortcut.sh"
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
  printf '\n  %sNext%s\n' "$BOLD" "$OFF"
  local envs=() e
  for e in "$SWIFTLY_ENV" "$CARGO_ENV"; do
    if [[ -f "$e" ]]; then envs+=(". $e;"); fi
  done
  if (( ${#envs[@]} )); then
    say "New terminals find swift and cargo through your shell profile; a terminal open from before needs:"
    say "  ${envs[*]}"
  fi
  say "scripts/linux/dev-run-shell.sh      the desktop shell (its first start asks which folders to index)"
  if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
    say "scripts/linux/gnome-shortcut.sh     Ctrl+Alt+Space opens the panel"
  fi
  say ".build/release/digup --help         the CLI (index, search, status)"
  say "scripts/linux/make-testbed.sh       the eval testbed (see scripts/linux/README.md)"
  exit 0
}

load_toolchains
step_system
step_apt
step_uv
step_swift
step_rust
step_build
step_model
step_test
step_shortcut
finish
