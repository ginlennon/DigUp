"""DigUp's search as a small HTTP API on this computer, for RAG apps, scripts and tool servers (Open WebUI…).

    uv run --project <repo>/integrations digup-http [--port 8484] [--token SECRET] [--root DIR]… [--code-root DIR]…

It listens on 127.0.0.1 only (another address only with an explicit --host, and with a warning), and answers only
requests addressed to localhost, so a web page can't reach it through DNS rebinding. With a token (--token or
$DIGUP_API_TOKEN) every endpoint but /health and /openapi.json needs `Authorization: Bearer <token>`. CORS is off
unless --cors names an origin.

    GET  /health                       → {"ok": true}
    GET  /status                       → the encoder, the vectors, the index, the folders
    POST /search   {query, kinds?, folders?, limit?, code?}        → {hits: [...]}   (also GET /search?q=…)
    GET  /segments/{id}?code=false     → {text}: a hit's indexed text
    POST /similar  {path, limit?, kinds?, folders?}               → {hits: [...]}
    POST /context  {query, limit?, max_chars?, kinds?, folders?, code?} → {context, sources}: for RAG
    GET  /preview?path=…&kind=pdf|video|image&loc=…&pixels=…      → image/jpeg
    GET  /openapi.json                 → this API as OpenAPI 3.1
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import signal
import socket
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit

from digup_client import DigUpError, HelperDied, HelperError, HelperNotFound, HelperTimeout
from digup_tools import KINDS, BadRequest, DigUp, Forbidden, Results, Unsupported, add_helper_arguments, config_from, where

VERSION = "0.1.0"
LOOPBACK = ("127.0.0.1", "localhost", "::1")
MAX_BODY = 1 << 20


def hits_json(results: Results) -> dict[str, Any]:
    """The helper's hit fields, plus `where` (the place in the file in words) and `rank`."""
    body: dict[str, Any] = {
        "query": results.query, "code": results.code, "meaning": results.meaning, "strong": results.strong,
        "count": len(results.hits),
        "hits": [{"rank": index + 1, **hit, "where": where(hit), "strong": index < results.strong}
                 for index, hit in enumerate(results.hits)],
    }
    if results.warning:
        body["warning"] = results.warning
    if results.ms:
        body["ms"] = results.ms
    return body


def truthy(value: Any) -> bool:
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on")
    return bool(value)


class ApiServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], digup: DigUp, *, token: str | None = None,
                 check_host: bool = True, cors: str | None = None, verbose: bool = False):
        self.digup = digup
        self.token = token or None
        self.check_host = check_host
        self.cors = cors
        self.verbose = verbose
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(address, Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{'[' + host + ']' if ':' in str(host) else host}:{port}"


class Handler(BaseHTTPRequestHandler):
    server: ApiServer
    protocol_version = "HTTP/1.1"
    server_version = f"DigUp/{VERSION}"

    # MARK: Plumbing

    def log_message(self, format: str, *args: Any) -> None:
        if self.server.verbose:
            sys.stderr.write(f"digup-http: {self.address_string()} {format % args}\n")

    def send_json(self, status: int, body: Any) -> None:
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_bytes(status, data, "application/json; charset=utf-8")

    def send_bytes(self, status: int, data: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if self.server.cors:
            self.send_header("Access-Control-Allow-Origin", self.server.cors)
            self.send_header("Vary", "Origin")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def fail(self, status: int, message: str) -> None:
        self.send_json(status, {"error": message})

    def body(self) -> dict[str, Any]:
        raw = self.raw_body
        if not raw.strip():
            return {}
        try:
            value = json.loads(raw)
        except ValueError:
            raise BadRequest("the body must be JSON") from None
        if not isinstance(value, dict):
            raise BadRequest("the body must be a JSON object")
        return value

    def host_allowed(self) -> bool:
        """Only requests addressed to this computer by name (DNS-rebinding protection), when bound to loopback."""
        if not self.server.check_host:
            return True
        host = (self.headers.get("Host") or "").strip().lower()
        if host.startswith("["):
            name = host[1:host.find("]")] if "]" in host else host
        else:
            name = host.rsplit(":", 1)[0] if host.count(":") == 1 else host
        return name in LOOPBACK

    def authorized(self) -> bool:
        if not self.server.token:
            return True
        given = self.headers.get("Authorization") or ""
        scheme, _, value = given.partition(" ")
        return scheme.lower() == "bearer" and hmac.compare_digest(value.strip().encode(), self.server.token.encode())

    def do_OPTIONS(self) -> None:
        if not self.server.cors:
            self.fail(HTTPStatus.METHOD_NOT_ALLOWED, "CORS is off (start with --cors ORIGIN)")
            return
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Access-Control-Allow-Origin", self.server.cors)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Max-Age", "600")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        self.dispatch("GET")

    def do_HEAD(self) -> None:
        self.dispatch("GET")

    def do_POST(self) -> None:
        self.dispatch("POST")

    def dispatch(self, method: str) -> None:
        self.raw_body = b""
        if method == "POST":
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if length < 0 or length > MAX_BODY:
                self.close_connection = True
                self.fail(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "the body is too large (or its length is wrong)")
                return
            self.raw_body = self.rfile.read(length) if length else b""
        if not self.host_allowed():
            self.fail(HTTPStatus.FORBIDDEN, "requests must be addressed to localhost")
            return
        url = urlsplit(self.path)
        path = url.path.rstrip("/") or "/"
        query = {name: values[-1] for name, values in parse_qs(url.query).items()}
        public = path in ("/health", "/openapi.json", "/")
        if not public and not self.authorized():
            self.send_response(HTTPStatus.UNAUTHORIZED)
            self.send_header("WWW-Authenticate", 'Bearer realm="digup"')
            data = b'{"error": "a bearer token is required"}'
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        try:
            self.route(method, path, query)
        except BadRequest as error:
            self.fail(HTTPStatus.BAD_REQUEST, str(error))
        except Forbidden as error:
            self.fail(HTTPStatus.FORBIDDEN, str(error))
        except Unsupported as error:
            self.fail(HTTPStatus.NOT_IMPLEMENTED, str(error))
        except HelperTimeout as error:
            self.fail(HTTPStatus.GATEWAY_TIMEOUT, str(error))
        except (HelperNotFound, HelperDied) as error:
            self.fail(HTTPStatus.SERVICE_UNAVAILABLE, str(error))
        except HelperError as error:
            self.fail(HTTPStatus.BAD_GATEWAY, str(error))
        except DigUpError as error:
            self.fail(HTTPStatus.INTERNAL_SERVER_ERROR, str(error))
        except (BrokenPipeError, ConnectionResetError):
            pass

    # MARK: Endpoints

    def route(self, method: str, path: str, query: dict[str, str]) -> None:
        digup = self.server.digup
        if path in ("/", "/health") and method == "GET":
            self.send_json(HTTPStatus.OK, {"ok": True, "service": "digup", "version": VERSION,
                                           "helper_running": digup.client.running})
        elif path == "/openapi.json" and method == "GET":
            self.send_json(HTTPStatus.OK, openapi(self.headers.get("Host") or self.server.url.split("//")[1],
                                                  bool(self.server.token)))
        elif path == "/status" and method == "GET":
            self.send_json(HTTPStatus.OK, digup.status())
        elif path == "/search" and method in ("GET", "POST"):
            body = self.body() if method == "POST" else {
                "query": query.get("q", query.get("query", "")), "kinds": query.get("kinds"),
                "folders": query.get("folders"), "limit": query.get("limit"), "code": query.get("code")}
            results = digup.search(body.get("query", body.get("q", "")), kinds=body.get("kinds"),
                                   folders=body.get("folders"), limit=body.get("limit", 10),
                                   code=truthy(body.get("code")), meaning=body.get("meaning", True) is not False)
            self.send_json(HTTPStatus.OK, hits_json(results))
        elif path.startswith("/segments/") and method == "GET":
            segment = unquote(path[len("/segments/"):])
            code = truthy(query.get("code", "false"))
            text = digup.text(segment, code=code)
            if text is None:
                self.fail(HTTPStatus.NOT_FOUND, "that segment has no indexed text (a picture or a frame), or it's "
                                                "gone from the index")
            else:
                self.send_json(HTTPStatus.OK, {"segment_id": int(segment), "code": code, "text": text})
        elif path == "/similar" and method == "POST":
            body = self.body()
            results = digup.similar(body.get("path", ""), limit=body.get("limit", 10), kinds=body.get("kinds"),
                                    folders=body.get("folders"))
            self.send_json(HTTPStatus.OK, hits_json(results))
        elif path == "/context" and method == "POST":
            body = self.body()
            context = digup.context(body.get("query", body.get("q", "")), limit=body.get("limit", 5),
                                    max_chars=body.get("max_chars", 6000), kinds=body.get("kinds"),
                                    folders=body.get("folders"), code=truthy(body.get("code")))
            self.send_json(HTTPStatus.OK, context)
        elif path == "/preview" and method == "GET":
            image = digup.render(query.get("path", ""), kind=query.get("kind") or None, loc=query.get("loc"),
                                 pixels=query.get("pixels") or 1024)
            try:
                with open(image, "rb") as file:
                    data = file.read()
            except OSError as error:
                raise DigUpError(f"the preview can't be read: {error}") from None
            self.send_bytes(HTTPStatus.OK, data, "image/jpeg")
        elif path in ("/search", "/similar", "/context", "/status", "/preview", "/health", "/openapi.json") \
                or path.startswith("/segments/"):
            self.fail(HTTPStatus.METHOD_NOT_ALLOWED, f"{method} isn't allowed on {path}")
        else:
            self.fail(HTTPStatus.NOT_FOUND, f"no endpoint {path} (see /openapi.json)")


# MARK: OpenAPI


def openapi(host: str, token: bool) -> dict[str, Any]:
    """The API as OpenAPI 3.1, for tool servers (Open WebUI) and client generators."""
    kinds = {"type": "array", "items": {"type": "string", "enum": list(KINDS)},
             "description": "Only these kinds of files (default: all)."}
    folders = {"type": "array", "items": {"type": "string"},
               "description": "Only files inside these folders (absolute or ~/ paths; default: all searched folders)."}
    limit = {"type": "integer", "minimum": 1, "maximum": 200, "default": 10, "description": "How many results at most."}
    error = {"description": "An error", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Error"}}}}
    errors = {"400": error, "401": error, "502": error, "503": error, "504": error}

    def json_body(schema: str) -> dict[str, Any]:
        return {"required": True, "content": {"application/json": {"schema": {"$ref": f"#/components/schemas/{schema}"}}}}

    def json_reply(schema: str, description: str) -> dict[str, Any]:
        return {"description": description,
                "content": {"application/json": {"schema": {"$ref": f"#/components/schemas/{schema}"}}}}

    spec: dict[str, Any] = {
        "openapi": "3.1.0",
        "info": {
            "title": "DigUp local search",
            "version": VERSION,
            "description": "On-device semantic search over the user's own files (documents, PDFs by page, photos, "
                           "screenshots with their text, audio, video, and code folders), by DigUp. Everything runs "
                           "on this computer; results are local file paths.",
        },
        "servers": [{"url": f"http://{host}"}],
        "paths": {
            "/search": {"post": {
                "operationId": "search_files",
                "summary": "Search local files by meaning and words",
                "description": "Searches the files DigUp indexed on this computer by meaning (EmbeddingGemma 2) and "
                               "words. Describe what you look for in plain words. Each hit has the file's absolute "
                               "path, its kind, where in the file it matched (`where`: page, time, lines) and a "
                               "segment_id whose indexed text /segments/{segment_id} returns. Set code=true (or start "
                               "the query with \"code:\") to search the code index.",
                "requestBody": json_body("SearchRequest"),
                "responses": {"200": json_reply("SearchResults", "The matches, best first"), **errors},
            }},
            "/segments/{segment_id}": {"get": {
                "operationId": "read_segment",
                "summary": "Read the indexed text of a search hit",
                "description": "The text DigUp indexed for a hit: a document's chunk, a PDF page's text, a "
                               "screenshot's OCR text, or a stretch of a code file. Pictures and frames have none (404).",
                "parameters": [
                    {"name": "segment_id", "in": "path", "required": True, "schema": {"type": "integer"},
                     "description": "A hit's segment_id"},
                    {"name": "code", "in": "query", "required": False, "schema": {"type": "boolean", "default": False},
                     "description": "true for a hit of a code search"},
                ],
                "responses": {"200": json_reply("Segment", "The text"), "404": error, **errors},
            }},
            "/context": {"post": {
                "operationId": "get_context",
                "summary": "Retrieve passages from local files for answering a question (RAG)",
                "description": "Searches, then returns the top hits' indexed texts concatenated, each numbered and "
                               "headed by its citation (file path and page or time), within max_chars. Cite sources "
                               "as [n].",
                "requestBody": json_body("ContextRequest"),
                "responses": {"200": json_reply("Context", "The passages and their sources"), **errors},
            }},
            "/similar": {"post": {
                "operationId": "find_similar",
                "summary": "Find files like a given file",
                "description": "Files whose content is like the given indexed file's. Needs a DigUp helper with the "
                               "`similar` op (501 otherwise).",
                "requestBody": json_body("SimilarRequest"),
                "responses": {"200": json_reply("SearchResults", "Similar files, most similar first"), "501": error,
                              **errors},
            }},
            "/status": {"get": {
                "operationId": "index_status",
                "summary": "DigUp's state",
                "description": "The query encoder's state, the vectors loaded, the index, and the folders searched.",
                "responses": {"200": json_reply("Status", "The state"), **errors},
            }},
            "/preview": {"get": {
                "operationId": "preview",
                "summary": "A JPEG of a PDF page, a video frame or a picture",
                "parameters": [
                    {"name": "path", "in": "query", "required": True, "schema": {"type": "string"}},
                    {"name": "kind", "in": "query", "schema": {"type": "string", "enum": ["pdf", "video", "image"]}},
                    {"name": "loc", "in": "query", "schema": {"type": "number"},
                     "description": "The PDF page (from 1) or seconds into the video"},
                    {"name": "pixels", "in": "query", "schema": {"type": "integer", "default": 1024}},
                ],
                "responses": {"200": {"description": "The image", "content": {"image/jpeg": {
                    "schema": {"type": "string", "contentMediaType": "image/jpeg"}}}}, "403": error, **errors},
            }},
            "/health": {"get": {
                "operationId": "health", "summary": "Whether the API is up",
                "responses": {"200": {"description": "Up", "content": {"application/json": {"schema": {
                    "type": "object", "properties": {"ok": {"type": "boolean"}}}}}}},
                "security": [],
            }},
        },
        "components": {"schemas": {
            "SearchRequest": {"type": "object", "required": ["query"], "properties": {
                "query": {"type": "string", "description": "What to find, in plain words"},
                "kinds": kinds, "folders": folders, "limit": limit,
                "code": {"type": "boolean", "default": False, "description": "Search the code index"},
            }},
            "SimilarRequest": {"type": "object", "required": ["path"], "properties": {
                "path": {"type": "string", "description": "An indexed file"},
                "kinds": kinds, "folders": folders, "limit": limit,
            }},
            "ContextRequest": {"type": "object", "required": ["query"], "properties": {
                "query": {"type": "string", "description": "The question or topic"},
                "limit": {**limit, "default": 5, "description": "How many hits to read"},
                "max_chars": {"type": "integer", "default": 6000, "description": "The context's size at most"},
                "kinds": kinds, "folders": folders,
                "code": {"type": "boolean", "default": False},
            }},
            "Hit": {"type": "object", "required": ["path", "kind", "where", "score", "segment_id"], "properties": {
                "rank": {"type": "integer"},
                "path": {"type": "string", "description": "The file's absolute path"},
                "kind": {"type": "string", "enum": [*KINDS, "code"]},
                "where": {"type": "string", "description": "Where in the file: \"page 3\", \"0:06-0:12 (picture)\", "
                                                           "\"lines 1-33 (line 8)\", \"text\""},
                "score": {"type": "number", "description": "Fused rank score, for ordering only"},
                "strong": {"type": "boolean", "description": "A clear match (false: a weaker one)"},
                "segment": {"type": "string", "description": "What matched: chunk, page, page_image, image, ocr, "
                                                             "frame, audio, name, lines, cells"},
                "segment_id": {"type": "integer"},
                "loc": {"type": "number", "description": "PDF page, seconds, or first line/cell"},
                "loc_end": {"type": "number"},
                "focus": {"type": "number", "description": "Code: the line to open at"},
                "excerpt": {"type": "string", "description": "Keyword matches marked «like this»"},
                "modified": {"type": "number", "description": "Seconds since 1970"},
                "size": {"type": "integer"},
                "info": {"type": "object", "additionalProperties": {"type": "string"}},
                "z": {"type": "number"}, "cosine": {"type": "number"}, "keyword_rank": {"type": "integer"},
            }},
            "SearchResults": {"type": "object", "properties": {
                "query": {"type": "string"}, "code": {"type": "boolean"},
                "meaning": {"type": "boolean", "description": "false: keyword matches only"},
                "strong": {"type": "integer"}, "count": {"type": "integer"},
                "hits": {"type": "array", "items": {"$ref": "#/components/schemas/Hit"}},
                "warning": {"type": "string"},
            }},
            "Segment": {"type": "object", "properties": {
                "segment_id": {"type": "integer"}, "code": {"type": "boolean"}, "text": {"type": "string"}}},
            "Context": {"type": "object", "properties": {
                "query": {"type": "string"},
                "context": {"type": "string", "description": "[n] path (where)\\ntext, separated by blank lines"},
                "sources": {"type": "array", "items": {"type": "object"}},
                "other_matches": {"type": "array", "items": {"type": "object"},
                                  "description": "Matches without text (pictures, frames)"},
                "chars": {"type": "integer"},
            }},
            "Status": {"type": "object", "additionalProperties": True},
            "Error": {"type": "object", "properties": {"error": {"type": "string"}}},
        }},
    }
    if token:
        spec["components"]["securitySchemes"] = {"bearer": {"type": "http", "scheme": "bearer"}}
        spec["security"] = [{"bearer": []}]
    return spec


# MARK: Running it


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="digup-http", description="DigUp's search as an HTTP API on localhost.")
    parser.add_argument("--host", help="the address to listen on (default 127.0.0.1; anything else is reachable "
                                       "from other computers)")
    parser.add_argument("--port", type=int, default=8484, help="the port (default 8484; 0: any free one)")
    parser.add_argument("--token", help="require this bearer token (default: $DIGUP_API_TOKEN, else none)")
    parser.add_argument("--cors", metavar="ORIGIN", help="allow this browser origin (default: CORS off)")
    parser.add_argument("--prewarm", action="store_true", help="start the encoder now, not on the first search")
    parser.add_argument("--verbose", action="store_true", help="log each request")
    add_helper_arguments(parser)
    return parser.parse_args(argv)


def serve(args: argparse.Namespace) -> int:
    host = args.host or "127.0.0.1"
    loopback = host in LOOPBACK
    token = args.token or os.environ.get("DIGUP_API_TOKEN") or None
    if not loopback:
        print(f"digup-http: warning: listening on {host}: other computers can reach this API and search your "
              "files" + ("" if token else ", and no token is set (--token)"), file=sys.stderr)
    digup = DigUp(config=config_from(args))
    digup.client.request_timeout = args.timeout
    server = ApiServer((host, args.port), digup, token=token, check_host=loopback, cors=args.cors,
                       verbose=args.verbose)
    print(f"digup-http: DigUp API on {server.url} (OpenAPI: {server.url}/openapi.json)", file=sys.stderr, flush=True)
    if args.prewarm:
        threading.Thread(target=lambda: _quietly(lambda: digup.client.request("prewarm", timeout=300)),
                         daemon=True).start()
    signal.signal(signal.SIGTERM, _interrupt)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        digup.close()
    return 0


def _interrupt(*_: Any) -> None:
    raise KeyboardInterrupt


def _quietly(action: Any) -> None:
    try:
        action()
    except DigUpError as error:
        print(f"digup-http: prewarm: {error}", file=sys.stderr)


def main(argv: list[str] | None = None) -> None:
    sys.exit(serve(parse_arguments(argv)))


if __name__ == "__main__":
    main()
