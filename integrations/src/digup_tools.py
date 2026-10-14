"""What the MCP server and the HTTP API both do with DigUp's helper: searches with their arguments checked, a hit's
place in its file in words ("page 3", "0:06-0:12", "lines 1-33"), the indexed text of a hit, similar files, previews,
and RAG context (the top hits' texts with citations).

Folders: the helper restricts a search to `folders` when it knows that field; an older one ignores it, so hits are
also filtered here (from a larger set), and the answer is the same either way.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from dataclasses import dataclass
from typing import Any

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


class BadRequest(DigUpError):
    """The caller's arguments are wrong (HTTP 400)."""


class Forbidden(DigUpError):
    """Outside what DigUp searches (HTTP 403)."""


class Unsupported(DigUpError):
    """This helper is older than the feature (HTTP 501)."""


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


class DigUp:
    """DigUp's search for an integration: one helper, started on the first use and shared by every caller."""

    def __init__(self, client: DigUpClient | None = None, config: HelperConfig | None = None):
        self.client = client or DigUpClient(config)
        self.config = self.client.config

    def close(self) -> None:
        self.client.close()

    def search(self, query: str, *, kinds: Any = None, folders: Any = None, limit: Any = 10,
               code: bool | None = None, meaning: bool = True) -> Results:
        if not isinstance(query, str) or not query.strip():
            raise BadRequest("query is empty")
        stripped = code_query(query)
        text = stripped if stripped is not None else query.strip()
        code = bool(code) or stripped is not None
        if code and not text:
            raise BadRequest('"code:" needs words after it')
        kinds = None if code else kinds_of(kinds)
        folders = folders_of(folders)
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
        reply = self.client.request("search", **fields)
        hits, strong = self._kept(reply, kinds, folders, limit)
        return Results(query=text, code=code, hits=hits, strong=strong, meaning=bool(reply.get("meaning")),
                       warning=reply.get("warning"), ms=reply.get("ms"))

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
        return self.client.request("text", segment=segment, code=bool(code)).get("text")

    def similar(self, path: str, *, limit: Any = 10, kinds: Any = None, folders: Any = None) -> Results:
        if not isinstance(path, str) or not path.strip():
            raise BadRequest("path is empty")
        kinds, folders, limit = kinds_of(kinds), folders_of(folders), limit_of(limit)
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
        return Results(query=fields["path"], code=False, hits=hits, strong=min(strong, len(hits)),
                       meaning=bool(reply.get("meaning", True)), warning=reply.get("warning"))

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
        return {**reply, "helper": helper, "roots": self.config.roots, "excludes": self.config.excludes,
                "code_roots": self.config.code_roots, "settings": self.config.settings_file,
                "helper_starts": self.client.starts}

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
                code: bool | None = None) -> dict[str, Any]:
        """For RAG: the top hits' indexed texts, numbered, each under its citation (path and page or time)."""
        try:
            budget = max(200, min(int(max_chars if max_chars is not None else 6000), 200_000))
        except (TypeError, ValueError):
            raise BadRequest("max_chars must be a number") from None
        limit = limit_of(limit, 5)
        results = self.search(query, kinds=kinds, folders=folders, limit=limit, code=code)
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
        return {"query": results.query, "code": results.code, "meaning": results.meaning,
                "context": "\n\n".join(parts), "sources": sources, "other_matches": others,
                "chars": used}


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


def config_from(args: argparse.Namespace) -> HelperConfig:
    return HelperConfig.load(helper=args.helper, index=args.index, roots=args.root, excludes=args.exclude,
                             exclude_ext=args.exclude_ext, code_roots=args.code_root,
                             encoder_idle=args.encoder_idle, settings=args.settings,
                             use_settings=not args.no_settings)
