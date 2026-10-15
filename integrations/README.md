# DigUp integrations: MCP server, local HTTP API, digup-ask

DigUp's search for other programs. DigUp indexes your own files on your computer (documents, PDFs page by page,
photos, screenshots with their text, audio, video, and code folders) with EmbeddingGemma 2 on llama.cpp. These two
servers let other apps search that index, and a small chat program uses it:

- **`digup-mcp`**: an [MCP](https://modelcontextprotocol.io) server for coding agents and chat apps (Claude Code,
  Cursor, VS Code Copilot, Zed…). They can search your files by meaning and read the passage that matched.
- **`digup-http`**: a small JSON API on `127.0.0.1` for RAG apps, scripts and tool servers (Open WebUI…), with an
  OpenAPI 3.1 spec and a `/context` endpoint that returns ready-made, cited passages for a prompt.
- **`digup-ask`**: ask one folder questions in the terminal. A chat model you choose (a local llama.cpp server, or
  any OpenAI-compatible service) searches the folder with DigUp and answers, citing the files
  ([below](#digup-ask-ask-a-folder-questions)).

All three run DigUp's helper (`digup search-service`) and keep it open, so a search takes tens of milliseconds once the
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
default), `--timeout S`, `--no-settings`; `--scope DIR`, `--allow-add-folders` and `--max-files N`
([below](#pinned-to-a-folder-and-adding-folders)).

## MCP server

Tools (read-only, but for `add_folder`):

| Tool | What it does |
|---|---|
| `search_files(query, filter?, kinds?, folders?, limit=10)` | Search by meaning and words. `kinds`: screenshot, image, pdf, doc, audio, video. Returns absolute paths, where in the file (page, time, lines), a score, an excerpt and a segment number. |
| `read_segment(segment_id, code=false, max_chars=8000)` | The indexed text of a hit: the document's chunk, the PDF page's text, a screenshot's text, a code stretch. |
| `search_code(query, filter?, limit=10)` | The code index (what a DigUp search starting with `code:` does). |
| `find_similar(path, limit=10, kinds?, folders?)` | Files like a given file; needs a helper with the `similar` op, says so otherwise. |
| `index_status(doctor=false)` | Encoder state, vectors, index, folders (and `digup doctor --json` when the helper has it); with `--scope`, whether the scope is indexed. |
| `add_folder(path)` | Only with `--allow-add-folders`: the DigUp app adds the folder ([below](#pinned-to-a-folder-and-adding-folders)). Not read-only. |

`filter` is the panel's keyword filter: exact words the file must have, `Rechnung* AND (Uster OR Winterthur) NOT
Mahnung`, `"Bahnhofstrasse 12"`, `*kaution*` (inside a word), `RE-2041`. Only those files come back, ranked by
`query`, each hit at the page, moment or lines with the words (marked «like this» in its excerpt); `query` may be
empty then. Words are ANDed; `AND`, `OR`, `NOT` / `-word` only in capitals; case, accents and ß/ss don't matter. A
filter that can't be parsed (an unclosed quote) is read as plain words, and the result says so. It needs a helper
from the same release (an older one ignores the filter).

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

## Pinned to a folder, and adding folders

**`--scope DIR`** (repeatable; or `$DIGUP_SCOPE`, `:`-separated) pins either server to DIR: absolute, `~/…`, or
relative to where the server was started. Every search, `/context` and similar-files request stays inside it. A
caller's `folders` can narrow it, never widen it (a folder wholly outside is refused). Results outside never come
back; `read_segment` reads only segments of this server's own results inside the scope (a segment number says nothing
of its file, so one from elsewhere is refused: search first), and `find_similar` and `/preview` refuse a file outside.
`index_status` (`GET /status`) says whether the scope is indexed: fully, partly (being indexed, with how far, or only
some folders in it), or not at all. A scope DigUp doesn't index gets a clear answer ("~/git/foo isn't indexed; start
the server with --allow-add-folders or add it in DigUp"). A scope that is a code folder only is searched with
`search_code` (`code: true` over HTTP); `search_files` there says so.

A coding app pinned to the repo it's open in (Claude Code starts MCP servers in the project's folder, and
`uv run --project` keeps that folder):

```sh
cd ~/git/my-app
claude mcp add digup -- uv run --project ~/DigUp-Linux/integrations digup-mcp --scope .
# and let it add the repo when DigUp doesn't index it yet:
claude mcp add digup -- uv run --project ~/DigUp-Linux/integrations digup-mcp --scope . --allow-add-folders
```

**`--allow-add-folders`** (off unless given) adds the `add_folder(path)` tool and `POST /folders {"path": …}`, and
with `--scope` an unindexed scope is added on its first use. DigUp's desktop app owns the settings, so the server asks
the running app over the session bus (`com.abdurrahim.DigUp.Tools`, `src/digup_app.py`; the app's side is
`shell/src-tauri/src/tools.rs`). The app checks, and adds only:

- a folder inside your home folder: not the home folder itself, not a hidden folder or one in it, not one you left
  out in Settings, nor anything the add window refuses (the whole computer, system folders);
- with at most `--max-files N` files (default 20000), counted before anything starts (hidden folders,
  `node_modules`, `venv` and the like aren't counted); a bigger one is refused, with a pointer to DigUp's own add
  window, which shows the counts and lets you leave subfolders out;
- `build`, `dist`, `target` and caches inside it are left out, as the add window starts them; a git repo goes into
  the code index.

The app shows a notification, "claude-code added ~/git/my-app to DigUp", with **Undo**, which takes it out again (its
rows leave the index with the next sync, as when it's taken out in Settings). The tool returns at once, saying how to
follow along: while the folder is indexed, searches return the results so far, flagged (`Partial: …` for MCP,
`"partial": true` with `indexing: {done, total}` over HTTP), and `index_status` says how far it is. Without the app
running there's no one to ask: the tool says so and adds nothing. The same request from a script:
`digup-shell --add-folder DIR --from-tool NAME --yes [--max-files N]`.

**Why it's safe enough.** This lets a model widen what DigUp indexes, and everything it indexes the model can then
read. So: it's off unless the person starting the server says `--allow-add-folders`; a pinned server only adds inside
its scope; the app, not the tool, applies the rules (home folder only, no hidden or skipped folders, the cap); each add
is visible (the notification names the tool and the folder) and undone with one click. Nothing new listens on the
network: the request goes over the session bus, which only your own programs reach (a sandboxed Flatpak or a strictly
confined Snap can't call a name it wasn't given), and any program of yours could already change DigUp's settings file. Over HTTP, `POST /folders` is
the one request that changes something, so it takes a JSON body only and no web page from another origin than
`--cors`'s (a page can't send it), keeps the token rule, and `--allow-add-folders` doesn't go with `--host`.

## HTTP API

```sh
uv run --project integrations digup-http [--port 8484] [--token SECRET] [--root DIR]… [--code-root DIR]…
```

| Endpoint | |
|---|---|
| `GET /health` | `{"ok": true}` (no token needed) |
| `GET /status` | encoder, vectors, index, folders |
| `POST /search` `{query, filter?, kinds?, folders?, limit?, code?}` | `{hits: [{rank, path, kind, where, score, strong, segment, segment_id, loc, loc_end, focus, excerpt, modified, size, info, …}], filter?, filter_note?}`; also `GET /search?q=…&filter=…&limit=…` |
| `GET /segments/{segment_id}?code=false` | `{text}`, the hit's indexed text (404: a picture or a frame) |
| `POST /similar` `{path, limit?, kinds?, folders?}` | like `/search` (501 when the helper hasn't the `similar` op) |
| `POST /context` `{query, filter?, limit=5, max_chars=6000, kinds?, folders?, code?}` | `{context, sources, other_matches}`: the top hits' texts, each as `[n] path (where)` then the text |
| `GET /preview?path=…&kind=pdf\|video\|image&loc=…&pixels=1024` | a JPEG of a PDF page, a video frame (at `loc` seconds) or a picture; only files in the searched folders |
| `GET /openapi.json` | the OpenAPI 3.1 spec (no token needed) |
| `POST /folders` `{path}` | only with `--allow-add-folders`: the DigUp app adds the folder ([above](#pinned-to-a-folder-and-adding-folders)); 403 with why when it doesn't, 503 when the app isn't running |

With `--scope`, a search outside the scope is 403 and a scope that isn't indexed 409; hits while the scope is still
being indexed come with `"partial": true`.

Security: binds `127.0.0.1` unless `--host` (then it warns, and the localhost-only `Host` check is off); with
`--token` or `$DIGUP_API_TOKEN` every other endpoint needs `Authorization: Bearer <token>`; CORS is off unless
`--cors ORIGIN`.

```sh
curl -s localhost:8484/search -d '{"query": "the lease agreement", "kinds": ["pdf"], "limit": 3}'
curl -s 'localhost:8484/search?q=code:%20retry%20with%20backoff&limit=3'
curl -s 'localhost:8484/search?q=&filter=*kaution*'              # the filter alone: files with "…kaution…"
curl -s localhost:8484/search -d '{"query": "invoice from the carpenter", "filter": "Rechnung* NOT Mahnung"}'
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

## digup-ask: ask a folder questions

```sh
uv run --project integrations digup-ask ~/Documents/Wohnung "Wie hoch ist die Mietkaution?"
uv run --project integrations digup-ask ~/git/my-app            # no question: a chat about the folder
cd ~/git/my-app && uv run --project ~/DigUp-Linux/integrations digup-ask "how is a failed call retried?"
```

**As a plain command.** Install the three commands on your PATH once (into `~/.local/bin`, following the checkout,
so a `git pull` updates them):

```sh
uv tool install --python 3.13 --editable integrations      # digup-ask, digup-mcp, digup-http
digup-ask ~/Documents/Wohnung "Wie hoch ist die Mietkaution?"
```

`uv tool uninstall digup-integrations` takes them away again.

The first word is the folder when it is one; otherwise it's the current folder, and every word is the question.
DigUp is pinned to the folder as `--scope` pins the servers ([above](#pinned-to-a-folder-and-adding-folders)): the
model searches and reads nothing outside it. A folder DigUp doesn't index yet is added when you say yes (`--yes`:
without asking), by the running desktop app with its notification and Undo, as `add_folder` does; then digup-ask
waits while it's read (up to `--wait` seconds, 120 by default; Ctrl+C asks right away, with what's read so far).

One question as arguments: one answer, and it exits. No question: a chat, with line editing and the questions of
earlier chats (↑; kept in `~/.local/state/digup/ask_history`, the answers never), `/sources` (the files of the last
answer, and the other matches DigUp found), `/clear` (start over), Ctrl+C to stop an answer, Ctrl+D to end. The
answer streams as it's written, the searches the model makes show dimmed (`-q` hides them), and the files it came
from follow, with the page, time or lines:

```
$ digup-ask ~/Documents/Wohnung "Wie hoch ist die Mietkaution, und auf wann kann ich kündigen?"
  search_files "Mietkaution Kündigung"
  read_match [1] Unterlagen Wohnung.pdf · page 2
Die Mietkaution beträgt drei Monatsmieten [1]. Die Kündigungsfrist beträgt drei Monate, wobei auf Ende März, Juni
oder September gekündigt werden kann [1].

Sources:
  [1] Unterlagen Wohnung.pdf · page 2
```

**The model** is any OpenAI-compatible chat-completions endpoint:

| | |
|---|---|
| `--base-url URL`, `$DIGUP_ASK_BASE_URL` | the API, ending in `/v1` (default `http://127.0.0.1:8080/v1`, a local llama.cpp server) |
| `--model NAME`, `$DIGUP_ASK_MODEL` | the model (default: the endpoint's only one, as a llama.cpp server has) |
| `$DIGUP_ASK_API_KEY`, else `$OPENAI_API_KEY` | the key, sent as a bearer token; never a flag, never shown, never written anywhere (a local server needs none) |

It gets DigUp's search as tools (`search_files` and `find_similar` for documents, PDFs, pictures, recordings;
`search_code` for a code folder; `read_match` to read a match's text) and calls them as it needs, at most
`--max-rounds` rounds per question (8); then it's asked to answer with what it has. It's told to answer only from
what the tools return, to say when nothing relevant was found, to cite the matches as [n], and to answer in the
language of the question. An answer that cites nothing lists what was read for it instead ("Read for this answer
(none cited)"). With `--no-tools`, or an endpoint that doesn't take tools (tried once per chat), DigUp's top matches
for the question go into the prompt instead: one search, then the answer, which is quicker but can't search again
with other words. Long chats are kept to about 16 000 characters: the older search results are shortened first,
then the oldest questions go.

**Defaults in a file**, so the command needs no flags: `~/.config/digup/ask.conf`, `key = value` lines (`#` for
comments); a flag or a `DIGUP_ASK_*` variable goes before it. The key is never read from it.

```ini
base-url = http://127.0.0.1:8080/v1
# model = …                      (only when the endpoint has several)
# Started when nothing answers at base-url (on this computer only); it keeps running for the next question:
server = ~/llama.cpp/build/bin/llama-server -m ~/models/<model>.gguf --jinja -ngl 99 -c 8192 --host 127.0.0.1 --port 8080
```

With `server` set (or `--server COMMAND`, `$DIGUP_ASK_SERVER`), the first question starts the model server when
it isn't running (its output goes to `~/.local/state/digup/ask-server.log`; `~` works in its words), waits until
it answers (up to 5 minutes while it loads the model), and leaves it running, so the next question is quick.
`digup-ask --stop-server` stops the one it started; a server you started yourself is never stopped.

Other flags: `--no-stream`, `--temperature T`, `--request-timeout S`, `--max-files N` (for adding, 20000), `--stats`
(after each answer: requests, searches, the first token's time, tokens per second), and the helper flags above
(`--index`, `--root`, `--code-root`, …). Only the standard library talks to the endpoint, so digup-ask needs nothing
beyond what the servers need.

A local llama.cpp server with a model that calls tools (an instruct GGUF of Gemma, Qwen or the like; `--jinja`
turns tool calling on):

```sh
llama-server -m <model>.gguf --jinja -ngl 99 -c 8192 --port 8080
uv run --project integrations digup-ask ~/Documents/Wohnung
```

8192 tokens of context are enough. On a laptop's integrated GPU, a mixture-of-experts model with 4B active
parameters wrote about 20 tokens/s and read the prompt at about 100 tokens/s: an answer with one search and one
match read took 25–45 s, most of it the model thinking before each step (`thinking…`); `--no-tools` took about
20 s.

A hosted OpenAI-compatible service (OpenRouter, a company gateway, OpenAI itself):

```sh
export DIGUP_ASK_BASE_URL=https://<the service>/v1 DIGUP_ASK_MODEL=<a model with tool calling>
export DIGUP_ASK_API_KEY=…            # better from your password manager than typed into the shell's history
uv run --project integrations digup-ask ~/git/my-app "how are invoices numbered?"
```

**Privacy.** With a local server nothing leaves your computer. With a hosted one, the passages DigUp finds in the
folder, their file names and your questions go to that service (digup-ask says so when it starts). Point it only at
folders you'd send there.

## Development

```sh
uv run --project integrations pytest -q integrations/tests      # unit tests against a fake helper
```

The end-to-end test runs both servers against a real helper and a **copy** of an index of the DigUp testbed; see
`tests/test_e2e_real.py` for the environment it needs. Files: `src/digup_client.py` (the helper process and its
JSON-lines protocol), `src/digup_tools.py` (what both servers do, the scope), `src/digup_app.py` (the desktop app
over the session bus), `src/digup_mcp.py`, `src/digup_http.py`, `src/digup_ask.py` (only the standard library talks
to the model: urllib and server-sent events; its tests use a fake OpenAI-compatible server, `tests/fake_openai.py`). The tests never touch your session bus: they point
at one that isn't there, or start their own `dbus-daemon` with a stand-in for the app (`tests/fake_app.py`).

The helper's protocol is documented in `Sources/digup/SearchService.swift`. The integrations send `folders` to
`search` and `similar` when given and also filter by folder themselves, so an older helper that ignores the field
gives the same answer.
