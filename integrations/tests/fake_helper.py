"""A stand-in for `digup search-service`: the same JSON-lines protocol, canned answers, and ways to misbehave.

A "filter" keeps the hits whose path or excerpt has its first word. Queries steer it: "die" exits without answering (only the first time when FAKE_STATE has a folder: it leaves a mark
there), "hang" never answers, "error" answers with an error. FAKE_NO_READY=1: never ready. FAKE_SIMILAR=1: knows the
`similar` op. FAKE_STATE/argv.json: its arguments; FAKE_STATE/quit: written on `quit`; FAKE_STATE/ops.jsonl: the
`folders` and `reload` requests.
"""

import json
import os
import sys
import time
from pathlib import Path

STATE = Path(os.environ["FAKE_STATE"]) if os.environ.get("FAKE_STATE") else None
ROOT = os.environ.get("FAKE_ROOT", "/data")

HITS = [
    {"path": f"{ROOT}/video/zoo.mp4", "kind": "video", "segment": "frame", "segment_id": 272, "score": 8.2579,
     "modified": 1791932067.2, "size": 453417, "info": {"duration": "18.1"}, "z": 5.25, "cosine": 0.71,
     "loc": 6.5, "loc_end": 12.5},
    {"path": f"{ROOT}/docs/lease.pdf", "kind": "pdf", "segment": "page", "segment_id": 31, "score": 5.5,
     "modified": 1791932060.0, "size": 9000, "info": {"pages": "4"}, "loc": 3,
     "excerpt": "…the «payment» was «declined» by the bank…"},
    {"path": f"{ROOT}/notes/todo.md", "kind": "doc", "segment": "chunk", "segment_id": 12, "score": 2.0,
     "modified": 1791932000.0, "size": 120, "info": {}, "excerpt": "buy milk"},
    {"path": "/elsewhere/img/zebra.jpg", "kind": "image", "segment": "image", "segment_id": 126, "score": 1.5,
     "modified": 1791932000.0, "size": 158809, "info": {"width": "768", "height": "768"}},
]
CODE_HITS = [
    {"path": f"{ROOT}/code/retry.py", "kind": "code", "segment": "lines", "segment_id": 77, "score": 4.06,
     "modified": 1791932072.7, "size": 2193, "info": {"lines": "63", "repo": f"{ROOT}/code"}, "loc": 1,
     "loc_end": 33, "focus": 8, "excerpt": "def «retry»_with_«backoff»(attempts=5):"},
]
TEXTS = {31: "Page three: the payment was declined by the bank on 3 March.", 12: "buy milk\nand bread",
         77: "import random\n\ndef retry_with_backoff(attempts=5):\n    ..."}


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def answer(request):
    op = request.get("op")
    if op == "search":
        q = request.get("q", "")
        if q == "die":
            if STATE is None or not (STATE / "died").exists():
                if STATE is not None:
                    (STATE / "died").write_text("1")
                os._exit(3)
        if q == "dieever":
            os._exit(4)
        if q == "hang":
            time.sleep(3600)
        if q == "error":
            return {"ok": False, "error": "something broke"}
        if request.get("code"):
            hits = CODE_HITS
        else:
            hits = [hit for hit in HITS if not request.get("kinds") or hit["kind"] in request["kinds"]]
            if request.get("folders") and os.environ.get("FAKE_FOLDERS"):
                hits = [hit for hit in hits if any(hit["path"].startswith(f + "/") for f in request["folders"])]
        note = None
        if request.get("filter"):
            # The filter: only the hits whose path or excerpt has its first word ("lease", "payment*"); an odd quote
            # is read as plain words, as KeywordFilter does.
            word = request["filter"].split()[0].strip('*"').lower()
            hits = [hit for hit in hits if word in (hit["path"] + hit.get("excerpt", "")).lower()]
            if request["filter"].count('"') % 2:
                note = "unclosed quote: read as plain words"
        elif not q:
            hits = []
        hits = hits[: request.get("limit", 40)]
        reply = {"hits": hits, "strong": min(2, len(hits)), "meaning": request.get("meaning", True) and bool(q),
                 "ms": {"embed": 1, "search": 1}, "echo": {k: v for k, v in request.items() if k != "id"}}
        if note:
            reply["filter_note"] = note
        return reply
    if op == "text":
        return {"text": TEXTS.get(request.get("segment"))}
    if op == "render":
        out = Path(os.environ.get("FAKE_STATE") or "/tmp") / "render.jpg"
        out.write_bytes(b"\xff\xd8\xff\xe0fakejpeg\xff\xd9")
        return {"image": str(out)}
    if op == "status":
        return {"encoder": "stopped", "vectors": 0, "code_vectors": 0, "index": "/idx/index.sqlite"}
    if op == "similar" and os.environ.get("FAKE_SIMILAR"):
        return {"hits": HITS[2:], "strong": 1, "meaning": True}
    if op in ("folders", "reload"):
        if STATE is not None:
            with open(STATE / "ops.jsonl", "a") as log:
                log.write(json.dumps({k: v for k, v in request.items() if k != "id"}) + "\n")
        return {"ok": True}
    return {"ok": False, "error": f"unknown op {op}"}


def main():
    if STATE is not None:
        (STATE / "argv.json").write_text(json.dumps({"argv": sys.argv[1:],
                                                     "backends": os.environ.get("DIGUP_BACKENDS")}))
    if os.environ.get("FAKE_NO_READY"):
        time.sleep(3600)
    print("a stray line that isn't JSON", flush=True)
    send({"event": "ready", "index": "/idx"})
    for line in sys.stdin:
        request = json.loads(line)
        if request.get("op") == "quit":
            if STATE is not None:
                (STATE / "quit").write_text("1")
            send({"id": request.get("id"), "ok": True})
            return
        if request.get("op") == "search" and request.get("q") == "event":
            send({"event": "encoder", "state": "ready"})
        reply = answer(request)
        reply["id"] = request.get("id")
        send(reply)


if __name__ == "__main__":
    main()
