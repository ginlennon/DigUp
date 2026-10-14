"""DigUp as an MCP server: search the files on this computer by meaning from a coding agent (Claude Code, Cursor,
VS Code, Zed…).

    uv run --project <repo>/integrations digup-mcp [--root DIR]… [--code-root DIR]… [--index DIR]
    uv run --project <repo>/integrations digup-mcp --http [--port 8765]     # streamable HTTP on 127.0.0.1

It runs DigUp's helper (`digup search-service`) on the first tool call and keeps it for the session, so a search
costs tens of milliseconds once the encoder is warm. Everything stays on this computer.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import sys
import threading
from collections.abc import AsyncIterator
from typing import Annotated, Any

from pydantic import Field

from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ToolAnnotations

from digup_client import DigUpError, HelperConfig
from digup_tools import FILTER_SYNTAX, KINDS, DigUp, Results, add_helper_arguments, config_from, excerpt, where

INSTRUCTIONS = """\
DigUp is an on-device semantic search engine for the user's own files on this computer. It has indexed the folders \
the user chose: documents and notes (doc), PDFs page by page (pdf), photos and pictures (image), screenshots with \
their text read by OCR (screenshot), audio by what is said and heard (audio) and videos by their frames and sound \
(video), plus, separately, code folders (source files, a repo's docs and notebooks). Queries are matched by meaning \
(EmbeddingGemma 2) and by words, in many languages, so describe what you are looking for in plain words \
("the lease agreement with the deposit clause", "a photo of a zebra", "where we retry with backoff"). Results are \
local files with absolute paths you can open; a hit also says where in the file it is (a PDF page, a moment in a \
video, a range of lines). Use read_segment with a hit's segment number to read the passage that matched. When exact \
words must be in the file (a name, a number, a code, German compounds), add a filter (Rechnung* NOT Mahnung, \
*kaution*, "Bahnhofstrasse 12"): it decides which files appear, the query ranks them.\
"""

READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)

_config = HelperConfig()
_digup: DigUp | None = None
_digup_lock = threading.Lock()


def digup() -> DigUp:
    """The session's DigUp (its helper starts on the first request)."""
    global _digup
    with _digup_lock:
        if _digup is None:
            _digup = DigUp(config=_config)
        return _digup


@contextlib.asynccontextmanager
async def lifespan(_: MCPServer) -> AsyncIterator[None]:
    try:
        yield None
    finally:
        with _digup_lock:
            if _digup is not None:
                _digup.close()


mcp = MCPServer("digup", instructions=INSTRUCTIONS, lifespan=lifespan)


def _call(action: Any) -> Any:
    try:
        return action()
    except DigUpError as error:
        raise ToolError(str(error)) from None


def format_results(results: Results, heading: str, *, code: bool = False) -> str:
    """A numbered list, one hit in two or three short lines: the path, then kind · where · score · segment, then the
    excerpt. Weaker matches come after a marker."""
    if not results.hits:
        lines = [f"{heading}: no matches."]
        if results.filter_note:
            lines.append(f"(Filter: {results.filter_note})")
        if results.filter:
            lines.append("(No file has the filter's words: words match whole, so try word* or *word*.)")
        elif not results.meaning:
            lines.append("(Keyword matching only: DigUp's encoder isn't running, so meaning wasn't searched.)")
        if results.warning:
            lines.append(f"(DigUp: {results.warning})")
        return "\n".join(lines)
    how = "by meaning and words" if results.meaning else "by words only (the encoder isn't running)"
    if results.filter and not results.query:
        how = "with the filter's words, best match first"
    count = len(results.hits)
    lines = [f"{heading}: {count} match{'es' if count != 1 else ''} {how}; {results.strong} strong."]
    if results.filter_note:
        lines.append(f"(Filter: {results.filter_note})")
    if results.warning:
        lines.append(f"(DigUp: {results.warning})")
    for index, hit in enumerate(results.hits):
        if index == results.strong and index > 0:
            lines.append("-- weaker matches --")
        details = [str(hit.get("kind")), where(hit), f"score {float(hit.get('score') or 0):.2f}"]
        if hit.get("segment_id") is not None:
            details.append(f"segment {hit['segment_id']}")
        lines.append(f"{index + 1}. {hit.get('path')}")
        lines.append("   " + " · ".join(details))
        text = excerpt(hit)
        if text:
            lines.append(f"   > {text[:300]}")
    reader = "read_segment(segment_id, code=True)" if code else "read_segment(segment_id)"
    lines.append(f"Read a match's indexed text with {reader}.")
    return "\n".join(lines)


def heading(results: Results, what: str) -> str:
    """'DigUp results for "invoice" filtered by Rechnung* NOT Mahnung'."""
    parts = [what] + ([f'for "{results.query}"'] if results.query else []) \
        + ([f"filtered by {results.filter}"] if results.filter else [])
    return " ".join(parts)


FILTER_HELP = ("Optional: exact words the file must contain. Only matching files are returned, ranked by query "
               "(query may be empty: then ranked by these words). Each hit points at the page/moment/lines where "
               "they are. ")


@mcp.tool(annotations=READ_ONLY)
def search_files(
    query: Annotated[str, Field(description="What to find, in plain words (any language): what the file is about, "
                                            "what's in the picture, what's said in the recording. May be empty "
                                            "when filter is given")] = "",
    filter: Annotated[str | None, Field(description=FILTER_HELP + FILTER_SYNTAX + " Looks at file and folder names, "
                                        "document and PDF text, text in screenshots and transcripts. Example: "
                                        "Rechnung* AND (Uster OR Winterthur) NOT Mahnung")] = None,
    kinds: Annotated[list[str] | None, Field(description=f"Only these kinds of files: {', '.join(KINDS)} "
                                                         "(default: all)")] = None,
    folders: Annotated[list[str] | None, Field(description="Only files inside these folders (absolute or ~/ paths; "
                                                           "default: every folder DigUp indexes)")] = None,
    limit: Annotated[int, Field(description="How many results at most", ge=1, le=100)] = 10,
) -> str:
    """Search the user's own files on this computer by meaning and words with DigUp (on-device; nothing leaves the
    machine). Finds documents, PDFs (by page), photos, screenshots (with their text), audio (by speech and sound) and
    videos (by frames and sound) in the folders DigUp indexes. Returns absolute paths, the kind, where in the file the
    match is (page, time, lines), a relevance score, an excerpt, and a segment number for read_segment. Results above
    the "weaker matches" line are clear matches. Use filter when exact words, a name, a number or a code must be in
    the file (German compounds and plurals: *kaution*, Rechnung*). For source code use search_code instead."""
    results = _call(lambda: digup().search(query, kinds=kinds, folders=folders, limit=limit, filter=filter))
    return format_results(results, heading(results, "DigUp results"))


@mcp.tool(annotations=READ_ONLY)
def search_code(
    query: Annotated[str, Field(description="What the code does, or a name in it: \"retry with exponential "
                                            "backoff\", \"where the config file is parsed\", \"PaymentDeclined\". "
                                            "May be empty when filter is given")] = "",
    filter: Annotated[str | None, Field(description=FILTER_HELP + FILTER_SYNTAX + " Looks at the code's text and "
                                        "file names. Example: *_handler AND retry* NOT test")] = None,
    limit: Annotated[int, Field(description="How many results at most", ge=1, le=100)] = 10,
) -> str:
    """Search DigUp's code index (the code folders the user chose: source files, their repos' docs and notebooks) by
    what the code does, on-device. Same as a DigUp search starting with "code:". Returns absolute file paths with the
    line range of the matching stretch (and the line to open at), a score and a segment number; read the stretch with
    read_segment(segment_id, code=True). Use filter when exact names or words must be in the file."""
    results = _call(lambda: digup().search(query, limit=limit, code=True, filter=filter))
    return format_results(results, heading(results, "DigUp code results"), code=True)


@mcp.tool(annotations=READ_ONLY)
def read_segment(
    segment_id: Annotated[int, Field(description="The segment number of a search result")],
    code: Annotated[bool, Field(description="True for a result of search_code")] = False,
    max_chars: Annotated[int, Field(description="Cut the text after this many characters", ge=200,
                                    le=100_000)] = 8000,
) -> str:
    """Read the text DigUp indexed for one search result: the matching chunk of a document, the text of a PDF page,
    the text read from a screenshot, or the stretch of a code file. Use it to quote or answer from a file without
    opening the whole file. Pictures and video frames have no text."""
    text = _call(lambda: digup().text(segment_id, code=code))
    if not text:
        return f"Segment {segment_id} has no indexed text (a picture or a frame), or it isn't in the index any more."
    if len(text) > max_chars:
        return text[:max_chars] + f"\n[… cut at {max_chars} of {len(text)} characters]"
    return text


@mcp.tool(annotations=READ_ONLY)
def find_similar(
    path: Annotated[str, Field(description="An indexed file (absolute or ~/ path)")],
    limit: Annotated[int, Field(description="How many results at most", ge=1, le=100)] = 10,
    kinds: Annotated[list[str] | None, Field(description=f"Only these kinds: {', '.join(KINDS)}")] = None,
    folders: Annotated[list[str] | None, Field(description="Only files inside these folders")] = None,
) -> str:
    """Find files on this computer that are like a given file (by DigUp's meaning vectors): other photos of the same
    scene, other versions of a document, related notes. Needs a DigUp helper with the `similar` op."""
    results = _call(lambda: digup().similar(path, limit=limit, kinds=kinds, folders=folders))
    return format_results(results, f"Files like {results.query}")


@mcp.tool(annotations=READ_ONLY)
def index_status(
    doctor: Annotated[bool, Field(description="Also run DigUp's health check (`digup doctor`), when the helper has "
                                              "it; slower")] = False,
) -> str:
    """DigUp's state: whether its query encoder is running, how many vectors the file and code indexes hold, the
    index file, and which folders are searched (and which code folders)."""
    status = _call(lambda: digup().status())
    lines = [f"Index: {status.get('index')}",
             f"Encoder: {status.get('encoder')} (it starts on the first search and stops when idle)",
             f"Vectors loaded: {status.get('vectors')} files, {status.get('code_vectors')} code (0 until a search "
             "loads them)",
             f"Helper: {status.get('helper')}",
             "Folders searched: " + (", ".join(status.get("roots") or []) or "all of the index"),
             "Code folders: " + (", ".join(status.get("code_roots") or []) or "none (code search is off)")]
    if status.get("excludes"):
        lines.append("Skipped: " + ", ".join(status["excludes"]))
    if status.get("settings"):
        lines.append(f"Folders from: {status['settings']}")
    if doctor:
        try:
            report = digup().doctor()
            lines.append("Doctor: " + json.dumps(report, ensure_ascii=False)[:4000])
        except DigUpError as error:
            lines.append(f"Doctor: {error}")
    return "\n".join(lines)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="digup-mcp", description="DigUp's search as an MCP server (stdio).")
    add_helper_arguments(parser)
    parser.add_argument("--http", action="store_true", help="serve streamable HTTP instead of stdio")
    parser.add_argument("--host", default="127.0.0.1", help="with --http: the address (default 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8765, help="with --http: the port (default 8765)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    global _config
    args = parse_arguments(argv)
    _config = config_from(args)
    with _digup_lock:
        global _digup
        _digup = DigUp(config=_config)
        _digup.client.request_timeout = args.timeout
    if args.http:
        if args.host not in ("127.0.0.1", "localhost", "::1"):
            print(f"digup-mcp: warning: listening on {args.host}, not only this computer; anyone who can reach it "
                  "can search your files", file=sys.stderr)
        mcp.run(transport="streamable-http", host=args.host, port=args.port)
    else:
        mcp.run()


if __name__ == "__main__":
    main()
