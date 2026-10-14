import http.client
import json
import threading

import pytest

from digup_client import HelperConfig
from digup_http import ApiServer
from digup_tools import DigUp


@pytest.fixture
def api(fake_helper):
    servers = []

    def start(**options):
        digup = DigUp(config=HelperConfig.load(roots=["/data"], code_roots=["/data/code"], use_settings=False))
        server = ApiServer(("127.0.0.1", 0), digup, **options)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
        return server

    yield start
    for server in servers:
        server.shutdown()
        server.server_close()
        server.digup.close()


def call(server, method, path, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=10)
    data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
    connection.request(method, path, body=data, headers={"Content-Type": "application/json", **(headers or {})})
    response = connection.getresponse()
    raw = response.read()
    connection.close()
    kind = response.getheader("Content-Type") or ""
    return response.status, (json.loads(raw) if kind.startswith("application/json") else raw), response


def test_endpoints(api):
    server = api()
    status, body, _ = call(server, "GET", "/health")
    assert status == 200 and body["ok"]

    status, body, _ = call(server, "POST", "/search", {"query": "zebra", "kinds": ["video", "pdf"], "limit": 5})
    assert status == 200 and body["count"] == 2 and body["strong"] == 2
    first = body["hits"][0]
    assert first["where"] == "0:06-0:12 (picture)" and first["rank"] == 1 and first["strong"]
    assert first["path"] == "/data/video/zoo.mp4" and first["cosine"] == 0.71 and first["info"]["duration"] == "18.1"

    status, body, _ = call(server, "GET", "/search?q=code:%20retry&limit=1")
    assert status == 200 and body["code"] and body["hits"][0]["where"] == "lines 1-33 (line 8)"

    status, body, _ = call(server, "GET", "/segments/31")
    assert status == 200 and body["text"].startswith("Page three")
    status, body, _ = call(server, "GET", "/segments/77?code=true")
    assert body["text"].startswith("import random")
    status, body, _ = call(server, "GET", "/segments/272")
    assert status == 404

    status, body, _ = call(server, "POST", "/context", {"query": "payment declined", "limit": 3, "max_chars": 2000})
    assert status == 200 and body["context"].startswith("[1] /data/docs/lease.pdf (page 3)\n")
    assert body["sources"][0]["citation"] == "/data/docs/lease.pdf (page 3)"

    status, body, _ = call(server, "POST", "/similar", {"path": "/data/notes/todo.md"})
    assert status == 501 and "newer DigUp helper" in body["error"]

    status, image, response = call(server, "GET", "/preview?path=/data/docs/lease.pdf&loc=2")
    assert status == 200 and response.getheader("Content-Type") == "image/jpeg" and image.startswith(b"\xff\xd8")
    status, body, _ = call(server, "GET", "/preview?path=/etc/hosts.png")
    assert status == 403

    status, body, _ = call(server, "GET", "/status")
    assert status == 200 and body["roots"] == ["/data"] and body["encoder"] == "stopped"

    status, spec, _ = call(server, "GET", "/openapi.json")
    assert spec["openapi"] == "3.1.0" and "/context" in spec["paths"] and "security" not in spec
    assert spec["servers"][0]["url"] == f"http://127.0.0.1:{server.server_address[1]}"


def test_filter(api):
    server = api()
    # GET with an empty query: the filter alone.
    status, body, _ = call(server, "GET", "/search?q=&filter=payment*")
    assert status == 200 and body["filter"] == "payment*" and [hit["path"] for hit in body["hits"]] == [
        "/data/docs/lease.pdf"]
    assert "filter_note" not in body
    status, body, _ = call(server, "POST", "/search", {"query": "zebra", "filter": "\"lease"})
    assert status == 200 and body["filter_note"] == "unclosed quote: read as plain words"
    status, body, _ = call(server, "POST", "/context", {"filter": "lease", "max_chars": 2000})
    assert status == 200 and body["filter"] == "lease" and body["context"].startswith("[1] /data/docs/lease.pdf")
    assert call(server, "POST", "/search", {"query": "", "filter": " "})[0] == 400
    assert call(server, "POST", "/search", {"query": "x", "filter": 3})[0] == 400
    spec = call(server, "GET", "/openapi.json")[1]
    search = spec["components"]["schemas"]["SearchRequest"]["properties"]
    assert "NOT" in search["filter"]["description"] and search["filter"]["examples"]
    assert spec["components"]["schemas"]["ContextRequest"]["properties"]["filter"] == search["filter"]
    assert spec["paths"]["/search"]["post"]["requestBody"]["content"]["application/json"]["example"]["filter"]


def test_errors(api):
    server = api()
    assert call(server, "POST", "/search", {"query": ""})[0] == 400
    assert call(server, "POST", "/search", {"query": "x", "kinds": ["spreadsheet"]})[0] == 400
    assert call(server, "POST", "/search", b"not json")[0] == 400
    assert call(server, "GET", "/nope")[0] == 404
    assert call(server, "GET", "/context")[0] == 405
    assert call(server, "POST", "/search", {"query": "error"})[0] == 502
    assert call(server, "GET", "/segments/abc")[0] == 400


def test_token(api):
    server = api(token="s3cret")
    assert call(server, "GET", "/health")[0] == 200
    status, body, response = call(server, "POST", "/search", {"query": "zebra"})
    assert status == 401 and response.getheader("WWW-Authenticate").startswith("Bearer")
    assert call(server, "POST", "/search", {"query": "zebra"}, {"Authorization": "Bearer wrong"})[0] == 401
    assert call(server, "POST", "/search", {"query": "zebra"}, {"Authorization": "Bearer s3cret"})[0] == 200
    spec = call(server, "GET", "/openapi.json")[1]
    assert spec["security"] == [{"bearer": []}]


def test_only_requests_to_localhost(api):
    server = api()
    port = server.server_address[1]
    assert call(server, "GET", "/status", headers={"Host": f"localhost:{port}"})[0] == 200
    assert call(server, "GET", "/status", headers={"Host": "evil.example:80"})[0] == 403


def test_cors_is_off_unless_asked(api):
    server = api()
    _, _, response = call(server, "GET", "/health")
    assert response.getheader("Access-Control-Allow-Origin") is None
    assert call(server, "OPTIONS", "/search")[0] == 405
    server = api(cors="http://localhost:3000")
    _, _, response = call(server, "GET", "/health")
    assert response.getheader("Access-Control-Allow-Origin") == "http://localhost:3000"
    assert call(server, "OPTIONS", "/search")[0] == 204
