"""Checks that a testbed has every file the evals expect: each path in evals/*.json exists (an "@a-b" suffix is a page,
time or chunk range and is stripped), PDFs have the pages the evals point at, and videos last long enough.

    uv run --project scripts/linux/testbed python -I scripts/linux/testbed/check_eval_paths.py <testbed> [eval.json ...]
        [--content]

The evals' "base" ("~/DigUpTestbed", "~/DigUpTestbed/code") is mapped onto <testbed>. With no eval files, all of
evals/*.json. --content also reads the text DigUp's Linux build would read (PDF pages through PDFium, docx/rtf/txt/md)
and reports, for the queries that are words to find ("exact", "*-word" tags), whether the words are in the expected
file or page; this says what's there, it isn't an eval. Exit status 1 when a path or page is missing.
"""
import glob
import json
import os
import re
import subprocess
import sys
import unicodedata
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))


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


def rtf_text(rtf):
    """Enough of RTF for a check: \\uN escapes decoded, control words and skipped groups dropped."""
    rtf = re.sub(r"\{\\\*[^{}]*\}|\{\\(fonttbl|colortbl)[^{}]*\}", "", rtf)
    rtf = re.sub(r"\\u(-?\d+) ?", lambda m: chr(int(m.group(1)) % 65536), rtf)
    rtf = re.sub(r"\\\n", "\n", rtf)
    rtf = re.sub(r"\\[a-z]+-?\d* ?", "", rtf)
    return rtf.replace("{", "").replace("}", "")


def text_of(path):
    extension = os.path.splitext(path)[1].lower()
    if extension == ".docx":
        with zipfile.ZipFile(path) as z:
            return re.sub(r"<[^>]+>", "", z.read("word/document.xml").decode("utf-8"))
    raw = open(path, encoding="utf-8", errors="replace").read()
    return rtf_text(raw) if extension == ".rtf" else raw


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    content = "--content" in sys.argv
    if not args:
        sys.exit(__doc__)
    testbed = os.path.abspath(os.path.expanduser(args[0]))
    evals = args[1:] or sorted(glob.glob(os.path.join(REPO, "evals", "*.json")))
    missing, checked, words = [], 0, []
    pdf_cache = {}
    for eval_path in evals:
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
                elif start is not None and (extension in (".mp4", ".mov") or
                                            (extension == ".ts" and is_transport_stream(path))):
                    if duration(path) <= start:
                        missing.append(f"{where}  (the video lasts {duration(path):.1f} s)")
                        continue
                tag = query.get("tag", "")
                if content and ("exact" in tag or tag.endswith("-word")):
                    if extension == ".pdf":
                        pages = pdf_cache[path]
                        text = "\n".join(pages[start - 1:end] if start else pages)
                    elif extension in (".txt", ".md", ".rtf", ".docx"):
                        text = text_of(path)
                    else:
                        words.append(f"  -    {query['q']!r} in {expect}: a picture; only its pixels hold the words")
                        continue
                    found = unicodedata.normalize("NFC", query["q"]) in unicodedata.normalize("NFC", text)
                    note = ""
                    if not found and bare(query["q"]) in bare(text):
                        note = "  (only with diacritics in the file)"
                    words.append(f"  {'ok  ' if found else 'MISS'} {query['q']!r} in {expect}{note}")
    print(f"{checked} expected paths in {len(evals)} eval files, {len(missing)} missing")
    for line in missing:
        print("  MISSING", line)
    if content:
        print("Words the exact/word queries look for, in the text DigUp reads:")
        print("\n".join(words))
    sys.exit(1 if missing else 0)


main()
