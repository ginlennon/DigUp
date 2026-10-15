"""A stand-in for an OpenAI-compatible chat-completions server, for digup-ask's tests: scripted replies (text, tool
calls, errors), streamed as server-sent events when asked, and every request kept (path, headers, body).

    server = FakeOpenAI([call("search_files", query="payment"), text("Declined [1].")])
    server.url        # http://127.0.0.1:PORT/v1
    server.requests   # [{"path", "headers", "body"}, …]

`reject_tools`: a request with tools gets llama.cpp's 500 without --jinja. `reject_stream`: a streamed request gets a
400 about streaming. `echo_auth`: errors repeat the Authorization header (as a careless server might).
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


def text(content: str) -> dict[str, Any]:
    return {"content": content}


def call(name: str, **arguments: Any) -> dict[str, Any]:
    return {"tool_calls": [(name, arguments)]}


def calls(*pairs: tuple[str, dict[str, Any]]) -> dict[str, Any]:
    return {"tool_calls": list(pairs)}


def error(status: int, message: str) -> dict[str, Any]:
    return {"error": (status, message)}


class FakeOpenAI:
    def __init__(self, script: list[dict[str, Any]] | None = None, *, models: list[str] | None = None,
                 reject_tools: bool = False, reject_stream: bool = False, echo_auth: bool = False,
                 repeat: dict[str, Any] | None = None):
        self.script = list(script or [])
        self.models = ["fake-model"] if models is None else models
        self.reject_tools = reject_tools
        self.reject_stream = reject_stream
        self.echo_auth = echo_auth
        self.repeat = repeat          # given again once the script is through (a model that never stops calling)
        self.requests: list[dict[str, Any]] = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: Any) -> None:
                pass

            def do_GET(self) -> None:
                fake.requests.append({"path": self.path, "headers": dict(self.headers), "body": None})
                if self.path == "/v1/models":
                    self._json(200, {"object": "list", "data": [{"id": m, "object": "model"} for m in fake.models]})
                else:
                    self._json(404, {"error": {"message": "not found"}})

            def do_POST(self) -> None:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                fake.requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
                auth = self.headers.get("Authorization", "")
                if self.path != "/v1/chat/completions":
                    self._json(404, {"error": {"message": "not found"}})
                    return
                if fake.reject_tools and body.get("tools"):
                    self._json(500, {"error": {"code": 500, "message": "tools param requires --jinja flag"
                                               + (f" (you sent {auth})" if fake.echo_auth else ""),
                                               "type": "server_error"}})
                    return
                if fake.reject_stream and body.get("stream"):
                    self._json(400, {"error": {"message": "stream is not supported"}})
                    return
                step = fake.script.pop(0) if fake.script else (fake.repeat or text("(the script is through)"))
                if "error" in step:
                    status, message = step["error"]
                    if fake.echo_auth:
                        message += f" (you sent {auth})"
                    self._json(status, {"error": {"message": message}})
                    return
                if body.get("stream"):
                    self._stream(step)
                else:
                    self._json(200, self._whole(step))

            def _json(self, status: int, value: Any) -> None:
                data = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            @staticmethod
            def _tool_calls(step: dict[str, Any]) -> list[dict[str, Any]]:
                return [{"id": f"call_{i}", "type": "function",
                         "function": {"name": name, "arguments": json.dumps(arguments)}}
                        for i, (name, arguments) in enumerate(step.get("tool_calls") or [])]

            def _whole(self, step: dict[str, Any]) -> dict[str, Any]:
                message: dict[str, Any] = {"role": "assistant", "content": step.get("content")}
                if step.get("tool_calls"):
                    message["tool_calls"] = self._tool_calls(step)
                return {"id": "x", "object": "chat.completion", "model": "fake-model",
                        "choices": [{"index": 0, "message": message,
                                     "finish_reason": "tool_calls" if step.get("tool_calls") else "stop"}],
                        "usage": {"prompt_tokens": 100, "completion_tokens": 7, "total_tokens": 107}}

            def _stream(self, step: dict[str, Any]) -> None:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()

                def send(chunk: dict[str, Any]) -> None:
                    self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
                    self.wfile.flush()

                def delta(value: dict[str, Any], finish: str | None = None) -> None:
                    send({"id": "x", "object": "chat.completion.chunk",
                          "choices": [{"index": 0, "delta": value, "finish_reason": finish}]})

                delta({"role": "assistant", "content": None})
                for word in (step.get("content") or "").split(" "):
                    if word:
                        delta({"content": word + " "})
                for i, call_ in enumerate(self._tool_calls(step)):
                    # As servers send them: the name first, then the arguments in pieces.
                    delta({"tool_calls": [{"index": i, "id": call_["id"], "type": "function",
                                           "function": {"name": call_["function"]["name"], "arguments": ""}}]})
                    arguments = call_["function"]["arguments"]
                    for start in range(0, len(arguments), 7):
                        delta({"tool_calls": [{"index": i, "function": {"arguments": arguments[start:start + 7]}}]})
                delta({}, "tool_calls" if step.get("tool_calls") else "stop")
                send({"id": "x", "object": "chat.completion.chunk", "choices": [],
                      "usage": {"prompt_tokens": 100, "completion_tokens": 5},
                      "timings": {"predicted_n": 5, "predicted_per_second": 42.0}})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}/v1"

    @property
    def chats(self) -> list[dict[str, Any]]:
        """The chat-completions requests' bodies."""
        return [request["body"] for request in self.requests if request["path"] == "/v1/chat/completions"]

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
