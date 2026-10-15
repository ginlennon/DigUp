# DigUp on Linux — user guide

DigUp finds files by what's in them: the photo of a dog on a beach, the minute of a recording where someone talks
about a delayed flight, the PDF page with the clause about the deposit, the screenshot with the error code. You
describe it in your own words and it digs it up, on your machine, without sending anything anywhere.

This guide is for the Linux port (tested on Ubuntu 24.04 with GNOME). Setup is in the [README](../README.md#set-it-up).

## The basics

| Key (in the panel) | What it does |
|---|---|
| **Ctrl+Alt+Space** | opens the search panel from anywhere, and closes it again (a GNOME shortcut; change it in Settings → Keyboard) |
| ↓ ↑ | moves through the results |
| ↩ | opens the result: PDFs at the page with your word found, videos and recordings at the moment, the rest in its default app |
| Ctrl+↩ | shows the file in Files, selected |
| Tab, Ctrl+F | goes to the filter under the search field ([exact words](#filter-by-exact-words)); Tab goes back |
| Ctrl+O | chooses the folders to search in ([folders](#search-in-some-folders)) |
| Esc | closes the folder list, clears the filter if it has something, else closes the panel |

The tray icon shows what DigUp is doing ("Indexing 120 of 482", "Transcribing 3 of 12" when transcripts are on,
"Up to date · 482 files") and has Pause/Resume, Index Now, Settings… and Quit.

**Moving and resizing the panel.** Drag it by the grip strip along its top (the small bar), its magnifier or funnel
icon, the space around the fields or the footer; drag its edges to make it wider or, with results showing, taller. It keeps that size (Settings → Search
panel → Reset Size goes back), but on Wayland GNOME decides where a window opens, so it may put the panel back in
the middle the next time it opens.

**How to ask.** Describe what you'd see or hear, as you'd tell a friend: "a receipt where the card was declined",
"the bit where they talk about the storm". Type exact things exactly: an invoice number, an error code, a name.
DigUp does both at once: the meaning of your words, and the words themselves (in file names, document text, and
the text inside screenshots and scans). Results that are clearly weaker are folded under "N weaker matches".
Rare words count more than common ones ("die", "für", "the", "la"), in any language. A code is matched as written:
*"RE-2041"* finds RE-2041 (or "RE 2041" in a transcript), not INV-2041. Say what kind of file you mean in English,
German, French, Spanish, Italian or Portuguese and those come first: *"Fotos vom Strand"*, *"Bildschirmfoto
Zahlung abgelehnt"*, *"capture d'écran paiement refusé"*, *"Sprachnachricht wegen der Rechnung"*, *"grabación de
la llamada por la factura"*.

## 20 ways to use it

The queries below were tried on DigUp's own test files (`scripts/linux/make-testbed.sh`), so you can try them
there before pointing DigUp at your own folders.

### Finding things you half remember

1. **The screenshot with that error.** You took a screenshot of an error weeks ago and only remember roughly what it
   said. Search *"payment declined error"* or *"python package not installed"*: DigUp matches what the screenshot
   shows and the words in it. → the payment-error screenshot, first.
2. **An exact code inside a picture.** Invoice numbers, ticket IDs, error codes, licence plates, booking references
   are read from screenshots and scanned PDFs (OCR) and matched as written. Search *"INV-2041"* or *"K7Q2LM"*.
3. **A photo, by what's in it.** No tags or albums needed: *"yellow flower"*, *"bird of prey"*, *"planet earth from
   space"*, *"a dog on the beach"*. Works on HEIC, AVIF, WebP, JPEG, PNG and more.
4. **The page in a long PDF.** *"sourdough bread recipe"* → the yearly notes PDF, *p. 3*, and ↩ opens Evince (or Okular) at that page with the word highlighted. Long PDFs are read page by page,
   the first 30 pages right away and the rest after everything else is in.
5. **The moment in a recording.** Podcasts, voice memos, meeting recordings: *"flight to Tokyo delayed by a
   storm"* → the recording, and ↩ starts it at that moment in VLC. (DigUp listens in overlapping 30-second windows.)
6. **The scene in a video.** *"zebra"* → the clip, *at 0:06*. DigUp looks at a frame every few seconds and one per
   shot, and listens to the soundtrack too.
7. **Notes, whatever the format.** txt, md, rtf, docx, odt and html are all read as text. *"a recipe with chocolate
   and strawberries"* finds the cake recipe whether it's a note, a PDF page or a spoken recording.
20. **What was said in a recording.** Turn on Settings → Indexing → "Transcribe recordings" and DigUp also writes
    down what's said in recordings and videos (with Whisper, on this computer), so the exact words are found too: a
    name, a place, a number someone said in a meeting. On the European test files (`synthetic/lang/eu`),
    *"Brunner"* finds the voice memo where a carpenter asks Frau Brunner to pay, *"Villeurbanne"* the French one
    about a flat viewing, and *"Uster"* the moment 25 seconds in where a delivery there is mentioned. The result shows
    the line that was said, your word in bold, next to the moment ("Said at 0:25"), and ↩ opens it there. RAG
    clients get the words too: `/context` and the MCP server's `read_segment` return what was said in that stretch.
    It's off by default: transcripts come after everything else is indexed and take about 7 minutes per hour of
    recordings on a Radeon 860M, and their model is a 575 MB download (without the GPU a smaller one, 489 MB, less
    exact). Songs (artist and album tags) are skipped unless "Also transcribe music" is on too. Names and words come
    out more reliably than codes ("RE-2041" may be heard as "RE 2041", or not at all). From the terminal:
    `digup index ~/Recordings --transcripts gpu` (`off` takes them out again; without the option they stay as they
    are), and `digup transcribe memo.m4a` prints what Whisper hears.

### Beyond one language

8. **Search in one language, find another.** The model knows 100+ languages: an English query can find a Bengali or
   Arabic file and the other way around. *"বৃষ্টি"* (rain) finds the Bengali weather recording; *"rainy weather in
   Riyadh"* finds the Arabic one, and *"the clause about pets in the lease"* finds page 2 of a rental contract
   written in Bengali. (Exact-word matching inside screenshots needs the OCR language installed:
   `sudo apt install tesseract-ocr-ara tesseract-ocr-ben`.)

### Work and code

9. **Code by what it does.** Add your code folders in Settings → Code search and start the query with `code:`:
   *"code: plot how many examples each class has"* finds the notebook cell; *"code: retry a failed call with
   backoff"* finds the function whatever it's called. ↩ opens it at the line in the editor chosen under Settings →
   Opening → "Open code in" (VS Code, VSCodium, Cursor, Zed, Sublime Text, Geany, JetBrains IDEs, Kate, Text Editor,
   or the file's default app); the footer says where ("Open at line 12 in VS Code"). Code is indexed again a minute
   after you stop changing it. From the terminal:
   `digup index --code ~/projects && digup search "code: retry with backoff"`.
10. **Your coding assistant asks DigUp.** The MCP server in [`integrations/`](../integrations/README.md) lets Claude
    Code, Cursor, VS Code or Zed search your files: "find the design doc that mentions the rate limiter", "which
    screenshot shows the staging error?", then read the matching passage (`read_segment`). For Claude Code:
    `claude mcp add --scope user digup -- uv run --project <checkout>/integrations digup-mcp`.
11. **Your own files as a RAG source.** `uv run --project integrations digup-http` starts a local API on
    `127.0.0.1:8484`; `POST /context {"query": "…", "limit": 5}` returns the best passages with their file and page,
    ready for a local model's prompt. Open WebUI and other tools can import `/openapi.json` as a tool server.

### Scripts and the terminal

12. **Search from the terminal.** `digup search "zebra" -n 5` prints results with where they matched;
    `--kind pdf,doc` narrows the kinds.
13. **Open the best match in one line.**
    ```sh
    digup search "train timetable" --json | jq -r '.[0].path' | xargs -d '\n' xdg-open
    ```
14. **A quick report of everything about a topic.**
    ```sh
    digup search "quarterly revenue" -n 20 --json | jq -r '.[] | "\(.kind)\t\(.loc // "")\t\(.path)"'
    ```
    pastes into a spreadsheet as a list of every recording, page and note on it.

19. **More like this.** In the panel, Ctrl+L on a result (or its More Like This button) shows the photos, frames and
    pages most like it: the other shots of the same scene, the other copy of a document, the scan of a printout. A
    "Like IMG_2041.jpg" chip stands for it; Esc goes back to your search. From the terminal:
    `digup similar ~/Pictures/IMG_2041.jpg`. A file already in the index needs no model at all; any other file is
    read and embedded on the spot.

### Keeping it out of your way

15. **Only some folders.** Settings → Folders: add or remove folders, skip subfolders (an old sync conflict, a
    downloads dump), or leave out file types (`heic, txt`). Search follows at once. To search *inside* some folders
    for a moment, choose them in the panel ([below](#search-in-some-folders)). From the terminal:
    `digup search "beach sunset" --in ~/Documents/Trips` (repeat `--in` for several).
16. **Pause it.** Presenting, gaming, on a train? Tray → Pause Indexing. Search keeps working; new files wait until
    you resume. It stays paused across restarts.
17. **CPU or GPU.** Settings → Indexing → "Use the GPU". On an AMD or Intel GPU (Vulkan) indexing is about 2.7× faster
    than on the CPU; turn it off on battery or if your graphics driver misbehaves. Searching is fast either way. If
    the graphics driver crashes twice within ten minutes, DigUp switches to the CPU by itself until it restarts (the
    tray says "GPU problem — indexing on the CPU"; Settings has "Try the GPU Again"). A file whose reading runs away
    is skipped after its helper is restarted; if that keeps happening, indexing pauses and says which file.
18. **Turn it off completely.** Tray → Quit stops DigUp and its helpers. To keep it off: Settings → Turn off → "Turn
    DigUp Off" quits it and stops it starting at login; the shortcut stays (pressing it starts DigUp again) unless you
    also tick "Also remove the shortcut", which removes only DigUp's own GNOME shortcut. From a script or another
    shortcut: `digup-shell --quit`, `--pause`, `--resume`, `--index-now`, `--settings`, `--show`, `--hide`,
    `--toggle` (without DigUp running, `--quit` just says so and `--pause`/`--resume` apply at its next start). To
    remove its data: `rm -rf ~/.local/share/digup ~/.config/com.abdurrahim.DigUp`.

## Search in some folders

The folder button at the start of the filter's row (or **Ctrl+O**) lists the folders DigUp searches; ▸ (or →) shows
the folders right inside one. Check one or several: each becomes a chip in the filter's row (*in Documents*,
*in Trips*), and the search covers all of them together, as `digup search --in ~/Documents --in ~/Trips` does.

| Key (folder list) | What it does |
|---|---|
| ↓ ↑ | moves through the folders |
| → ← | shows or hides the folders inside one (on a folder inside, ← goes back to it) |
| Space | checks or unchecks the folder (one inside a checked folder is searched already) |
| ↩, Esc, Tab | done: back to the search field |

You can also type the folder at the start of the query: *"in:Documents invoice"*, *"in:~/Pictures/2026 beach"*,
*"in:\"Big Folder\" notes"*. A chosen folder's name works, and so does the name of a folder right inside one
(*"in:Trips"*); it makes the same chip. With code: `in:billing-service code: retry`. A chip goes with its ×, or the
last one with Backspace at the start of the search field or the filter. Like the filter, the chips are for one
look: they're gone when the panel opens again. Your code folders are listed apart: they're searched by queries that
start with `code:`.

## Filter by exact words

The search field goes by meaning, and its word matching is tuned for English: a German plural, a word inside a
compound or a street number can slip through. When you know the exact words, put them in the **filter** under the
search field (Tab or Ctrl+F gets you there). The filter decides which files appear; the search field, if you type
anything there, ranks them. Each result points at the page or the moment where the filter's words are, with the
words in bold. On the European test files (`synthetic/lang/eu`):

1. **A word inside a compound.** Filter *`*kaution*`* → `Unterlagen Wohnung.pdf` at *p. 2*: "Die **Mietkaution** …
   auf ein **Mietkautionskonto**". `Kaution` alone in the search field doesn't find it, as the word only appears
   inside longer ones.
2. **Singular or plural.** Filter *`Versichertenkarte*`* (a word starting with it) → `Arzttermin.odt`, where it says
   "**Versichertenkarte** und die Liste der Medikamente mitbringen". It finds "Versichertenkarten" just as well.
3. **This but not that.** Filter *`Rechnung*`* finds the carpenter's invoice in `Unterlagen Wohnung.pdf` (p. 1) and,
   with transcripts on, the voice memo where he asks Frau Brunner to pay. *`Rechnung* NOT Brunner`* keeps only the
   PDF; at home that's *`Rechnung* NOT Mahnung`*: the invoices without the reminders.
4. **A phrase, and a query to rank.** Filter *`"Bahnhofstrasse 12"`* (the words side by side, in this order) finds the
   PDF, at *p. 1*, the invoice's address. Type *Mietvertrag* in the search field as well, and the same file points at
   *p. 2*, the rental contract with that address. Without a query the filter's own best match counts; with one, the
   page that fits the query best among those with the filter's words.
5. **A code on a screenshot.** Filter *`ZK-4471`* → the German screenshot with that error code, shown as the
   picture, the code in bold below it.

How it's written (the **?** at the end of the filter shows the same table):

| Written | Means |
|---|---|
| `Rechnung Uster` | both words (AND is implied) |
| `A OR B`, `NOT A`, `-A`, `A AND B` | either, without, both; operators only in capitals, so "or" and "und" stay words |
| `( … )` | grouping: `Rechnung* AND (Uster OR Winterthur)`; NOT binds before AND, AND before OR |
| `"Bahnhofstrasse 12"` | these words side by side |
| `Rechnung*`, `*karte`, `*kaution*` | a word starting with it, ending with it, with it inside (3 letters or more) |
| `RE-2041`, `2'380.50` | a code or a number as written |

Case, accents and ß/ss don't matter (`Bahnhofstraße` finds `Bahnhofstrasse`). The filter looks at file and folder
names, document and PDF text, the text in screenshots and scans, transcripts (when they're on) and, with `code:`,
your code. A filter it can't read, such as one with an unclosed quote, is read as plain words and the panel says so
under it. Esc clears the filter, and it's gone when the panel opens again. It works with `in:` folders and with
Ctrl+L (only the similar files with the filter's words). From the terminal: `digup search "Mietvertrag" --filter
'"Bahnhofstrasse 12"'`, `digup search --filter '*kaution*'`; the HTTP API and the MCP server take `filter` too.

## Good to know

- **What it reads:** only the folders you choose. It skips hidden folders, Trash, caches, `~/snap`, Flatpak data,
  network and FUSE mounts reached from inside a chosen folder, code projects (except their screenshots, unless code
  search is on), datasets, keys and password files. It never changes, moves or uploads your files.
- **How long:** the first pass is the slow part (on a Radeon 860M: about 10 minutes for ~500 everyday files); after
  that a new file is searchable a few seconds after it lands.
- **Where things live:** index `~/.local/share/digup/index`, model `~/.local/share/digup/Models` (865 MB; the
  transcripts' model, once they're on, in its `whisper` folder),
  settings `~/.config/com.abdurrahim.DigUp/settings.json`, logs `~/.local/share/com.abdurrahim.DigUp/logs`.
- **Health check:** Settings → About → Check DigUp, or `digup doctor`, checks the model, the GPU, ffmpeg, tesseract, transcripts and the index, and embeds two
  reference sentences to prove the vectors are right (`--deep` also checks the model files' SHA-256).
- **Private:** DigUp goes online only to download the model once (and the transcripts' model, if you turn them on). No account, no telemetry. The HTTP API and the
  MCP server listen on this machine only.
