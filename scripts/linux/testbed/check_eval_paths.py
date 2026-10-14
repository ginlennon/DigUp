"""Checks that a testbed has every file the evals expect: each path in evals/*.json exists (an "@a-b" suffix is a page,
time or chunk range and is stripped), PDFs have the pages the evals point at, and recordings and videos last long
enough.

    uv run --project scripts/linux/testbed python -I scripts/linux/testbed/check_eval_paths.py <testbed> [eval.json ...]
        [--content]

The evals' "base" ("~/DigUpTestbed", "~/DigUpTestbed/code") is mapped onto <testbed>. With no eval files, all of
evals/*.json. Tier-2 evals (multilingual.json: Bengali and Arabic, which make-testbed.sh builds only with --tier2) are
skipped with a note when their folders aren't in the testbed. --content also reads the text DigUp's Linux build would
read (PDF pages through PDFium, docx/odt/rtf/txt/md) and reports, for the queries that are words to find ("exact",
"*-word" tags), whether the words are in the expected file or page, and for "spoken-term" queries that the words are in
no text under synthetic/ (they're only said in a recording); this says what's there, it isn't an eval. Exit status 1
when a path or page is missing or a recording or video is shorter than its range.
"""
import glob
import html
import json
import os
import re
import subprocess
import sys
import unicodedata
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
# Evals over tier-2 files, and the folders make-testbed.sh --tier2 adds for them.
TIER2 = {"multilingual.json": ["synthetic/lang/bn", "synthetic/lang/ar"]}
TEXT_EXTENSIONS = (".txt", ".md", ".rtf", ".docx", ".odt")
MEDIA_EXTENSIONS = (".mp4", ".mov", ".wav", ".m4a", ".mp3", ".ogg", ".flac", ".opus")


def split(path):
    match = re.fullmatch(r"(.*)@(\d+)-(\d+)", path)
    return (match.group(1), int(match.group(2)), int(match.group(3))) if match else (path, None, None)


def pdf_pages(path):
    import pypdfium2
    document = pypdfium2.PdfDocument(path)
    try:
        return [document[i].get_textpage().get_text_range() for i in range(len(document))]
    finally:
        document.close()


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         capture_output=True, text=True).stdout.strip()
    try:
        return float(out)
    except ValueError:
        return 0.0


def is_transport_stream(path):
    """An MPEG-TS video, not TypeScript: sync bytes every 188 bytes (Rules.isMPEGTransportStream)."""
    with open(path, "rb") as f:
        head = f.read(400)
    return len(head) >= 400 and head[0] == head[188] == head[376] == 0x47


def bare(text):
    """NFC, without Arabic diacritics (harakat), for a second look."""
    return "".join(c for c in unicodedata.normalize("NFD", text)
                   if not (unicodedata.category(c) == "Mn" and "\u064b" <= c <= "\u065f"))


def fold(text):
    return unicodedata.normalize("NFC", text).casefold()


def rtf_text(rtf):
    """Enough of RTF for a check: \\uN escapes decoded, control words and skipped groups dropped."""
    rtf = re.sub(r"\{\\\*[^{}]*\}|\{\\(fonttbl|colortbl)[^{}]*\}", "", rtf)
    rtf = re.sub(r"\\u(-?\d+) ?", lambda m: chr(int(m.group(1)) % 65536), rtf)
    rtf = re.sub(r"\\\n", "\n", rtf)
    rtf = re.sub(r"\\[a-z]+-?\d* ?", "", rtf)
    return rtf.replace("{", "").replace("}", "")


def text_of(path):
    extension = os.path.splitext(path)[1].lower()
    if extension in (".docx", ".odt"):
        with zipfile.ZipFile(path) as z:
            xml = z.read("word/document.xml" if extension == ".docx" else "content.xml").decode("utf-8")
        return html.unescape(re.sub(r"<[^>]+>", "", re.sub(r"</(w|text):p>", "\n", xml)))
    raw = open(path, encoding="utf-8", errors="replace").read()
    return rtf_text(raw) if extension == ".rtf" else raw


def written_texts(testbed, pdf_cache):
    """Every text DigUp reads under synthetic/, as (path in the testbed, text): where a spoken term mustn't be."""
    texts = []
    for root, _, files in os.walk(os.path.join(testbed, "synthetic")):
        for name in sorted(files):
            path = os.path.join(root, name)
            extension = os.path.splitext(name)[1].lower()
            if extension == ".pdf":
                if path not in pdf_cache:
                    pdf_cache[path] = pdf_pages(path)
                texts.append((os.path.relpath(path, testbed), "\n".join(pdf_cache[path])))
            elif extension in TEXT_EXTENSIONS:
                texts.append((os.path.relpath(path, testbed), text_of(path)))
    return texts


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    content = "--content" in sys.argv
    if not args:
        sys.exit(__doc__)
    testbed = os.path.abspath(os.path.expanduser(args[0]))
    evals = args[1:] or sorted(glob.glob(os.path.join(REPO, "evals", "*.json")))
    missing, checked, words, skipped = [], 0, [], 0
    pdf_cache, written = {}, None
    for eval_path in evals:
        absent = [d for d in TIER2.get(os.path.basename(eval_path), []) if not os.path.isdir(os.path.join(testbed, d))]
        if absent:
            print(f"{os.path.basename(eval_path)}: skipped, tier 2 isn't in this testbed (no {', '.join(absent)}; "
                  "make-testbed.sh --tier2 builds it)")
            skipped += 1
            continue
        with open(eval_path, encoding="utf-8") as f:
            data = json.load(f)
        base = data["base"]
        if not base.startswith("~/DigUpTestbed"):
            sys.exit(f"{eval_path}: base {base} isn't under ~/DigUpTestbed")
        root = testbed + base[len("~/DigUpTestbed"):]
        for query in data["queries"]:
            for expect in query["expect"]:
                rel, start, end = split(expect)
                path = os.path.join(root, rel)
                checked += 1
                where = f"{os.path.basename(eval_path)}: {expect}"
                if not os.path.isfile(path):
                    missing.append(f"{where}  (no such file)")
                    continue
                extension = os.path.splitext(path)[1].lower()
                if extension == ".pdf":
                    if path not in pdf_cache:
                        pdf_cache[path] = pdf_pages(path)
                    if end is not None and end > len(pdf_cache[path]):
                        missing.append(f"{where}  (the PDF has {len(pdf_cache[path])} pages)")
                        continue
                elif start is not None and (extension in MEDIA_EXTENSIONS or
                                            (extension == ".ts" and is_transport_stream(path))):
                    if duration(path) <= start:
                        missing.append(f"{where}  (it lasts {duration(path):.1f} s)")
                        continue
                tag = query.get("tag", "")
                if content and tag == "spoken-term":
                    if written is None:
                        written = written_texts(testbed, pdf_cache)
                    also = [name for name, text in written if fold(query["q"]) in fold(text)]
                    words.append(f"  {'ALSO WRITTEN in ' + ', '.join(also) if also else 'ok, only said'}  "
                                 f"{query['q']!r} in {expect}")
                elif content and ("exact" in tag or tag.endswith("-word")):
                    if extension == ".pdf":
                        pages = pdf_cache[path]
                        text = "\n".join(pages[start - 1:end] if start else pages)
                    elif extension in TEXT_EXTENSIONS:
                        text = text_of(path)
                    else:
                        words.append(f"  -    {query['q']!r} in {expect}: a picture; only its pixels hold the words")
                        continue
                    found = unicodedata.normalize("NFC", query["q"]) in unicodedata.normalize("NFC", text)
                    note = ""
                    if not found and bare(query["q"]) in bare(text):
                        note = "  (only with diacritics in the file)"
                    words.append(f"  {'ok  ' if found else 'MISS'} {query['q']!r} in {expect}{note}")
    print(f"{checked} expected paths in {len(evals) - skipped} eval files, {len(missing)} missing")
    for line in missing:
        print("  MISSING", line)
    if content:
        print("Words the exact/word queries look for, in the text DigUp reads; spoken terms, in no text:")
        print("\n".join(words))
    sys.exit(1 if missing else 0)


main()
