# PLAN — A keyword filter beside the search field (AND, OR, NOT, wildcards, phrases)

**Status (2026-10-14): F1 built (normalization + `fts_tri`, schema 6); F2–F5 not yet.** Starts after transcripts Stage 2
(PLANS/TRANSCRIPTS_PLAN.md) is merged, since both touch the keyword index. Input: the German keyword weaknesses
measured in `docs/linux-port/EVAL_RESULTS.md` ("European languages — baseline").

---

# Part A — Conceptual design

## A1. Why
The main field mixes meaning and words, and its word half is tuned for English: Porter stemming cuts English endings
only, so German plurals ("Versichertenkarten" vs "Versichertenkarte") and compounds ("Kaution" in
"Mietkautionskonto") never match, ß ≠ ss, "2'380.50" falls apart into 2 / 380 / 50, and common words ("die", "für")
let unrelated files in. On the European eval these cost: "Versichertenkarten" and "Kaution" find nothing,
"Seestrasse" finds the wrong file. Automatic language rules would fix some of it and guess wrong elsewhere. **The user
wants control instead: a second field with a small boolean language that says exactly which files may appear.**

## A2. What the user sees
```
┌──────────────────────────────────────────────────────────┐
│ 🔍 invoice from the carpenter                            │  meaning + words, as today: ranks
├──────────────────────────────────────────────────────────┤
│ ⧩  Rechnung* AND (Uster OR Winterthur) NOT Mahnung       │  filter: which files may appear
└──────────────────────────────────────────────────────────┘
```
Tab / Ctrl+F focuses the filter; Esc clears the filter first, then closes the panel; the filter stays while the panel
is open. Filter alone (main field empty) = a pure keyword search.

## A3. The filter language
| Written | Means |
|---|---|
| `Rechnung Uster` | both (AND is implied between terms) |
| `A AND B`, `A OR B`, `NOT A`, `-A` | boolean; operators only in capitals (French "or", German "und" stay words) |
| `( … )` | grouping; precedence NOT > AND > OR |
| `"Bahnhofstrasse 12"` | phrase: these words next to each other |
| `Rechnung*` | a word starting with it |
| `*karte` | a word ending with it (≥ 3 letters) |
| `*kaution*` | inside a word (≥ 3 letters) |
| `RE-2041`, `2'380.50` | a code / number as written (its parts next to each other) |

Case, accents and ß/ss don't matter. It looks at everything DigUp keeps as text: file and folder names, document and
PDF page text, OCR of screenshots and scans, transcripts (when on), and code stretches in the code index. A filter it
can't parse (an unclosed quote or bracket) is read as plain words, and the panel says so.

## A4. Semantics (user decision 2026-10-14: "B")
- **The filter decides membership; the main field ranks.** Candidates = files whose text satisfies the filter (per
  file: `A AND B` is true when A is anywhere in the file and B anywhere in it), within `in:` and kind limits. Every
  candidate is ranked by the main query (meaning z + word coverage, as now) **even below the meaning gate** — nothing
  the filter matches is lost; clearly weaker ones fold under "N weaker matches" as today.
- **Main field empty:** candidates ranked by how well the filter's positive terms match (bm25 over the matching
  segments), then by date.
- **Where a hit points (user: yes):** a PDF / recording / video / long document hit points at the page or moment the
  filter matches. With the main field filled: the segment that fits the meaning best among the segments containing a
  positive filter term; if no single segment has one (only the file name matched), the meaning's own segment. Main
  field empty: the best-matching segment for the filter.

## A5. How it works inside
- **Normalization first** (also helps the main field): `SearchText.normalized` folds `ß`→`ss` and removes the
  digit-group marks between digits (`'`, `’`, thin and narrow no-break spaces: `2'380.50` → `2380.50`). The keyword
  table is rebuilt from the text it already stores — seconds, no re-embedding (a migration, as schema 1→2 did).
- **Words, phrases, prefixes**: FTS5 queries on the existing `fts` table (per term, quoted; `term*` native).
- **Suffix and infix**: a second FTS5 table `fts_tri` with the `trigram` tokenizer (SQLite 3.54, case- and
  diacritics-insensitive) over the same normalized text: `LIKE '%karte%'` gives candidates fast, and a word-boundary
  check in Swift keeps only real suffixes. Size on the dev laptop's real index: ~14 MB for 5.8 M characters (the index
  is 17 MB); built in the same migration and kept in step wherever `fts` is written.
- **Boolean evaluation** on sets of file ids (per term one query, then ∩ ∪ and "all files in scope minus"), so NOT is
  exact and cheap. Then the ranking above on just those files.
- **Code index** gets the same (`code: … ` + filter; `*_handler` finds handler names).

## A6. The main-field fixes that stay (measured, each on its own)
1. ß/ss + Swiss numbers (A5, shared with the filter).
2. **Rare words count more**: coverage weighted by each word's rarity in the index (IDF), so "die", "für", "the"
   count little in every language — instead of stopword lists, which collide across languages ("die", "war", "will").
3. **Codes kept together**: a query word shaped like a code (letters-digits, `RE-2041`) is matched as a phrase, so it
   no longer matches `INV-2041`.
4. Kind words in de/fr/es/it/pt ("Foto", "Bild", "Bildschirmfoto", "Aufnahme", "Sprachnachricht", "Vidéo" …).
Dropped for now: automatic plural trimming (the filter's `Rechnung*` does it on purpose).

## A7. Evaluation and decision rule
- Eval files get an optional `"filter"` per query; `european.json` gains ~20 filter queries (plurals by `*`,
  compounds by `*…*`, NOT, phrases, codes, filter-only queries) with the page/moment expected.
- Main-field fixes: european.json + synthetic/multilingual/code before/after, per fix.
- **Rule:** the filter ships when every filter query returns exactly the files its expression implies (it's
  deterministic — a test, not a statistic) and search with an empty filter is unchanged on every eval. Each A6 fix
  ships if it improves european.json and drops no other eval by > 0.01 R@1.
- Speed: a filter over the dev laptop's index (and the testbed) answers in < 50 ms on top of today's search.

## A8. Risks
| Risk | Answer |
|---|---|
| `NOT x` alone = nearly every file | allowed; ranked by the main field, capped at the usual limit |
| Infix on 3 letters matches a lot | fine for a filter; the main field ranks |
| Index migration on the user's machine | rebuilt from stored text, no file is read again; older DigUp builds can still open it only if the schema allows — check, and say so in the release notes |
| Upstream (Mac app) | engine changes are platform-neutral; the panel part is the Tauri shell only |

---

# Part B — Stages

### F1 — Engine: normalization + trigram table (migration)
ß/ss + digit marks in `SearchText.normalized`; `fts_tri` created, filled and kept in step (every place `fts` is
written or deleted, incl. transcripts' rows); migration from the stored text; tests.
**Check:** old evals unchanged or better; "Seestrasse" finds the doctor's appointment.
- **Done (2026-10-14).** Decided on the way:
  - *Digit marks*: `'`, `’`, U+2009, U+202F and the Arabic thousands separator U+066C, only between two decimal digits,
    taken out before NFKC (which turns the two spaces into plain ones: "Seite 2 380 Gäste" with a plain space stays two
    numbers). `SearchText.matches`/`snippet` fold the same way, so «2'380» and «Seestraße» are marked as written;
    `original` keeps the text as written for every row normalizing changed (now also every row with ß).
  - *`fts_tri`*: `trigram remove_diacritics 1`, contentless with `contentless_delete = 1` and **`detail = none`**:
    2.4 MB on the dev laptop's real index (5.8 M characters) instead of 17.7 MB with places. It answers "which rows
    have all three-letter pieces of x" (candidates, `IndexStore.trigramQuery`); F2 checks them against `fts.body`.
    Every write goes through `addKeywords` / `addNameRow` / `deleteKeywords` / `move` (segments, name rows, transcripts
    in and out, requeue, resetAll, delete, prune); the code index is the same `IndexStore`, so it has it too.
  - *Schema 6*: `fts_tri` filled from `fts`; `fts` rows whose words change are rewritten in place from `original`
    (else `body`). An older DigUp refuses a schema 6 index ("made by a newer DigUp"), which is right: it wouldn't keep
    `fts_tri` in step. Release notes must say that going back means re-indexing.
- **Check passed:** european 0.84 → 0.86 R@1 (with transcripts; only "Seestrasse" moved, miss → #1 on
  `Arzttermin.odt`), synthetic / multilingual / code identical line for line. Migration on a copy of the real index
  0.53 s, 17.1 → 21.1 MB. Numbers in `docs/linux-port/EVAL_RESULTS.md`.

### F2 — Engine: the filter
Parser (A3) with tests; set evaluation (A5); ranking (A4) incl. below-gate candidates and filter-only mode; hit
location (A4); `digup search … --filter '…'`; search-service `filter` field (old shells unaffected); `digup eval`
reads `"filter"`. **Check:** the filter queries in european.json all exact; < 50 ms.

### F3 — Panel, HTTP, MCP
Second field (Tab / Ctrl+F, Esc order, a parse hint), the hit's page/moment as the engine says; HTTP `/search`,
`/context` and MCP `search_files` / `search_code` get `filter`; OpenAPI updated.
**Check:** the user tries it.

### F4 — Main-field fixes A6.2–A6.4, one at a time, measured.

### F5 — Docs: user guide cases ("Rechnung* NOT Mahnung", "*kaution*", a phrase), README, EVAL_RESULTS.
