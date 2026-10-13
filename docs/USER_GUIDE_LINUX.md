# DigUp on Linux — user guide

DigUp finds files by what's in them: the photo of a dog on a beach, the minute of a recording where someone talks
about a delayed flight, the PDF page with the clause about the deposit, the screenshot with the error code. You
describe it in your own words and it digs it up, on your machine, without sending anything anywhere.

This guide is for the Linux port (tested on Ubuntu 24.04 with GNOME). Setup is in the [README](../README.md#set-it-up).

## The basics

| Key (in the panel) | What it does |
|---|---|
| **Ctrl+Alt+Space** | opens the search panel from anywhere (a GNOME shortcut; change it in Settings → Keyboard) |
| ↓ ↑ | moves through the results |
| ↩ | opens the result: PDFs at the page with your word found, videos and recordings at the moment, the rest in its default app |
| Ctrl+↩ | shows the file in Files, selected |
| Esc | closes the panel |

The tray icon shows what DigUp is doing ("Indexing 120 of 482", "Up to date · 482 files") and has Pause/Resume,
Index Now, Settings… and Quit.

**How to ask.** Describe what you'd see or hear, as you'd tell a friend: "a receipt where the card was declined",
"the bit where they talk about the storm". Type exact things exactly: an invoice number, an error code, a name.
DigUp does both at once: the meaning of your words, and the words themselves (in file names, document text, and
the text inside screenshots and scans). Results that are clearly weaker are folded under "N weaker matches".

## 18 ways to use it

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

### Beyond one language

8. **Search in one language, find another.** The model knows 100+ languages: an English query can find a Bengali or
   Arabic file and the other way around. *"বৃষ্টি"* (rain) finds the Bengali weather recording; *"rainy weather in
   Riyadh"* finds the Arabic one, and *"the clause about pets in the lease"* finds page 2 of a rental contract
   written in Bengali. (Exact-word matching inside screenshots needs the OCR language installed:
   `sudo apt install tesseract-ocr-ara tesseract-ocr-ben`.)

### Work and code

9. **Code by what it does.** Turn on code folders and start the query with `code:`: *"code: plot how many examples
   each class has"* finds the notebook cell; *"code: retry a failed call with backoff"* finds the function whatever
   it's called. (In the desktop app: coming. From the terminal today:
   `digup index --code ~/projects && digup search "code: retry with backoff"`.)
10. **Your coding assistant asks DigUp** (coming: `integrations/`). With the MCP server, Claude Code, Cursor, VS Code
    or Zed can search your files: "find the design doc that mentions the rate limiter", "which screenshot shows the
    staging error?", and read the matching passage.
11. **Your own files as a RAG source** (coming). The local HTTP API's `/context` endpoint returns the best passages
    for a question with their file and page, ready to paste into a prompt for a local model; it listens on
    localhost only.

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

### Keeping it out of your way

15. **Only some folders.** Settings → Folders: add or remove folders, skip subfolders (an old sync conflict, a
    downloads dump), or leave out file types (`heic, txt`). Search follows at once. Searching *inside* one folder
    from the panel: coming (`in:` in the query).
16. **Pause it.** Presenting, gaming, on a train? Tray → Pause Indexing. Search keeps working; new files wait until
    you resume. It stays paused across restarts.
17. **CPU or GPU.** Settings → Indexing → "Use the GPU". On an AMD or Intel GPU (Vulkan) indexing is about 2.7× faster
    than on the CPU; turn it off on battery or if your graphics driver misbehaves. Searching is fast either way.
18. **Turn it off completely.** Tray → Quit stops DigUp and its helpers. To keep it off: Settings → Start at login
    off, and remove the shortcut with `scripts/linux/gnome-shortcut.sh --remove`. To remove its data:
    `rm -rf ~/.local/share/digup ~/.config/com.abdurrahim.DigUp`.

## Good to know

- **What it reads:** only the folders you choose. It skips hidden folders, Trash, caches, `~/snap`, Flatpak data,
  network and FUSE mounts reached from inside a chosen folder, code projects (except their screenshots, unless code
  search is on), datasets, keys and password files. It never changes, moves or uploads your files.
- **How long:** the first pass is the slow part (on a Radeon 860M: about 10 minutes for ~500 everyday files); after
  that a new file is searchable a few seconds after it lands.
- **Where things live:** index `~/.local/share/digup/index`, model `~/.local/share/digup/Models` (865 MB),
  settings `~/.config/com.abdurrahim.DigUp/settings.json`, logs `~/.local/share/com.abdurrahim.DigUp/logs`.
- **Private:** DigUp goes online only to download the model once. No account, no telemetry.
