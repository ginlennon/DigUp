import pytest

import digup_client
from digup_client import HelperConfig
from digup_tools import BadRequest, DigUp, Forbidden, Unsupported, code_query, compact, kinds_of, where


def digup(**config):
    return DigUp(config=HelperConfig.load(**{"roots": ["/data"], "use_settings": False, **config}))


def test_code_query_matches_digupkit():
    assert code_query("code: retry with backoff") == "retry with backoff"
    assert code_query("  CODE:x ") == "x"
    assert code_query("code:") == ""
    assert code_query("my code: notes") is None
    assert code_query("cod") is None


def test_kinds():
    assert kinds_of(None) is None and kinds_of([]) is None
    assert kinds_of("pdf, Photos ,videos") == ["pdf", "image", "video"]
    assert kinds_of(["doc", "documents"]) == ["doc"]
    with pytest.raises(BadRequest, match="the kinds are"):
        kinds_of(["spreadsheet"])
    with pytest.raises(BadRequest, match="search_code"):
        kinds_of(["code"])


def test_where():
    assert where({"segment": "page", "loc": 3.0}) == "page 3"
    assert where({"segment": "page_image", "loc": 2}) == "page 2 (as an image)"
    assert where({"segment": "frame", "loc": 6.5, "loc_end": 12.5}) == "0:06-0:12 (picture)"
    assert where({"segment": "audio", "loc": 3725}) == "1:02:05 (sound)"
    assert where({"segment": "lines", "loc": 1, "loc_end": 33, "focus": 8}) == "lines 1-33 (line 8)"
    assert where({"segment": "lines", "loc": 5, "loc_end": 5}) == "line 5"
    assert where({"segment": "cells", "loc": 2, "loc_end": 4}) == "cells 2-4"
    assert where({"segment": "ocr"}) == "text in the image"
    assert where({"segment": "chunk"}) == "text"
    row = compact({"path": "/a", "kind": "pdf", "segment": "page", "segment_id": 3, "score": 1.23456, "loc": 2,
                   "info": {}})
    assert row == {"path": "/a", "kind": "pdf", "where": "page 2", "score": 1.235, "segment_id": 3, "loc": 2}


def test_search(fake_helper):
    d = digup()
    try:
        results = d.search("zebra", kinds=["video", "pdf"], limit=5)
        assert [hit["kind"] for hit in results.hits] == ["video", "pdf"]
        assert results.strong == 2 and results.meaning
        # folders: sent along, and filtered here too (this fake helper ignores them, as an older helper does)
        results = d.search("zebra", folders=["/data/docs"], limit=5)
        assert [hit["path"] for hit in results.hits] == ["/data/docs/lease.pdf"]
        assert results.strong == 1
        results = d.search("zebra", folders="/elsewhere", limit=5)
        assert [hit["kind"] for hit in results.hits] == ["image"] and results.strong == 0
        with pytest.raises(BadRequest):
            d.search("   ")
    finally:
        d.close()


def test_code_search_needs_code_folders(fake_helper):
    d = digup()
    try:
        with pytest.raises(BadRequest, match="--code-root"):
            d.search("code: retry with backoff")
    finally:
        d.close()
    d = digup(code_roots=["/data/code"])
    try:
        results = d.search("code: retry with backoff")
        assert results.code and results.query == "retry with backoff"
        assert where(results.hits[0]) == "lines 1-33 (line 8)"
        assert d.text(77, code=True).startswith("import random")
    finally:
        d.close()


def test_similar_unsupported_then_supported(fake_helper, monkeypatch):
    d = digup()
    try:
        with pytest.raises(Unsupported, match="newer DigUp helper"):
            d.similar("/data/notes/todo.md")
    finally:
        d.close()
    monkeypatch.setenv("FAKE_SIMILAR", "1")
    d = digup()
    try:
        results = d.similar("/data/x.md", limit=5)
        assert [hit["path"] for hit in results.hits] == ["/data/notes/todo.md", "/elsewhere/img/zebra.jpg"]
        results = d.similar("/data/notes/todo.md", limit=5)   # the file itself is left out
        assert [hit["path"] for hit in results.hits] == ["/elsewhere/img/zebra.jpg"]
    finally:
        d.close()


def test_context_cites_and_budgets(fake_helper):
    d = digup()
    try:
        context = d.context("payment declined", limit=4, max_chars=1000)
        assert context["context"].startswith("[1] /data/docs/lease.pdf (page 3)\nPage three: the payment")
        assert "[2] /data/notes/todo.md (text)\nbuy milk" in context["context"]
        assert [source["n"] for source in context["sources"]] == [1, 2]
        assert {hit["path"] for hit in context["other_matches"]} == {"/data/video/zoo.mp4",
                                                                     "/elsewhere/img/zebra.jpg"}
        assert len(d.context("payment", max_chars=200)["context"]) < 400
    finally:
        d.close()


def test_render_only_inside_the_searched_folders(fake_helper):
    d = digup()
    try:
        assert d.render("/data/docs/lease.pdf", loc=2).endswith("render.jpg")
        with pytest.raises(Forbidden, match="isn't in a folder"):
            d.render("/etc/passwd.png")
        with pytest.raises(BadRequest, match="previews are of"):
            d.render("/data/a.mp3", kind="audio")
    finally:
        d.close()


def test_status_adds_the_configuration(fake_helper):
    d = digup()
    try:
        status = d.status()
        assert status["roots"] == ["/data"] and status["encoder"] == "stopped"
        assert status["helper"].endswith("digup")
    finally:
        d.close()


def test_repo_default_is_this_checkout():
    root = digup_client.repo_root()
    assert root is not None and (root / "integrations" / "src" / "digup_client.py").is_file()
