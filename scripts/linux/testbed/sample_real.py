"""Picks a random (seeded) sample of your own files by kind and puts them in <testbed>/real/, as
scripts/testbed/sample_real.py does on macOS. Opt-in on Linux (make-testbed.sh --with-real).

    uv run --project scripts/linux/testbed python -I scripts/linux/testbed/sample_real.py <testbed_dir> [--hardlinks]

macOS clones files (APFS, no extra space, never touching the originals). Here the copy method follows the file system:
  - reflinks (cp --reflink=always) where the file system has them (Btrfs, XFS, bcachefs): copy-on-write clones, like
    macOS's; the originals can't change through them;
  - otherwise real copies (cp -p), which take space; the sample's size is printed first and the run stops above
    --max-gb (default 5);
  - --hardlinks: hard links instead of copies on the same file system. No extra space, but a hard link IS the original
    file: editing a testbed file edits yours. Only for an index-only run.
Originals are only ever read. There is no Spotlight here, so kinds come from extensions, screenshots from their names
(what DigUp's Linux build does), page counts from PDFium and durations from ffprobe.
"""
import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
SKIP = re.compile(r"/(node_modules|\.git|\.venv|venv|site-packages|build|DerivedData|Pods|__pycache__)/|\.noindex/|"
                  r"\.photoslibrary/|\.app/|/\.[^/]+/|DigUpTestbed/|/snap/")
IMAGE = {"jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "avif"}
VIDEO = {"mp4", "m4v", "mov", "mkv", "webm", "avi"}
AUDIO = {"mp3", "m4a", "wav", "flac", "ogg", "opus", "aac", "aiff"}
DOCS = {"docx", "doc", "rtf", "md", "txt", "odt"}
SCREENSHOT_PREFIXES = ("Screenshot", "Screen Shot", "CleanShot", "SCR-")  # Sources/DigUpKit/Rules.swift


def roots():
    """The XDG user folders (Desktop, Documents, Downloads, Pictures, Videos, Music), as macOS's six."""
    found = []
    for kind, default in [("DESKTOP", "Desktop"), ("DOCUMENTS", "Documents"), ("DOWNLOAD", "Downloads"),
                          ("PICTURES", "Pictures"), ("VIDEOS", "Videos"), ("MUSIC", "Music")]:
        path = os.path.join(HOME, default)
        if shutil.which("xdg-user-dir"):
            out = subprocess.run(["xdg-user-dir", kind], capture_output=True, text=True).stdout.strip()
            if out and out != HOME:
                path = out
        if os.path.isdir(path) and path not in found:
            found.append(path)
    return found


def walk(folders):
    files = []
    for root in folders:
        for folder, dirs, names in os.walk(root):
            dirs[:] = sorted(d for d in dirs if not d.startswith("."))
            for name in sorted(names):
                path = os.path.join(folder, name)
                if not name.startswith(".") and not SKIP.search(path + "/") and os.path.isfile(path) \
                        and not os.path.islink(path):
                    files.append(path)
    return sorted(set(files))


def ext(path):
    return os.path.splitext(path)[1][1:].lower()


def pages(path):
    import pypdfium2
    try:
        document = pypdfium2.PdfDocument(path)
        count = len(document)
        document.close()
        return count
    except Exception:
        return 0


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", path],
                         capture_output=True, text=True).stdout
    try:
        return float(json.loads(out)["format"]["duration"])
    except (ValueError, KeyError):
        return 0.0


def big_enough(path):
    from PIL import Image
    try:
        with Image.open(path) as image:  # reads the header only
            return image.width >= 256 and image.height >= 256
    except Exception:
        return ext(path) in {"heic", "heif"}  # Pillow can't read HEIC; keep it, as macOS would


def has_reflinks(source, folder):
    """Whether cp --reflink=always works from source's file system into folder (it only reads source)."""
    target = os.path.join(folder, ".reflink-probe")
    ok = subprocess.run(["cp", "--reflink=always", source, target], capture_output=True).returncode == 0
    if os.path.exists(target):
        os.remove(target)
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("testbed")
    parser.add_argument("--hardlinks", action="store_true", help="hard-link instead of copying (see above)")
    parser.add_argument("--max-gb", type=float, default=5, help="stop if real copies would take more (default 5)")
    args = parser.parse_args()
    out = os.path.join(args.testbed, "real")
    rng = random.Random(7)
    folders = roots()
    print("real/: sampling", ", ".join(folders) or "(no user folders)")
    everything = walk(folders)

    def pick(paths, n, keep=lambda p: True):
        paths = paths[:]
        rng.shuffle(paths)
        chosen = []
        for p in paths:
            if len(chosen) == n:
                break
            if keep(p):
                chosen.append(p)
        return chosen

    sample = {}
    images = [p for p in everything if ext(p) in IMAGE]
    is_shot = lambda p: os.path.basename(p).startswith(SCREENSHOT_PREFIXES)
    sample["screenshots"] = pick([p for p in images if is_shot(p)], 120)
    sample["images"] = pick([p for p in images if not is_shot(p)], 120, big_enough)
    pdfs = [p for p in everything if ext(p) == "pdf"]
    big = pick(pdfs, 2, lambda p: pages(p) > 100)
    sample["pdfs"] = big + pick([p for p in pdfs if p not in big], 23, lambda p: 0 < pages(p) <= 100)
    sample["docs"] = pick([p for p in everything if ext(p) in DOCS], 15)
    sample["videos"] = pick([p for p in everything if ext(p) in VIDEO], 6,
                            lambda p: 30 <= duration(p) <= 900 and os.path.getsize(p) <= 600e6)
    audio = [p for p in everything if ext(p) in AUDIO]
    dur = lambda lo, hi: (lambda p: lo <= duration(p) < hi)
    a_short = pick(audio, 3, dur(5, 300))
    a_mid = pick([p for p in audio if p not in a_short], 2, dur(300, 1200))
    a_long = pick([p for p in audio if p not in a_short + a_mid], 1, dur(1800, 5400))
    sample["audio"] = a_short + a_mid + a_long

    os.makedirs(out, exist_ok=True)
    total = sum(os.path.getsize(p) for paths in sample.values() for p in paths)
    first = next((p for paths in sample.values() for p in paths), None)
    if first is None:
        method = "none"
    elif has_reflinks(first, out):
        method = "reflink"
    elif args.hardlinks:
        method = "hardlink"  # files on another file system than the testbed are copied
    else:
        method = "copy"
        if total > args.max_gb * 1e9:
            sys.exit(f"real/: the sample would take {total / 1e9:.1f} GB as copies (no reflinks on this file system); "
                     f"raise --max-gb or pass --hardlinks")
    print(f"  {sum(map(len, sample.values()))} files, {total / 1e9:.2f} GB, by {method}")

    manifest = []
    for kind, paths in sample.items():
        dest_dir = os.path.join(out, kind)
        os.makedirs(dest_dir, exist_ok=True)
        for src in paths:
            name = os.path.basename(src)
            dst, i = os.path.join(dest_dir, name), 2
            while os.path.exists(dst):
                stem, extension = os.path.splitext(name)
                dst, i = os.path.join(dest_dir, f"{stem} {i}{extension}"), i + 1
            try:
                if method == "hardlink" and os.stat(src).st_dev == os.stat(dest_dir).st_dev:
                    os.link(src, dst)
                else:  # -p keeps dates (and the reflink is copy-on-write: the original never changes)
                    flags = ["--reflink=always"] if method == "reflink" else []
                    subprocess.run(["cp", "-p", *flags, src, dst], check=True, capture_output=True)
                manifest.append(f"{kind}\t{os.path.relpath(dst, out)}\t{src}")
            except (OSError, subprocess.CalledProcessError):
                print(f"  skipped (copy failed): {name}", file=sys.stderr)

    with open(os.path.join(out, "MANIFEST.tsv"), "w") as f:
        f.write("kind\ttestbed path\tsource\n" + "\n".join(manifest) + "\n")
    counts = {}
    for line in manifest:
        counts[line.split("\t")[0]] = counts.get(line.split("\t")[0], 0) + 1
    print("real/:", ", ".join(f"{v} {k}" for k, v in counts.items()) or "nothing found")


main()
