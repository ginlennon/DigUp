# DigUp integrations: MCP server and local HTTP API

DigUp's search for other programs. DigUp indexes your own files on your computer (documents, PDFs page by page,
photos, screenshots with their text, audio, video, and code folders) with EmbeddingGemma 2 on llama.cpp. These two
servers let other apps search that index:

- **`digup-mcp`**: an [MCP](https://modelcontextprotocol.io) server for coding agents and chat apps (Claude Code,
  Cursor, VS Code Copilot, Zed…). They can search your files by meaning and read the passage that matched.
- **`digup-http`**: a small JSON API on `127.0.0.1` for RAG apps, scripts and tool servers (Open WebUI…), with an
  OpenAPI 3.1 spec and a `/context` endpoint that returns ready-made, cited passages for a prompt.

Both run DigUp's helper (`digup search-service`) and keep it open, so a search takes tens of milliseconds once the
encoder is warm (the first one starts it: about a second). They only read the index; the desktop app can run at the
same time.

**Privacy.** Everything stays on your computer: the model, the index and the searches. Nothing is sent anywhere.
The HTTP API listens on localhost only and answers only requests addressed to localhost (another address only with
an explicit `--host`, and a warning). Keep in mind that whatever you connect gets to read your files' indexed text:
a cloud-hosted model behind an agent sees what its tools return to it.

## Install and run

You need DigUp built or installed (the helper `digup`, the model, an index: see the repo's [README](../README.md))
and [uv](https://docs.astral.sh/uv/). The integrations run on Python 3.13; uv fetches it if needed.

```sh
cd <repo>                                     # your DigUp checkout, e.g. ~/DigUp-Linux
uv run --project integrations digup-mcp --help
uv run --project integrations digup-http      # → http://127.0.0.1:8484, spec at /openapi.json
```

**Which helper.** `--helper PATH`, else `$DIGUP_HELPER`, else `digup` on PATH, else the dev build in this checkout
(`<repo>/.build/release/digup`, with `DIGUP_BACKENDS=<repo>/Vendor/llama/lib` set for it when unset). On a Mac the
app's helper is `DigUp.app/Contents/Helpers/digup`.

**Which index and folders.** The index is DigUp's own (`~/.local/share/digup/index` on Linux) unless `--index DIR` or
`$DIGUP_INDEX`. The searched folders are `--root DIR` (repeatable), else `$DIGUP_ROOTS` (`:`-separated), else the
desktop app's settings (`~/.config/com.abdurrahim.DigUp/settings.json`: its folders, skipped folders and skipped
types). Code search needs the code folders: `--code-root DIR` or `$DIGUP_CODE_ROOTS`. A folder that isn't indexed
simply finds nothing. `DIGUP_GPU=0` keeps the query encoder on the CPU (fine for queries).

Other flags: `--exclude DIR`, `--exclude-ext EXT`, `--encoder-idle S` (the encoder exits after S idle seconds, 300 by
default), `--timeout S`, `--no-settings`.

## MCP server

Tools (all read-only):

| Tool | What it does |
|---|---|
| `search_files(query, kinds?, folders?, limit=10)` | Search by meaning and words. `kinds`: screenshot, image, pdf, doc, audio, video. Returns absolute paths, where in the file (page, time, lines), a score, an excerpt and a segment number. |
| `read_segment(segment_id, code=false, max_chars=8000)` | The indexed text of a hit: the document's chunk, the PDF page's text, a screenshot's text, a code stretch. |
| `search_code(query, limit=10)` | The code index (what a DigUp search starting with `code:` does). |
| `find_similar(path, limit=10, kinds?, folders?)` | Files like a given file; needs a helper with the `similar` op, says so otherwise. |
| `index_status(doctor=false)` | Encoder state, vectors, index, folders (and `digup doctor --json` when the helper has it). |

A result looks like this (what the model reads):

```
DigUp results for "zebra in a video": 3 matches by meaning and words; 3 strong.
1. /home/you/Videos/penguin_zebra_parrot_18s.mp4
   video · 0:06-0:12 (picture) · score 8.26 · segment 272
2. /home/you/Pictures/Animals-Zebra.jpg
   image · the image · score 6.93 · segment 126
Read a match's indexed text with read_segment(segment_id).
```

In the snippets below, replace `/ABSOLUTE/PATH/TO/DigUp` with your checkout's absolute path (editors don't expand
`~` in these files). Add `--code-root /ABSOLUTE/PATH/TO/code` to the args to enable `search_code`.

**Claude Code** (`--scope user`: in every project; the default is this project only):

```sh
claude mcp add --scope user digup -- uv run --project ~/DigUp-Linux/integrations digup-mcp
# with options: claude mcp add digup -e DIGUP_GPU=0 -- uv run --project ~/DigUp-Linux/integrations digup-mcp --code-root ~/src
```

**Cursor** (`~/.cursor/mcp.json`, or `.cursor/mcp.json` in a project):

```json
{
  "mcpServers": {
    "digup": {
      "command": "uv",
      "args": ["run", "--project", "/ABSOLUTE/PATH/TO/DigUp/integrations", "digup-mcp"]
    }
  }
}
```

**VS Code** (`.vscode/mcp.json` in a workspace, or `MCP: Open User Configuration`):

```json
{
  "servers": {
    "digup": {
      "type": "stdio",
      "command": "uv",
      "args": ["run", "--project", "/ABSOLUTE/PATH/TO/DigUp/integrations", "digup-mcp"]
    }
  }
}
```

**Zed** (`settings.json`):

```json
{
  "context_servers": {
    "digup": {
      "command": "uv",
      "args": ["run", "--project", "/ABSOLUTE/PATH/TO/DigUp/integrations", "digup-mcp"],
      "env": {}
    }
  }
}
```

**Over HTTP** (for clients that only take a URL): `digup-mcp --http --port 8765` serves streamable HTTP at
`http://127.0.0.1:8765/mcp`.

## HTTP API

```sh
uv run --project integrations digup-http [--port 8484] [--token SECRET] [--root DIR]… [--code-root DIR]…
```

| Endpoint | |
|---|---|
| `GET /health` | `{"ok": true}` (no token needed) |
| `GET /status` | encoder, vectors, index, folders |
| `POST /search` `{query, kinds?, folders?, limit?, code?}` | `{hits: [{rank, path, kind, where, score, strong, segment, segment_id, loc, loc_end, focus, excerpt, modified, size, info, …}]}`; also `GET /search?q=…&limit=…` |
| `GET /segments/{segment_id}?code=false` | `{text}`, the hit's indexed text (404: a picture or a frame) |
| `POST /similar` `{path, limit?, kinds?, folders?}` | like `/search` (501 when the helper hasn't the `similar` op) |
| `POST /context` `{query, limit=5, max_chars=6000, kinds?, folders?, code?}` | `{context, sources, other_matches}`: the top hits' texts, each as `[n] path (where)` then the text |
| `GET /preview?path=…&kind=pdf\|video\|image&loc=…&pixels=1024` | a JPEG of a PDF page, a video frame (at `loc` seconds) or a picture; only files in the searched folders |
| `GET /openapi.json` | the OpenAPI 3.1 spec (no token needed) |

Security: binds `127.0.0.1` unless `--host` (then it warns, and the localhost-only `Host` check is off); with
`--token` or `$DIGUP_API_TOKEN` every other endpoint needs `Authorization: Bearer <token>`; CORS is off unless
`--cors ORIGIN`.

```sh
curl -s localhost:8484/search -d '{"query": "the lease agreement", "kinds": ["pdf"], "limit": 3}'
curl -s 'localhost:8484/search?q=code:%20retry%20with%20backoff&limit=3'
curl -s localhost:8484/segments/31
curl -s localhost:8484/context -d '{"query": "when is the rent due?", "limit": 4, "max_chars": 4000}'
curl -s -o page.jpg 'localhost:8484/preview?path=/home/you/Documents/lease.pdf&loc=2'
curl -s -H "Authorization: Bearer $DIGUP_API_TOKEN" localhost:8484/status    # with a token
```

Python (standard library only):

```python
import json, urllib.request

def digup(endpoint, body):
    request = urllib.request.Request(f"http://127.0.0.1:8484{endpoint}", json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
    with urllib.request.urlopen(request) as response:
        return json.load(response)

for hit in digup("/search", {"query": "a photo of a zebra", "limit": 5})["hits"]:
    print(hit["path"], hit["where"], round(hit["score"], 2))
```

**RAG in 10 lines** (any OpenAI-compatible chat API, here a local one):

```python
import json, urllib.request

def post(url, body, headers={}):
    request = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json", **headers})
    return json.load(urllib.request.urlopen(request))

question = "When is the rent due, and how much is the deposit?"
found = post("http://127.0.0.1:8484/context", {"query": question, "limit": 5, "max_chars": 6000})
prompt = f"Answer from these excerpts of my files, citing them as [n].\n\n{found['context']}\n\nQuestion: {question}"
answer = post("http://127.0.0.1:11434/v1/chat/completions",          # e.g. Ollama
              {"model": "llama3.2", "messages": [{"role": "user", "content": prompt}]})
print(answer["choices"][0]["message"]["content"])
```

**Open WebUI.** Add it as a tool server: *Settings → Admin → Tool Servers* → add an OpenAPI
connection with URL `http://127.0.0.1:8484` and spec path `openapi.json` (auth: Bearer with your token, if you set
one), then *Verify*. The tools appear as `search_files`, `read_segment`, `get_context`, `find_similar`,
`index_status`. Notes:
- Admin tool servers are called by Open WebUI's backend. If it runs in Docker, `127.0.0.1` is the container: run the
  container with `--network=host`, or start `digup-http --host <the docker bridge address> --token …`.
- A tool server added under the *user* settings is called from the browser: start `digup-http` with
  `--cors http://localhost:3000` (your Open WebUI origin).
- Open WebUI can also use the MCP server over HTTP (`digup-mcp --http`, URL `http://127.0.0.1:8765/mcp`).

## Development

```sh
uv run --project integrations pytest -q integrations/tests      # unit tests against a fake helper
```

The end-to-end test runs both servers against a real helper and a **copy** of an index of the DigUp testbed; see
`tests/test_e2e_real.py` for the environment it needs. Files: `src/digup_client.py` (the helper process and its
JSON-lines protocol), `src/digup_tools.py` (what both servers do), `src/digup_mcp.py`, `src/digup_http.py`.

The helper's protocol is documented in `Sources/digup/SearchService.swift`. The integrations send `folders` to
`search` and `similar` when given and also filter by folder themselves, so an older helper that ignores the field
gives the same answer.
