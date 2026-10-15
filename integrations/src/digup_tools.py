"""What the MCP server and the HTTP API both do with DigUp's helper: searches with their arguments checked, a hit's
place in its file in words ("page 3", "0:06-0:12", "lines 1-33"), the indexed text of a hit, similar files, previews,
and RAG context (the top hits' texts with citations).

Folders: the helper restricts a search to `folders` when it knows that field; an older one ignores it, so hits are
also filtered here (from a larger set), and the answer is the same either way.

The scope (`--scope DIR`, `Scope`): a server pinned to some folders searches only inside them. A caller's `folders`
can narrow that, never widen it; hits outside never come back, and a segment or a file outside is refused. A scope
that isn't indexed is said so; with `--allow-add-folders` the desktop app is asked to add it (digup_app.py), and while
it's indexed the results are flagged as partial.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import subprocess
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable

from digup_app import AppNotRunning, DesktopApp
from digup_client import DigUpClient, DigUpError, HelperConfig, HelperError, absolute, find_helper, helper_env

KINDS = ("screenshot", "image", "pdf", "doc", "audio", "video")
KIND_ALIASES = {
    "screenshots": "screenshot", "images": "image", "photo": "image", "photos": "image", "picture": "image",
    "pictures": "image", "pdfs": "pdf", "document": "doc", "documents": "doc", "docs": "doc", "text": "doc",
    "audios": "audio", "recording": "audio", "recordings": "audio", "music": "audio", "videos": "video",
    "movie": "video", "movies": "video", "clip": "video",
}
RENDER_KINDS = ("pdf", "video", "image")
CODE_PREFIX = "code:"
MAX_LIMIT = 200
MAX_FILTER = 2000

# The keyword filter (KeywordFilter in DigUpKit), for the tools' and the API's descriptions.
FILTER_SYNTAX = (
    "Words are ANDed; AND, OR, NOT (or -word) in capitals; ( ) to group (NOT before AND before OR); "
    '"exact phrase"; word* (starts with), *word (ends with), *word* (inside a word, 3+ letters); codes and '
    "numbers as written (RE-2041, 2'380.50). Case, accents and ß/ss don't matter."
)


class BadRequest(DigUpError):
    """The caller's arguments are wrong (HTTP 400)."""


class Forbidden(DigUpError):
    """Outside what DigUp searches (HTTP 403)."""


class Unsupported(DigUpError):
    """This helper is older than the feature (HTTP 501)."""


class NotIndexed(DigUpError):
    """The folders asked for (the scope) aren't in DigUp's index, or not in this one (HTTP 409)."""


# How many files a folder a tool adds may have, unless --max-files says otherwise (the shell's tools::MAX_FILES).
MAX_FILES = 20_000


# MARK: Arguments


def code_query(query: str) -> str | None:
    """What follows "code:" (as DigUpKit's `CodeQuery`), or None for a query that isn't one of code."""
    trimmed = query.lstrip()
    if trimmed[: len(CODE_PREFIX)].lower() != CODE_PREFIX:
        return None
    return trimmed[len(CODE_PREFIX):].strip()


def kinds_of(value: Any) -> list[str] | None:
    """["pdf", "video"] from a list or "pdf, video"; aliases ("photos", "documents") allowed; None: all kinds."""
    if value is None or value == "" or value == []:
        return None
    items = value.split(",") if isinstance(value, str) else value
    if not isinstance(items, list):
        raise BadRequest("kinds must be a list of strings")
    kinds: list[str] = []
    for item in items:
        if not isinstance(item, str):
            raise BadRequest("kinds must be a list of strings")
        word = item.strip().lower()
        if not word:
            continue
        kind = KIND_ALIASES.get(word, word)
        if kind == "code":
            raise BadRequest("code isn't a kind of the file index: search code with search_code (or code: true)")
        if kind not in KINDS:
            raise BadRequest(f"unknown kind {item!r}: the kinds are {', '.join(KINDS)}")
        if kind not in kinds:
            kinds.append(kind)
    return kinds or None


def folders_of(value: Any) -> list[str] | None:
    """Absolute folders from a list or one string ("~/Documents" → "/home/you/Documents"); None: no restriction."""
    if value is None or value == "" or value == []:
        return None
    items = [value] if isinstance(value, str) else value
    if not isinstance(items, list) or not all(isinstance(item, str) for item in items):
        raise BadRequest("folders must be a list of paths")
    folders = [absolute(item) for item in items if item.strip()]
    return folders or None


def filter_of(value: Any) -> str | None:
    """The keyword filter as the helper takes it ("Rechnung* NOT Mahnung"); None: no filter."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise BadRequest("filter must be a string, e.g. Rechnung* AND (Uster OR Winterthur) NOT Mahnung")
    if len(value) > MAX_FILTER:
        raise BadRequest(f"filter is longer than {MAX_FILTER} characters")
    return value.strip() or None


def limit_of(value: Any, default: int = 10) -> int:
    if value is None:
        return default
    try:
        limit = int(value)
    except (TypeError, ValueError):
        raise BadRequest("limit must be a number") from None
    return max(1, min(limit, MAX_LIMIT))


def is_inside(path: str, folders: list[str]) -> bool:
    return any(path == folder or path.startswith(folder.rstrip("/") + "/") for folder in folders)


def shown(path: str) -> str:
    """`/home/you/git/app` → `~/git/app`, as people read it."""
    home = os.path.expanduser("~").rstrip("/")
    return "~" + path[len(home):] if home and path.startswith(home + "/") else path


# MARK: The scope


@dataclass
class Scope:
    """The folders a server is pinned to (`--scope`), absolute; `also` holds the same ones with their links resolved,
    where that differs (the index and the settings keep a folder added on the spot by its real path)."""

    folders: list[str]
    also: list[str] = field(default_factory=list)

    @classmethod
    def of(cls, dirs: list[str], cwd: str | None = None) -> Scope | None:
        """`--scope` values: absolute, `~/…`, or relative to `cwd` (where the server was started). None: no scope."""
        base = cwd or os.getcwd()
        folders: list[str] = []
        for value in dirs:
            if value.strip():
                folder = os.path.normpath(os.path.join(base, os.path.expanduser(value.strip())))
                if folder not in folders:
                    folders.append(folder)
        if not folders:
            return None
        also = []
        for folder in folders:
            real = os.path.realpath(folder)
            if real not in folders and real not in also:
                also.append(real)
        return cls(folders, also)

    @property
    def every(self) -> list[str]:
        return self.folders + self.also

    def contains(self, path: str) -> bool:
        return is_inside(path, self.every)

    def narrow(self, asked: list[str] | None) -> list[str]:
        """The folders to search: the caller's inside the scope, the scope's inside the caller's; the scope when the
        caller names none. Folders wholly outside it are refused."""
        if not asked:
            return self.every
        kept: list[str] = []
        for folder in asked:
            for inner in ([folder] if self.contains(folder) else [s for s in self.every if is_inside(s, [folder])]):
                if inner not in kept:
                    kept.append(inner)
        if not kept:
            raise Forbidden(f"{', '.join(shown(f) for f in asked)} is outside the folders this server searches "
                            f"({self.text()}): it was started with --scope")
        return kept

    def text(self) -> str:
        return ", ".join(shown(folder) for folder in self.folders)


def coverage(folder: str, roots: list[str], skipped: list[str]) -> str | None:
    """How an index covers `folder`: "yes" (it's in one of the roots, not in a folder skipped there), "partly" (roots
    lie inside it), or None. As FolderSelection (and adding.rs's `searched_in`) has it."""
    for root in roots:
        if is_inside(folder, [root]) and not any(
                is_inside(skip, [root]) and is_inside(folder, [skip]) for skip in skipped):
            return "yes"
    return "partly" if any(root != folder and is_inside(root, [folder]) for root in roots) else None


# MARK: Hits in words


def clock(seconds: float) -> str:
    whole = int(seconds)
    hours, rest = divmod(whole, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def _number(value: Any) -> str:
    return f"{value:g}" if isinstance(value, float) else str(value)


def where(hit: dict[str, Any]) -> str:
    """Where in the file the hit is: "page 3", "0:06-0:12 (frame)", "lines 1-33 (line 8)", "text", "the image"…"""
    segment = hit.get("segment")
    loc, end, focus = hit.get("loc"), hit.get("loc_end"), hit.get("focus")
    if segment == "lines" and loc is not None:
        span = f"lines {_number(loc)}-{_number(end)}" if end is not None and end != loc else f"line {_number(loc)}"
        return span + (f" (line {_number(focus)})" if focus is not None and focus != loc else "")
    if segment == "cells" and loc is not None:
        return f"cells {_number(loc)}-{_number(end)}" if end is not None and end != loc else f"cell {_number(loc)}"
    if segment in ("page", "page_image") and loc is not None:
        return f"page {int(loc)}" + (" (as an image)" if segment == "page_image" else "")
    if segment in ("frame", "audio") and loc is not None:
        span = f"{clock(loc)}-{clock(end)}" if end is not None and end != loc else clock(loc)
        return span + (" (picture)" if segment == "frame" else " (sound)")
    return {"name": "file name", "image": "the image", "ocr": "text in the image", "chunk": "text",
            "frame": "a frame", "audio": "the sound"}.get(str(segment), str(segment))


def compact(hit: dict[str, Any]) -> dict[str, Any]:
    """The few fields a caller needs: path, kind, where, score, segment_id (for the text) and the excerpt."""
    row: dict[str, Any] = {"path": hit.get("path"), "kind": hit.get("kind"), "where": where(hit),
                           "score": round(float(hit.get("score") or 0), 3), "segment_id": hit.get("segment_id")}
    for name in ("loc", "loc_end", "focus", "excerpt"):
        if hit.get(name) is not None:
            row[name] = hit[name]
    return row


def excerpt(hit: dict[str, Any]) -> str | None:
    """The excerpt on one line, keyword matches as they come from DigUp («like this»)."""
    text = hit.get("excerpt")
    return " ".join(text.split()) if isinstance(text, str) and text.strip() else None


# MARK: The operations


@dataclass
class Results:
    query: str
    code: bool
    hits: list[dict[str, Any]]
    strong: int            # the first `strong` hits are clear matches; the rest are weaker
    meaning: bool          # False: keyword matches only (the encoder couldn't run)
    warning: str | None = None
    ms: dict[str, Any] | None = None
    filter: str | None = None        # the keyword filter the hits are for
    filter_note: str | None = None   # how DigUp read a filter it couldn't read as written ("unclosed quote: …")
    # The folders searched are still being indexed: {"folders", "state", "done", "total"}; the hits are those so far.
    partial: dict[str, Any] | None = None
    notes: list[str] = field(default_factory=list)   # what's worth saying first ("Added ~/git/app to DigUp…")


def partial_text(partial: dict[str, Any]) -> str:
    """'DigUp is still indexing ~/git/app (40 of 300 files read): these are the results so far.'"""
    folders = ", ".join(shown(folder) for folder in partial.get("folders") or []) or "the folders searched"
    state = partial.get("state")
    if state == "paused":
        return f"{folders} isn't indexed through yet and indexing is paused in DigUp: these are the results so far."
    if state == "waiting":
        return f"{folders} waits for DigUp's model to download before it's indexed: these are the results so far."
    done, total = partial.get("done") or 0, partial.get("total") or 0
    progress = f" ({done} of {total} files read)" if total else ""
    return f"DigUp is still indexing {folders}{progress}: these are the results so far."


class DigUp:
    """DigUp's search for an integration: one helper, started on the first use and shared by every caller.

    `scope`: the folders every search is pinned to (None: all of the index). `allow_add`: folders may be added
    through the desktop app (`app`), with at most `max_files` files; an unindexed scope is added on first use.
    `reload_config`: the configuration loaded again (the app's settings change when a folder is added); `tool`: the
    name the app's notification shows."""

    def __init__(self, client: DigUpClient | None = None, config: HelperConfig | None = None, *,
                 scope: Scope | None = None, allow_add: bool = False, max_files: int = MAX_FILES,
                 app: DesktopApp | None = None, reload_config: Callable[[], HelperConfig] | None = None,
                 tool: str = "digup", cwd: str | None = None):
        self.client = client or DigUpClient(config)
        self.config = self.client.config
        self.scope = scope
        self.allow_add = allow_add
        self.max_files = max_files
        self.app = app or DesktopApp()
        self.reload_config = reload_config
        self.tool = tool
        self.cwd = cwd or os.getcwd()   # where relative folders are taken from: where the server started
        self._lock = threading.RLock()
        # Segments this server returned (code?, id) → path: with a scope, only these are read.
        self._served: collections.OrderedDict[tuple[bool, int], str] = collections.OrderedDict()
        self._tried: dict[str, float] = {}          # scope folders asked to be added, and when
        self._added: list[str] = []                 # folders added through this server
        self._notes: list[str] = []                 # for the next answer
        self._app_status: tuple[float, dict[str, Any] | None] = (0.0, None)
        self._config_read = time.monotonic()
        self._reloaded = 0.0
        self._was_partial = False

    def close(self) -> None:
        self.client.close()

    # MARK: The scope, adding, and indexing still under way

    def _covered(self, folder: str, code: bool) -> str | None:
        """How the file index (or the code index) covers `folder`: "yes", "partly" or None."""
        if code:
            roots, skipped = self.config.code_roots, self.config.code_excludes
        else:
            roots, skipped = self.config.roots, self.config.excludes
            if not roots:
                return "yes"   # no folders given: the whole index is searched
        best = None
        for variant in dict.fromkeys([folder, os.path.realpath(folder)]):
            found = coverage(variant, roots, skipped)
            if found == "yes":
                return "yes"
            best = best or found
        return best

    def refresh(self, force: bool = False, every: float | None = None) -> bool:
        """Loads the configuration again (the app's settings: a folder was added) when `force`, or when it was read
        more than `every` seconds ago; a running helper is told the new folders. True when they changed."""
        if self.reload_config is None:
            return False
        with self._lock:
            now = time.monotonic()
            if not force and (every is None or now - self._config_read < every):
                return False
            self._config_read = now
            try:
                fresh = self.reload_config()
            except DigUpError:
                return False
            names = ("roots", "excludes", "exclude_ext", "code_roots", "code_excludes", "settings_file")
            if all(getattr(fresh, name) == getattr(self.config, name) for name in names):
                return False
            for name in names:
                setattr(self.config, name, getattr(fresh, name))   # the client's too: a restart starts with them
        if self.client.running:
            try:
                self.client.request("folders", roots=self.config.roots, skipped=self.config.excludes,
                                    types=self.config.exclude_ext, code_roots=self.config.code_roots,
                                    code_skipped=self.config.code_excludes)
                self.client.request("reload")
            except DigUpError:
                pass
        return True

    def add_folder(self, path: Any, tool: str | None = None) -> dict[str, Any]:
        """Asks the desktop app to add a folder (only with `allow_add`; inside the scope when there is one). The app's
        answer, with how to follow the indexing; `Forbidden` when it says no, `AppNotRunning` when it isn't there."""
        if not self.allow_add:
            raise Forbidden("adding folders is off: start the server with --allow-add-folders")
        if not isinstance(path, str) or not path.strip():
            raise BadRequest("path is empty")
        folder = os.path.normpath(os.path.join(self.cwd, os.path.expanduser(path.strip())))
        if self.scope is not None and not self.scope.contains(folder) and \
                not self.scope.contains(os.path.realpath(folder)):
            raise Forbidden(f"{shown(folder)} is outside the folders this server searches ({self.scope.text()})")
        answer = self.app.add_folder(folder, tool or self.tool, self.max_files)
        if answer.get("ok") is not True:
            raise Forbidden(str(answer.get("message") or "DigUp didn't add it"))
        with self._lock:
            added = str(answer.get("path") or folder)
            if answer.get("added") and added not in self._added:
                self._added.append(added)
            self._app_status = (0.0, None)
        self.refresh(force=True)
        if answer.get("added"):
            answer["follow"] = ("It's being indexed now; searches return what's read so far (flagged as partial), and "
                                "index_status (GET /status) says how far it is.")
        return answer

    def _ensure_scope(self) -> None:
        """With a scope: the settings read again now and then while part of it isn't indexed (it may have been added
        in DigUp), and, with `allow_add`, a scope folder in neither index added (once; again after 30 s when that
        failed)."""
        if self.scope is None:
            return
        missing = [f for f in self.scope.folders if not self._covered(f, False) and not self._covered(f, True)]
        if not missing:
            return
        if self.refresh(every=10.0):
            missing = [f for f in missing if not self._covered(f, False) and not self._covered(f, True)]
        if not self.allow_add:
            return
        for folder in missing:
            with self._lock:
                tried = self._tried.get(folder)
                if tried is not None and (tried == float("inf") or time.monotonic() - tried < 30):
                    continue
                self._tried[folder] = time.monotonic()
            try:
                answer = self.add_folder(folder)
            except DigUpError as error:
                self._say(f"{shown(folder)} isn't indexed, and DigUp didn't add it: {error}")
                continue
            with self._lock:
                self._tried[folder] = float("inf")
            self._say(f"{answer.get('message') or 'Added ' + shown(folder)} {answer.get('follow', '')}".strip())

    def _say(self, note: str) -> None:
        with self._lock:
            if note not in self._notes:
                self._notes.append(note)

    def _take_notes(self) -> list[str]:
        with self._lock:
            notes, self._notes = self._notes, []
        return notes

    def _effective(self, folders: Any, code: bool) -> tuple[list[str] | None, list[str]]:
        """The folders a search covers: the caller's, narrowed to the scope; those the index has nothing of are left
        out with a note, and when none is left, `NotIndexed` says why."""
        asked = folders_of(folders)
        if self.scope is None:
            return asked, []
        self._ensure_scope()
        kept, notes = [], []
        for folder in self.scope.narrow(asked):
            covered = self._covered(folder, code)
            if covered == "yes":
                kept.append(folder)
                continue
            if covered == "partly":   # only the indexed folders in it
                roots = self.config.code_roots if code else self.config.roots
                kept += [root for root in roots if root not in kept and is_inside(root, [folder])]
                continue
            if self._covered(folder, not code) == "yes":
                notes.append(f"{shown(folder)} is in DigUp's file index, not its code index: search it with "
                             "search_files" if code else
                             f"{shown(folder)} is in DigUp's code index, not its file index: search it with "
                             "search_code (code: true over HTTP)")
            elif self.allow_add:
                notes.append(f"{shown(folder)} isn't indexed (DigUp didn't add it; index_status says why)")
            else:
                notes.append(f"{shown(folder)} isn't indexed; start the server with --allow-add-folders or add it in "
                             "DigUp")
        notes = list(dict.fromkeys(notes))
        if not kept:
            raise NotIndexed("; ".join(self._take_notes() + notes))
        return kept, notes

    def _status_of_app(self) -> dict[str, Any] | None:
        """The app's indexing (digup_app's Status), at most every 2 s."""
        with self._lock:
            at, status = self._app_status
            if time.monotonic() - at < 2.0:
                return status
        try:
            status = self.app.status()
        except DigUpError:
            status = None
        with self._lock:
            self._app_status = (time.monotonic(), status)
        return status

    def _partial(self, folders: list[str] | None) -> dict[str, Any] | None:
        """The folders searched that the app is still indexing for the first time, and how far it is; None when none
        are (or no one can say). While they are, the helper reloads the index every few seconds, so new files show."""
        if self.scope is None and not self._added:
            return None
        status = self._status_of_app()
        pending = [str(path) for path in (status or {}).get("pending") or []]
        if folders:
            pending = [path for path in pending
                       if is_inside(path, folders) or any(is_inside(folder, [path]) for folder in folders)]
        reload = False
        with self._lock:
            now = time.monotonic()
            if pending and now - self._reloaded > 3.0 or not pending and self._was_partial:
                self._reloaded, reload = now, True
            self._was_partial = bool(pending)
        if reload:
            try:
                self.client.request("reload")
            except DigUpError:
                pass
        if not pending:
            return None
        return {"folders": pending, "state": status.get("state"), "done": status.get("done"),
                "total": status.get("total")}

    def scope_report(self) -> list[dict[str, Any]]:
        """Each scope folder: in which index, and whether it's indexed fully, partly (being indexed, or only some
        folders in it), or not at all."""
        if self.scope is None:
            return []
        self._ensure_scope()
        status = self._status_of_app()
        pending = [str(path) for path in (status or {}).get("pending") or []]
        rows = []
        for folder in self.scope.folders:
            files, code = self._covered(folder, False), self._covered(folder, True)
            row: dict[str, Any] = {"path": folder, "files": files, "code": code}
            going = [path for path in pending if is_inside(path, [folder]) or is_inside(folder, [path])]
            if going:
                row["indexed"] = "partly"
                row["indexing"] = {"state": status.get("state"), "done": status.get("done"),
                                   "total": status.get("total"), "folders": going}
            elif "yes" in (files, code):
                row["indexed"] = "fully"
            elif "partly" in (files, code):
                row["indexed"] = "partly"
                inner = [r for r in self.config.roots + self.config.code_roots if r != folder and is_inside(r, [folder])]
                row["inside"] = inner
            else:
                row["indexed"] = "no"
            rows.append(row)
        return rows

    def _remember(self, hits: list[dict[str, Any]], code: bool) -> None:
        """With a scope: the segments returned, so read_segment reads only those."""
        if self.scope is None:
            return
        with self._lock:
            for hit in hits:
                for key in ("segment_id", "text_segment_id"):
                    if isinstance(hit.get(key), int):
                        self._served[(code, hit[key])] = str(hit.get("path", ""))
                        self._served.move_to_end((code, hit[key]))
            while len(self._served) > 50_000:
                self._served.popitem(last=False)

    def search(self, query: str, *, kinds: Any = None, folders: Any = None, limit: Any = 10,
               code: bool | None = None, meaning: bool = True, filter: Any = None) -> Results:
        """`filter`: the keyword filter (FILTER_SYNTAX): only the files whose text has it, ranked by `query`, each hit
        where its words are; `query` may be empty then (ranked by how well the filter's words match)."""
        keywords = filter_of(filter)
        if query is None:
            query = ""
        if not isinstance(query, str):
            raise BadRequest("query must be a string")
        if not query.strip() and not keywords:
            raise BadRequest("query is empty (give a query, a filter, or both)")
        stripped = code_query(query)
        text = stripped if stripped is not None else query.strip()
        code = bool(code) or stripped is not None
        if code and not text and not keywords:
            raise BadRequest('"code:" needs words after it (or a filter)')
        kinds = None if code else kinds_of(kinds)
        folders, notes = self._effective(folders, code)
        limit = limit_of(limit)
        if code and not self.config.code_roots:
            raise BadRequest("no code folders are set, so the code index isn't searched: start the integration with "
                             "--code-root DIR (or set DIGUP_CODE_ROOTS)")
        fields: dict[str, Any] = {"q": text, "code": code, "meaning": meaning,
                                  "limit": min(max(limit * 5, 50), 400) if folders else limit}
        if kinds:
            fields["kinds"] = kinds
        if folders:
            fields["folders"] = folders
        if keywords:
            fields["filter"] = keywords
        partial = self._partial(folders)   # first: it reloads the index while new files come in
        reply = self.client.request("search", **fields)
        hits, strong = self._kept(reply, kinds, folders, limit)
        self._remember(hits, code)
        return Results(query=text, code=code, hits=hits, strong=strong, meaning=bool(reply.get("meaning")),
                       warning=reply.get("warning"), ms=reply.get("ms"), filter=keywords,
                       filter_note=reply.get("filter_note"), partial=partial, notes=self._take_notes() + notes)

    def _kept(self, reply: dict[str, Any], kinds: list[str] | None, folders: list[str] | None,
              limit: int) -> tuple[list[dict[str, Any]], int]:
        """The reply's hits in the kinds and folders asked for, and how many of them are strong."""
        hits = [hit for hit in reply.get("hits") or [] if isinstance(hit, dict)]
        strong_before = int(reply.get("strong") or 0)
        kept, strong = [], 0
        for index, hit in enumerate(hits):
            if folders and not is_inside(str(hit.get("path", "")), folders):
                continue
            if kinds and hit.get("kind") not in kinds:
                continue
            kept.append(hit)
            strong += index < strong_before
        return kept[:limit], min(strong, limit)

    def text(self, segment_id: Any, code: bool = False) -> str | None:
        try:
            segment = int(segment_id)
        except (TypeError, ValueError):
            raise BadRequest("segment_id must be a number (a hit's segment_id)") from None
        if self.scope is not None:
            # A segment says nothing of its file, so with a scope only the segments of results given here are read.
            with self._lock:
                path = self._served.get((bool(code), segment))
            if path is None:
                raise Forbidden(f"segment {segment} isn't one of this server's results: it reads only segments of "
                                f"its own search results (it searches {self.scope.text()}), so search first")
            if not self.scope.contains(path):
                raise Forbidden(f"segment {segment} is of {path}, outside {self.scope.text()}")
        return self.client.request("text", segment=segment, code=bool(code)).get("text")

    def similar(self, path: str, *, limit: Any = 10, kinds: Any = None, folders: Any = None) -> Results:
        if not isinstance(path, str) or not path.strip():
            raise BadRequest("path is empty")
        if self.scope is not None and not self.scope.contains(absolute(path)):
            raise Forbidden(f"{shown(absolute(path))} is outside the folders this server searches ({self.scope.text()})")
        kinds, limit = kinds_of(kinds), limit_of(limit)
        folders, notes = self._effective(folders, False)
        fields: dict[str, Any] = {"path": absolute(path), "limit": min(max(limit * 5, 50), 400) if folders else limit}
        if kinds:
            fields["kinds"] = kinds
        if folders:
            fields["folders"] = folders
        try:
            reply = self.client.request("similar", **fields)
        except HelperError as error:
            if error.unsupported:
                raise Unsupported("finding similar files needs a newer DigUp helper (one with the `similar` op); "
                                  "search by describing the file instead") from None
            raise
        hits, strong = self._kept(reply, kinds, folders, limit)
        hits = [hit for hit in hits if hit.get("path") != fields["path"]]
        self._remember(hits, False)
        return Results(query=fields["path"], code=False, hits=hits, strong=min(strong, len(hits)),
                       meaning=bool(reply.get("meaning", True)), warning=reply.get("warning"),
                       partial=self._partial(folders), notes=self._take_notes() + notes)

    def render(self, path: str, kind: str | None = None, loc: Any = None, pixels: Any = 1024) -> str:
        """A JPEG of a PDF's page, a video's frame at `loc` seconds, or a picture; its path."""
        if not isinstance(path, str) or not path.strip():
            raise BadRequest("path is empty")
        path = absolute(path)
        if kind is None:
            extension = os.path.splitext(path)[1].lower()
            kind = "pdf" if extension == ".pdf" else "video" if extension in (
                ".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi", ".ts", ".mts") else "image"
        if kind == "screenshot":
            kind = "image"
        if kind not in RENDER_KINDS:
            raise BadRequest(f"previews are of {', '.join(RENDER_KINDS)}, not {kind}")
        allowed = self.config.roots + self.config.code_roots
        if allowed and not is_inside(path, allowed):
            raise Forbidden("that file isn't in a folder DigUp searches")
        if self.scope is not None and not self.scope.contains(path):
            raise Forbidden(f"that file is outside the folders this server searches ({self.scope.text()})")
        try:
            size = max(32, min(int(pixels or 1024), 2048))
        except (TypeError, ValueError):
            raise BadRequest("pixels must be a number") from None
        fields: dict[str, Any] = {"path": path, "kind": kind, "pixels": size}
        if loc is not None and loc != "":
            try:
                fields["loc"] = float(loc)
            except (TypeError, ValueError):
                raise BadRequest("loc must be a number (a PDF page, or seconds into a video)") from None
        image = self.client.request("render", timeout=120, **fields).get("image")
        if not isinstance(image, str):
            raise DigUpError("digup render gave no image")
        return image

    def status(self) -> dict[str, Any]:
        reply = self.client.request("status")
        try:
            helper = str(find_helper(self.config.helper))
        except DigUpError as error:
            helper = str(error)
        status = {**reply, "helper": helper, "roots": self.config.roots, "excludes": self.config.excludes,
                  "code_roots": self.config.code_roots, "settings": self.config.settings_file,
                  "helper_starts": self.client.starts, "allow_add_folders": self.allow_add}
        if self.scope is not None:
            status["scope"] = self.scope_report()
        if self.scope is not None or self.allow_add:
            app = self._status_of_app()
            status["app"] = app if app is not None else {"running": False}
            if self.allow_add:
                status["max_files"] = self.max_files
        notes = self._take_notes()
        if notes:
            status["notes"] = notes
        return status

    def doctor(self, timeout: float = 60) -> dict[str, Any]:
        """`digup doctor --json`, when this helper has it."""
        helper = find_helper(self.config.helper)
        args = [str(helper), "doctor", "--json"] + (["--index", absolute(self.config.index)] if self.config.index else [])
        env = helper_env(helper)
        env.update(self.config.env)
        try:
            done = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise DigUpError(f"digup doctor didn't finish: {error}") from None
        try:
            return json.loads(done.stdout)
        except ValueError:
            raise Unsupported(f"`digup doctor --json` isn't available in this helper (exit {done.returncode})") \
                from None

    def context(self, query: str, *, limit: Any = 5, max_chars: Any = 6000, kinds: Any = None, folders: Any = None,
                code: bool | None = None, filter: Any = None) -> dict[str, Any]:
        """For RAG: the top hits' indexed texts, numbered, each under its citation (path and page or time). With
        `filter`, only files with its words, each text the part where they are."""
        try:
            budget = max(200, min(int(max_chars if max_chars is not None else 6000), 200_000))
        except (TypeError, ValueError):
            raise BadRequest("max_chars must be a number") from None
        limit = limit_of(limit, 5)
        results = self.search(query, kinds=kinds, folders=folders, limit=limit, code=code, filter=filter)
        per_hit = max(400, budget // max(1, min(limit, len(results.hits) or 1)))
        parts, sources, others, used = [], [], [], 0
        for hit in results.hits:
            text = self.text(hit.get("segment_id"), code=results.code) if hit.get("segment_id") is not None else None
            text = (text or "").strip()
            if not text:
                # A screenshot's hit points at the image, its OCR text is only in the excerpt
                text = (excerpt(hit) or "").replace("«", "").replace("»", "")
            if not text:
                others.append(compact(hit))   # a picture or a frame: nothing to read, but it matched
                continue
            room = min(per_hit, budget - used)
            if room < 100:
                break
            if len(text) > room:
                text = text[: room - 1].rstrip() + "…"
            number = len(sources) + 1
            citation = f"{hit.get('path')} ({where(hit)})"
            parts.append(f"[{number}] {citation}\n{text}")
            used += len(text)
            sources.append({"n": number, "citation": citation, **compact(hit)})
        reply = {"query": results.query, "code": results.code, "meaning": results.meaning,
                 "context": "\n\n".join(parts), "sources": sources, "other_matches": others,
                 "chars": used}
        if results.filter:
            reply["filter"] = results.filter
        if results.filter_note:
            reply["filter_note"] = results.filter_note
        if results.partial:
            reply["partial"] = True
            reply["indexing"] = results.partial
        if results.notes:
            reply["notes"] = results.notes
        return reply


# MARK: Command lines


def add_helper_arguments(parser: argparse.ArgumentParser) -> None:
    """The flags both servers take to say which helper, index and folders."""
    group = parser.add_argument_group("DigUp")
    group.add_argument("--helper", help="the digup binary (default: $DIGUP_HELPER, digup on PATH, the repo's build)")
    group.add_argument("--index", help="the index folder (default: $DIGUP_INDEX, else DigUp's own)")
    group.add_argument("--root", action="append", default=[], metavar="DIR",
                       help="a folder to search (repeatable; default: $DIGUP_ROOTS, else the desktop app's folders)")
    group.add_argument("--exclude", action="append", default=[], metavar="DIR", help="a folder to leave out")
    group.add_argument("--exclude-ext", action="append", default=[], metavar="EXT", help="an extension to leave out")
    group.add_argument("--code-root", action="append", default=[], metavar="DIR",
                       help="a code folder (repeatable; default: $DIGUP_CODE_ROOTS); code search needs one")
    group.add_argument("--settings", help="the desktop app's settings.json (default: its usual place)")
    group.add_argument("--no-settings", action="store_true", help="don't read the desktop app's settings")
    group.add_argument("--encoder-idle", type=float, help="seconds before the idle encoder exits (default 300)")
    group.add_argument("--timeout", type=float, default=60.0, help="seconds to wait for a reply (default 60)")


    group = parser.add_argument_group("Pinning and adding folders")
    group.add_argument("--scope", action="append", default=[], metavar="DIR",
                       help="search only inside DIR (repeatable; absolute, ~/ or relative to where this starts; "
                            "default: $DIGUP_SCOPE, else everything DigUp searches)")
    group.add_argument("--allow-add-folders", action="store_true",
                       help="let callers add folders to DigUp (through the running desktop app, which shows a "
                            "notification with Undo); an unindexed --scope is added on first use")
    group.add_argument("--max-files", type=int, default=MAX_FILES, metavar="N",
                       help=f"with --allow-add-folders: a folder with more files isn't added (default {MAX_FILES})")


def config_from(args: argparse.Namespace) -> HelperConfig:
    return HelperConfig.load(helper=args.helper, index=args.index, roots=args.root, excludes=args.exclude,
                             exclude_ext=args.exclude_ext, code_roots=args.code_root,
                             encoder_idle=args.encoder_idle, settings=args.settings,
                             use_settings=not args.no_settings)


def scope_from(args: argparse.Namespace) -> Scope | None:
    """`--scope`, else $DIGUP_SCOPE (os.pathsep-separated), taken from where the server was started."""
    dirs = list(args.scope or []) or [part for part in os.environ.get("DIGUP_SCOPE", "").split(os.pathsep)
                                      if part.strip()]
    return Scope.of(dirs)


def digup_from(args: argparse.Namespace, tool: str) -> DigUp:
    """The server's DigUp: its helper's configuration, the scope, adding folders when allowed. `tool`: the name the
    desktop app's notification shows."""
    return DigUp(config=config_from(args), scope=scope_from(args), allow_add=args.allow_add_folders,
                 max_files=args.max_files, reload_config=lambda: config_from(args), tool=tool)
