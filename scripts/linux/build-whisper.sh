#!/bin/bash
# Linux: whisper.cpp (MIT), the engine for transcripts of recordings (optional, off unless turned on), as one program:
# whisper-cli at a pinned release, built into Vendor/whisper/bin (out of git), where dev builds of digup find it
# (`Transcriber.find`); install-user.sh puts it beside the installed digup. Does nothing when that build is already
# there; fetch-vendor.sh runs it every time. Needs git, cmake and a C++ compiler; ninja if it's there.
#
# It's built statically (BUILD_SHARED_LIBS=OFF: whisper and ggml are linked in), so it never loads the libggml*.so of
# llama.cpp that sit beside digup: the two ggml copies differ, and one process with both would clash. What it takes
# from the system is only libc, libm, libstdc++, libgcc_s, libgomp (OpenMP, the CPU threads) and, for Vulkan, the
# loader libvulkan.so.1; the script checks that with ldd. ldd can't see what's opened at run time, though, and
# whisper-cli asks ggml to look for backends to open in its own folder and the current one (it opened llama.cpp's
# libggml-vulkan.so and libggml-cpu-*.so beside digup): scripts/linux/whisper.cpp-no-backend-search.patch takes that
# one call out, the backends linked in are all it uses.
#
# Flavours (WHISPER_FLAVOR picks one): vulkan when glslc and the Vulkan headers are there (Ubuntu: glslc,
# libvulkan-dev), else cpu. The CPU code is for any x86-64-v3 machine (AVX2, FMA, F16C, BMI2; Intel Haswell 2013,
# AMD Excavator 2015 and later), not for this machine only: GGML_NATIVE=OFF with those set explicitly. A static ggml
# can't carry ggml's per-CPU variants (GGML_CPU_ALL_VARIANTS needs shared backends), so one baseline it is; on arm64 it's
# ggml's armv8 baseline. WHISPER_SOURCE / WHISPER_BUILD point at an existing clone and build folder.
set -euo pipefail
cd "$(dirname "$0")/../.."
TAG=v1.9.5
COMMIT=d1be6fde11ac6e0407606b4e42fe72d34add8037   # TAG's commit: a tag can be moved, a commit can't
PATCH=scripts/linux/whisper.cpp-no-backend-search.patch
SOURCE="${WHISPER_SOURCE:-Vendor/whisper.cpp}"
BUILD="${WHISPER_BUILD:-Vendor/whisper-build}"
OUT=Vendor/whisper
if [[ -n "${WHISPER_FLAVOR:-}" ]]; then
  FLAVOR=$WHISPER_FLAVOR
elif command -v glslc > /dev/null \
    && { [[ -f /usr/include/vulkan/vulkan.h ]] || pkg-config --exists vulkan 2> /dev/null; }; then
  FLAVOR=vulkan
else
  FLAVOR=cpu
fi
case "$(uname -m)" in
  x86_64) CPU=x86-64-v3; CPU_FLAGS=(-DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON
                                    -DGGML_BMI2=ON -DGGML_AVX_VNNI=OFF -DGGML_AVX512=OFF) ;;
  *) CPU=$(uname -m); CPU_FLAGS=() ;;
esac
STAMP="$TAG $(sha256sum "$PATCH" | cut -c1-12) $FLAVOR $CPU"
if [[ -x "$OUT/bin/whisper-cli" && "$(cat "$OUT/BUILD" 2> /dev/null)" == "$STAMP" ]]; then
  exit 0
fi

if [[ ! -d "$SOURCE" ]]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp \
    "$SOURCE"
elif [[ "$(git -C "$SOURCE" describe --tags --exact-match 2> /dev/null)" != "$TAG" ]]; then
  git -C "$SOURCE" fetch --quiet --depth 1 origin tag "$TAG"
  git -C "$SOURCE" checkout --quiet --force "$TAG"
fi
if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]]; then
  echo "whisper.cpp's $TAG isn't commit $COMMIT here: not building it" >&2
  exit 1
fi
if git -C "$SOURCE" apply --check "$PWD/$PATCH" 2> /dev/null; then
  git -C "$SOURCE" apply "$PWD/$PATCH"
elif ! git -C "$SOURCE" apply --check --reverse "$PWD/$PATCH" 2> /dev/null; then
  echo "$PATCH doesn't apply to whisper.cpp's $TAG in $SOURCE" >&2
  exit 1
fi

case $FLAVOR in
  vulkan) GPU=(-DGGML_VULKAN=ON) ;;
  cpu) GPU=() ;;
  *) echo "WHISPER_FLAVOR is vulkan or cpu, not $FLAVOR" >&2; exit 1 ;;
esac
GENERATOR=$(command -v ninja > /dev/null && echo Ninja || echo "Unix Makefiles")
# Only whisper-cli: no server, no tests, nothing downloaded or linked beyond ggml (no curl, SDL2 or ffmpeg).
cmake -S "$SOURCE" -B "$BUILD" -G "$GENERATOR" -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_IS_DEV=OFF \
  -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF "${CPU_FLAGS[@]}" "${GPU[@]}" -DGGML_CCACHE=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_CURL=OFF -DWHISPER_SDL2=OFF -DWHISPER_COMMON_FFMPEG=OFF > /dev/null
cmake --build "$BUILD" --config Release -j "$(nproc)" --target whisper-cli > /dev/null

# Nothing but the system's own libraries: no libggml/libwhisper, nothing from Vendor/.
LIBS=$(ldd "$BUILD/bin/whisper-cli" | awk '{ print $1 }')
OTHER=$(grep -Ev '^(linux-vdso\.so|/?.*ld-linux.*\.so|lib(c|m|stdc\+\+|gcc_s|gomp|vulkan)\.so)' <<< "$LIBS" || true)
if [[ -n "$OTHER" ]]; then
  echo "whisper-cli would load more than the system's libraries: $OTHER" >&2
  exit 1
fi
rm -rf "$OUT" && mkdir -p "$OUT/bin"
install -m755 "$BUILD/bin/whisper-cli" "$OUT/bin/"
install -m644 "$SOURCE/LICENSE" "$OUT/LICENSE"
echo "$STAMP" > "$OUT/BUILD"
echo "Built whisper.cpp $TAG ($FLAVOR, $CPU) into $OUT: $("$OUT/bin/whisper-cli" --version)"
