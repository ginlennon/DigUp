# PLAN — Transcripts for recordings (D1), with the European-language testbed it needs

**Status (2026-10-14): approved by the user, default OFF. Stages 0 (European testbed + eval, baseline), 1
(whisper-cli in the build, models, doctor), 2 (the engine's transcript pass, CLI) and 4 (shell: setting, model
download, tray, panel, user guide) built, Stage 4 waiting for the user's own check; Stage 3 and 5 not implemented.** Engine chosen by measurement:
[docs/linux-port/ASR_SPIKE.md](../docs/linux-port/ASR_SPIKE.md). Parent plan: [LINUX_PORT_PLAN.md](./LINUX_PORT_PLAN.md)
Part D. Languages in focus: German and English first, then French, Spanish, Italian, Portuguese; Bengali and Arabic
(upstream's multilingual set) become tier 2.

---

# Part A — Conceptual design

## A1. Why
Recordings and video soundtracks are embedded as 30 s windows (window 30 s, hop 25 s): a query finds the right moment
by meaning, but nothing that was *said* is text. So:
- exact spoken words don't match: a name, an invoice number, a flight number, "RE-2041";
- RAG clients get nothing for a recording (`/context`, `read_segment` return no text);
- the panel can't show what was said at the moment it found.

**Null hypothesis:** meaning search already finds the moment (the evals' audio queries are 1.00), and most people have
few recordings with speech, so transcripts add cost (~7× the audio's embedding time, 574 MB more model) for rare wins.

## A2. What we measured (ASR_SPIKE.md)
- whisper.cpp v1.9.5 + large-v3-turbo q5_0 on Vulkan: FLEURS WER de 3 / en 4 / fr 11 / es 2 / it 3 / pt 5, 82 % of
  planted names/numbers/codes, 5.1× real time, 0.9 GB GPU, load 0.14 s, stable over ~330 calls.
- Silero VAD (`--vad`) removes every hallucination on silence, noise and music at no cost.
- One call per whole file beats per-window calls (21 s vs ~29 s for 162 s), keeps context and one language.
- CPU only: turbo is ~1× real time (too slow for bulk); whisper small 3.7×; Parakeet v3 24× but weaker on names and
  codes and needs ≤ 2 min chunks.

## A3. Design

```
index helper (digup index-service)
  pass 1, as now: file → ffmpeg 16 kHz → 30 s windows → EmbeddingGemma vectors → searchable
  pass 2, after everything else is in (like long PDFs' later pages):
     audio/video file → ffmpeg 16 kHz mono WAV (the whole file, or 10-min chunks with 5 s overlap)
       → whisper-cli -m turbo-q5_0 -l auto --vad -vm silero -oj   (a separate program, its own ggml)
       → segments [start, end, text, lang, p]
       → guards (A4) → text of the segments overlapping each existing audio window
       → FTS row + excerpt on that audio segment (no new segments, no re-embedding)
```

- **Where the text lives.** On the existing `audio` segments: the transcript goes into `fts` with the segment's id as
  rowid (as `addSegment(text:)` does for pages), and `excerpt` gets its first ~200 characters. A keyword hit then
  already points at the window's `loc`, so ↩ opens VLC at the moment, the snippet shows «the word», and
  `text(ofSegment:)` — hence `/context`, `read_segment`, the preview — returns what was said. No schema change.
  A segment in the 5 s overlap of two windows goes to both (keyword search ranks per file, so that costs nothing).
- **No text vector for transcripts (default).** Screenshots taught us that a text vector of OCR text outranked better
  matches (2026-10-08); the audio vector already carries meaning. Stage 3 tests "audio vector + transcript vector" as
  an option against the evals before deciding.
- **State.** `files.info.transcript` = `done` | `none` (no speech) | `failed: …` | absent (= waiting), plus
  `transcript_model` / `transcript_lang`. Meta `transcripts` = engine+model id: turning transcripts on, or a new model,
  queues the transcript pass only — embeddings stay. Turning them off deletes the transcript FTS rows.
- **The engine is a program, as ffmpeg and tesseract are.** `whisper-cli` built **statically** (`BUILD_SHARED_LIBS=OFF`)
  so its ggml never meets llama.cpp's `libggml*.so` beside `digup` (the two copies differ; one process with both would
  clash). Looked for in `$DIGUP_WHISPER`, beside the helper, then on PATH. Behind a `Transcriber` interface in
  `Platform/` so macOS could later fill it with Apple's own speech recognition (an upstream-friendly shape).
- **One GPU job at a time.** The index helper runs embedding and transcription one after the other, never together.
  The search helper's query encoder may run during a transcription (two processes on the GPU): check it once by hand
  in Stage 2 (a dozen searches while a long file transcribes), and if it misbehaves, pause the pass while the panel
  is open.
- **Models.** `ggml-large-v3-turbo-q5_0.bin` (574 MB) and `ggml-silero-v6.2.0.bin` (0.9 MB), pinned by sha256, into
  `~/.local/share/digup/Models/whisper/` by `digup download-model --transcripts`, offered when the setting is turned
  on. Without a GPU: `ggml-small.bin` (488 MB) on the CPU, said so in Settings ("slower and less exact").

## A4. Guards (wrong text in the index is worse than none)
- VAD always on; drop segments whose language probability is < 0.9 (speech ≥ 0.997, probes 0.38–0.78 in the spike);
- a short blocklist of known hallucinations ("Thank you.", "Untertitel …", "Subtitles by …", "[Music]") applied only to
  segments that are the whole text of a window;
- JSON read with invalid UTF-8 replaced (whisper small wrote broken JSON on music);
- a timeout per call from the audio length (e.g. 2 min + 1× duration), under the helper's watchdog; a file that fails
  twice is `failed` and not retried until the engine changes;
- **songs are skipped by default**: audio with artist + album tags (ffprobe) gets no transcript unless "also
  transcribe music" is set (by tags, not by folder: voice memos land in Music folders too). Lyrics are rarely what one looks
  for, and VAD lets sung vocals through.

## A5. Keyword search has to meet whisper's spelling
whisper writes "RE-2041" as "RE-2041" or "RE 2041", "1'250" as "1250"/"1.250", "19.30 Uhr" for "19 Uhr 30", "großer"
in Swiss text. Folding digit-group separators in numbers (`1'250`, `1.250`, `1,250` → `1250`) and `ß`→`ss` belongs in
`SearchText.normalized` for all text, not only transcripts — it's part of the European-language work (A7).

## A6. Evaluation
- New `evals/european.json` over a new testbed folder `synthetic/lang/eu/` (Stage 0): per language a note, a PDF page,
  a screenshot, and two recordings with planted names/numbers/codes (the spike's Piper clips + ground truth), plus
  the German 162 s clip and the silence/music probes.
- Query tags: `spoken-term` (exact words only said in a recording: "RE-2041", "Brunner", "Wädenswil"), `spoken-topic`
  (meaning), `xx-doc` / `xx-pdf` / `xx-shot` per language, `cross` (German query → English file and back).
- Measure before/after: R@1/R@5/MRR on `synthetic`, `multilingual`, `code` (must not drop) and `european`;
  `spoken-term` R@5; hallucination probes must stay without text; transcript pass time per audio minute.

## A7. The language refocus that comes with it (also parent plan D5)
Keyword search was tuned for English plus Bengali/Arabic: Porter stemming is English-only, the stopwords and the kind
words ("photo", "video", …) are English/Bengali/Arabic. A German query's "der/die/und/mit" count as content words,
"Rechnung" doesn't match "Rechnungen" unless the prefix fallback kicks in, and "Foto"/"Aufnahme" don't hint a kind.
Stage 0 measures this with `european.json`; Stage 3b fixes what the numbers show: stopwords and kind words for
de/fr/es/it/pt, prefix matching for long words of those languages (as `inflects` does for Bengali), the A5 folding.
Bengali and Arabic stay as they are (tier 2: kept working, not extended); OCR offers `tesseract-ocr-fra/spa/ita/por`
in `setup.sh` (deu is there).

## A8. Decision rule
The C7 rule ("≤ 1.5× the audio indexing time") is **not met and can't be**: turbo transcribes at ~5× real time,
embedding runs at ~37×, so transcripts cost ~7× the audio's embedding. **User decision (2026-10-14): transcripts are
off by default** — a setting the user turns on. Revised rule — the feature is kept (and recommended in Settings) if:
1. `spoken-term` R@5 on `european.json` goes from ~0 to ≥ 0.7, with no drop > 0.01 R@1 on the other evals;
2. the probes stay without text and the 4 English testbed recordings come out with WER ≤ 10 %;
3. the pass never delays pass 1 (a new file is searchable by meaning as fast as today) and an hour of recordings is
   transcribed in ≤ 15 min on the 860M.
If (1) holds but (3) doesn't: offer greedy decoding (~1.5× faster) as the "fast" choice.

## A9. Risks
| Risk | Answer |
|---|---|
| Real speech is noisier than Piper and FLEURS; Swiss German dialect comes out as approximate Standard German | check on a few real recordings by hand (user's own, not committed); words that matter (names, numbers) are usually said in Standard German |
| GPU: two processes on the iGPU (transcription + query encoder) | one manual check in Stage 2; fall back to pausing the pass while searching |
| Long files (a 2 h podcast) | 10-min chunks: resumable, under the watchdog, progress shown |
| Disk and download: +574 MB | asked when turning it on; small model as the light choice |
| Lyrics, TV audio, music under speech | songs skipped by default; VAD + guards |

---

# Part B — Staged implementation (each stage ends with a check written down)

### Stage 0 — European testbed + eval, baseline (no transcripts yet)
- `scripts/linux/testbed/make_eu.sh` (+ `make_eu.py`, `speak.py` gains de/fr/es/it/pt Piper voices, pinned by sha256):
  notes, PDF, screenshot, two recordings per language, the 162 s German clip, probes → `synthetic/lang/eu/`.
- `make-testbed.sh`: Bengali/Arabic become tier 2 — `--tier2` builds them (default off); `multilingual.json` stays as
  upstream's file, run only when tier 2 is there.
- `evals/european.json` with the A6 tags; `check_eval_paths.py` covers it.
- **Check:** baseline numbers for european.json (expect `spoken-term` ≈ 0, German keyword queries weaker) in
  `docs/linux-port/EVAL_RESULTS.md`.
- **Done 2026-10-14:** european 0.79 / 0.88 / 0.83 (R@1 / R@5 / MRR, 76 queries), `spoken-term` 0.10 / 0.40 (the
  audio vector catches some names, never codes); the other evals unchanged. Weaknesses for 3b in EVAL_RESULTS.md.

### Stage 1 — whisper.cpp in the build
- `scripts/linux/build-whisper.sh`: v1.9.5 pinned, Vulkan, static, only `whisper-cli` → `Vendor/whisper/bin/`;
  `fetch-vendor.sh` calls it; `install-user.sh` puts it beside `digup`; CI builds the CPU flavour.
- `digup download-model --transcripts` (turbo q5_0 or `--small`, + Silero VAD; sha256; resume as the main model does).
- `digup doctor`: transcriber found, model present, a 3 s self-test clip transcribed (CPU in CI).
- **Check:** `whisper-cli` from the installed tree under `env -i` on the 162 s clip = the spike's text.
- **Done (2026-10-14):** as above, with two findings. (1) A static `whisper-cli` still calls `ggml_backend_load_all()`,
  which opened llama.cpp's `libggml-vulkan.so` / `libggml-cpu-*.so` beside `digup` (and would from the current
  folder): `scripts/linux/whisper.cpp-no-backend-search.patch` takes the call out (2 backends, none loaded). (2) The
  doctor self-test clip is left for Stage 2, where the `Transcriber` runs anything. Check passed: the installed
  `whisper-cli` under `env -i` gives the spike's text word for word on the 162 s clip (with VAD, 17.4 s on Vulkan)
  and on `syn_de_invoice` (without VAD).

### Stage 2 — engine: the transcript pass
- `Transcriber` (Platform/Portable: subprocess, JSON, guards, chunking); `Indexer` pass 2 after pending files, with
  progress events ("transcribing 3 of 12"); state in `files.info`; meta `transcripts`; `IndexOptions.transcripts`
  (off / gpu / cpu-small) passed by the shell; `digup index --transcripts`, `digup transcribe <file>` (prints the
  segments, for debugging), `digup status` counts.
- Window mapping, guards, songs rule, re-queue on model change, delete on off.
- Unit tests: segment→window mapping (overlaps, chunk seams), guards, broken UTF-8, song detection; an integration test
  with a tiny model behind an env flag.
- **Check:** testbed indexed with transcripts; `digup search "RE-2041"` finds the German invoice recording at the
  right second; the manual GPU check (searching during a long transcription).
- **Done (2026-10-14).** What was decided on the way:
  - *Where the code is.* `Transcripts.swift` (shared: chunks, seams, guards, window mapping, whisper's JSON and log,
    song tags), `Platform/Portable/Transcribe+Portable.swift` (ffmpeg → WAV per chunk, whisper-cli with the current
    folder set to the file's own scratch folder, a time limit per call: 2 min + the chunk's length, then SIGKILL),
    `Platform/Apple/Transcribe+Apple.swift` (no engine: the pass is a no-op). `Indexer.checkTranscripts` /
    `transcribeRecordings`, `IndexStore.setTranscript` / `removeTranscripts` / `untranscribed`. No schema change.
  - *Window mapping.* The words go onto the audio segments pass 1 stored (their `loc`/`loc_end`, not recomputed
    windows). A segment belongs to every window it overlaps by ≥ 1 s, and to the window holding its middle: a sentence
    in the 5 s two windows share is in both, one longer than a window in each it spans, a short word at an edge stays
    where it was said. A segment in a stretch pass 1 left out as silent is lost.
  - *Chunks.* Up to 10 min: one call for the file. Longer: 10-min chunks overlapping by 5 s (a last one under a
    minute joins the one before); a segment in an overlap is kept from the chunk whose half of the overlap holds its
    middle. A stop between chunks drops the file's progress (it waits for the next pass, from its start).
  - *Language confidence* comes from whisper-cli's log ("auto-detected language: de (p = 0.999)"): the JSON names the
    language but not how sure, and `-ojf`'s probabilities are per token. Applied per chunk. Segments without that
    line = `failed` (better than unguarded text); no speech heard = no line, no segments = `none`.
  - *State.* `files.info`: `transcript` done | none | failed, `transcript_lang`, `transcript_model` (whisper.cpp
    version + model), `transcript_why` (music, no sound, no speech, unsure of the language, the error),
    `transcript_tries`. Meta `transcripts` = "whisper <model file>": a new model (gpu ↔ cpu) takes all transcripts out
    and queues pass 2; a new whisper.cpp alone doesn't, but retries what failed twice. Off removes the FTS rows,
    excerpts and info keys. Songs by tags get `none`/music and come back when "also music" is turned on.
  - *Helper.* `index-service --transcripts gpu|cpu|off [--transcribe-music]` (args, as the shell passes the other
    settings; without it, as from today's shell, transcripts are off). Pass 2 runs after pending files, code and the
    rest of long files, under the backfill's rules; it yields between recordings and chunks like the others. On the
    GPU the embedder is closed first. New events: `transcript` (as `file`'s, + `audio_seconds`), `summary` with
    `"transcripts": true`; counts gain `transcripts_done` / `transcripts_waiting` while on. The watchdog gives each
    chunk its time limit (`Indexer.nowTranscribing`); a stop there fails the transcript only (`StoppedFile.transcript`).
  - *CLI.* `digup index … --transcripts gpu|cpu|off [--transcribe-music]` (off removes them; since Stage 4, without
    the option they're left as they are),
    `digup transcribe <file> [--cpu] [--json]`, `digup status` counts when on.
- **Check (2026-10-14, Radeon 860M, Vulkan, turbo q5_0, VAD):** the spike's 69 clips into a scratch index: pass 1
  21 s (62 done, 7 skipped as silent: the silence probe and 6 FLEURS clips at −62…−66 dB); pass 2 200 s for ~19 min
  of audio (5.7× real time, ~2.3 s a call of start-up on short clips; 162 s clip 18.2 s, a 280 s file 31.6 s = 8.9×:
  an hour of long recordings ≈ 7 min, A8.3 met): 60 done, noise and music probes `none` (no speech), no text on any
  probe. Keyword hits at the right window: "Brunner", "Winterthur" → syn_de_invoice at 0:00, "Uster" at 0:25 (said
  at 25.2 s); "Villeurbanne", "Moreau Immobilier" → syn_fr_invoice 0:00; "Bianchi Arredamenti", "Modena" →
  syn_it_invoice 0:00; "Rapperswil" → both 162 s clips at 0:00. **"RE-2041" is not found**: with VAD whisper writes
  "Rhe 2000 41" (without VAD "RE 2041"); VAD stays (16 planted-term clips: 135/160 terms with default VAD, 132 without,
  133 with longer silences). "Kassier Peter Huber" finds the 162 s clip but points at 1:40, its best meaning window
  (z 3.1), not at 0:00 where the words are (Searcher's rule; Stage 3). `search --json`: the excerpt is the transcript
  snippet («Rapperswil»), `info` carries the transcript keys; `text(ofSegment:)` returns the window's words.
  **GPU concurrency (once):** 12 searches through `search-service` (encoder on Vulkan) while whisper-cli transcribed
  the 280 s file: no errors; encoder start 1.6 s (0.6 s alone), searches 12–640 ms (~15 ms alone); the transcription
  took 31.6 s (32.0 s alone). **CPU** (`--transcripts cpu`, small, 8 threads): the 162 s clip in 22.9 s (7.1× real
  time), "Rapperswil" found ("Gassier" for "Kassier"); switching it to gpu redid the transcript (vectors untouched),
  `off` took it out. Helper run: a tagged song `none` (music), a video without sound `none` (no sound), a video's
  French soundtrack found by "Villeurbanne"; restarted without `--transcripts`, its transcripts were removed.

### Stage 3 — evals and tuning
- (a) european.json + the other evals before/after; beam vs greedy; transcript text vector on/off; the A8 rule.
- (b) the language fixes A7 shows are needed (stopwords, kind words, prefixes, number/ß folding), each measured.
- **Check:** numbers in EVAL_RESULTS.md; decision recorded here.

### Stage 4 — shell and integrations
- Settings → Indexing → "Transcribe recordings" (model download with progress; GPU or "slower on the CPU"; "also
  transcribe music"); tray "Transcribing 3 of 12"; pause/battery respected; the panel shows the transcript line with
  «word» at the moment; Check DigUp includes it.
- MCP `read_segment` / HTTP `/context` return transcripts (nothing to change if A3 holds — test it); user guide case
  ("the meeting where someone said the invoice number"); README numbers.
- **Check:** the user tries it on their own recordings.
- **Built (2026-10-14); the user's own check is still to come.** What was decided on the way:
  - *Setting.* `transcripts` and `transcribeMusic` in settings.json, both false by default. The index helper is always
    told: `--transcripts gpu` when on and the GPU is in use (Settings' "Use the GPU", and no GPU fallback this
    session), `cpu` when on otherwise, `off` when off (which takes them out); `--transcribe-music` with it. A change
    is a change of the helper's arguments, so it starts over, as with the other indexing settings
    (`shell/src-tauri/src/transcripts.rs`).
  - *The model.* Turning them on runs `digup download-model --transcripts` (`--small` when the CPU is in use), which
    says "done" at once when the files are there; its progress shows in Settings in setup's words ("Downloading the
    model · 41% of 575 MB"), with Cancel. Cancel turns them off; a failed download turns them off and says why. Once
    it's in, the index helper starts over (one started before has no transcriber). The GPU switch fetches the other
    model if it's missing; a GPU fallback doesn't (a session's fallback isn't worth 489 MB: without the small model
    the helper leaves the transcripts as they are). At start, with them on, the same check runs, so a download cut off
    by quitting is picked up (quitting isn't a failure: they stay on).
  - *whisper-cli missing.* The shell looks for it where the helper does (`$DIGUP_WHISPER`, beside the helper, a dev
    build's Vendor/whisper/bin, PATH) rather than asking `digup doctor` (a second and the model on the GPU each time
    Settings opens); the checkbox is then disabled with "Not installed in this build". Check DigUp shows doctor's
    whisper and transcripts lines as they are.
  - *Tray and panel.* Each `transcript` event says "Transcribing 3 of 12" (and the panel's activity line), then
    "Up to date · N files" as before. An audio hit whose window has a transcript (`info.transcript` = done, segment
    `audio`) shows its excerpt under the reason, the words found in bold; with words found the reason says "Said at
    0:25", else "Matches what's heard at 2:05". Hits without one look as before.
  - *Engine.* `digup index` without `--transcripts` now leaves an index's transcripts alone (only `off` removes them),
    so a run by hand doesn't undo the app's; `index-service` without it still means off. And `download-model
    --transcripts` had stopped working when Stage 2 made `--transcripts` take a value (it read the next argument, or
    failed "needs a value"): for `download-model` it's a flag again.
- **Check (2026-10-14, dev shell on a private D-Bus session and XDG folders, temp index/settings/models, roots =
  `synthetic/lang/eu`):** settings on with the VAD missing → the shell fetched it (0.9 MB), restarted the index
  helper; pass 1 (35 files, 39 s) said "Indexing n of 35", pass 2 "Transcribing 1 of 14" … "14 of 14" (128 s),
  then "Up to date · 34 files". The panel (`--debug-query`): "Brunner" → the German invoice memo, "Said at 0:00" and
  its line; "Uster" → "Said at 0:25", footer "↩ Open at 0:25"; "Villeurbanne" → the French memo; "Kassier Peter
  Huber" → the 162 s clip, "Matches what's heard at 2:05" with that window's words. `/context` (digup-http) returns
  the memo's transcript. Off → restarted with `--transcripts off`, the index had none left. GPU off → `cpu`, whisper
  small, 13 done (same 128 s here: 8 threads), "Villeurbanne" found. Quitting during a download kept them on and left
  no download running. Settings' rows (off, CPU text, not installed, downloading, retrying, failed, on with music,
  turning on → download → done, failing, Cancel) checked in headless Chrome with a stand-in for Tauri's API: the
  real window wasn't clicked.

### Stage 5 — optional: CPU transcripts with Parakeet v3
Only if transcripts with the GPU off turn out to matter: sherpa-onnx C API (Apache-2.0) + Parakeet v3 int8 (CC-BY-4.0,
670 MB), VAD chunks ≤ 2 min, its token timestamps → the same windows. Also worth a measurement then:
**Canary-180m-flash** (CC-BY-4.0, ~200 MB GGUF for transcribe.cpp; en/de/fr/es only, no it/pt; no timestamps in that
port, so it would transcribe DigUp's 30 s windows one by one, which its length limit allows anyway).
