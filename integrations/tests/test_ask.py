"""digup-ask (PLANS/FOLDERS_PLAN.md, A5/S5): the tool loop, its cap, the fallback without tools, the sources, the
scope, adding the folder, and the key never shown. Against the fake helper and a fake OpenAI-compatible server."""

import io
import json

import pytest

import digup_ask
from digup_ask import Asker, Endpoint, EndpointError, Matches, cited, ensure_indexed, fit, split_words
from digup_client import HelperConfig
from digup_tools import DigUp, Scope
from fake_openai import FakeOpenAI, call, calls, error, text

KEY = "sk-test-0123456789abcdef"


@pytest.fixture
def server():
    servers = []

    def start(*script, **options):
        found = FakeOpenAI(list(script), **options)
        servers.append(found)
        return found

    yield start
    for found in servers:
        found.close()


def asker_for(server, scope="/data/docs", roots=("/data",), code_roots=(), stream=True, **options):
    config = HelperConfig.load(roots=list(roots), code_roots=list(code_roots), use_settings=False)
    digup = DigUp(config=config, scope=Scope.of([scope]), cwd=scope)
    endpoint = Endpoint(server.url, "fake-model", KEY)
    endpoint.stream = stream
    out, err = io.StringIO(), io.StringIO()
    asker = Asker(digup, endpoint, scope, files=options.pop("files", True), code=options.pop("code", False),
                  out=out, err=err, **options)
    return asker, out, err


def tool_results(body):
    return [message["content"] for message in body["messages"] if message["role"] == "tool"]


@pytest.mark.parametrize("stream", [True, False])
def test_the_tool_loop_answers_and_lists_its_sources(fake_helper, server, stream):
    fake = server(call("search_files", query="payment declined"), call("read_match", n=1),
                  text("The payment was declined by the bank on 3 March [1]."))
    asker, out, err = asker_for(fake, stream=stream)
    try:
        answer = asker.ask("Why did the payment fail?")
    finally:
        asker.digup.close()
    assert answer.strip() == "The payment was declined by the bank on 3 March [1]."
    first, second, third = fake.chats
    assert [tool["function"]["name"] for tool in first["tools"]] == ["search_files", "read_match", "find_similar"]
    assert first["messages"][0]["role"] == "system" and "/data/docs" in first["messages"][0]["content"]
    assert first["messages"][-1] == {"role": "user", "content": "Why did the payment fail?"}
    assert bool(first.get("stream")) is stream
    found = tool_results(second)[0]
    assert "[1] lease.pdf · pdf · page 3" in found, "paths relative to the folder, numbered"
    assert "zoo.mp4" not in found and "todo.md" not in found, "nothing outside the folder"
    assert tool_results(third)[1].startswith("[1] lease.pdf (page 3):\nPage three: the payment was declined")
    assert "\nSources:\n  [1] lease.pdf · page 3\n" in out.getvalue()
    assert 'search_files "payment declined"' in err.getvalue() and "read_match [1]" in err.getvalue()
    assert [m.path for m in asker.sources] == ["/data/docs/lease.pdf"]


def test_streamed_text_comes_as_it_is_made(server):
    fake = server(text("Die Kaution beträgt drei Monatsmieten [2]."))
    pieces = []
    reply = Endpoint(fake.url, "fake-model").chat([{"role": "user", "content": "x"}], on_text=pieces.append)
    assert len(pieces) == 6 and "".join(pieces).strip() == "Die Kaution beträgt drei Monatsmieten [2]."
    assert reply.first_token is not None and reply.speed == 42.0 and reply.tokens == 5
    fake = server(call("search_files", query="Kaution", filter="*kaution*"))
    reply = Endpoint(fake.url, "fake-model").chat([{"role": "user", "content": "x"}], on_text=pieces.append)
    assert reply.tool_calls == [{"id": "call_0", "type": "function", "function": {
        "name": "search_files", "arguments": json.dumps({"query": "Kaution", "filter": "*kaution*"})}}], \
        "arguments put together from their pieces"


def test_an_endpoint_that_wont_stream_is_asked_again_without(server):
    fake = server(text("Fine."), reject_stream=True)
    endpoint = Endpoint(fake.url, "fake-model")
    pieces = []
    assert endpoint.chat([{"role": "user", "content": "x"}], on_text=pieces.append).content == "Fine."
    assert pieces == ["Fine."] and endpoint.stream is False
    assert [bool(body.get("stream")) for body in fake.chats] == [True, False]


def test_the_rounds_are_capped(fake_helper, server):
    fake = server(repeat=call("search_files", query="again"))
    asker, out, err = asker_for(fake, max_rounds=3)
    try:
        asker.ask("Keep searching")
    finally:
        asker.digup.close()
    assert len(fake.chats) == 4, "3 rounds of tool calls, then one asked to answer"
    assert [body.get("tool_choice") for body in fake.chats] == [None, None, None, "none"]
    assert "Stopped after 3 rounds" in err.getvalue()
    assert asker.history[-1]["role"] == "assistant"


def test_without_tools_the_matches_go_into_the_prompt(fake_helper, server):
    fake = server(text("Declined on 3 March [1]."))
    asker, out, _ = asker_for(fake, tools=False)
    try:
        asker.ask("Why did the payment fail?")
    finally:
        asker.digup.close()
    (body,) = fake.chats
    assert "tools" not in body
    prompt = body["messages"][-1]["content"]
    assert "[1] lease.pdf (page 3)\nPage three: the payment was declined" in prompt
    assert prompt.endswith("Question: Why did the payment fail?")
    assert "Sources:\n  [1] lease.pdf · page 3" in out.getvalue()
    assert asker.history == [{"role": "user", "content": "Why did the payment fail?"},
                             {"role": "assistant", "content": "Declined on 3 March [1]. "}], \
        "only the question and the answer are kept"


def test_an_endpoint_without_tools_falls_back(fake_helper, server):
    fake = server(text("From the excerpts: declined [1]."), reject_tools=True)
    asker, out, err = asker_for(fake)
    try:
        asker.ask("Why did the payment fail?")
        asker.ask("And when?")
    finally:
        asker.digup.close()
    assert [bool(body.get("tools")) for body in fake.chats] == [True, False, False], "tried once, then without"
    assert "doesn't take tools (tools param requires --jinja flag)" in err.getvalue()
    assert asker.use_tools is False and "Sources:" in out.getvalue()


def test_tool_calls_outside_the_folder_are_refused(fake_helper, server, monkeypatch):
    monkeypatch.setenv("FAKE_SIMILAR", "1")
    fake = server(calls(("search_files", {"query": "x", "folder": "/elsewhere"}),
                        ("find_similar", {"path": "/data/notes/todo.md"}),
                        ("read_match", {"n": 99}),
                        ("search_code", {"query": "retry"}),
                        ("search_files", {"query": "x", "folder": "../notes"})),
                  text("I found nothing about that in this folder."))
    asker, out, err = asker_for(fake)
    try:
        asker.ask("What's elsewhere?")
    finally:
        asker.digup.close()
    outside, similar, missing, no_tool, relative = tool_results(fake.chats[1])
    assert outside.startswith("Refused: ~/elsewhere") or outside.startswith("Refused: /elsewhere")
    assert "is outside the folder" in outside
    assert similar.startswith("Refused:") and "outside" in similar
    assert missing.startswith("There's no match [99]")
    assert no_tool.startswith("Error: there's no tool named search_code")
    assert relative.startswith("Refused:"), "../ leaves the folder: refused too"
    assert "Sources:" not in out.getvalue() and "refused" in err.getvalue()
    assert "the folder digup-ask searches" in outside and "--scope" not in outside


def test_an_answer_that_cites_nothing_lists_what_was_read(fake_helper, server):
    fake = server(call("search_files", query="tax"), call("read_match", n=1), text("Nothing about taxes here."))
    asker, out, err = asker_for(fake)
    try:
        asker.ask("When are taxes due?")
    finally:
        asker.digup.close()
    assert "Read for this answer (none cited):\n  [1] lease.pdf · page 3" in out.getvalue()
    assert "Sources:" not in out.getvalue()


def test_read_match_reads_only_matches_shown(fake_helper, server):
    asker, _, _ = asker_for(server())
    try:
        assert asker.run_tool("read_match", '{"n": 1}').startswith("There's no match [1]")
        asker.run_tool("search_files", '{"query": "zebra"}')
        assert "Page three" in asker.run_tool("read_match", '{"n": 1}')
        assert asker.run_tool("search_files", "{not json").startswith("Error: the arguments")
    finally:
        asker.digup.close()


def test_a_code_folder_gets_search_code(fake_helper, server):
    fake = server(call("search_code", query="retry"), call("read_match", n=1), text("It retries 5 times [1]."))
    asker, out, _ = asker_for(fake, scope="/data/code", roots=["/data/docs"], code_roots=["/data/code"], files=False,
                              code=True)
    try:
        asker.ask("How often does it retry?")
    finally:
        asker.digup.close()
    assert [tool["function"]["name"] for tool in fake.chats[0]["tools"]] == ["search_code", "read_match"]
    assert "[1] retry.py · code · lines 1-33 (line 8)" in tool_results(fake.chats[1])[0]
    assert "def retry_with_backoff" in tool_results(fake.chats[2])[1]
    assert "Sources:\n  [1] retry.py · lines 1-33 (line 8)" in out.getvalue()


def test_sources_clear_and_the_chat(fake_helper, server):
    fake = server(call("search_files", query="payment"), text("Declined [1]."), text("Nothing about that."))
    asker, out, err = asker_for(fake)
    lines = iter(["Why did it fail?", "/sources", "/clear", "/sources", "Anything else?", "/nope"])

    def read(_prompt):
        try:
            return next(lines)
        except StopIteration:
            raise EOFError from None

    try:
        digup_ask.chat(asker, read=read)
    finally:
        asker.digup.close()
    shown = out.getvalue()
    assert "Sources of the last answer:\n  [1] lease.pdf · page 3" in shown
    assert "No sources yet" in shown, "/clear forgets them"
    assert "Cleared" in err.getvalue() and "Unknown command /nope" in err.getvalue()
    assert fake.chats[-1]["messages"][1:] == [{"role": "user", "content": "Anything else?"}], \
        "/clear starts a new conversation"


def test_the_key_is_sent_but_never_shown(fake_helper, server, monkeypatch, capsys, tmp_path):
    monkeypatch.setenv("DIGUP_ASK_API_KEY", KEY)
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    fake = server(call("search_files", query="payment"), error(500, "something broke"), echo_auth=True)
    monkeypatch.setenv("DIGUP_ROOTS", "/data")
    code = digup_ask.run(digup_ask.parse_arguments(["--base-url", fake.url, "--no-settings", "/", "Why?"]))
    shown = capsys.readouterr()
    assert code == 1
    assert all(request["headers"].get("Authorization") == f"Bearer {KEY}" for request in fake.requests)
    assert "something broke (you sent Bearer ***)" in shown.err
    assert KEY not in shown.out + shown.err
    assert not (tmp_path / "state").exists() or KEY not in "".join(
        p.read_text() for p in (tmp_path / "state").rglob("*") if p.is_file())
    with pytest.raises(EndpointError) as raised:
        Endpoint("http://127.0.0.1:9/v1", "m", KEY).chat([{"role": "user", "content": "x"}])
    assert "can't reach" in str(raised.value) and KEY not in str(raised.value)


def test_the_model_is_the_endpoints_only_one(server):
    assert digup_ask.choose_model(Endpoint(server(models=["gemma"]).url)) == "gemma"
    with pytest.raises(EndpointError, match="has 2 models .*--model"):
        digup_ask.choose_model(Endpoint(server(models=["a", "b"]).url))


def test_a_one_shot_question_from_the_command_line(fake_helper, server, monkeypatch, capsys, tmp_path):
    fake = server(call("search_files", query="payment"), text("Declined [1]."))
    (tmp_path / "docs").mkdir()
    monkeypatch.setenv("FAKE_ROOT", str(tmp_path))   # the fake helper's hits are in tmp_path/docs …
    monkeypatch.setenv("DIGUP_ROOTS", str(tmp_path))
    monkeypatch.delenv("DIGUP_ASK_API_KEY", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.chdir(tmp_path)
    code = digup_ask.run(digup_ask.parse_arguments(["--base-url", fake.url, "--no-settings", "-q", "docs",
                                                    "Why", "did", "it", "fail?"]))
    shown = capsys.readouterr()
    assert code == 0 and shown.out.startswith("Declined [1].")
    assert "Sources:\n  [1] lease.pdf · page 3" in shown.out
    assert fake.chats[0]["model"] == "fake-model", "the endpoint's only model"
    assert "Authorization" not in fake.requests[0]["headers"], "no key: no header"


def test_the_folder_and_the_question(tmp_path):
    (tmp_path / "docs").mkdir()
    assert split_words([], cwd=str(tmp_path)) == (str(tmp_path), "")
    assert split_words(["docs", "what", "is", "it?"], cwd=str(tmp_path)) == (str(tmp_path / "docs"), "what is it?")
    assert split_words(["what", "is", "it?"], cwd=str(tmp_path)) == (str(tmp_path), "what is it?")
    assert split_words([str(tmp_path / "docs")], cwd="/") == (str(tmp_path / "docs"), "")


def test_citations_and_matches():
    assert cited("Yes [2], and [1, 3]; also [4][2]. Not [x].") == [2, 1, 3, 4]
    matches = Matches()
    first = matches.add({"path": "/a.pdf", "segment": "page", "loc": 2, "segment_id": 5, "kind": "pdf"}, False)
    again = matches.add({"path": "/a.pdf", "segment": "page", "loc": 2, "segment_id": 5, "kind": "pdf"}, False)
    code = matches.add({"path": "/a.py", "segment": "lines", "loc": 1, "loc_end": 9, "segment_id": 5}, True)
    assert first is again and first.n == 1 and code.n == 2 and matches.get("2") is code and matches.get(3) is None


def test_the_conversation_fits_its_budget():
    old_tool = {"role": "tool", "tool_call_id": "a", "content": "x" * 5000}
    history = [{"role": "user", "content": "first"},
               {"role": "assistant", "content": None, "tool_calls": [{"id": "a"}]}, old_tool,
               {"role": "assistant", "content": "answer one"},
               {"role": "user", "content": "second"}]
    fitted = fit(history, 1000, turn=4)
    assert fitted[2]["content"].endswith("[…shortened]") and len(fitted) == 5 and old_tool["content"] == "x" * 5000
    history.append({"role": "tool", "tool_call_id": "b", "content": "y" * 900})
    assert fit(history, 1000, turn=4)[0] == {"role": "user", "content": "second"}, "the oldest question goes"
    assert fit(history, 100, turn=4)[-1]["content"] == "y" * 900, "the current question's results stay whole"


def test_an_unindexed_folder_is_added_on_a_yes(fake_app, tmp_path):
    fake_app.write_text(json.dumps({"folders": ["/data"]}))
    folder = tmp_path / "home" / "notes"
    folder.mkdir(parents=True)
    load = lambda: HelperConfig.load()   # noqa: E731  (the stand-in's settings, as the app's)
    digup = DigUp(config=load(), scope=Scope.of([str(folder)]), reload_config=load, tool="digup-ask")
    err = io.StringIO()
    requests = tmp_path / "state" / "requests.jsonl"
    try:
        assert ensure_indexed(digup, str(folder), yes=False, wait=0, err=err, interactive=False) is None
        assert "--yes" in err.getvalue() and not requests.exists(), "not a terminal: nothing asked, nothing added"
        assert ensure_indexed(digup, str(folder), yes=False, wait=0, err=err, interactive=True,
                              ask=lambda _: "n") is None
        assert not requests.exists()
        row = ensure_indexed(digup, str(folder), yes=False, wait=0.3, err=err, interactive=True, ask=lambda _: "y")
        assert row is not None and row["files"] == "yes"
        assert json.loads(requests.read_text().splitlines()[0])["tool"] == "digup-ask"
        assert f"digup-ask added {folder} to DigUp" in err.getvalue()
        assert "still indexing" in err.getvalue(), "the stand-in keeps it pending"
        assert digup.allow_add is False, "adding stays off for the model"
        assert digup.config.roots == ["/data", str(folder)]
    finally:
        digup.close()


def test_without_the_app_nothing_is_added(fake_helper, tmp_path):
    digup = DigUp(config=HelperConfig.load(roots=["/data"], use_settings=False), scope=Scope.of(["/home/me/x"]))
    err = io.StringIO()
    try:
        assert ensure_indexed(digup, "/home/me/x", yes=True, wait=0, err=err) is None
        assert "DigUp isn't running" in err.getvalue()
    finally:
        digup.close()
