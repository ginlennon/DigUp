"""--scope and adding folders (PLANS/FOLDERS_PLAN.md, A4), against the fake helper and a stand-in for the app."""

import json
import os

import pytest

from digup_app import AppNotRunning, DesktopApp
from digup_client import HelperConfig
from digup_tools import DigUp, Forbidden, NotIndexed, Scope, coverage, partial_text


class FakeApp:
    """The desktop app as digup_tools sees it: what it was asked, what it answers."""

    def __init__(self, pending=(), answer=None, settings=None):
        self.pending = list(pending)
        self.answer = answer
        self.settings = settings
        self.asked = []

    def add_folder(self, folder, tool, max_files):
        self.asked.append((folder, tool, max_files))
        if self.answer is not None:
            return self.answer
        if self.settings is not None:
            chosen = json.loads(self.settings.read_text()) if self.settings.exists() else {}
            chosen.setdefault("folders", []).append(folder)
            self.settings.write_text(json.dumps(chosen))
        self.pending.append(folder)
        return {"ok": True, "added": True, "path": folder, "message": f"{tool} added {folder} to DigUp"}

    def status(self):
        return {"ok": True, "state": "indexing", "done": 4, "total": 30, "pending": list(self.pending)}


def digup(scope, roots=("/data",), code_roots=(), **options):
    config = HelperConfig.load(roots=list(roots), code_roots=list(code_roots), use_settings=False)
    return DigUp(config=config, scope=Scope.of(scope, cwd="/data"), cwd="/data", **options)


def ops(state):
    path = state / "ops.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def test_scope_folders_and_how_they_narrow():
    scope = Scope.of(["docs", "~/notes", "/data/docs/"], cwd="/data")
    assert scope.folders == ["/data/docs", os.path.expanduser("~/notes")]
    assert Scope.of(["", " "]) is None
    assert scope.contains("/data/docs/lease.pdf") and not scope.contains("/data/docsy/x")
    only = Scope.of(["/data/docs"])
    assert only.narrow(None) == ["/data/docs"]
    assert only.narrow(["/data"]) == ["/data/docs"], "a wider folder is narrowed to the scope"
    assert only.narrow(["/data/docs/2024"]) == ["/data/docs/2024"], "a narrower one stays"
    with pytest.raises(Forbidden, match="outside the folders this server searches"):
        only.narrow(["/elsewhere"])
    # A link to the scope matches by its real path too.
    assert coverage("/data/docs", ["/data"], []) == "yes"
    assert coverage("/data/docs", ["/data"], ["/data/docs"]) is None, "skipped there"
    assert coverage("/data", ["/data/docs"], []) == "partly"
    assert coverage("/other", ["/data"], []) is None


def test_link_to_the_scope(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    (tmp_path / "link").symlink_to(real)
    scope = Scope.of(["link"], cwd=str(tmp_path))
    assert scope.folders == [str(tmp_path / "link")] and scope.also == [str(real)]
    assert scope.contains(str(real / "a.md"))


def test_searches_stay_inside_the_scope(fake_helper):
    d = digup(["docs"])
    try:
        results = d.search("zebra", limit=10)
        assert [hit["path"] for hit in results.hits] == ["/data/docs/lease.pdf"]
        assert results.partial is None and results.notes == []
        assert [hit["path"] for hit in d.search("zebra", folders=["/data"]).hits] == ["/data/docs/lease.pdf"]
        with pytest.raises(Forbidden, match="outside"):
            d.search("zebra", folders=["/elsewhere"])
        context = d.context("payment")
        assert [source["path"] for source in context["sources"]] == ["/data/docs/lease.pdf"]
        assert {hit["path"] for hit in context["other_matches"]} == set()
    finally:
        d.close()


def test_segments_and_files_outside_the_scope_are_refused(fake_helper, monkeypatch):
    monkeypatch.setenv("FAKE_SIMILAR", "1")
    d = digup(["docs"])
    try:
        with pytest.raises(Forbidden, match="search first"):
            d.text(31)
        d.search("zebra")
        assert d.text(31).startswith("Page three")
        with pytest.raises(Forbidden, match="search first"):
            d.text(12)   # todo.md's: the helper has it, but it's outside
        with pytest.raises(Forbidden, match="search first"):
            d.text(31, code=True)
        with pytest.raises(Forbidden, match="outside"):
            d.similar("/data/notes/todo.md")
        assert d.similar("/data/docs/lease.pdf").hits == [], "similar files outside the scope don't come back"
        with pytest.raises(Forbidden, match="outside"):
            d.render("/data/video/zoo.mp4")
        assert d.render("/data/docs/lease.pdf").endswith("render.jpg")
    finally:
        d.close()
    unscoped = digup([])
    try:
        assert unscoped.scope is None and unscoped.text(12) == "buy milk\nand bread", "no scope: as before"
    finally:
        unscoped.close()


def test_a_scope_that_isnt_indexed(fake_helper):
    d = digup(["/home/me/git/foo"])
    try:
        with pytest.raises(NotIndexed, match=r"/home/me/git/foo isn't indexed; start the server with "
                                             r"--allow-add-folders or add it in DigUp"):
            d.search("zebra")
        report = d.status()["scope"]
        assert report == [{"path": "/home/me/git/foo", "files": None, "code": None, "indexed": "no"}]
    finally:
        d.close()
    # Partly: only folders inside it are indexed.
    d = digup(["/data"], roots=["/data/docs"])
    try:
        assert [hit["path"] for hit in d.search("zebra").hits] == ["/data/docs/lease.pdf"]
        assert d.status()["scope"][0]["indexed"] == "partly"
    finally:
        d.close()


def test_a_scope_that_is_a_code_folder(fake_helper):
    d = digup(["/data/code"], roots=["/data/docs"], code_roots=["/data/code"])
    try:
        with pytest.raises(NotIndexed, match="code index, not its file index: search it with search_code"):
            d.search("retry")
        results = d.search("code: retry")
        assert [hit["path"] for hit in results.hits] == ["/data/code/retry.py"]
        assert d.text(77, code=True).startswith("import random")
        assert d.status()["scope"][0] == {"path": "/data/code", "files": None, "code": "yes", "indexed": "fully"}
    finally:
        d.close()
    d = digup(["/data/docs"], code_roots=["/data/code"])
    try:
        with pytest.raises(NotIndexed, match="file index, not its code index: search it with search_files"):
            d.search("code: retry")
    finally:
        d.close()


def test_results_while_it_is_indexed_are_partial(fake_helper):
    app = FakeApp(pending=["/data/docs"])
    d = digup(["docs"], app=app)
    try:
        results = d.search("zebra")
        assert results.partial == {"folders": ["/data/docs"], "state": "indexing", "done": 4, "total": 30}
        assert partial_text(results.partial) == ("DigUp is still indexing /data/docs (4 of 30 files read): these are "
                                                 "the results so far.")
        assert {"op": "reload"} in ops(fake_helper), "the index is reloaded so new files show"
        assert d.status()["scope"][0]["indexed"] == "partly"
        app.pending = []
        d._app_status = (0.0, None)
        assert d.search("zebra").partial is None
        assert d.status()["scope"][0]["indexed"] == "fully"
    finally:
        d.close()


def test_adding_needs_the_flag_and_stays_inside_the_scope(fake_helper):
    app = FakeApp()
    d = digup(["docs"], app=app)
    try:
        with pytest.raises(Forbidden, match="--allow-add-folders"):
            d.add_folder("/data/docs/new")
        assert app.asked == [], "the app isn't asked without the flag"
    finally:
        d.close()
    d = digup(["docs"], app=app, allow_add=True, max_files=500, tool="claude-code")
    try:
        with pytest.raises(Forbidden, match="outside the folders this server searches"):
            d.add_folder("/data/notes")
        answer = d.add_folder("docs/new")   # relative to where the server started
        assert app.asked[-1] == ("/data/docs/new", "claude-code", 500)
        assert answer["ok"] and "index_status" in answer["follow"]
    finally:
        d.close()


def test_the_apps_refusal_and_absence_are_said(fake_helper):
    refusing = FakeApp(answer={"ok": False, "message": "/home/me/huge has more than 500 files"})
    d = digup([], app=refusing, allow_add=True)
    try:
        with pytest.raises(Forbidden, match="more than 500 files"):
            d.add_folder("/home/me/huge")
    finally:
        d.close()
    d = digup([], allow_add=True)   # the real DesktopApp, on a bus that isn't there
    try:
        with pytest.raises(AppNotRunning, match="DigUp isn't running"):
            d.add_folder("/home/me/git/foo")
        assert DesktopApp().status() is None
    finally:
        d.close()


def test_an_unindexed_scope_is_added_on_first_use(fake_helper, tmp_path):
    settings = tmp_path / "settings.json"
    settings.write_text(json.dumps({"folders": ["/data/docs"]}))
    app = FakeApp(settings=settings)
    load = lambda: HelperConfig.load(settings=str(settings))   # noqa: E731
    d = DigUp(config=load(), scope=Scope.of(["/data/notes"]), app=app, allow_add=True, reload_config=load,
              tool="claude-code")
    try:
        d.client.start()   # running: it's told the new folders
        results = d.search("zebra")
        assert app.asked == [("/data/notes", "claude-code", 20_000)]
        assert d.config.roots == ["/data/docs", "/data/notes"]
        assert any(op.get("op") == "folders" and "/data/notes" in op["roots"] for op in ops(fake_helper))
        assert [hit["path"] for hit in results.hits] == ["/data/notes/todo.md"]
        assert results.partial and results.partial["folders"] == ["/data/notes"]
        assert results.notes and results.notes[0].startswith("claude-code added /data/notes to DigUp")
        d.search("zebra")
        assert len(app.asked) == 1, "added once"
    finally:
        d.close()
    # Without the app: said, and tried again later, not on every search.
    d = DigUp(config=HelperConfig.load(roots=["/data"], use_settings=False), scope=Scope.of(["/home/me/x"]),
              allow_add=True)
    try:
        with pytest.raises(NotIndexed, match="DigUp didn't add it: DigUp isn't running"):
            d.search("zebra")
        with pytest.raises(NotIndexed, match="isn't indexed") as second:
            d.search("zebra")
        assert "isn't running" not in str(second.value)
    finally:
        d.close()


def test_the_app_over_a_private_session_bus(fake_app, tmp_path):
    """digup_app's D-Bus calls, against the stand-in on its own dbus-daemon."""
    app = DesktopApp(timeout=5)
    home = tmp_path / "home"
    (home / "git" / "repo" / ".git").mkdir(parents=True)
    assert app.status() == {"ok": True, "state": "indexing", "done": 1, "total": 3, "pending": []}
    answer = app.add_folder(str(home / "git" / "repo"), "claude-code", 500)
    assert answer["ok"] and answer["code"] and answer["message"] == f"claude-code added {home}/git/repo to DigUp"
    assert json.loads(fake_app.read_text()) == {"codeFolders": [str(home / "git" / "repo")]}
    assert app.status()["pending"] == [str(home / "git" / "repo")]
    assert not app.add_folder("/etc", "x", 500)["ok"]
