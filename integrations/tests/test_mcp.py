"""The MCP server over stdio, as a coding agent runs it, with the fake helper behind it."""

import asyncio
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

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
             ("index_status", {})]
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


def test_missing_helper_is_a_clear_tool_error(fake_helper, tmp_path):
    out = run({"DIGUP_HELPER": str(tmp_path / "nope")}, [("search_files", {"query": "x"})])
    result = out["search_files", str({"query": "x"})]
    assert failed(result) and "isn't an executable" in text_of(result)
