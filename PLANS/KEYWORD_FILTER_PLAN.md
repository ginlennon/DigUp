# PLAN — A keyword filter beside the search field (AND, OR, NOT, wildcards, phrases)

**Status (2026-10-15): F1 (normalization + `fts_tri`, schema 6), F2 (the filter in the engine, CLI, search
service, evals), F3 (panel, HTTP, MCP), F4 (the main field's rare words, codes, kind words: all three kept) and F5
built; F3 waits for the user to try it.** Starts after transcripts Stage 2
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
- **Done (2026-10-14).** Decided on the way:
  - *Grammar* (`KeywordFilter`, a value type): or := and ("OR" and)* · and := unary (["AND"] unary)* ·
    unary := ("NOT" | "-") unary | "(" or ")" | term. `-` is NOT only at a token's start (`RE-2041` stays a code);
    quotes `"…"` and „…“/“…”; `"…"*` is a phrase whose last word is a prefix; a word with inner punctuation is its parts
    as a phrase (`2'380.50` → "2380 50"). `*ab` (under three letters) is read as the word, with a note. Unclosed quote,
    unbalanced bracket or a dangling operator → every word a term, ANDed, operators and quotes dropped, and a note
    ("unclosed quote: read as plain words"). Nothing but operators/punctuation → no filter.
  - *Membership* per term, on file-id sets, combined with ∩ ∪ and universe − x for NOT (universe = the search's
    kinds and folders, in the main or the code index). Words and phrases: `fts` MATCH (so English endings match through
    Porter, as in the main field). **Prefixes, suffixes and infixes: `fts_tri` candidates (rows with all the term's
    three-letter pieces) checked on `fts.body`** for a word start / word end / anywhere. Not prefixes through `fts`:
    Porter cuts the typed word too ("facture*" became "factur*" and found the Spanish *factura*; "connecti*" would miss
    "connection", kept as "connect"). A two-letter prefix or a phrase prefix (`"RE 20"*`) stays `fts`'s.
  - *Ranking B*: candidates = the filter's files; score = the main query's as today (meaning z + coverage, coverage
    now counted over every candidate, not only the best 100 keyword files); ties by raw z (below the gate, below 0),
    then the filter's bm25. Main query empty: bm25 of the positive words/phrases/prefixes (a file found only by a
    suffix, infix or NOT after those), then newest; scores 2 → just over 1, so nothing is folded. A filter with an
    empty main query ignores a query vector; without a filter, search is exactly as before.
  - *Where a hit points*: the file's segments (not its name row) holding a positive term; best z for the main query
    (without a query vector: the main words' segment), then most positive terms, then bm25, then the first. Only the
    name/folder matched → the meaning's segment, else the words', else the name row. Code: the stretch with the term,
    opening at its first line with a mark; a name's definition is looked up only when no stretch has the filter's
    words. The snippet marks the filter's words (whole words, a phrase/code as one: «2'380.50», «RE-2041»).
  - *Interfaces*: `digup search [words] --filter EXPR` (note on stderr), search-service `"filter"` →
    `"filter_note"` when it fell back (old requests unchanged), `digup eval` `"filter"` + an "exact" column and
    "filter queries exact: n of m".
- **Check passed:** 25 filter queries in european.json (14 filter-only, 2 code), **25 of 25 exact**, their sets also
  confirmed by an independent regex reading of the index's text; european without them 0.86 / 0.93 / 0.88 and the
  other three evals identical to F1. Filter cost ≤ 18 ms over the search on a copy of the real index (`*tion*`,
  245 files), ≤ 3 ms on the testbed. Numbers in `docs/linux-port/EVAL_RESULTS.md`.
- Open: hits that point at a screenshot's OCR row (no vector) show "text in image" rather than the picture; the panel
  (F3) may want the picture with the words. A NOT-only filter on a big index lists everything (capped by `limit`).

### F3 — Panel, HTTP, MCP
Second field (Tab / Ctrl+F, Esc order, a parse hint), the hit's page/moment as the engine says; HTTP `/search`,
`/context` and MCP `search_files` / `search_code` get `filter`; OpenAPI updated.
**Check:** the user tries it.
- **Built (2026-10-14)**, waiting for the user's try. Decided on the way:
  - *Panel*: a slimmer field under the main one (funnel icon, placeholder `Filter: Rechnung* AND (Uster OR
    Winterthur) NOT Mahnung`, a "?" that shows on hover or focus); the empty panel is 88 px instead of 56. Tab moves
    between the two fields only (Shift+Tab too), Ctrl+F goes to the filter with its text selected; ↓↑ ↩ Ctrl+↩
    Ctrl+L work from both. Esc: the syntax if it's open, then the filter (the keyboard goes back to the main field),
    then Like, then the panel. The filter is cleared when the panel opens again (the main field keeps its text, as
    before): a filter left over from the last look would hide files without saying so.
  - *Searching*: the main field as before, the filter sent along; typing in the filter searches once typing pauses
    (120 ms) without the at-once keyword pass, as its words match whole (a half-typed word finds nothing, a quote
    being typed would flash "read as plain words"). Main empty + filter: one keyword request, phase "filtered",
    footer "N files have the filter's words". `filter_note` shows under the filter (capitalized, amber).
  - *Ctrl+L*: the engine had no filter for `similar`, so it got one (`Searcher.similar(…, filter:)`, search-service
    `similar` `"filter"`, `digup similar --filter`): every file the filter allows that has a vector, by likeness, no
    gate (the weakest fold), each at its segment with the filter's words most like the file, the words marked.
  - *A hit*: the badge is the engine's page/moment; below the meaning gate the reason says where the filter's words
    are ("Has the filter's words on page 2", "… on screen" for a screenshot's OCR row, "Said at 0:25" for a
    transcript), else "Matches the filter" (name, folder or NOT only). A screenshot's OCR hit shows the picture, as
    the panel draws by the file's kind. The passage preview marks the excerpt's «» words too.
  - *Syntax help*: the "?" (or the filter focused while empty with nothing searched) shows A3's table in the
    preview's place.
  - *HTTP*: `filter` in `/search` (GET `?filter=`, POST body) and `/context` (body); `query` may be empty with a
    filter; replies carry `filter` and `filter_note`; OpenAPI: a `filter` property with the syntax, examples and
    request examples. *MCP*: `search_files` / `search_code` take `filter` (query optional with it), the syntax in its
    description, the result's heading says "filtered by …" and the note.
  - Debug runs: `--debug-filter EXPR` beside `--debug-query`; the report has the filter, its note and each row's badge.
- **Checked:** pytest (31), cargo test (51) + clippy, swift test; the panel's page in headless Chrome against a real
  search-service over the European testbed (Tauri's API stubbed): 22 steps (keys, help, filter-only, the note,
  query + filter, Ctrl+L with a filter, `code:`, reopening); the real shell (`--debug-query/--debug-filter`, a private
  session bus and XDG folders): `*kaution*` → p. 2 with its picture and "Open at p. 2", `ZK-4471` → the screenshot's
  picture; `digup-http`: `/search?q=&filter=*kaution*` → p. 2, `/context` with a filter → that page's text.
- Open: an integration with an older helper gets unfiltered results (the helper ignores `filter`); the README says
  so. A dev shell started with transcripts off takes an index's transcripts out (by design), so a dev run on a
  transcribed temp index needs Settings' transcripts on.

### F4 — Main-field fixes A6.2–A6.4, one at a time, measured.
- **Done (2026-10-15), all three kept.** Decided on the way:
  - *Rare words* (A6.2): coverage (gate 0.5 and bonus) weighs each query word by BM25's IDF over the index's files
    (`Searcher.weights`), no stopword lists added (the English, Bengali and Arabic ones stay). A word in no file counts
    as an average word for the bonus (else "black and white striped animal", where only "animal" is in a name, lost
    the zebra photo's #1) and as a word in one file at the gate (else "photo d'un perroquet" without "perroquet" let in
    every file with "un"). A query of only common words still ranks by them.
  - *Codes* (A6.3): a query word of two parts or more with a digit is one FTS phrase of its parts ("re 2041") when the
    index has that phrase, else its parts as before ("FA-1187" still finds the transcript's "FAM 1187"); then it's a
    lookup (`isLookup`). Marked as one in the snippet («RE 2041», `KeywordFilter.marks(of:in:)`). `Searcher.terms(_:)`
    without `keepingCodes` still gives the parts (the Mac app's highlights). Out of scope: a code typed with a space
    ("LX 1074").
  - *Kind words* (A6.4): de/fr/es/it/pt words and phrases ("capture d'écran", "nota de voz") compared without accents,
    whole words; dropped from the query's words as the English ones are, except "Aufnahme", "Film", "enregistrement",
    "registrazione" (everyday words too: a hint, and still words). "recording"/"voicemail" for English changed nothing
    and were left out. Bengali and Arabic unchanged.
- **Check:** 41 new european queries (`stopwords`, `code-twin`, `kind-word`; written for the fixes, so the 101 before
  are the fair test). The 101 before: R@1 0.891 and MRR 0.913 → 0.911 (R@5 0.950 → 0.941: "EXP-6083" was #5 by
  "exp*" matching "expediente"); european all 142: 0.859 / 0.958 / 0.900 → 0.915 / 0.951 / 0.930; synthetic,
  multilingual, code identical; 25 of 25 filter queries exact. Word-only intruders in the top 10 (no meaning match,
  not expected): 33 → 2 on the old european queries. Search speed unchanged on the testbed, a bit faster on the real
  index's copy. Numbers in `docs/linux-port/EVAL_RESULTS.md`.
- Open: rarity is the index's, so a language that's rare in an index keeps its common words rare; a vague query whose
  only word matches were common words now says "no good matches"; a meaning match still points at its own segment
  ("Offerten für die Sanierung des Bootsstegs" at 2:05).

### F5 — Docs: user guide cases ("Rechnung* NOT Mahnung", "*kaution*", a phrase), README, EVAL_RESULTS.
- **User guide, README, integrations README done (2026-10-14)** with F3: docs/USER_GUIDE_LINUX.md "Filter by exact
  words" (five cases checked on `synthetic/lang/eu`: `*kaution*`, `Versichertenkarte*`, `Rechnung* NOT Brunner` (the
  testbed has no "Mahnung"), `"Bahnhofstrasse 12"` with and without "Mietvertrag", `ZK-4471`), the key table (Tab,
  Ctrl+F, Esc); README's Linux table; integrations/README.md. EVAL_RESULTS with F4 (2026-10-15); the user guide's
  "How to ask" says rare words count more, codes match as written, and kind words work in de/fr/es/it/pt.
