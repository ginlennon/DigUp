# PLAN — Transcripts for recordings (D1), with the European-language testbed it needs

**Status (2026-10-14): approved by the user, default OFF; Stages 0–1 in progress.** Engine chosen by measurement:
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

### Stage 1 — whisper.cpp in the build
- `scripts/linux/build-whisper.sh`: v1.9.5 pinned, Vulkan, static, only `whisper-cli` → `Vendor/whisper/bin/`;
  `fetch-vendor.sh` calls it; `install-user.sh` puts it beside `digup`; CI builds the CPU flavour.
- `digup download-model --transcripts` (turbo q5_0 or `--small`, + Silero VAD; sha256; resume as the main model does).
- `digup doctor`: transcriber found, model present, a 3 s self-test clip transcribed (CPU in CI).
- **Check:** `whisper-cli` from the installed tree under `env -i` on the 162 s clip = the spike's text.

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

### Stage 5 — optional: CPU transcripts with Parakeet v3
Only if transcripts with the GPU off turn out to matter: sherpa-onnx C API (Apache-2.0) + Parakeet v3 int8 (CC-BY-4.0,
670 MB), VAD chunks ≤ 2 min, its token timestamps → the same windows. Also worth a measurement then:
**Canary-180m-flash** (CC-BY-4.0, ~200 MB GGUF for transcribe.cpp; en/de/fr/es only, no it/pt; no timestamps in that
port, so it would transcribe DigUp's 30 s windows one by one, which its length limit allows anyway).
