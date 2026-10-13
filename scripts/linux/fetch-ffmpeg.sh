#!/bin/bash
# Linux: a static ffmpeg and ffprobe at a pinned version, in Vendor/ffmpeg/ (out of git), where dev builds of digup
# find them (`FFmpeg.find`). Ubuntu 24.04's ffmpeg 6.1 reads no HEIC and leaves WebP and TIFF pictures unturned; 8.1
# does both. The build is BtbN/FFmpeg-Builds' LGPL one (it reads HEIC, HEIF, AVIF, WebP and TIFF: no GPL-only library
# is needed for pictures, audio or the frames of a video), from the last autobuild of a month, which BtbN keeps for two
# years (daily ones go after 14 days). Its licence comes along as Vendor/ffmpeg/LICENSE.txt. Does nothing when the
# pinned build is already there. Needs curl, tar with xz, and sha256sum.
set -euo pipefail
cd "$(dirname "$0")/../.."
TAG=autobuild-2026-09-30-13-08
VERSION=n8.1.3-9-g29e619e767
case "$(uname -m)" in
  x86_64) TARGET=linux64; SHA256=dfa863a00ca81f1bdf58a372b18cff4820f0017e55de32778de8ecd8ed92a02e ;;
  aarch64) TARGET=linuxarm64; SHA256=8463881ca7a25015ca6e00f5c91dd2f1637eb73d33c8230413cb74db760a86b3 ;;
  *) echo "no static ffmpeg build known for $(uname -m)"; exit 1 ;;
esac
NAME=ffmpeg-$VERSION-$TARGET-lgpl-8.1
STAMP="ffmpeg $TAG $NAME"
if [[ "$(cat Vendor/ffmpeg/VENDOR 2>/dev/null)" == "$STAMP" ]]; then exit 0; fi

T=Vendor/ffmpeg-tmp
rm -rf "$T" && mkdir -p "$T"
echo "ffmpeg ($NAME, ~140 MB)"
curl -sSL -o "$T/ffmpeg.tar.xz" "https://github.com/BtbN/FFmpeg-Builds/releases/download/$TAG/$NAME.tar.xz"
echo "$SHA256  $T/ffmpeg.tar.xz" | sha256sum -c --quiet -
tar -xJf "$T/ffmpeg.tar.xz" -C "$T" "$NAME/bin/ffmpeg" "$NAME/bin/ffprobe" "$NAME/LICENSE.txt"
rm -rf Vendor/ffmpeg && mkdir -p Vendor/ffmpeg
mv "$T/$NAME/bin/ffmpeg" "$T/$NAME/bin/ffprobe" "$T/$NAME/LICENSE.txt" Vendor/ffmpeg/
rm -rf "$T"
echo "$STAMP" > Vendor/ffmpeg/VENDOR
Vendor/ffmpeg/ffmpeg -hide_banner -version | head -1
