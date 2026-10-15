"""digup-ask: ask a folder questions. A chat model answers from what DigUp finds in it, and says which files.

    digup-ask [FOLDER] [QUESTION…]      # FOLDER: the current folder unless the first word is one
    digup-ask ~/Documents/Wohnung "Wie hoch ist die Kaution?"
    digup-ask                           # no question: a chat about the current folder (Ctrl+D ends it)

DigUp is pinned to FOLDER as `--scope` pins the servers: nothing outside it is searched or read. A folder DigUp
doesn't index is added on a yes (the running desktop app adds it, as `add_folder` does; `--yes` asks nothing).

The model is any OpenAI-compatible chat-completions endpoint: `--base-url` (or $DIGUP_ASK_BASE_URL; by default a
local llama.cpp server at http://127.0.0.1:8080/v1) and `--model` (or $DIGUP_ASK_MODEL; by default the endpoint's
only model). The API key comes from $DIGUP_ASK_API_KEY or $OPENAI_API_KEY; it's sent to the endpoint and nowhere
else, never shown and never written down. The model gets DigUp's search as tools and calls them, at most
`--max-rounds` rounds per question. With `--no-tools`, or an endpoint that doesn't take tools, DigUp's top matches
for the question go into the prompt instead. Either way each answer ends with the files it came from.

Only the standard library talks to the endpoint (urllib, server-sent events for streaming).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, TextIO

from digup_app import AppNotRunning
from digup_client import DigUpError
from digup_tools import (FILTER_SYNTAX, KINDS, DigUp, Forbidden, NotIndexed, Scope, add_helper_arguments, config_from,
                         excerpt, partial_text, shown, where, MAX_FILES)

DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1"
MAX_ROUNDS = 8
READ_CHARS = 3000        # of one match's text, for the model
BUDGET_CHARS = 16_000    # of the conversation sent (about 4–5k tokens): older tool results are shortened first
LOCAL_HOSTS = ("127.0.0.1", "localhost", "::1", "[::1]")


# MARK: The endpoint


class EndpointError(Exception):
    """The chat endpoint couldn't be reached or said no; the message is for a person (the key is never in it)."""

    def __init__(self, message: str, status: int | None = None, body: str = ""):
        super().__init__(message)
        self.status = status
        self.body = body

    @property
    def rejects_tools(self) -> bool:
        """The endpoint doesn't take `tools` (llama.cpp without --jinja, a model without tool calling…)."""
        return self.status in (400, 404, 422, 500, 501) and "tool" in self.body.lower()

    @property
    def rejects_stream(self) -> bool:
        return self.status in (400, 422, 501) and "stream" in self.body.lower() and "tool" not in self.body.lower()


@dataclass
class Reply:
    """One chat completion: its text, the tool calls it asks for, and how fast it came."""

    content: str = ""
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    finish: str | None = None
    first_token: float | None = None     # seconds from the request to the first token of text
    seconds: float = 0.0
    tokens: int | None = None            # tokens generated, when the endpoint says
    prompt_tokens: int | None = None
    speed: float | None = None           # tokens per second while generating (llama.cpp's timings, else counted)


class Endpoint:
    """An OpenAI-compatible chat-completions API (`base_url` ends in /v1, as the services give it)."""

    def __init__(self, base_url: str, model: str | None = None, api_key: str | None = None, *,
                 timeout: float = 300.0, temperature: float | None = None):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self._key = api_key or None
        self.timeout = timeout
        self.temperature = temperature
        self.stream = True

    @property
    def host(self) -> str:
        return urllib.parse.urlsplit(self.base_url).hostname or ""

    @property
    def local(self) -> bool:
        host = self.host
        return host in LOCAL_HOSTS or host.startswith("127.")

    def redact(self, text: str) -> str:
        """`text` without the key in it (an endpoint may echo what it was sent)."""
        return text.replace(self._key, "***") if self._key and len(self._key) >= 4 else text

    def _request(self, path: str, body: dict[str, Any] | None = None):
        headers = {"Accept": "application/json, text/event-stream"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if self._key:
            headers["Authorization"] = f"Bearer {self._key}"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers,
                                         method="POST" if body is not None else "GET")
        try:
            return urllib.request.urlopen(request, timeout=self.timeout)
        except urllib.error.HTTPError as error:
            try:
                text = error.read().decode("utf-8", "replace")
            except OSError:
                text = ""
            text = self.redact(text)
            raise EndpointError(f"{self.base_url}{path} answered {error.code}: {_said(text) or error.reason}",
                                error.code, text) from None
        except (urllib.error.URLError, OSError) as error:
            reason = getattr(error, "reason", error)
            raise EndpointError(f"can't reach {self.base_url} ({self.redact(str(reason))}): is the server running? "
                                "(--base-url, $DIGUP_ASK_BASE_URL)") from None

    def models(self) -> list[str]:
        with self._request("/models") as response:
            try:
                value = json.load(response)
            except ValueError:
                raise EndpointError(f"{self.base_url}/models didn't answer with JSON") from None
        rows = value.get("data") if isinstance(value, dict) else None
        return [str(row["id"]) for row in rows or [] if isinstance(row, dict) and row.get("id")]

    def chat(self, messages: list[dict[str, Any]], *, tools: list[dict[str, Any]] | None = None,
             tool_choice: str | None = None, on_text: Callable[[str], None] | None = None,
             on_thinking: Callable[[], None] | None = None) -> Reply:
        """One completion; with `on_text`, streamed: each piece of text as it comes (`on_thinking` once when a
        thinking model starts thinking, which it does apart from its text). An endpoint that won't stream is asked
        again without, and not asked to stream after that."""
        body: dict[str, Any] = {"model": self.model or "default", "messages": messages}
        if tools:
            body["tools"] = tools
            if tool_choice:
                body["tool_choice"] = tool_choice
        if self.temperature is not None:
            body["temperature"] = self.temperature
        stream = self.stream and on_text is not None
        if stream:
            body["stream"] = True
            body["stream_options"] = {"include_usage": True}
        started = time.monotonic()
        try:
            response = self._request("/chat/completions", body)
        except EndpointError as error:
            if not (stream and error.rejects_stream):
                raise
            self.stream = False
            return self.chat(messages, tools=tools, tool_choice=tool_choice, on_text=on_text, on_thinking=on_thinking)
        with response:
            kind = response.headers.get("Content-Type", "")
            if stream and "text/event-stream" in kind:
                reply = self._streamed(response, started, on_text, on_thinking)
            else:
                reply = self._whole(response, started)
                if on_text is not None and reply.content:
                    on_text(reply.content)
        reply.seconds = time.monotonic() - started
        if reply.speed is None and reply.tokens and reply.first_token is not None \
                and reply.seconds - reply.first_token > 0.05:
            reply.speed = reply.tokens / (reply.seconds - reply.first_token)
        return reply

    def _whole(self, response: Any, started: float) -> Reply:
        try:
            value = json.load(response)
        except ValueError:
            raise EndpointError(f"{self.base_url}/chat/completions didn't answer with JSON") from None
        choice = (value.get("choices") or [{}])[0] if isinstance(value, dict) else {}
        message = choice.get("message") or {}
        reply = Reply(content=message.get("content") or "", finish=choice.get("finish_reason"),
                      first_token=time.monotonic() - started)
        for index, call in enumerate(message.get("tool_calls") or []):
            function = call.get("function") or {}
            reply.tool_calls.append({"id": call.get("id") or f"call_{index}", "type": "function",
                                     "function": {"name": function.get("name") or "",
                                                  "arguments": function.get("arguments") or "{}"}})
        self._usage(reply, value)
        return reply

    def _streamed(self, response: Any, started: float, on_text: Callable[[str], None] | None,
                  on_thinking: Callable[[], None] | None = None) -> Reply:
        reply = Reply()
        thinking = False
        calls: dict[int, dict[str, Any]] = {}
        counted = 0
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except ValueError:
                continue
            if isinstance(chunk, dict) and chunk.get("error"):
                message = self.redact(json.dumps(chunk["error"], ensure_ascii=False))
                raise EndpointError(f"{self.base_url} stopped with an error: {_said(message)}", 500, message)
            self._usage(reply, chunk)
            for choice in chunk.get("choices") or []:
                delta = choice.get("delta") or {}
                if choice.get("finish_reason"):
                    reply.finish = choice["finish_reason"]
                if not thinking and (delta.get("reasoning_content") or delta.get("reasoning")):
                    thinking = True
                    if on_thinking is not None:
                        on_thinking()
                text = delta.get("content")
                if text:
                    if reply.first_token is None:
                        reply.first_token = time.monotonic() - started
                    reply.content += text
                    counted += 1
                    if on_text is not None:
                        on_text(text)
                for position, piece in enumerate(delta.get("tool_calls") or []):
                    index = piece.get("index", position)
                    call = calls.setdefault(index, {"id": "", "type": "function",
                                                    "function": {"name": "", "arguments": ""}})
                    if piece.get("id"):
                        call["id"] = piece["id"]
                    function = piece.get("function") or {}
                    if function.get("name"):
                        call["function"]["name"] += function["name"]
                    if function.get("arguments"):
                        call["function"]["arguments"] += function["arguments"]
        for index in sorted(calls):
            call = calls[index]
            call["id"] = call["id"] or f"call_{index}"
            call["function"]["arguments"] = call["function"]["arguments"] or "{}"
            reply.tool_calls.append(call)
        if reply.tokens is None and counted:
            reply.tokens = counted   # one piece of text per token, as most servers stream it
        return reply

    @staticmethod
    def _usage(reply: Reply, value: Any) -> None:
        if not isinstance(value, dict):
            return
        usage = value.get("usage")
        if isinstance(usage, dict):
            reply.tokens = usage.get("completion_tokens") or reply.tokens
            reply.prompt_tokens = usage.get("prompt_tokens") or reply.prompt_tokens
        timings = value.get("timings")   # llama.cpp's server
        if isinstance(timings, dict) and timings.get("predicted_per_second"):
            reply.speed = float(timings["predicted_per_second"])
            reply.tokens = timings.get("predicted_n") or reply.tokens


def _said(body: str) -> str:
    """The message in an error body ({"error": {"message": …}}), else its start."""
    try:
        value = json.loads(body)
    except ValueError:
        return " ".join(body.split())[:300]
    error = value.get("error", value) if isinstance(value, dict) else value
    if isinstance(error, dict):
        error = error.get("message") or error
    return " ".join(str(error).split())[:300]


# MARK: Matches, numbered for citing


@dataclass
class Match:
    n: int
    path: str
    where: str
    kind: str
    code: bool
    segment_id: int | None
    excerpt: str | None
    score: float


class Matches:
    """Every match DigUp showed the model in this chat, numbered [1], [2]… once each (the same file and place keeps its
    number), so the model cites them and `read_match(n)` reads them."""

    def __init__(self) -> None:
        self.items: list[Match] = []
        self._keys: dict[tuple[Any, ...], Match] = {}

    def add(self, hit: dict[str, Any], code: bool) -> Match:
        segment = hit.get("segment_id") if isinstance(hit.get("segment_id"), int) else None
        place = where(hit)
        key = (code, segment) if segment is not None else (code, hit.get("path"), place)
        found = self._keys.get(key)
        if found is None:
            found = Match(len(self.items) + 1, str(hit.get("path") or ""), place, str(hit.get("kind") or ""), code,
                          segment, excerpt(hit), float(hit.get("score") or 0))
            self.items.append(found)
            self._keys[key] = found
        return found

    def get(self, n: Any) -> Match | None:
        try:
            index = int(n)
        except (TypeError, ValueError):
            return None
        return self.items[index - 1] if 1 <= index <= len(self.items) else None


CITATION = re.compile(r"\[(\d+(?:\s*[,;]\s*\d+)*)\]")


def cited(answer: str) -> list[int]:
    """The match numbers an answer cites: [2], [1, 3], [4][5]."""
    numbers: list[int] = []
    for group in CITATION.findall(answer):
        for part in re.split(r"[,;]", group):
            number = int(part.strip())
            if number not in numbers:
                numbers.append(number)
    return numbers


# MARK: Prompts and tools

SYSTEM = """\
You answer questions about the files in one folder on the user's computer: {folder}. You can't see the files \
yourself. DigUp, a search engine on this computer that has indexed them, finds them for you with the tools.

How to work:
- Search before you answer, every time. Search with a few words of what the passage would say, in the files' \
language when you can guess it. If the first search finds nothing useful, try other words, or a filter for an exact \
word, name or number.
- Read the best matches with read_match before you answer from them: excerpts are short.
- Answer only from what the tools returned. If nothing relevant was found, say so plainly and don't guess or use \
what you know from elsewhere.
- Cite each fact with its match number in brackets, like [2]. Only use numbers the tools gave you.
- Be brief: a few sentences or a short list. Paths in the tools are relative to {folder}.
- Reply in the language the user's question is written in: a German question gets a German answer, a French one a \
French answer, also when the files are in another language and also when you found nothing."""

SYSTEM_NO_TOOLS = """\
You answer questions about the files in one folder on the user's computer: {folder}. With each question come \
excerpts from its files that DigUp, a search engine on this computer, found for it, each under its number [n] and \
its file.

- Answer only from these excerpts. If they don't answer the question, say so plainly and don't guess or use what \
you know from elsewhere.
- Cite each fact with its excerpt's number in brackets, like [2].
- Be brief: a few sentences or a short list.
- Reply in the language the user's question is written in: a German question gets a German answer, a French one a \
French answer, also when the excerpts are in another language and also when they don't answer it."""


def tool_definitions(files: bool, code: bool) -> list[dict[str, Any]]:
    """The tools the model gets: search_files and find_similar when the folder is in DigUp's file index, search_code
    when it's in the code index, read_match always."""

    def tool(name: str, description: str, properties: dict[str, Any], required: list[str]) -> dict[str, Any]:
        return {"type": "function", "function": {"name": name, "description": description, "parameters": {
            "type": "object", "properties": properties, "required": required}}}

    query = {"type": "string", "description": "What to find, in a few plain words (any language): what the "
                                              "passage says, what's in the picture, what's said in the recording"}
    filter_ = {"type": "string", "description": "Optional: exact words the file must contain. " + FILTER_SYNTAX}
    limit = {"type": "integer", "description": "How many matches at most (default 6)", "minimum": 1, "maximum": 15}
    tools = []
    if files:
        tools.append(tool("search_files", "Search the folder's documents, PDFs (by page), notes, screenshots (with "
                          "their text), photos, recordings and videos by meaning and words. Returns numbered "
                          "matches: file, where in it (page, time), an excerpt.",
                          {"query": query, "filter": filter_,
                           "kinds": {"type": "array", "items": {"type": "string", "enum": list(KINDS)},
                                     "description": "Optional: only these kinds of files"},
                           "folder": {"type": "string", "description": "Optional: only inside this subfolder"},
                           "limit": limit}, ["query"]))
    if code:
        tools.append(tool("search_code", "Search the folder's source code by what it does, or a name in it. Returns "
                          "numbered matches: file, line range, an excerpt.",
                          {"query": query, "filter": filter_, "limit": limit}, ["query"]))
    tools.append(tool("read_match", "Read the indexed text of match [n]: the passage of a document, the text of a "
                      "PDF page, a screenshot's text, a transcript's stretch, the lines of code.",
                      {"n": {"type": "integer", "description": "The match's number"}}, ["n"]))
    if files:
        tools.append(tool("find_similar", "Files in the folder like a given one (other versions of a document, "
                          "related notes, photos of the same scene).",
                          {"path": {"type": "string", "description": "The file (relative to the folder)"},
                           "limit": limit}, ["path"]))
    return tools


# MARK: The chat


class Asker:
    """A chat about one folder: DigUp pinned to it (`digup` has the scope), the endpoint's model answering."""

    def __init__(self, digup: DigUp, endpoint: Endpoint, folder: str, *, files: bool = True, code: bool = False,
                 tools: bool = True, max_rounds: int = MAX_ROUNDS, budget: int = BUDGET_CHARS, quiet: bool = False,
                 stats: bool = False, out: TextIO | None = None, err: TextIO | None = None):
        self.digup = digup
        self.endpoint = endpoint
        self.folder = folder
        self.files = files
        self.code = code
        self.use_tools = tools
        self.max_rounds = max(1, max_rounds)
        self.budget = budget
        self.quiet = quiet
        self.stats = stats
        self.out = out or sys.stdout
        self.err = err or sys.stderr
        self.color = _colors(self.err)
        self.tools = tool_definitions(files, code)
        self.clear()

    def clear(self) -> None:
        """A new conversation: no history, matches numbered from 1 again."""
        self.history: list[dict[str, Any]] = []
        self.matches = Matches()
        self.sources: list[Match] = []     # the last answer's
        self.seen: list[Match] = []        # every match the last question brought up
        self._read: list[Match] = []
        self._said: set[str] = set()
        self._at_line_start = True
        self._searches = 0
        self._replies: list[Reply] = []
        self._cited = False

    # MARK: Asking

    def ask(self, question: str) -> str:
        """Answers `question` (streamed to `out`), then the files it's from; returns the answer."""
        self.seen, self._read = [], []
        self._at_line_start = True
        self._searches = 0
        self._replies = []
        if self.use_tools:
            try:
                answer = self._with_tools(question)
            except EndpointError as error:
                if not error.rejects_tools:
                    raise
                if self._replies:
                    # It took tools before (a call it made couldn't be read, say): without them this time only.
                    self._status(f"(The endpoint failed on a tool call ({_said(error.body) or error.status}): "
                                 "answering from DigUp's top matches instead.)")
                else:
                    self.use_tools = False
                    self._status(f"(The endpoint doesn't take tools ({_said(error.body) or error.status}): "
                                 "answering from DigUp's top matches instead. --no-tools does this from the start.)")
                answer = self._without_tools(question)
        else:
            answer = self._without_tools(question)
        self._end_line()
        if not answer.strip():
            self._status("(The model gave no answer.)")
        self.sources = self._sources_of(answer)
        self._show_sources()
        if self.stats:
            self._show_stats()
        return answer

    def _with_tools(self, question: str) -> str:
        start = len(self.history)
        self.history.append({"role": "user", "content": question})
        try:
            for round_ in range(self.max_rounds + 1):
                last = round_ == self.max_rounds
                reply = self._chat(SYSTEM, self.history, tools=self.tools, tool_choice="none" if last else None,
                                   turn=start)
                if reply.tool_calls and not last:
                    self.history.append({"role": "assistant", "content": reply.content or None,
                                         "tool_calls": reply.tool_calls})
                    for call in reply.tool_calls:
                        name = call["function"]["name"]
                        result = self.run_tool(name, call["function"]["arguments"])
                        self.history.append({"role": "tool", "tool_call_id": call["id"], "content": result})
                    continue
                if reply.tool_calls:
                    self._status(f"(Stopped after {self.max_rounds} rounds of searching: --max-rounds.)")
                self.history.append({"role": "assistant", "content": reply.content})
                return reply.content
        except BaseException:
            del self.history[start:]   # a question that wasn't answered (Ctrl+C, an error) leaves nothing behind
            raise
        return ""

    def _without_tools(self, question: str) -> str:
        excerpts = self.retrieve(question)
        prompt = (f"Excerpts from the files DigUp found for the question:\n\n{excerpts}\n\nQuestion: {question}"
                  if excerpts else f"DigUp found nothing in the folder for this question.\n\nQuestion: {question}")
        history = [message for message in self.history if message["role"] in ("user", "assistant")
                   and message.get("content")]
        reply = self._chat(SYSTEM_NO_TOOLS, history + [{"role": "user", "content": prompt}], turn=len(history))
        # Only the question and the answer are kept: the next question brings its own excerpts.
        self.history += [{"role": "user", "content": question}, {"role": "assistant", "content": reply.content}]
        return reply.content

    def _chat(self, system: str, messages: list[dict[str, Any]], *, tools: list[dict[str, Any]] | None = None,
              tool_choice: str | None = None, turn: int = 0) -> Reply:
        fitted = fit(messages, self.budget, turn)
        prompt = [{"role": "system", "content": system.format(folder=shown(self.folder))}] + fitted
        reply = self.endpoint.chat(prompt, tools=tools, tool_choice=tool_choice, on_text=self._write,
                                   on_thinking=lambda: self._status("  thinking…"))
        self._replies.append(reply)
        return reply

    def _write(self, text: str) -> None:
        self.out.write(text)
        self.out.flush()
        self._at_line_start = text.endswith("\n")

    def _end_line(self) -> None:
        if not self._at_line_start:
            self.out.write("\n")
            self.out.flush()
            self._at_line_start = True

    # MARK: The tools

    def run_tool(self, name: str, arguments: str) -> str:
        """What a tool call returns to the model: the matches, a text, or why not ("Refused: … is outside …")."""
        try:
            args = json.loads(arguments) if arguments.strip() else {}
        except ValueError:
            return f"Error: the arguments for {name} aren't valid JSON: {arguments[:200]}"
        if not isinstance(args, dict):
            return f"Error: the arguments for {name} must be an object"
        try:
            if name == "search_files" and self.files:
                return self._search(args, code=False)
            if name == "search_code" and self.code:
                return self._search(args, code=True)
            if name == "read_match":
                return self._read_match(args.get("n"))
            if name == "find_similar" and self.files:
                return self._similar(args)
            return f"Error: there's no tool named {name}; the tools are " + \
                ", ".join(tool["function"]["name"] for tool in self.tools)
        except Forbidden as error:
            said = str(error).replace("the folders this server searches", "the folder digup-ask searches") \
                .replace(": it was started with --scope", "")
            self._status(f"  refused: {said}")
            return f"Refused: {said}"
        except DigUpError as error:
            return f"Error: {error}"

    def _search(self, args: dict[str, Any], code: bool) -> str:
        query = str(args.get("query") or "")
        keywords = args.get("filter") or None
        folder = args.get("folder") or None
        folders = [self._path(str(folder))] if folder else None
        limit = max(1, min(_int(args.get("limit"), 6), 15))
        self._searches += 1
        label = "search_code" if code else "search_files"
        self._status(f"  {label} {json.dumps(query, ensure_ascii=False)}"
                     + (f" filter {json.dumps(keywords, ensure_ascii=False)}" if keywords else "")
                     + (f" in {folder}" if folder else ""))
        results = self.digup.search(query, filter=keywords, kinds=None if code else args.get("kinds"),
                                    folders=folders, limit=limit, code=code)
        lines = [f"({note})" for note in results.notes]
        if results.partial:
            text = partial_text(results.partial)
            lines.append(f"(Partial: {text})")
            self._note(text)
        if not results.hits:
            lines.append(f'No matches for "{query}"' + (f" with the filter {keywords}" if keywords else "")
                         + " in this folder.")
            if results.filter_note:
                lines.append(f"(Filter: {results.filter_note})")
            return "\n".join(lines)
        lines.append(f"{len(results.hits)} matches, the best first:")
        for index, hit in enumerate(results.hits):
            if index == results.strong and index > 0:
                lines.append("-- weaker matches --")
            match = self.matches.add(hit, code)
            self._saw(match)
            lines.append(f"[{match.n}] {self._relative(match.path)} · {match.kind} · {match.where}")
            if match.excerpt:
                lines.append(f"    > {match.excerpt[:240]}")
        lines.append("Read a match's text with read_match(n).")
        return "\n".join(lines)

    def _read_match(self, n: Any) -> str:
        match = self.matches.get(n)
        if match is None:
            return f"There's no match [{n}]: search first, then read a match by its number."
        self._status(f"  read_match [{match.n}] {self._relative(match.path)} · {match.where}")
        self._saw(match)
        if match not in self._read:
            self._read.append(match)
        text = self.digup.text(match.segment_id, code=match.code) if match.segment_id is not None else None
        text = (text or "").strip() or (match.excerpt or "").replace("«", "").replace("»", "")
        if not text:
            return f"[{match.n}] {self._relative(match.path)} ({match.where}) has no text (a picture or a frame)."
        if len(text) > READ_CHARS:
            text = text[:READ_CHARS].rstrip() + f" […cut at {READ_CHARS} characters]"
        return f"[{match.n}] {self._relative(match.path)} ({match.where}):\n{text}"

    def _similar(self, args: dict[str, Any]) -> str:
        path = self._path(str(args.get("path") or ""))
        self._status(f"  find_similar {self._relative(path)}")
        results = self.digup.similar(path, limit=max(1, min(_int(args.get("limit"), 6), 15)))
        if not results.hits:
            return f"No files like {self._relative(path)} in this folder."
        lines = [f"Files like {self._relative(path)}:"]
        for hit in results.hits:
            match = self.matches.add(hit, False)
            self._saw(match)
            lines.append(f"[{match.n}] {self._relative(match.path)} · {match.kind} · {match.where}")
        return "\n".join(lines)

    def retrieve(self, question: str, limit: int = 6, max_chars: int = 6000) -> str:
        """Without tools: DigUp's top matches for the question (in the file index, the code index or both), each
        under its number and file, with as much of its text as fits."""
        found: list[tuple[Match, dict[str, Any]]] = []
        self._searches += 1
        self._status(f"  search {json.dumps(question, ensure_ascii=False)}")
        for code in [False] * self.files + [True] * self.code:
            try:
                results = self.digup.search(question, limit=limit, code=code)
            except NotIndexed:
                continue
            if results.partial:
                self._note(partial_text(results.partial))
            found += [(self.matches.add(hit, code), hit) for hit in results.hits]
        found = sorted(found, key=lambda pair: -pair[0].score)[:limit]
        per_match = max(400, max_chars // max(1, len(found)))
        parts, used = [], 0
        for match, _ in found:
            self._saw(match)
            text = self.digup.text(match.segment_id, code=match.code) if match.segment_id is not None else None
            text = " ".join((text or "").split()) or (match.excerpt or "").replace("«", "").replace("»", "")
            if not text:
                continue
            room = min(per_match, max_chars - used)
            if room < 100:
                break
            if len(text) > room:
                text = text[: room - 1].rstrip() + "…"
            used += len(text)
            self._read.append(match)
            parts.append(f"[{match.n}] {self._relative(match.path)} ({match.where})\n{text}")
        return "\n\n".join(parts)

    def _path(self, value: str) -> str:
        """A path the model gave: relative to the folder, ~/…, or absolute."""
        return os.path.normpath(os.path.join(self.folder, os.path.expanduser(value.strip())))

    def _relative(self, path: str) -> str:
        if path == self.folder:
            return "."
        if path.startswith(self.folder.rstrip("/") + "/"):
            return path[len(self.folder.rstrip("/")) + 1:]
        return shown(path)

    def _saw(self, match: Match) -> None:
        if match not in self.seen:
            self.seen.append(match)

    # MARK: Sources

    def _sources_of(self, answer: str) -> list[Match]:
        """The matches the answer cites; else those read for it; else those whose file it names."""
        numbers = [self.matches.get(n) for n in cited(answer)]
        sources = [match for match in numbers if match is not None]
        self._cited = bool(sources)
        if sources:
            return sources
        if self._read:
            return list(self._read)
        return [match for match in self.seen if os.path.basename(match.path) and
                os.path.basename(match.path) in answer]

    def source_lines(self, matches: list[Match]) -> list[str]:
        return [f"  [{match.n}] {self._relative(match.path)} · {match.where}" for match in matches]

    def _show_sources(self) -> None:
        if self.sources:
            # Cited: the sources. Not cited: what was read for it, which an answer of "nothing found" didn't use.
            title = "Sources" if self._cited else "Read for this answer (none cited)"
            self.out.write(f"\n{title}:\n" + "\n".join(self.source_lines(self.sources)) + "\n")
        elif self.seen:
            self._status(f"(No source cited; /sources lists the {len(self.seen)} matches DigUp found.)")
        self.out.flush()

    def sources_text(self) -> str:
        """/sources: the files of the last answer, then the other matches DigUp found for it."""
        if not self.sources and not self.seen:
            return "No sources yet: ask something first."
        lines = []
        if self.sources:
            lines += ["Sources of the last answer:" if self._cited else "Read for the last answer (none cited):"] \
                + self.source_lines(self.sources)
        others = [match for match in self.seen if match not in self.sources]
        if others:
            lines += ["Also found:"] + [f"{line} · score {match.score:.2f}"
                                        for line, match in zip(self.source_lines(others), others)]
        return "\n".join(lines)

    def _show_stats(self) -> None:
        replies = self._replies
        if not replies:
            return
        speeds = [reply.speed for reply in replies if reply.speed]
        total = sum(reply.seconds for reply in replies)
        parts = [f"{len(replies)} request{'s' if len(replies) != 1 else ''}",
                 f"{self._searches} DigUp search{'es' if self._searches != 1 else ''}"]
        last = replies[-1]
        if last.first_token is not None:
            parts.append(f"answer's first token after {last.first_token:.1f} s")
        if speeds:
            parts.append(f"{speeds[-1]:.0f} tokens/s")
        parts.append(f"{total:.1f} s in all")
        self._status("(" + " · ".join(parts) + ")")

    # MARK: Talking to the person

    def _status(self, text: str) -> None:
        if self.quiet:
            return
        self._end_line()
        dim, plain = ("\033[2m", "\033[0m") if self.color else ("", "")
        self.err.write(f"{dim}{text}{plain}\n")
        self.err.flush()

    def _note(self, text: str) -> None:
        """Said once per chat (DigUp still indexing the folder…)."""
        if text not in self._said:
            self._said.add(text)
            self._status(f"({text})")


def fit(messages: list[dict[str, Any]], budget: int, turn: int) -> list[dict[str, Any]]:
    """The conversation within `budget` characters: tool results before `turn` (the question being answered) cut to
    their start first, then the oldest questions dropped with everything that came of them. Nothing of the current
    question is dropped."""

    def size(items: list[dict[str, Any]]) -> int:
        return sum(len(str(item.get("content") or "")) + len(json.dumps(item.get("tool_calls") or ""))
                   for item in items)

    if size(messages) <= budget:
        return list(messages)
    fitted = [dict(message) for message in messages]
    for index, message in enumerate(fitted[:turn]):
        if message["role"] == "tool" and len(message.get("content") or "") > 300:
            message["content"] = message["content"][:300].rstrip() + " […shortened]"
            if size(fitted) <= budget:
                return fitted
    while size(fitted) > budget and turn > 0:
        later = next((i for i in range(1, turn) if fitted[i]["role"] == "user"), turn)
        fitted, turn = fitted[later:], turn - later
    return fitted


def _int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _colors(stream: TextIO) -> bool:
    return hasattr(stream, "isatty") and stream.isatty() and not os.environ.get("NO_COLOR")


# MARK: The folder: indexed, or added on a yes


def ensure_indexed(digup: DigUp, folder: str, *, yes: bool, wait: float, err: TextIO,
                   ask: Callable[[str], str] = input, interactive: bool | None = None) -> dict[str, Any] | None:
    """The folder's row of the scope report once DigUp indexes it (fully or partly); None when it doesn't and isn't
    added (no, the app isn't running, it refused)."""
    row = digup.scope_report()[0]
    if row["indexed"] != "no":
        return row
    print(f"{shown(folder)} isn't in DigUp's index.", file=err)
    if not yes:
        if not (sys.stdin.isatty() if interactive is None else interactive):
            print("Add it in DigUp, or run digup-ask with --yes to add it.", file=err)
            return None
        try:
            said = ask("Add it to DigUp? It stays among DigUp's folders until you take it out in Settings. [y/N] ")
        except (EOFError, KeyboardInterrupt):
            said = ""
        if said.strip().lower() not in ("y", "yes", "j", "ja", "o", "oui"):
            return None
    digup.allow_add = True
    try:
        answer = digup.add_folder(folder, tool="digup-ask")
    except AppNotRunning as error:
        print(str(error), file=err)
        return None
    except DigUpError as error:
        print(f"DigUp didn't add it: {error}", file=err)
        return None
    finally:
        digup.allow_add = False
    print(str(answer.get("message") or f"Added {shown(folder)} to DigUp."), file=err)
    if answer.get("indexing") == "paused":
        print("Indexing is paused in DigUp: resume it there, and the folder is read.", file=err)
    return wait_for_indexing(digup, wait, err)


def wait_for_indexing(digup: DigUp, wait: float, err: TextIO) -> dict[str, Any]:
    """Waits (at most `wait` seconds; Ctrl+C stops waiting) while DigUp reads a folder just added."""
    deadline = time.monotonic() + wait
    row = digup.scope_report()[0]
    shown_once = False
    try:
        while row.get("indexing") and time.monotonic() < deadline:
            progress = row["indexing"]
            if progress.get("state") == "paused":
                break
            done = (f" {progress.get('done')} of {progress.get('total')}" if progress.get("total") else "")
            print(f"\rIndexing{done}… (Ctrl+C to ask now)   ", end="", file=err, flush=True)
            shown_once = True
            time.sleep(1.0)
            row = digup.scope_report()[0]
    except KeyboardInterrupt:
        pass
    if shown_once:
        print(file=err)
    if row.get("indexing"):
        print("DigUp is still indexing it: answers use what's read so far.", file=err)
    return row


# MARK: The command line


def split_words(words: list[str], cwd: str | None = None) -> tuple[str, str]:
    """`[FOLDER] [question…]`: the first word is the folder when it is one; else the folder is `cwd`."""
    base = cwd or os.getcwd()
    if words:
        first = os.path.join(base, os.path.expanduser(words[0]))
        if os.path.isdir(first):
            return os.path.normpath(first), " ".join(words[1:]).strip()
    return os.path.normpath(base), " ".join(words).strip()


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="digup-ask", formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Ask a folder questions: a chat model answers from what DigUp finds in it, citing the files.",
        epilog="The API key comes from $DIGUP_ASK_API_KEY or $OPENAI_API_KEY (never a flag); a local server needs "
               "none.\nIn the chat: /sources (the files of the last answer), /clear (start over), /help; Ctrl+D "
               "ends it.")
    parser.add_argument("words", nargs="*", metavar="[FOLDER] [QUESTION]",
                        help="the folder (default: the current one), then a question (none: a chat)")
    group = parser.add_argument_group("The model")
    group.add_argument("--base-url", default=os.environ.get("DIGUP_ASK_BASE_URL") or DEFAULT_BASE_URL,
                       help=f"an OpenAI-compatible API (default: $DIGUP_ASK_BASE_URL, else {DEFAULT_BASE_URL}, a "
                            "local llama.cpp server)")
    group.add_argument("--model", default=os.environ.get("DIGUP_ASK_MODEL") or None,
                       help="the model (default: $DIGUP_ASK_MODEL, else the endpoint's only one)")
    group.add_argument("--no-tools", action="store_true",
                       help="don't give the model tools: put DigUp's top matches into the prompt")
    group.add_argument("--max-rounds", type=int, default=MAX_ROUNDS,
                       help=f"rounds of tool calls per question at most (default {MAX_ROUNDS})")
    group.add_argument("--no-stream", action="store_true", help="wait for the whole answer")
    group.add_argument("--temperature", type=float, help="the model's temperature (default: the endpoint's)")
    group.add_argument("--request-timeout", type=float, default=300.0, metavar="S",
                       help="seconds to wait for the model (default 300)")
    group = parser.add_argument_group("The folder")
    group.add_argument("--yes", "-y", action="store_true",
                       help="add the folder to DigUp without asking when it isn't indexed")
    group.add_argument("--max-files", type=int, default=MAX_FILES, metavar="N",
                       help=f"a folder with more files isn't added (default {MAX_FILES})")
    group.add_argument("--wait", type=float, default=120.0, metavar="S",
                       help="after adding: seconds to wait for its indexing at most (default 120)")
    group = parser.add_argument_group("Output")
    group.add_argument("--quiet", "-q", action="store_true", help="don't show the searches")
    group.add_argument("--stats", action="store_true", help="after each answer: requests, time to first token, "
                                                            "tokens per second")
    add_helper_arguments(parser, pinning=False)
    return parser.parse_args(argv)


def api_key() -> str | None:
    return os.environ.get("DIGUP_ASK_API_KEY") or os.environ.get("OPENAI_API_KEY") or None


def choose_model(endpoint: Endpoint) -> str:
    """The endpoint's only model (a llama.cpp server has one); several: --model has to say which."""
    models = endpoint.models()
    if len(models) == 1:
        return models[0]
    if not models:
        raise EndpointError(f"{endpoint.base_url}/models lists no model: say which with --model or $DIGUP_ASK_MODEL")
    some = ", ".join(models[:5]) + (", …" if len(models) > 5 else "")
    raise EndpointError(f"{endpoint.base_url} has {len(models)} models ({some}): say which with --model or "
                        "$DIGUP_ASK_MODEL")


HELP = """\
Ask anything about the folder's files. /sources: the files of the last answer and the other matches; /clear: start
over; Ctrl+C stops an answer; Ctrl+D (or /quit) ends."""


def history_file() -> str:
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "digup", "ask_history")


def chat(asker: Asker, read: Callable[[str], str] = input) -> None:
    """The interactive chat: questions until Ctrl+D (readline keeps the questions asked, never the answers)."""
    readline = None
    if read is input:
        try:
            import readline   # noqa: F401  (line editing and history for input())
            readline.read_history_file(history_file())
        except (ImportError, OSError):
            pass
    model = os.path.basename(asker.endpoint.model or "") or asker.endpoint.model   # llama.cpp names it by its file
    print(f"Ask about {shown(asker.folder)} ({model}; /help). Ctrl+D ends.", file=asker.err)
    try:
        while True:
            try:
                line = read("› ").strip()
            except EOFError:
                print(file=asker.err)
                return
            except KeyboardInterrupt:
                print(file=asker.err)
                continue
            if not line:
                continue
            if line in ("/quit", "/exit", "/q"):
                return
            if line == "/sources":
                print(asker.sources_text(), file=asker.out)
                continue
            if line == "/clear":
                asker.clear()
                print("(Cleared: a new conversation.)", file=asker.err)
                continue
            if line in ("/help", "/?"):
                print(HELP, file=asker.err)
                continue
            if line.startswith("/"):
                print(f"Unknown command {line.split()[0]}: /sources, /clear, /help, /quit.", file=asker.err)
                continue
            try:
                asker.ask(line)
            except KeyboardInterrupt:
                asker._end_line()
                print("(Stopped.)", file=asker.err)
            except EndpointError as error:
                print(f"digup-ask: {error}", file=asker.err)
            except DigUpError as error:
                print(f"digup-ask: DigUp: {error}", file=asker.err)
    finally:
        if readline is not None:
            try:
                os.makedirs(os.path.dirname(history_file()), exist_ok=True)
                readline.set_history_length(1000)
                readline.write_history_file(history_file())
            except OSError:
                pass


def run(args: argparse.Namespace) -> int:
    folder, question = split_words(args.words)
    endpoint = Endpoint(args.base_url, args.model, api_key(), timeout=args.request_timeout,
                        temperature=args.temperature)
    if args.no_stream:
        endpoint.stream = False
    digup = DigUp(config=config_from(args), scope=Scope.of([folder]), max_files=args.max_files,
                  reload_config=lambda: config_from(args), tool="digup-ask", cwd=folder)
    digup.client.request_timeout = args.timeout
    try:
        row = ensure_indexed(digup, folder, yes=args.yes, wait=args.wait, err=sys.stderr)
        if row is None:
            return 1
        code = row.get("code") in ("yes", "partly")
        files = row.get("files") in ("yes", "partly") or not code
        if not endpoint.model:
            endpoint.model = choose_model(endpoint)
        if not endpoint.local:
            print(f"(Answers come from {endpoint.host}: the passages DigUp finds in {shown(folder)} are sent there.)",
                  file=sys.stderr)
        asker = Asker(digup, endpoint, folder, files=files, code=code, tools=not args.no_tools,
                      max_rounds=args.max_rounds, quiet=args.quiet, stats=args.stats)
        if question:
            asker.ask(question)
        else:
            chat(asker)
        return 0
    except EndpointError as error:
        print(f"digup-ask: {error}", file=sys.stderr)
        return 1
    except DigUpError as error:
        print(f"digup-ask: DigUp: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(file=sys.stderr)
        return 130
    finally:
        digup.close()


def main(argv: list[str] | None = None) -> None:
    sys.exit(run(parse_arguments(argv)))


if __name__ == "__main__":
    main()
