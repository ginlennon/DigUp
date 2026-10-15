# Folders: choose where to search, add a folder on the spot (plan, 2026-10-15)

**Stage S1 in progress; S2–S5 PLAN ONLY — not implemented.**

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
### S2 — Add a folder: shell `--add-folder DIR`, subtree dialog with counts, priority indexing, code-index for repos,
Files script "DigUp: Add this folder", CLI path; Settings shows it like any folder.
### S3 — Tools: `--scope` on MCP and HTTP; `add_folder` behind `--allow-add-folders` via the shell, notification + Undo.
### S4 — Docs: user guide cases (choose folders, add a repo, a coding app pinned to a repo), integrations README.
### S5 — `digup-ask` with an OpenAI-compatible backend.
