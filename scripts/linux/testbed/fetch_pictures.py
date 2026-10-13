"""Puts the testbed's sample pictures in <out_dir>: the stand-ins for macOS's /Library/User Pictures listed in
pictures.json (Wikimedia Commons, free licenses), each at most 768 px on its long side, as `sips -Z 768` makes them.

    uv run --project scripts/linux/testbed python -I scripts/linux/testbed/fetch_pictures.py <out_dir>

Originals are downloaded once into ${DIGUP_TESTBED_CACHE:-${XDG_CACHE_HOME:-~/.cache}/digup-testbed}/pictures and
checked against their sha256; a changed file on Commons stops the run rather than change the testbed.
"""
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

from PIL import Image, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
UA = "DigUpTestbed/0.1 (https://github.com/ginlennon/DigUp; testbed generator)"  # Wikimedia asks for one


def cache_dir():
    root = os.environ.get("DIGUP_TESTBED_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "digup-testbed")
    path = os.path.join(root, "pictures")
    os.makedirs(path, exist_ok=True)
    return path


def download(url, path, sha256):
    if os.path.exists(path) and hashlib.sha256(open(path, "rb").read()).hexdigest() == sha256:
        return False
    print(f"  downloading {url.rsplit('/', 1)[-1]}", file=sys.stderr)
    for attempt in range(8):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(request, timeout=300) as response:
                data = response.read()
            break
        except urllib.error.HTTPError as error:
            if error.code not in (429, 503) or attempt == 7:
                raise
            wait = int(error.headers.get("Retry-After") or 0) or 5 * 2 ** attempt
            print(f"  Wikimedia asks to slow down; waiting {wait} s", file=sys.stderr)
            time.sleep(wait)
    if hashlib.sha256(data).hexdigest() != sha256:
        sys.exit(f"{url}: sha256 mismatch (the file on Commons changed; pick another in pictures.json)")
    with open(path + ".part", "wb") as f:
        f.write(data)
    os.replace(path + ".part", path)
    return True


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(HERE, "pictures.json"), encoding="utf-8") as f:
        pictures = json.load(f)["pictures"]
    cache = cache_dir()
    fetched = 0
    for name, picture in sorted(pictures.items()):
        original = os.path.join(cache, picture["sha256"] + os.path.splitext(picture["url"])[1].lower())
        if download(picture["url"], original, picture["sha256"]):
            fetched += 1
            time.sleep(1)  # one at a time, politely
        with Image.open(original) as image:
            image = ImageOps.exif_transpose(image).convert("RGB")
            image.thumbnail((768, 768), Image.LANCZOS)
            image.save(os.path.join(out, name), "JPEG", quality=90)
    print(f"{len(pictures)} pictures ({fetched} downloaded, the rest from {cache})")


main()
