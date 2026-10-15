"""The MCP server over stdio, as a coding agent runs it, with the fake helper behind it."""

import asyncio
import json
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.types import Implementation

SERVER = Path(__file__).resolve().parents[1] / "src" / "digup_mcp.py"


def text_of(result) -> str:
    return "\n".join(part.text for part in result.content if getattr(part, "text", None))


def failed(result) -> bool:
    return bool(getattr(result, "is_error", None) or getattr(result, "isError", None))


async def session_calls(env, calls, args=()):
    params = StdioServerParameters(command=sys.executable, args=[str(SERVER), "--no-settings", "--root", "/data",
                                                                 *args], env=env)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            outputs = {"tools": {tool.name: tool for tool in tools.tools}}
            for name, arguments in calls:
                outputs[(name, str(arguments))] = await session.call_tool(name, arguments=arguments)
            return outputs


def run(env, calls, args=()):
    return asyncio.run(session_calls({**os.environ, **env}, calls, args))


def test_tools_over_stdio(fake_helper):
    calls = [("search_files", {"query": "zebra in a video", "limit": 3}),
             ("search_files", {"query": "x", "kinds": ["spreadsheet"]}),
             ("read_segment", {"segment_id": 31}),
             ("read_segment", {"segment_id": 272}),
             ("search_code", {"query": "retry with backoff"}),
             ("find_similar", {"path": "/data/notes/todo.md"}),
             ("index_status", {}),
             ("search_files", {"filter": "payment*"}),
             ("search_files", {"query": "zebra", "filter": "\"nothing"}),
             ("search_code", {"filter": "retry"})]
    out = run({}, calls, args=("--code-root", "/data/code"))
    assert set(out["tools"]) == {"search_files", "search_code", "read_segment", "find_similar", "index_status"}
    assert "on-device" in out["tools"]["search_files"].description

    search = out[calls[0][0], str(calls[0][1])]
    text = text_of(search)
    assert not failed(search)
    assert text.splitlines()[0] == 'DigUp results for "zebra in a video": 3 matches by meaning and words; 2 strong.'
    assert "1. /data/video/zoo.mp4\n   video · 0:06-0:12 (picture) · score 8.26 · segment 272" in text
    assert "-- weaker matches --\n3. /data/notes/todo.md" in text
    assert "   > …the «payment» was «declined» by the bank…" in text

    bad = out[calls[1][0], str(calls[1][1])]
    assert failed(bad) and "unknown kind" in text_of(bad)
    assert text_of(out[calls[2][0], str(calls[2][1])]).startswith("Page three")
    assert "no indexed text" in text_of(out[calls[3][0], str(calls[3][1])])
    code = text_of(out[calls[4][0], str(calls[4][1])])
    assert "/data/code/retry.py\n   code · lines 1-33 (line 8)" in code and "code=True" in code
    similar = out[calls[5][0], str(calls[5][1])]
    assert failed(similar) and "newer DigUp helper" in text_of(similar)
    status = text_of(out[calls[6][0], str(calls[6][1])])
    assert "Folders searched: /data" in status and "Code folders: /data/code" in status

    # The filter: in both search tools' schemas, alone or with a query.
    for tool in ("search_files", "search_code"):
        schema = out["tools"][tool].input_schema
        assert "filter" in schema["properties"] and "query" not in schema.get("required", [])
        assert "*word*" in schema["properties"]["filter"]["description"]
    filtered = text_of(out[calls[7][0], str(calls[7][1])])
    assert filtered.splitlines()[0] == ("DigUp results filtered by payment*: 1 match with the filter's words, best "
                                        "match first; 1 strong.")
    assert "1. /data/docs/lease.pdf" in filtered
    none = text_of(out[calls[8][0], str(calls[8][1])])
    assert none.startswith('DigUp results for "zebra" filtered by "nothing: no matches.')
    assert "(Filter: unclosed quote: read as plain words)" in none
    code = text_of(out[calls[9][0], str(calls[9][1])])
    assert code.startswith("DigUp code results filtered by retry: 1 match") and "/data/code/retry.py" in code


def test_missing_helper_is_a_clear_tool_error(fake_helper, tmp_path):
    out = run({"DIGUP_HELPER": str(tmp_path / "nope")}, [("search_files", {"query": "x"})])
    result = out["search_files", str({"query": "x"})]
    assert failed(result) and "isn't an executable" in text_of(result)


async def calls_with(env, calls, args, client="test-agent"):
    params = StdioServerParameters(command=sys.executable, args=[str(SERVER), *args], env=env)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write, client_info=Implementation(name=client, version="1")) as session:
            await session.initialize()
            tools = await session.list_tools()
            outputs = {"tools": {tool.name: tool for tool in tools.tools}}
            for index, (name, arguments) in enumerate(calls):
                outputs[index] = await session.call_tool(name, arguments=arguments)
            return outputs


def test_pinned_to_a_folder(fake_helper):
    calls = [("search_files", {"query": "zebra"}),
             ("read_segment", {"segment_id": 31}),
             ("read_segment", {"segment_id": 12}),
             ("search_files", {"query": "zebra", "folders": ["/elsewhere"]}),
             ("index_status", {})]
    out = asyncio.run(calls_with({**os.environ}, calls, ["--no-settings", "--root", "/data", "--scope", "/data/docs"]))
    assert "add_folder" not in out["tools"], "adding is off without --allow-add-folders"
    search = text_of(out[0])
    assert "1. /data/docs/lease.pdf" in search and "/data/video" not in search and "/data/notes" not in search
    assert text_of(out[1]).startswith("Page three")
    assert failed(out[2]) and "search first" in text_of(out[2])
    assert failed(out[3]) and "outside the folders this server searches" in text_of(out[3])
    status = text_of(out[4])
    assert "Scope: /data/docs: indexed (in the file index; DigUp keeps it current)" in status
    assert "DigUp app: not running" in status and "Adding folders" not in status


def test_an_unindexed_scope_without_adding(fake_helper):
    out = asyncio.run(calls_with({**os.environ}, [("search_files", {"query": "zebra"})],
                                 ["--no-settings", "--root", "/data", "--scope", "/home/me/git/foo"]))
    assert failed(out[0])
    assert text_of(out[0]).endswith(": /home/me/git/foo isn't indexed; start the server with --allow-add-folders or "
                                    "add it in DigUp")


def test_adding_folders_through_the_app(fake_app, fake_helper, tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / "notes").mkdir(parents=True)
    monkeypatch.setenv("FAKE_ROOT", str(home))
    fake_app.write_text(json.dumps({"folders": [str(home / "docs")]}))
    args = ["--settings", str(fake_app), "--scope", str(home / "notes"), "--allow-add-folders", "--max-files", "500"]
    calls = [("search_files", {"query": "zebra"}),
             ("index_status", {}),
             ("add_folder", {"path": str(home / "huge")}),
             ("add_folder", {"path": "/etc"})]
    out = asyncio.run(calls_with({**os.environ}, calls, args, client="claude-code"))
    tool = out["tools"]["add_folder"]
    assert not tool.annotations.read_only_hint and "notification with Undo" in tool.description
    search = text_of(out[0])
    assert search.splitlines()[0].startswith(f"(claude-code added {home}/notes to DigUp")
    assert "(Partial: DigUp is still indexing" in search and f"1. {home}/notes/todo.md" in search
    status = text_of(out[1])
    assert f"Scope: {home}/notes: partly indexed, being indexed: 1 of 3 files read" in status
    assert "Adding folders: allowed (add_folder; at most 500 files" in status
    assert failed(out[2]) and "outside the folders this server searches" in text_of(out[2])
    assert failed(out[3]) and "outside" in text_of(out[3])
    asked = [json.loads(line) for line in (fake_helper / "requests.jsonl").read_text().splitlines()]
    assert asked == [{"folder": str(home / "notes"), "tool": "claude-code", "max_files": 500}]
    assert json.loads(fake_app.read_text())["folders"] == [str(home / "docs"), str(home / "notes")]


def test_add_folder_without_a_scope(fake_app, fake_helper, tmp_path):
    home = tmp_path / "home"
    (home / "git" / "huge").mkdir(parents=True)
    calls = [("add_folder", {"path": str(home / "git" / "huge")}), ("add_folder", {"path": str(home / "git")})]
    out = asyncio.run(calls_with({**os.environ}, calls, ["--settings", str(fake_app), "--allow-add-folders"]))
    assert failed(out[0]) and "more than 20000 files" in text_of(out[0])
    added = text_of(out[1])
    assert added.startswith(f"test-agent added {home}/git to DigUp") and "index_status" in added
