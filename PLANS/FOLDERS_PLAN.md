# Folders: choose where to search, add a folder on the spot (plan, 2026-10-15)

**All stages done (2026-10-15, notes under them).**

---

# Part A — Conceptual design

## A1. Why
Two things people want while they search:
- **Narrow the search to some folders without typing.** `in:Documents` works but has to be typed and takes one folder.
- **Search a folder that isn't indexed yet.** A new git repo, a folder someone sent, a USB stick copied over: today it
  means Settings → Folders → Add, wait, then search. The wish is one step: "index this now, I want to search in it",
  with a choice of which subtrees, and it stays in the search space from then on.

The same wish comes from tools: a coding app or a local RAG/chat program that wants to talk about one repo should be
able to pin DigUp to that folder (and, if allowed, have it indexed).

## A2. What the person sees
```
┌──────────────────────────────────────────────────────────┐
│ ═══                                                      │  grip strip: drag the panel here
│ 🔍 invoice from the carpenter                            │
├──────────────────────────────────────────────────────────┤
│ 📁 [in Documents ×] [in Trips ×]  ⧩ Rechnung*            │  folder button + chips, then the filter
└──────────────────────────────────────────────────────────┘
          ┌───────────────────────────────┐
          │ ☑ Documents                   │  folder popover (Ctrl+O): indexed folders,
          │   ☐ Trips   ☐ Taxes   ▸ …     │  two levels, expandable; checked = chip
          │ ☐ Pictures                    │
          │ ─────────────────────────────  │
          │ ＋ Add a folder…              │  → A3
          └───────────────────────────────┘
```
- Several folders can be chosen; the search covers their union (search-service already takes `folders`). `in:` typing
  keeps working and makes the same chips.
- **Moving the panel:** the field fills its row, so the icons were the only free place to grab. A slim grip strip at
  the top gives a clear place.

## A3. Add a folder on the spot
1. Pick it: the panel's "Add a folder…" (the desktop's folder dialog), Files' right-click "DigUp: Add this folder",
   or `digup-shell --add-folder DIR` / the CLI.
2. **Choose subtrees**: a checkbox tree of its subfolders with file counts and a time estimate (setup's `estimate`).
   Unchecked = skipped. Pre-unchecked: `node_modules`, `.venv`, `venv`, `target`, `build`, `dist`, `.git`, caches.
3. Indexing starts at once with this folder **first**; the panel searches inside it right away ("Indexing 40 of 300 —
   results so far"). It's **permanent** (user decision): it stays until removed in Settings → Folders.
4. A folder with `.git` goes into the **code index** (search_code, editors), with "also as documents" as an option.
5. A folder inside an indexed one: nothing to index; it just becomes the scope (and skipped subtrees can be taken in).

## A4. Tools: MCP and HTTP
- **`--scope DIR`** on `digup-mcp` and `digup-http`: every search is inside DIR (absolute or relative to where the
  tool was started). `claude mcp add digup -- digup-mcp --scope .` in a repo → that repo only.
- **`add_folder` MCP tool, off by default** (user decision): only with `--allow-add-folders`. Guards: inside the home
  folder, never the home folder itself or a hidden/system folder; a size cap (files counted first; above the cap the
  tool says so and stops); the request goes through the running desktop app (it owns the settings), which shows a
  notification with **Undo**. Without the desktop app running: refused, with a message. `--scope` + allowed adding:
  an unindexed scope is added on first use.
- HTTP gets `scope` the same way; adding over HTTP only with the same opt-in.

## A5. `digup-ask` (last, optional)
A small uv/Python chat program: `digup-ask ~/git/foo` → ensures the folder is indexed (A3), then a chat whose LLM
calls DigUp's tools pinned to that folder. **Backend: any OpenAI-compatible URL + model** (user decision) — a local
llama.cpp server, OpenRouter, others. Key from an env var, never stored by DigUp.

## A6. Risks
- An AI widening what's indexed: opt-in flag, home-only, cap, Undo, visible notification.
- A huge folder picked by mistake: counts and time estimate before anything starts; cap for tools.
- Priority indexing must not starve the rest forever: the new folder goes first once, then normal order.
- Wayland folder dialog: through the desktop portal (setup already uses it).

## A7. Success bar
- Choosing two folders in the popover gives the same results as `--in A --in B` on the CLI.
- Adding a 300-file folder: first results for it within ~30 s on the Vulkan build, without restarting anything.
- A coding app with `--scope .` never gets a result outside the repo (test).

---

# Part B — Stages

### S1 — Panel: grip strip + folder button and popover (indexed folders only), several chips, Ctrl+O.
**Done.** As sketched, with these choices:
- The grip strip is 10 px with a small centred bar; the field went from 56 to 52 px, so the panel with nothing
  searched is 94 px (was 88; panel.rs has a test that the CSS heights add up to it).
- The popover lies inside the panel window (a window can't draw outside itself): while it's open the panel takes its
  results height, and with nothing searched the preview says how the popover works.
- Two levels: the folders searched and the folders right inside them, without skipped and hidden ones. A folder
  inside a checked one shows as covered and can't be checked on its own; checking a folder drops the chips inside it.
- Code folders are listed apart, under "Code · searched with code:": search-service applies `folders` to code
  search too, and `in:` already took code folders.
- Folder chips sit in the filter's row (the "Like …" chip of Ctrl+L stays before the field). `in:` adds a chip to
  the others instead of replacing the one there was. Backspace at the start of the field or the filter takes the last
  one away.
- The chips go when the panel opens again, as the filter does. (The single `in:` chip used to stay with the last
  query; with several folders chosen by hand, a stale scope was the bigger surprise.)
- Keys: arrows, → ← to open and close, Space checks, Enter/Esc/Tab are done; Esc closes the popover before anything
  else.
### S2 — Add a folder: shell `--add-folder DIR`, subtree dialog with counts, priority indexing, code-index for repos,
Files script "DigUp: Add this folder", CLI path; Settings shows it like any folder.
**Done.** Notes and deviations:
- Entry points: the popover's "Add a folder…" (the desktop's folder dialog, as setup's), `digup-shell --add-folder
  DIR` (handed to the running DigUp like `--toggle`; a relative DIR is taken from where it was run; DigUp starts if
  it isn't running), and the Files script, installed by `integrations/desktop/install.sh` like the other two. The
  CLI path is `digup-shell --add-folder`; no new `digup` subcommand (the helper doesn't own the settings).
- The subtree dialog is a small window of its own (add.html), not a view in the panel: the panel steps away when the
  folder dialog takes the keyboard, and the Files and CLI entries have no panel open. Keys: ↑ ↓, → ← open and close,
  Space, ↩ adds, Esc cancels.
- The tree is `digup estimate`'s, one level at a time (→ counts the next level then): only folders with something
  DigUp reads are listed, so hidden folders, `node_modules`, `venv` and `__pycache__` never show (the crawler skips
  them anyway). `build`, `dist`, `target`, caches, `.tox` and `.gradle` start unchecked. Times are the first pass's,
  from the costs indexing measured here.
- Priority: `index-service --first DIR`. After its first sync every file waiting in DIR, in either index, goes
  before anything else, past the 50-new-files limit and whatever the power source; once per helper. The shell gives
  it only to the helper it starts for the add (`Launch.once`: not compared, so it doesn't restart a running helper,
  and the next launch goes without). Checked on a private index: 6 files of the folder added came first, ahead of a
  102-file backfill (without it they came at 49–65); a repo's 12 code files came before the main index's backfill.
- A repo (`.git`) goes into `codeFolders` (its unchecked subfolders into `codeSkipped`); "also as documents" adds it
  to `folders` too, which in a code project reads only its screenshots, and the window says so.
- A folder searched already (as documents, or in a code folder) only becomes the scope; the skipped folders in it are
  listed to take back in (out of `skipped`). A folder that is itself skipped is taken in by dropping the skip; one
  deeper inside a skipped folder becomes a folder of its own (FolderSelection's rule).
- Guards: not `/`, the home folder or a folder holding it, nor a system folder (`/usr`, `/etc`, `/var`, `/opt`,
  `/run` but `/run/media`…); a dev run started with `--roots` refuses too (its folders aren't the settings'). The
  counts and the time show before anything starts.
- After adding, the panel opens with the folder's chip alone and says how far its indexing is until something is
  typed ("Indexing Sent: 40 of 300"); with a query the footer adds "indexing 40 of 300, results so far". A repo opens
  with `code:` typed in. With indexing paused it's added and waits for Resume (the window says so).
### S3 — Tools: `--scope` on MCP and HTTP; `add_folder` behind `--allow-add-folders` via the shell, notification + Undo.
**Done.** Notes and deviations:
- `--scope DIR` (repeatable, or `$DIGUP_SCOPE`) on both servers, relative to where they start; matched by the path
  given and by its real path (the settings keep an added folder's real one). A caller's `folders` narrow it; one
  wholly outside is refused (403 over HTTP), not silently emptied. A scope that's partly indexed (folders inside it
  are) searches those. `read_segment` can't tell a segment's file, so a pinned server reads only segments of its own
  results inside the scope ("search first" otherwise). `similar` and `/preview` refuse a file outside.
- A scope in neither index: "~/git/foo isn't indexed; start the server with --allow-add-folders or add it in DigUp"
  (MCP: a tool error; HTTP 409). A code-only scope: `search_files` points to `search_code`, and the other way round.
  The servers read the app's settings again every 10 s while part of the scope isn't indexed, and right after an add,
  and tell their helper the new folders (`folders` op).
- The request path: a D-Bus name of the shell's own, `com.abdurrahim.DigUp.Tools` (`AddFolder(folder, tool,
  max_files)` and `Status()`, JSON answers), beside the single-instance one. The single-instance hand-over is
  one-way (the second launch exits without an answer), and a tool must hear why an add was refused. The integrations
  call it with jeepney (pure Python, a new dependency, Linux only); `digup-shell --add-folder DIR --from-tool NAME
  --yes [--max-files N]` is the same request from a script, and never starts DigUp.
- Guards (tools.rs, on top of adding.rs's): inside the home folder only (so drives aren't, unlike the add window),
  not the home folder, no hidden folder or one in it, nothing in a folder skipped in Settings (a tool mustn't undo a
  skip). The cap (20 000, `--max-files`) counts files with the crawler's never-read folders and the left-out ones
  aside, stops past the cap, and gives up after 10 s (too big). `build`, `dist`, `target`, `cache`, `caches` found
  are skipped. A folder searched already only says so. A pinned server adds only inside its scope.
- Notification: freedesktop Notify over the same zbus (Tauri's notification plugin has no buttons on Linux), with
  Undo; clicking it opens the panel searching in the folder. Undo takes back exactly what the add changed (`Change`),
  keeping later changes; the last code folder taken out turns code search off and deletes its index, as Settings
  does; the rows of a document folder go with the next sync's prune. No notification service: the add still happens,
  and the answer says Settings takes it out again.
- Partial: the shell keeps how indexing goes and the folders added that no pass has been through since
  (`Progress`); a pinned server (or one that added something) asks `Status` at most every 2 s, flags results whose
  folders are pending, and reloads its helper's index every 3 s meanwhile (and once after), so new files show.
  Over HTTP: `"partial": true`, `indexing: {folders, state, done, total}`; MCP: a "(Partial: …)" line first.
- `--allow-add-folders` refuses `--host` (both servers). `POST /folders` takes `application/json` only and no
  `Origin` but `--cors`'s, so a web page can't send it (it's the one request that changes something).
- Checked for real against a dev DigUp on private session buses (its own HOME and XDG dirs, a headless GNOME Shell
  46 as the display, a stand-in notification service to press Undo): `--scope .` in an unindexed repo added it on
  the first call (16 files, `build` left out, the notification named "claude-code"), results came after ~2 s,
  read_segment refused a segment of elsewhere; Undo emptied the code folders and deleted the code index; the guards
  (cap, hidden, home, `/`, `/usr/share`, missing, searched already, no `--yes`, app not running) all answered as
  meant; `digup-http --scope ~/Sent` showed `partial` with 8, 16, 24 of 35 while it indexed. GNOME Shell's own
  notification service took the notification (it has `actions`); its Undo button wasn't pressed by hand.
### S4 — Docs: user guide cases (choose folders, add a repo, a coding app pinned to a repo), integrations README.
**Done**, with S1–S3: the user guide's "Search in some folders", "Add a folder on the spot" (a repo among its
cases) and "A coding app pinned to a repo"; the integrations README's "Pinned to a folder, and adding folders".
### S5 — `digup-ask` with an OpenAI-compatible backend.
**Done** (`integrations/src/digup_ask.py`, entry point `digup-ask`). Notes and deviations:
- `digup-ask [FOLDER] [question…]`: the first word is the folder when it is one, else the current folder. It uses
  the DigUp class in-process with `Scope.of([folder])`, so everything `--scope` does holds. A folder in neither index
  is added on y/N (`--yes`), through the app as `add_folder` does (the tool is named "digup-ask" in the
  notification); adding stays off for the model. Then it waits while the folder is read (`--wait`, 120 s).
- No new dependency: urllib and server-sent events by hand (about 150 lines) instead of `openai` or `httpx`. The
  protocol part used is small (chat completions, tool calls, streamed deltas), and the integrations stay one set of
  dependencies, no extra.
- Tools for the model: `search_files` and `find_similar` when the folder is in the file index, `search_code` when
  it's in the code index, and `read_match(n)`. Every match shown gets a number for the chat ([1], [2] …, the same
  file and place keeps it), so the model cites [n] and reads a match by its number: no segment ids or code flags
  for it to get wrong, and nothing it wasn't shown. Paths are relative to the folder. A call outside it ("../x",
  an absolute path) is refused by the scope, and the model is told why.
- Sources: the matches the answer cites; an answer citing none lists what was read for it ("none cited"), so a
  "found nothing" answer doesn't look sourced. `/sources` adds the other matches with their scores.
- The cap: after `--max-rounds` (8) rounds the last request has `tool_choice: "none"`. Without tools (`--no-tools`,
  or a first request answered 4xx/5xx with "tool" in the error: llama.cpp without `--jinja` says "tools param
  requires --jinja flag"), the top 6 matches of the file and code index go into the prompt; the history keeps only
  questions and answers. The conversation sent is kept under 16 000 characters (old tool results cut, then the
  oldest questions dropped), for an 8k-context local model.
- The key: `$DIGUP_ASK_API_KEY` or `$OPENAI_API_KEY`, sent as a bearer header and taken out of any error text
  shown (an endpoint may echo it). A non-local endpoint is named at the start: the passages go there.
- Checked with a local llama.cpp server (`--jinja`, `-c 8192`, a Gemma MoE instruct GGUF with 4B active, Vulkan
  on a laptop's integrated GPU) against a private index of testbed copies (a German folder with a lease PDF, a
  recipe, a doctor's appointment, voice memos; a small billing repo in the code index). Tool calling worked: it searched (in
  German for a French question), read the match, answered in the question's language (German, English, French) with
  [1] citations, said "nothing found" for a question the folder can't answer (in English at first, despite the
  German question: the language rule moved to the end of the system prompt, and then it answered in German), and
  a search for `../billing-service` was refused. About 100 tokens/s reading, 20 tokens/s writing; 25–45 s per answer
  with tools, mostly thinking; 19 s with `--no-tools`.
