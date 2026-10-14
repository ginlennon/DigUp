"""End to end against a real `digup` helper and an index built from the DigUp testbed. Skipped unless asked for:

    DIGUP_HELPER=<repo>/.build/release/digup DIGUP_GPU=0 \\
    DIGUP_E2E_INDEX=<a COPY of an index of the testbed> \\
    DIGUP_E2E_ROOTS=~/DigUpTestbed/synthetic:~/DigUpTestbed/traps DIGUP_E2E_CODE_ROOTS=~/DigUpTestbed/code \\
    uv run --project integrations pytest integrations/tests/test_e2e_real.py -v
"""

import asyncio
import os
import sys
from pathlib import Path

import pytest

from digup_client import HelperConfig
from digup_tools import DigUp

INDEX = os.environ.get("DIGUP_E2E_INDEX")
pytestmark = pytest.mark.skipif(not INDEX, reason="set DIGUP_E2E_INDEX (and DIGUP_HELPER) to run against DigUp")


def paths(name):
    return [os.path.expanduser(part) for part in os.environ.get(name, "").split(os.pathsep) if part]


@pytest.fixture(scope="module")
def digup():
    d = DigUp(config=HelperConfig.load(index=INDEX, roots=paths("DIGUP_E2E_ROOTS"),
                                       code_roots=paths("DIGUP_E2E_CODE_ROOTS"), use_settings=False))
    yield d
    d.close()


def test_search_read_and_context(digup):
    results = digup.search("zebra in a video", limit=5)
    assert results.meaning and results.hits
    assert any(hit["kind"] == "video" and "zebra" in hit["path"] for hit in results.hits[:3])
    results = digup.search("payment declined error", limit=5)
    assert "payment" in results.hits[0]["path"]
    context = digup.context("payment declined error", limit=5, max_chars=2000)
    assert context["sources"] and context["context"].startswith("[1] ")


def test_code(digup):
    if not digup.config.code_roots:
        pytest.skip("no DIGUP_E2E_CODE_ROOTS")
    results = digup.search("code: retry with backoff", limit=3)
    assert results.code and results.hits[0]["path"].endswith("retry.py")
    assert "def " in (digup.text(results.hits[0]["segment_id"], code=True) or "")


def test_mcp_over_stdio():
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    server = Path(__file__).resolve().parents[1] / "src" / "digup_mcp.py"
    args = [str(server), "--no-settings", "--index", INDEX]
    for root in paths("DIGUP_E2E_ROOTS"):
        args += ["--root", root]

    async def ask():
        async with stdio_client(StdioServerParameters(command=sys.executable, args=args, env=dict(os.environ))) as (
                read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool("search_files", arguments={"query": "zebra in a video", "limit": 3})
                return "\n".join(part.text for part in result.content if getattr(part, "text", None))

    text = asyncio.run(ask())
    assert text.startswith('DigUp results for "zebra in a video"') and "zebra" in text
