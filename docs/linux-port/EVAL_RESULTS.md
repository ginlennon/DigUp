# Search quality on Linux — `digup eval`

Testbed: `scripts/linux/make-testbed.sh` (synthetic/, traps/, code/; no real/), i.e. Wikimedia photos and piper voices
instead of Apple's sample pictures and `say` voices, so numbers are comparable to macOS but not identical.
Index: `digup index ~/DigUpTestbed/{synthetic,traps}` + `digup index --code ~/DigUpTestbed/code`, Vulkan backend
(860M), llama.cpp b11461, vectors 1. Indexing took 44 s (+10 s rest of long files, +4 s code).

## Baseline 2026-10-14 ~01:20 — before Stage 3 (no OCR; testbed shot_*.png indexed as plain images)

| Eval | n | R@1 | R@5 | R@10 | MRR |
|---|---|---|---|---|---|
| synthetic | 37 | 0.97 | 0.97 | 0.97 | 0.97 |
| multilingual | 48 | 0.92 | 0.98 | 0.98 | 0.95 |
| code | 41 | 1.00 | 1.00 | 1.00 | 1.00 |

Per tag, below 1.00 only: synthetic `exact` 0.80 (1 of 5 missing — exact strings in screenshots need OCR);
multilingual `bn-word` R@1 0.67 (“ধানমন্ডি” at #2), `bn→en` 0.50 (1 of 2), `en→ar` R@1 0.83 (“rainy weather in
Riyadh” at #2), `en→bn` R@1 0.86 (“mobile wallet transfer failed…” at #2). Everything else — image, audio, video
moments, PDF pages, long files, screenshots by meaning, Bengali/Arabic docs/PDFs/speech — is 1.00.

## After Stage 3 (2026-10-14 ~01:45) — tesseract OCR (eng+deu), ffmpeg 8.1, Linux skip rules, screenshot detection

| Eval | n | R@1 | R@5 | R@10 | MRR |
|---|---|---|---|---|---|
| synthetic | 37 | 0.97 | **1.00** | 1.00 | **0.99** |
| multilingual | 48 | **0.94** | 0.98 | 0.98 | 0.95 |
| code | 41 | 1.00 | 1.00 | 1.00 | 1.00 |

Changes vs baseline: synthetic `exact` 0.80 → **1.00** (OCR finds `INV-2041`, `card_declined`, `K7Q2LM`,
`externally-managed-environment`); `en→ar` R@1 0.83 → 1.00; `screenshot` R@1 1.00 → 0.83 (one at #2; the testbed's
`shot_*.png` are now classified as screenshots — screenshot budget, OCR words — which shifts one ranking; R@5 1.00).
Unchanged misses: `bn-word` “ধানমন্ডি” at #2, `bn→en` 1 of 2 (Bengali OCR not installed: tesseract-ocr-ben needs sudo).

## European languages — baseline before transcripts (2026-10-14)

Stage 0 of [TRANSCRIPTS_PLAN.md](../../PLANS/TRANSCRIPTS_PLAN.md): the new `synthetic/lang/eu/` folder
(`scripts/linux/testbed/make_eu.sh`; per language de/en/fr/es/it/pt a note, a two-page PDF, a screenshot named as GNOME
names one in that language, two recordings with planted names/numbers/codes, plus the German 162 s board-meeting clip
and a silence and a music probe) and `evals/european.json` (76 queries). No transcripts yet: what is only *said* in a
recording can be found by the audio vector alone. Same build and model as above (llama.cpp b11461, vectors 1, Vulkan
on the 860M); tesseract eng+deu only.

```sh
scripts/linux/testbed/make_eu.sh ~/DigUpTestbed/synthetic/lang/eu        # added to the existing testbed (~30 s)
digup index --index .dev/eval-idx-eu ~/DigUpTestbed/synthetic ~/DigUpTestbed/traps     # 111 files, 59 s
digup index --code --index .dev/eval-idx-eu ~/DigUpTestbed/code                        # 3 s
digup eval --index .dev/eval-idx-eu evals/european.json      # and synthetic, multilingual, code
```

| Eval | n | R@1 | R@5 | R@10 | MRR |
|---|---|---|---|---|---|
| **european** | 76 | **0.79** | **0.88** | 0.88 | **0.83** |
| synthetic | 37 | 0.97 | 1.00 | 1.00 | 0.99 |
| multilingual (tier 2) | 48 | 0.94 | 0.98 | 0.98 | 0.95 |
| code | 41 | 1.00 | 1.00 | 1.00 | 1.00 |

The old evals are unchanged by the 35 new files (same totals as after Stage 3). One rank moved inside a miss that
was already counted: multilingual `bn-word` “ধানমন্ডি” #2 → #3 (the Bengali screenshot now edges the PDF page; no `eu`
file is in its top 5, so it's the bigger index shifting the score normalisation, not a competitor).

european.json per tag:

| Tag | n | R@1 | R@5 | MRR |
|---|---|---|---|---|
| `spoken-term` | 10 | 0.10 | 0.40 | 0.21 |
| `de-audio` | 4 | 0.50 | 0.75 | 0.62 |
| `es-audio`, `it-audio` | 2 + 2 | 0.50 | 1.00 | 0.75 |
| `cross` | 7 | 0.86 | 0.86 | 0.86 |
| `de-keyword` | 11 | 0.82 | 0.91 | 0.85 |
| everything else: `xx-doc` (8), `xx-pdf` (10), `xx-shot` (6), `xx-shot-ocr` (7), `en/fr/pt-audio` (6), `fr/es/it-keyword` (3) | 40 | 1.00 | 1.00 | 1.00 |

Not at #1, per tag:
- `spoken-term` (the Stage 3 target): “Brunner” is #1 and “Guarulhos” #2, “Wädenswil” #3 (right window), “INV-3381” #4 —
  the audio vector catches some spoken names; codes never: “RE-2041”, “OF-2026-118”, “FA-1187”, “EXP-6083”, “FT-3326”
  and the surname “Okafor” are not in the top 10. “RE-2041” also word-matches `shot_payment_error.png` (its `INV-2041`
  shares the token `2041`).
- `de-audio`: “Anruf eines Schreiners wegen einer unbezahlten Rechnung” #2 (the written carpenter invoice, PDF p. 1, is
  #1); “Offerten für die Sanierung des Bootsstegs” misses — the right file, the wrong moment (2:05, the “Verschiedenes”
  part about the boat house, instead of 1:15–1:40: one segment per file is listed).
- `es-audio` “llamada de una constructora por una factura pendiente” #2 (the electricity bill PDF first); `it-audio`
  “telefonata per una fattura di mobili non pagata” #2 (the German carpenter invoice first).
- `cross`: “voicemail from a carpenter about an unpaid bill and twelve chairs” (English → the German call) misses; the
  six text crossings (de→en/fr/es, en→de, fr→de) are #1.
- `de-keyword`: “Seestrasse” misses (the note says “Seestraße”); “Versichertenkarten” #3 (the note says
  “Versichertenkarte”).
- Probes: the silence is skipped at indexing (“silent or too short”); the music probe is in no european query's top 10.
- `xx-shot-ocr` is 7/7 with eng+deu only: the codes OCR fine in every language, and “Cartão de débito” is found by
  meaning even though OCR reads “Cartäo”.

### Keyword-search weaknesses seen (input for Stage 3b)

Checked with `digup search` on the same index (`words #n` in its output = a keyword hit):
1. **German inflection.** “Rechnungen” and “Versichertenkarten” get no word hit on “Rechnung”/“Versichertenkarte”
   (meaning carries the first; the second drops to #3). Plurals in -e/-s match only by accident of the English Porter
   stemmer plus diacritic folding (“Laborwert” ↔ “Laborwerte”, “Mietverträge” → “Mietvertrag”, “facturas” → “factura”);
   -en/-n plurals and umlaut changes don't.
2. **ß vs ss.** “Seestrasse” finds nothing of “Seestraße” (miss); “Großmutter” gets no word hit on “Grossmutters” and
   “Bahnhofstraße” none on “Bahnhofstrasse” (meaning finds both); the ss spellings do word-match.
3. **Swiss numbers.** “CHF 2'380.50” is indexed as 2 / 380 / 50: “2380” gets no word hit on the invoice, and
   “2'380.50” word-matches unrelated pages through “380”/“50” (the sailing log's p. 38 outranks the invoice). Codes split
   the same way (“RE-2041” ↔ “INV-2041”).
4. **German stopwords count as words.** “Offerten für die Sanierung des Bootsstegs” gives `Arzttermin.odt` a word hit
   on «für» «die»; “die Rechnung von der Schreinerei in Winterthur” gives the German screenshot one (#3).
5. **Kind words are English only.** “photo of a zebra” puts the photo first, “Foto von einem Zebra” the video;
   “Bildschirmfoto Zahlung” finds the screenshot only through its file name and OCR words (a PDF has the higher meaning
   score), while “screenshot payment failed train ticket” lists five screenshots. “Aufnahme der Vorstandssitzung” is #1
   by meaning, not as a kind hint.
6. **Recordings by meaning, across languages, are weak**: the English query for the German call misses; “recording of
   the board meeting” doesn't list the German meeting in its top 5. Written invoices outrank the calls about invoices in
   de/es/it. Transcripts (keyword hits on the moment) are the fix the plan has; the stopword and folding fixes above
   apply to them too.
