import Foundation

public struct SearchHit: Sendable {
    public let path: String
    public let kind: FileKind
    public let score: Double          // fused rank score, for ordering only
    public let z: Double?             // how far the best segment stands out for this query (`Searcher.meaning`)
    public let cosine: Double?
    public let keywordRank: Int?      // 1-based rank among keyword matches
    public let segment: SegmentKind
    /// The segment the hit points at (its text is `Searcher.text(ofSegment:)`).
    public let segmentID: Int64
    public let loc: Double?           // PDF page, or seconds into audio/video
    public let locEnd: Double?
    public let excerpt: String?
    /// The file's modification date (seconds since 1970), and what indexing learned about it: "width", "height",
    /// "taken", "pages", "duration"… (see `Indexer`).
    public let modified: Double
    public let size: Int64
    public let info: [String: String]
    /// Code: the line to open at, in the stretch (`loc`…`locEnd`): where the name looked up is defined, or the first
    /// line with the query's words. Nil: the stretch's first line.
    public var focus: Double? = nil
    /// The segment with the words that go with this one, when it has none of its own: what OCR read off a screenshot
    /// whose picture matched, a page's text where its other vector matched (`Searcher.text(ofSegment:)` reads it).
    public var textSegmentID: Int64? = nil
}

/// Hybrid search: meaning (EmbeddingGemma's vectors) + words (FTS5).
///
/// Meaning is the model's cosine similarity, put on one scale per query (`meaning`): every vector is scored anyway, so
/// the distribution comes for free, and only segments that stand out (`zGate`) count as meaning matches. That also
/// gives an honest "nothing found". Words rescue what a vector can't hold exactly: codes, IDs and names.
public final class Searcher {
    let store: IndexStore
    private var matrix: VectorStorage?   // rows × 768 float16, row-major
    private var rowFile: [Int64] = []
    private var rowSegment: [Int64] = []
    private var rowModality: [Modality] = []
    /// False for the vectors the later pass adds (`Indexer.finishLongFiles`): scored, but they don't set the scale.
    private var rowSetsScale: [Bool] = []
    private var fileKind: [Int64: FileKind] = [:]
    public private(set) var vectorSource: String?
    /// False after `releaseVectors()` (or `loadVectors: false`): keyword search still works, and the next search with
    /// a query vector loads them again.
    public private(set) var vectorsLoaded = false

    public var vectorCount: Int { rowFile.count }

    /// This is the code index's searcher (`IndexStore.codeFile`): names are looked up as names (`CodeLookup`).
    public var isCode: Bool { store.file.lastPathComponent == IndexStore.codeFile }

    /// With `loadVectors: false` only keyword search is ready; vectors load on the first meaning search. The app
    /// uses that to stay small while idle: 20k vectors are ~30 MB.
    public init(store: IndexStore, loadVectors: Bool = true) throws {
        self.store = store
        if loadVectors { try reload() } else { try reloadFiles() }
    }

    /// Reads the files and all vectors again (after indexing added some).
    public func reload() throws {
        releaseVectors()
        try reloadFiles()
        var rows = 0
        try store.db.query("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL") { rows = Int($0.int(0)) }
        guard let matrix = VectorStorage(rows: rows) else {
            vectorsLoaded = true   // nothing to load
            return
        }
        let rowBytes = Vectors.dimension * MemoryLayout<Float16>.stride
        let steps = IndexOptions()
        try store.db.query("""
            SELECT s.id, s.file, s.modality, s.vec, s.kind, s.loc, f.kind, CAST(json_extract(f.info, '$.pages') AS INTEGER)
            FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL ORDER BY s.id
            """) { row in
            guard let blob = row.blob(3), blob.count == rowBytes, rowFile.count < rows else { return }
            blob.copyBytes(to: UnsafeMutableRawBufferPointer(start: matrix.halves + rowFile.count * Vectors.dimension,
                                                             count: rowBytes))
            rowSegment.append(row.int(0))
            rowFile.append(row.int(1))
            rowModality.append(Modality(rawValue: row.text(2) ?? "") ?? .none)
            // Past the first step of a long PDF (its pages) or document (its chunks).
            let (kind, place) = (row.text(4), row.isNull(5) ? 0 : Int(row.double(5)))
            let later = row.text(6) == "pdf"
                ? kind != SegmentKind.chunk.rawValue && Int(row.int(7)) > steps.bigPDFPages && place > steps.pdfStep
                : kind == SegmentKind.chunk.rawValue && place > steps.docStep
            rowSetsScale.append(!later)
        }
        self.matrix = matrix
        vectorsLoaded = true
    }

    /// Frees the vectors' memory; keyword search keeps working.
    public func releaseVectors() {
        matrix = nil
        rowFile = []
        rowSegment = []
        rowModality = []
        rowSetsScale = []
        vectorsLoaded = false
    }

    private func reloadFiles() throws {
        fileKind.removeAll(keepingCapacity: true)
        try store.db.query("SELECT id, kind FROM files") { row in
            fileKind[row.int(0)] = FileKind(rawValue: row.text(1) ?? "")
        }
        vectorSource = try store.meta("vector_source")
    }

    /// How much finding the query's words counts against meaning (`search`). Code's words count for less: they're
    /// everywhere in code ("app", "running", "location"), and a stretch that shares a few of them beat the one that
    /// does what the query says (2026-10-09, the real-code eval of 27 queries over DigUp, Sparkle and llama.cpp: 18 → 20
    /// found first, the top 5 unchanged; the synthetic code eval 40 → 41 of 41; 1.5 changed nothing, 0.5 lost the top 5).
    public static let wordWeight = 2.0
    public static let codeWordWeight = 1.0

    /// `folders`: only files inside them (nil or empty: everywhere), applied before the limit, so a search of one
    /// folder still fills `limit` from inside it.
    ///
    /// `filter` (`KeywordFilter`, the field beside the search field) decides which files appear, and `text` ranks them
    /// as it ranks any search, except that no gate drops one: every file the filter holds for is a result, the ones
    /// that match `text` least at the end (where the app folds them, `strongCount`). With `text` empty they're ranked by
    /// how well the filter's words match (bm25), then by date. A hit points at a segment with the filter's words: the
    /// one that fits `text` best, or with `text` empty the best match for the filter (`filterSegment`).
    public func search(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>? = nil, limit: Int = 20,
                       zGate: Double = 2.0, wordWeight: Double? = nil, prefixLast: Bool = false,
                       folders: [String]? = nil, filter keywordFilter: KeywordFilter? = nil) throws -> [SearchHit] {
        let wordWeight = wordWeight ?? (isCode ? Self.codeWordWeight : Self.wordWeight)
        let keywordFilter = keywordFilter?.expression == nil ? nil : keywordFilter
        // A filter alone ranks by its own words. (Without one, a vector with no words is a search by meaning alone.)
        let mainEmpty = keywordFilter != nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let queryVector = mainEmpty ? nil : queryVector
        if queryVector != nil, !vectorsLoaded { try reload() }
        let place = try Place(folders, in: store)
        let allowed = filter(kinds: kinds, place: place)
        let filtered = try keywordFilter.map { keywords in
            try FilterMatch(keywords, store: store, universe: Set(fileKind.keys.filter(allowed)))
        }

        // Meaning: score every vector on this query's scale (`meaning`), keep each file's best segment.
        var best: [Int64: (z: Double, cosine: Double, row: Int)] = [:]
        var segmentZ: [Int64: Double] = [:]   // of the segments with the filter's words
        if let query = queryVector, query.count == Vectors.dimension, !rowFile.isEmpty {
            let scores = score(query)
            let meaning = Self.meaning(scores, rowModality, setsScale: rowSetsScale)
            for row in 0..<scores.count where allowed(rowFile[row]) {
                let z = meaning[row]
                if z > (best[rowFile[row]]?.z ?? -.infinity) { best[rowFile[row]] = (z, Double(scores[row]), row) }
                if let filtered, filtered.segments[rowFile[row]]?[rowSegment[row]] != nil {
                    segmentZ[rowSegment[row]] = z
                }
            }
        }

        // Words: FTS5 with Porter stemming over file names, folder names, OCR, page and document text. A name from code
        // ("quantize_row_q8_0_ref") is matched as one phrase, as it's written. So is a code ("RE-2041") that's in the
        // index as written; one that isn't is its parts, as before (`terms`).
        let identifier = isCode ? CodeLookup.identifier(text) : nil
        let terms = try Self.terms(text, keepingCodes: { try isIndexed("\"\($0)\"") })
        var words: [(file: Int64, segment: Int64, snippet: String?)] = []
        var coverage: [Int64: Double] = [:]   // share of the query's words found anywhere in the file
        var gateShare = 1.0   // what `coverage` is worth at the gate (`weights`)
        var patterns = identifier.map { [CodeLookup.phrase($0)] } ?? Self.patterns(terms, prefixLast: prefixLast)
        // A word that's in no file as typed matches as the start of longer words, as the last word does while it's
        // being typed: "grok" finds "Grok4" and "Grokipedia" (stemming only covers endings, as in "grokking").
        // Otherwise a file the panel showed while you typed dropped out once you stopped. A word that is in the index
        // as typed stays whole, so "cat" doesn't bring in "category"; so does a word of two letters, the start of too
        // many words to stand for one.
        if identifier == nil {
            for index in terms.indices where terms[index].count >= 3 && !patterns[index].hasSuffix("*") {
                if try !isIndexed(patterns[index]) { patterns[index] += "*" }
            }
        }
        if !patterns.isEmpty {
            var seen = Set<Int64>()
            // In folders, the matches outside them are left out by SQLite, so the best 1,000 are all inside.
            try store.db.query("""
                SELECT s.file, s.id, snippet(fts, 1, '«', '»', '…', 12), fts.original, fts.body FROM fts
                JOIN segments s ON s.id = fts.rowid\(place.map { " JOIN files f ON f.id = s.file AND \($0.sql)" } ?? "")
                WHERE fts MATCH ? ORDER BY bm25(fts, 3.0, 1.0) LIMIT 1000
                """, (place?.values ?? []) + [.text(patterns.joined(separator: " OR "))]) { row in
                let file = row.int(0)
                guard words.count < 100, allowed(file), filtered?.files.contains(file) ?? true,
                      seen.insert(file).inserted else { return }
                // Text that normalizing changed is quoted as it's written (with its hamza, harakat, joiners), and so is
                // a code, marked as one («RE-2041»).
                let written = row.text(3) ?? (terms.contains { $0.contains(" ") } ? row.text(4) : nil)
                let snippet = written.flatMap { SearchText.snippet($0, marks: Self.marks(of: terms, in: $0)) }
                    ?? row.text(2)
                words.append((file, row.int(1), snippet))
            }
            // Each word counts by how rare it is in the index (`weights`): "die", "für", "de", "la" are in many files
            // and count little, in every language, where a stopword list would collide ("die", "war", "will"). With a
            // filter, every file it holds for is ranked, also those beyond the best 100 keyword matches.
            if !words.isEmpty || filtered != nil {
                let within = Set(words.map(\.file))
                let found = try patterns.map { pattern in
                    var files = Set<Int64>()
                    try store.db.query("""
                        SELECT DISTINCT s.file FROM fts JOIN segments s ON s.id = fts.rowid WHERE fts MATCH ?
                        """, [.text(pattern)]) { files.insert($0.int(0)) }
                    return files
                }
                let weights = Self.weights(found.map(\.count), of: fileKind.count)
                let total = weights.rank.reduce(0, +)
                gateShare = total / weights.gate.reduce(0, +)
                for (files, weight) in zip(found, weights.rank) {
                    for file in files where filtered?.files.contains(file) ?? within.contains(file) {
                        coverage[file, default: 0] += weight / total
                    }
                }
            }
        }

        // A file qualifies by standing out in meaning, or by containing at least half of the query's words.
        // Score: meaning z + a bonus that grows with word coverage, + 1 for the kind the query asks for.
        // One common word can't beat a strong meaning match; all the words of an exact lookup usually do.
        // (This beat reciprocal-rank fusion on both evals, 2026-10-07: R@1 0.88 vs 0.73 synthetic, 0.86 vs 0.82 real.)
        let lookup = Self.isLookup(terms) || identifier != nil
        let (meaningWeight, wordsWeight) = lookup ? (0.5, wordWeight * 2) : (1, wordWeight)
        let hinted = Self.kindHints(text)
        var candidates = Set(best.filter { $0.value.z >= zGate }.keys)
        for (file, share) in coverage where share * gateShare >= 0.5 { candidates.insert(file) }
        if let filtered { candidates = filtered.files }   // no gate: the filter says which
        var scored: [Int64: Double] = [:]
        for file in candidates {
            var score = meaningWeight * max(best[file]?.z ?? 0, 0) + wordsWeight * pow(coverage[file] ?? 0, 1.5)
            if let kind = fileKind[file], hinted.contains(kind) { score += 1 }
            scored[file] = score
        }

        var ranked = scored.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) })
        if let filtered {
            ranked = try Self.rank(filtered, scored: scored, best: best, mainEmpty: mainEmpty, in: store)
        }
        let wordRank = Dictionary(words.enumerated().map { ($0.element.file, ($0.offset + 1, $0.element)) },
                                  uniquingKeysWith: { first, _ in first })
        var hits: [SearchHit] = []
        for (file, score) in ranked.prefix(limit) {
            let rank = hits.count
            let semantic = best[file]
            let keyword = wordRank[file]
            // Point at the best meaning segment if it stands out; else at the segment the words matched.
            let useMeaning = semantic.map { $0.z >= zGate || keyword == nil } ?? false
            var segmentID: Int64
            if let filtered {
                segmentID = try filterSegment(file, filtered, segmentZ: queryVector == nil ? nil : segmentZ,
                                              meaning: semantic.map { rowSegment[$0.row] }, words: keyword?.1.segment)
            } else {
                guard let pointed = useMeaning ? semantic.map({ rowSegment[$0.row] }) : keyword?.1.segment else { continue }
                segmentID = pointed
            }
            var focus: Double?
            if isCode {
                // Where a name is defined is looked for in the first 10 results only: a name used all over a big repo
                // (ggml_tensor) is in hundreds of stretches of every file that has it (2026-10-09, llama.cpp and two
                // more repos: 560 → 100 ms a search; the others take 10–50 ms). With a filter, only where none of the
                // stretches has its words: the hit stays on one that has, and opens at the first line with them.
                let lookUp = rank < 10 && (filtered?.segments[file]?.isEmpty ?? true)
                let parts = terms.flatMap { $0.split(separator: " ").map(String.init) }   // a code's parts
                (segmentID, focus) = try codePlace(file: file, segment: segmentID, identifier: lookUp ? identifier : nil,
                                                   query: text, terms: parts,
                                                   wordsHere: keyword?.1.segment == segmentID || identifier != nil)
                if let keywordFilter, filtered?.segments[file]?[segmentID] != nil,
                   let line = try filterLine(segmentID, keywordFilter) {
                    focus = Double(line)
                }
            }
            let about = try self.file(file)
            let (segment, loc, locEnd, storedExcerpt) = try self.segment(segmentID)
            // Quote the matched words only when they come from the segment we point at, so a PDF hit on page 5
            // never shows page 2's words. A segment with no place and no text of its own (a screenshot's image
            // vector) can borrow them from its file's OCR text, which describes the same picture. With a filter, its
            // words are the ones marked.
            var snippet = keyword.flatMap { $0.1.segment == segmentID ? $0.1.snippet : nil }
                .flatMap { $0.contains("«") ? excerpt($0, limit: 400) : nil }
            if let keywordFilter, filtered?.segments[file]?[segmentID] != nil, let words = try self.text(ofSegment: segmentID),
               let marked = SearchText.snippet(words, marks: keywordFilter.marks(in: words)) {
                snippet = excerpt(marked, limit: 400)
            }
            if snippet == nil, storedExcerpt == nil, loc == nil, let match = keyword?.1,
               let text = match.snippet, text.contains("«") {
                var matchedKind: String?
                try store.db.query("SELECT kind FROM segments WHERE id = ?", [.int(match.segment)]) {
                    matchedKind = $0.text(0)
                }
                if matchedKind != SegmentKind.name.rawValue { snippet = excerpt(text, limit: 400) }
            }
            hits.append(SearchHit(path: about.path, kind: about.kind, score: score, z: semantic?.z,
                                  cosine: semantic?.cosine, keywordRank: keyword?.0, segment: segment,
                                  segmentID: segmentID, loc: loc, locEnd: locEnd, excerpt: snippet ?? storedExcerpt,
                                  modified: about.modified, size: about.size, info: about.info, focus: focus,
                                  textSegmentID: try textSegment(of: segmentID, kind: segment, file: file, loc: loc)))
        }
        return hits
    }

    /// The order of a filter's files (`search`). With a main query: its score, then meaning below the gate (`best`'s
    /// z, also when it's under 0 and adds nothing to the score), then how well the filter's words match. Without one:
    /// how well the filter's words match (bm25 of its words, phrases and prefixes; a file found only by a suffix, an
    /// infix or a NOT comes after those), then the newest first; scores from 2 down to just over 1, so the app folds
    /// none of them (each matches the filter as much as any other).
    static func rank(_ filtered: FilterMatch, scored: [Int64: Double], best: [Int64: (z: Double, cosine: Double, row: Int)],
                     mainEmpty: Bool, in store: IndexStore) throws -> [(key: Int64, value: Double)] {
        let words = { (file: Int64) in filtered.fileRank[file] ?? .infinity }
        guard mainEmpty else {
            return scored.sorted { a, b in
                let (za, zb) = (best[a.key]?.z ?? -.infinity, best[b.key]?.z ?? -.infinity)
                if a.value != b.value { return a.value > b.value }
                if za != zb { return za > zb }
                if words(a.key) != words(b.key) { return words(a.key) < words(b.key) }
                return a.key < b.key
            }
        }
        var modified: [Int64: Double] = [:]
        try store.db.query("SELECT id, mtime FROM files") { row in
            if filtered.files.contains(row.int(0)) { modified[row.int(0)] = row.double(1) }
        }
        let order = filtered.files.sorted { a, b in
            if words(a) != words(b) { return words(a) < words(b) }
            if modified[a] != modified[b] { return modified[a] ?? 0 > modified[b] ?? 0 }
            return a < b
        }
        return order.enumerated().map { ($0.element, 2 - Double($0.offset) / Double(order.count)) }
    }

    /// The segment a filter's hit points at: of the file's segments with a positive term, the one that fits the main
    /// query best (`segmentZ`, nil without a query vector: then the one the query's words matched, if it's among them),
    /// then the one with most of the filter's terms, then its best bm25, then the first. A recording's moment, a PDF's
    /// page, a document's part. When only the file's name or folder matched: the meaning's own segment, else the words',
    /// else the name's row.
    private func filterSegment(_ file: Int64, _ filtered: FilterMatch, segmentZ: [Int64: Double]?, meaning: Int64?,
                               words: Int64?) throws -> Int64 {
        if let matched = filtered.segments[file], !matched.isEmpty {
            func key(_ segment: Int64) -> (Double, Int, Double, Int64) {
                let fit = segmentZ.map { $0[segment] ?? -.infinity } ?? (segment == words ? 1 : 0)
                return (fit, matched[segment] ?? 0, -(filtered.segmentRank[segment] ?? .infinity), -segment)
            }
            return matched.keys.max { key($0) < key($1) }!
        }
        if let segment = meaning ?? words { return segment }
        var name: Int64 = 0
        try store.db.query("SELECT id FROM segments WHERE file = ? AND kind = 'name'", [.int(file)]) { name = $0.int(0) }
        return name
    }

    /// Code: the first line of a stretch with the filter's words (`*_delay` in "base_delay"), as the file numbers it.
    private func filterLine(_ segment: Int64, _ filter: KeywordFilter) throws -> Int? {
        guard let text = try text(ofSegment: segment) else { return nil }
        var first = 1
        try store.db.query("SELECT loc FROM segments WHERE id = ?", [.int(segment)]) { first = Int($0.double(0)) }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        return lines.firstIndex { !filter.marks(in: String($0)).isEmpty }.map { first + $0 }
    }

    /// The segment whose words go with `segment` when it has none of its own (`SearchHit.textSegmentID`): a
    /// screenshot's OCR beside its picture, or the page whose picture holds the text when the page's other vector
    /// (from garbled words) is the one that matched. Only pictures and pages can have one.
    private func textSegment(of segment: Int64, kind: SegmentKind, file: Int64, loc: Double?) throws -> Int64? {
        guard [.image, .page, .pageImage].contains(kind) else { return nil }
        var hasWords = false
        try store.db.query("SELECT 1 FROM fts WHERE rowid = ?", [.int(segment)]) { _ in hasWords = true }
        guard !hasWords else { return nil }
        var found: Int64?
        try store.db.query("""
            SELECT s.id FROM segments s JOIN fts ON fts.rowid = s.id
            WHERE s.file = ? AND s.id != ? AND s.kind IN ('ocr', 'page', 'page_image') AND s.loc IS ? LIMIT 1
            """, [.int(file), .int(segment), loc.map { .double($0) } ?? .null]) { found = $0.int(0) }
        return found
    }

    // MARK: Similar files

    /// The index's rows for the file at `path`, spelled as given or as the disk spells it (`IndexStore.pathRanges`).
    /// Empty when it isn't indexed.
    public func files(at path: String) throws -> Set<Int64> {
        var ids = Set<Int64>()
        let real = FolderSelection.realPath(path)
        for spelling in real.utf8.elementsEqual(path.utf8) ? [path] : [path, real] {
            try store.db.query("SELECT id FROM files WHERE path = ?", [.text(spelling)]) { ids.insert($0.int(0)) }
        }
        return ids
    }

    /// One vector for files already in the index: the mean of their vectors, made unit length again. It stands for the
    /// whole file (every page of a PDF, a video's frames and its sound), so files like any part of it come up, and it
    /// needs no model. Nil when they have no vectors (not embedded yet, or skipped).
    public func storedVector(of files: Set<Int64>) throws -> [Float]? {
        guard !files.isEmpty else { return nil }
        if !vectorsLoaded { try reload() }
        guard let matrix else { return nil }
        var sum = [Float](repeating: 0, count: Vectors.dimension), count = 0
        for row in rowFile.indices where files.contains(rowFile[row]) {
            let halves = matrix.halves + row * Vectors.dimension
            for index in sum.indices { sum[index] += Float(halves[index]) }
            count += 1
        }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return count > 0 && norm > 0 ? sum.map { $0 / norm } : nil
    }

    /// How far a file must stand out to be like another (`similar`): less than a search's 2. A file is a fuller query
    /// than a few words, and like goes with like everywhere (every photo is a bit like every other), so the right
    /// neighbours stand out less: on the testbed (2026-10-14) they came at z 1.5–4 (a cat's photo: the other animals and
    /// the zoo videos, 1.3–2.3; a Tokyo itinerary: the flight booking screenshot, 3.9), and unrelated files mostly
    /// below 1.
    public static let similarZGate = 1.0

    /// Files like the one `vector` stands for (`storedVector`, or `FileVector` for a file that isn't indexed): meaning
    /// alone, on a search's scale (`meaning`), each file at its segment most like it, best first. Only files that stand
    /// out (`zGate`) count, so "nothing much like it" is an answer too. `excluding`: the file itself (`files(at:)`),
    /// always the most like itself. `kinds` and `folders` as in `search`.
    ///
    /// `filter` (the field beside the search field) keeps it to the files whose text has it, as in `search`: every one
    /// of them with a vector is a result, ranked by how like the file it is, below the gate too (the weakest are folded
    /// by `strongCount`), each at its segment with the filter's words that's most like the file.
    public func similar(to vector: [Float], excluding: Set<Int64> = [], kinds: Set<FileKind>? = nil,
                        folders: [String]? = nil, limit: Int = 20, zGate: Double = Searcher.similarZGate,
                        filter keywordFilter: KeywordFilter? = nil) throws -> [SearchHit] {
        guard vector.count == Vectors.dimension else { return [] }
        if !vectorsLoaded { try reload() }
        let keywordFilter = keywordFilter?.expression == nil ? nil : keywordFilter
        let inScope = filter(kinds: kinds, place: try Place(folders, in: store))
        let filtered = try keywordFilter.map { keywords in
            try FilterMatch(keywords, store: store, universe: Set(fileKind.keys.filter(inScope)))
        }
        let allowed = { (file: Int64) in inScope(file) && (filtered?.files.contains(file) ?? true) }
        let scores = score(vector)
        // The file's own vectors are left out of the scale too: they're all close to it (a book's hundred pages to their
        // mean), and they lifted the average of their modality over everything else.
        var setsScale = rowSetsScale
        for row in rowFile.indices where excluding.contains(rowFile[row]) { setsScale[row] = false }
        let meaning = Self.meaning(scores, rowModality, setsScale: setsScale)
        var best: [Int64: (z: Double, row: Int)] = [:]
        var segmentZ: [Int64: Double] = [:]   // of the segments with the filter's words
        for row in scores.indices where !excluding.contains(rowFile[row]) && allowed(rowFile[row]) {
            if meaning[row] > (best[rowFile[row]]?.z ?? -.infinity) { best[rowFile[row]] = (meaning[row], row) }
            if let filtered, filtered.segments[rowFile[row]]?[rowSegment[row]] != nil {
                segmentZ[rowSegment[row]] = max(segmentZ[rowSegment[row]] ?? -.infinity, meaning[row])
            }
        }
        return try best.filter { filtered != nil || $0.value.z >= zGate }
            .sorted { $0.value.z > $1.value.z || ($0.value.z == $1.value.z && $0.key < $1.key) }
            .prefix(limit).map { file, match in
                let about = try self.file(file)
                var segmentID = rowSegment[match.row]
                if let filtered {
                    segmentID = try filterSegment(file, filtered, segmentZ: segmentZ, meaning: segmentID, words: nil)
                }
                let segment = try self.segment(segmentID)
                var snippet = segment.excerpt
                if let keywordFilter, filtered?.segments[file]?[segmentID] != nil,
                   let words = try self.text(ofSegment: segmentID),
                   let marked = SearchText.snippet(words, marks: keywordFilter.marks(in: words)) {
                    snippet = excerpt(marked, limit: 400)
                }
                return SearchHit(path: about.path, kind: about.kind, score: match.z, z: match.z,
                                 cosine: Double(scores[match.row]), keywordRank: nil, segment: segment.kind,
                                 segmentID: segmentID, loc: segment.loc, locEnd: segment.locEnd,
                                 excerpt: snippet, modified: about.modified, size: about.size, info: about.info,
                                 textSegmentID: try textSegment(of: segmentID, kind: segment.kind, file: file,
                                                                loc: segment.loc))
            }
    }

    /// The folders a search is kept to: the files under them, for meaning (every vector is scored anyway, and the
    /// ones outside are passed over, as other kinds are), and the SQL that keeps keyword matches to them (`f` is the
    /// files table). Each folder is looked up by its path's range in the index, in each of its spellings
    /// (`IndexStore.pathRanges`: /var and /private/var, a name decomposed and as the disk keeps it), so "inside" means
    /// on a component boundary: /a/b holds /a/b/c.png, not /a/bc.png.
    ///
    /// The meaning scale stays the whole index's: the few files of one folder would make a scale of their own out of
    /// too few scores, and a match has to stand out among everything, as it does without folders.
    struct Place {
        let files: Set<Int64>
        let sql: String
        let values: [SQLValue]

        init?(_ folders: [String]?, in store: IndexStore) throws {
            guard let folders, !folders.isEmpty else { return nil }
            let ranges = folders.flatMap(IndexStore.pathRanges(under:))
            sql = "(" + ranges.map { _ in "(f.path >= ? AND f.path < ?)" }.joined(separator: " OR ") + ")"
            values = ranges.flatMap { [SQLValue.text($0.from), .text($0.to)] }
            var files = Set<Int64>()
            try store.db.query("SELECT f.id FROM files f WHERE \(sql)", values) { files.insert($0.int(0)) }
            self.files = files
        }
    }

    /// Whether a file may be a result: one of `kinds` (nil: any), in `place` (nil: anywhere).
    private func filter(kinds: Set<FileKind>?, place: Place?) -> (Int64) -> Bool {
        let fileKind = self.fileKind
        return { file in
            (kinds == nil || fileKind[file].map { kinds!.contains($0) } ?? false)
                && (place?.files.contains(file) ?? true)
        }
    }

    /// What a hit says about its file.
    private func file(_ id: Int64) throws -> (path: String, kind: FileKind, modified: Double, size: Int64,
                                              info: [String: String]) {
        var about = (path: "", kind: FileKind.doc, modified: 0.0, size: Int64(0), info: [String: String]())
        try store.db.query("SELECT path, kind, mtime, size, info FROM files WHERE id = ?", [.int(id)]) {
            about.path = $0.text(0) ?? ""
            about.kind = FileKind(rawValue: $0.text(1) ?? "") ?? .doc
            about.modified = $0.double(2)
            about.size = $0.int(3)
            if let json = $0.text(4)?.data(using: .utf8) {
                about.info = (try? JSONSerialization.jsonObject(with: json) as? [String: String]) ?? [:]
            }
        }
        return about
    }

    /// What a hit says about the segment it points at.
    private func segment(_ id: Int64) throws -> (kind: SegmentKind, loc: Double?, locEnd: Double?, excerpt: String?) {
        var segment = (kind: SegmentKind.name, loc: Double?.none, locEnd: Double?.none, excerpt: String?.none)
        try store.db.query("SELECT kind, loc, loc_end, excerpt FROM segments WHERE id = ?", [.int(id)]) {
            segment.kind = SegmentKind(rawValue: $0.text(0) ?? "") ?? .name
            segment.loc = $0.isNull(1) ? nil : $0.double(1)
            segment.locEnd = $0.isNull(2) ? nil : $0.double(2)
            segment.excerpt = $0.text(3)
        }
        return segment
    }

    /// Code: the stretch to point at, and the line in it to open at. A name looked up points at the stretch that
    /// defines it, when one does (not the ones that call it). Otherwise the line is the first with the query's words,
    /// when they matched in this stretch; a match by meaning alone opens at the stretch's first line.
    private func codePlace(file: Int64, segment: Int64, identifier: [String]?, query: String, terms: [String],
                           wordsHere: Bool) throws -> (Int64, Double?) {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "()", with: "")
        if let identifier {
            var best: (segment: Int64, line: Int, strength: Int)?
            try store.db.query("""
                SELECT s.id, s.loc, coalesce(fts.original, fts.body) FROM fts JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ? AND s.file = ? ORDER BY s.loc LIMIT 300
                """, [.text(CodeLookup.phrase(identifier)), .int(file)]) { row in
                guard best?.strength ?? 0 < 2, let text = row.text(2),
                      let found = CodeLookup.definition(of: name, in: text, first: Int(row.double(1))) else { return }
                if found.strength > (best?.strength ?? 0) { best = (row.int(0), found.line, found.strength) }
            }
            if let best { return (best.segment, Double(best.line)) }
        }
        guard wordsHere || identifier != nil, let text = try text(ofSegment: segment) else { return (segment, nil) }
        var first = 1
        try store.db.query("SELECT loc FROM segments WHERE id = ?", [.int(segment)]) { first = Int($0.double(0)) }
        let words = identifier == nil ? terms : [name.lowercased()]
        return (segment, CodeLookup.firstLine(with: words, in: text, first: first).map(Double.init))
    }

    /// Codes and IDs ("K7Q2LM", "TRX50") and long numbers ("4815162342": an order, a phone number) mean nothing to an
    /// embedding but everything to keyword search: a query made of them weighs words double and meaning half. Numbers
    /// count since 2026-10-09, when text of digits lost its vectors (`SearchText.hasWords`): a number in a data dump fell
    /// below unrelated meaning matches.
    static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    /// How many of `hits` (best first) are strong: scoring at least `ratio` × the top hit. The rest pass the gates but
    /// trail far behind, and the app folds them under "weaker matches". On both evals (2026-10-07), 0.5 cut the list
    /// from 26.2 to 5.7 results per query and never folded an expected answer.
    public static func strongCount(_ hits: [SearchHit], ratio: Double = 0.5) -> Int {
        guard let top = hits.first?.score, top > 0 else { return hits.count }
        return hits.prefix { $0.score >= top * ratio }.count
    }

    /// Cosine similarity of `query` with every stored vector (all are L2-normalized): a matrix-vector product, done a
    /// block of rows at a time, each block turned into float32 first.
    private func score(_ query: [Float]) -> [Float] {
        let rows = rowFile.count
        var scores = [Float](repeating: 0, count: rows)
        guard let matrix, rows > 0 else { return scores }
        query.withUnsafeBufferPointer { query in
            scores.withUnsafeMutableBufferPointer { scores in
                var row = 0
                while row < rows {
                    let count = min(VectorStorage.blockRows, rows - row)
                    Vectors.floats(fromHalf: matrix.halves + row * Vectors.dimension, count: count * Vectors.dimension,
                                   to: matrix.block)
                    // (count × 768) · (768 × 1)
                    Vectors.scores(of: matrix.block, count: count, query: query.baseAddress!,
                                   into: scores.baseAddress! + row)
                    row += count
                }
            }
        }
        return scores
    }

    /// This query's meaning scores: each vector's cosine similarity minus the average of its modality (text, image and
    /// audio vectors can sit at slightly different levels for the same query), in standard deviations of all of them
    /// together. Within a modality that's the model's own order. Scaling each modality by its own deviation instead
    /// inflated the narrow ones and buried PDF pages under pictures (2026-10-08, on the three evals: 91 → 94 of 105
    /// queries with the right answer first).
    ///
    /// The scale (the averages and the deviation) comes from the vectors in `setsScale` (all by default): `search` leaves
    /// out the later pages of long files, which are scored on it but don't move it. A book's hundreds of pages pulled the
    /// text average down for every query, and documents rose over screenshots everywhere (2026-10-09, the testbed's long
    /// files finished: real eval 24 → 22 of 26 first; 24 with the scale kept).
    static func meaning(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Double] {
        let means = modalityMeans(scores, modality, setsScale: setsScale)
        let centered = zip(scores, modality).map { Double($0) - means[$1, default: 0] }
        var count = 0.0, sum = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            count += 1
            sum += centered[row]
        }
        let mean = sum / max(count, 1)
        var squares = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            squares += (centered[row] - mean) * (centered[row] - mean)
        }
        let deviation = max((squares / max(count, 1)).squareRoot(), 0.02)
        return centered.map { ($0 - mean) / deviation }
    }

    /// The average score of each modality for this query. Small groups (< 20 vectors) take the average of all.
    static func modalityMeans(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Modality: Double] {
        var sum: [Modality: Double] = [:], count: [Modality: Int] = [:]
        for row in scores.indices where setsScale?[row] ?? true {
            sum[modality[row], default: 0] += Double(scores[row])
            count[modality[row], default: 0] += 1
        }
        let all = sum.values.reduce(0, +) / Double(max(count.values.reduce(0, +), 1))
        var out: [Modality: Double] = [:]
        for modality in Modality.allCases {
            if let n = count[modality], n >= 20 {
                out[modality] = sum[modality]! / Double(n)
            } else {
                out[modality] = all
            }
        }
        return out
    }

    /// The text of a page, a document's passage or a screenshot's OCR, as it's written: the preview shows the part of a
    /// document that matched.
    public func text(ofSegment id: Int64) throws -> String? {
        var text: String?
        try store.db.query("SELECT coalesce(original, body) FROM fts WHERE rowid = ?", [.int(id)]) { text = $0.text(0) }
        return text
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "photo", "photos", "picture", "image", "images",
        "screenshot", "screenshots", "video", "videos", "pdf", "document", "documents", "recording",
        // Bengali and Arabic (normalized, as `terms` sees them)
        "এবং", "ও", "এই", "সেই", "একটি", "আমার", "থেকে", "জন্য", "সাথে", "মধ্যে", "কোথায়", "কোন", "কী", "কি", "যে",
        "ছবি", "স্ক্রিনশট", "ভিডিও", "ফাইল", "পিডিএফ",
        "في", "من", "على", "الى", "عن", "مع", "هذا", "هذه", "ذلك", "التي", "الذي", "اين", "ما",
        "صورة", "صور", "لقطة", "شاشة", "فيديو", "ملف", "مستند",
    ]

    /// The content words of a query, normalized as keyword search keeps its text (`SearchText`). Kind words
    /// ("screenshot", "video", "Bildschirmfoto", "capture d'écran") and stopwords are dropped: they describe what to
    /// look for, not what's in it. Words of two letters or more count; a Bengali letter with its vowel sign ("মা") is
    /// two.
    ///
    /// A code (`codeParts`: "RE-2041", "2380.50") is its parts, unless `keepingCodes` says to keep it whole: then it's
    /// one term, its parts joined by spaces ("re 2041"), which keyword search matches as a phrase (`search` keeps the
    /// codes that are in the index as written, so "RE-2041" no longer finds "INV-2041" by its 2041).
    public static func terms(_ text: String) -> [String] { terms(text, keepingCodes: { _ in false }) }

    /// The same, `keep` saying which codes stay whole.
    public static func terms(_ text: String, keepingCodes keep: (String) throws -> Bool) rethrows -> [String] {
        let tokens = SearchText.normalized(text).lowercased().split(whereSeparator: \.isWhitespace).map {
            $0.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let kinds = kindWordsIn(tokens.flatMap { $0 })
        var seen = Set<String>(), out: [String] = [], position = 0
        for parts in tokens {
            let dropped = parts.indices.map { kinds.dropped.contains(position + $0) }
            position += parts.count
            if !dropped.contains(true), let code = codeParts(parts), try keep(code) {
                if seen.insert(code).inserted { out.append(code) }
                continue
            }
            for (part, drop) in zip(parts, dropped) where !drop && part.unicodeScalars.count >= 2
                && !stopwords.contains(part) && seen.insert(part).inserted {
                out.append(part)
            }
        }
        return out
    }

    /// A query word's parts (split where keyword search splits words) as one code, when it is one: two parts or more
    /// and a digit among them ("re 2041" for RE-2041, "2380 50" for 2'380.50, "of 2026 118"). Words without a digit
    /// ("e-mail", "l'école") stay words. A code typed with a space ("LX 1074") is two words.
    static func codeParts(_ parts: [String]) -> String? {
        guard parts.count >= 2, parts.contains(where: { $0.contains(where: \.isNumber) }) else { return nil }
        return parts.joined(separator: " ")
    }

    /// Where `terms` (words, and codes as their parts joined by spaces) are in `text`, as ranges of the text as it's
    /// written: a code from its first part to its last («RE-2041»).
    static func marks(of terms: [String], in text: String) -> [Range<String.Index>] {
        KeywordFilter.marks(of: terms.map { KeywordFilter.Term(.words, $0.components(separatedBy: " ")) }, in: text)
    }

    /// How much each of a query's words counts in `search`'s coverage, from the number of files that have it
    /// (`files`) among the index's `total`: the rarer, the more. BM25's inverse document frequency, which stays above
    /// 0, so a query of only common words still ranks by them.
    ///
    /// A word in no file counts two ways. For the ranking (`rank`) as much as the found words on average: it tells no
    /// file from another, and a file's share of the query stays what it was when every word counted the same ("black
    /// and white striped animal", of which only "animal" is in a name). At the gate (`gate`, where a file gets in by its
    /// words alone) as a word in one file, as rare as words get: "photo d'un perroquet" with no "perroquet" in the
    /// index doesn't let in every file with "un".
    static func weights(_ files: [Int], of total: Int) -> (rank: [Double], gate: [Double]) {
        let total = Double(max(total, files.max() ?? 0, 1))
        func rarity(_ count: Int) -> Double { log(1 + (total - Double(count) + 0.5) / (Double(count) + 0.5)) }
        let found = files.filter { $0 > 0 }.map(rarity)
        let average = found.isEmpty ? 1 : found.reduce(0, +) / Double(found.count)
        return (files.map { $0 > 0 ? rarity($0) : average }, files.map { rarity(max($0, 1)) })
    }

    /// FTS5 patterns for the query's words: quoted, and as prefixes for the last word while it's being typed and for
    /// words of languages that attach endings (`SearchText.inflects`). `search` makes a word that's in no file a
    /// prefix too.
    static func patterns(_ terms: [String], prefixLast: Bool) -> [String] {
        terms.enumerated().map { index, term in
            let prefix = (prefixLast && index == terms.count - 1) || SearchText.inflects(term)
            return "\"\(term)\"" + (prefix ? "*" : "")
        }
    }

    /// Whether keyword search finds `pattern` in any file.
    private func isIndexed(_ pattern: String) throws -> Bool {
        var found = false
        try store.db.query("SELECT 1 FROM fts WHERE fts MATCH ? LIMIT 1", [.text(pattern)]) { _ in found = true }
        return found
    }

    /// The query's words as an FTS5 OR-query.
    public static func ftsQuery(_ text: String, prefixLast: Bool = false) -> String? {
        let words = terms(text)
        guard !words.isEmpty else { return nil }
        return patterns(words, prefixLast: prefixLast).joined(separator: " OR ")
    }

    static let kindWords: [String: FileKind] = [
        "screenshot": .screenshot, "screenshots": .screenshot, "photo": .image, "photos": .image, "picture": .image,
        "pictures": .image, "image": .image, "images": .image, "pdf": .pdf, "pdfs": .pdf, "paper": .pdf,
        "papers": .pdf, "document": .doc, "documents": .doc, "note": .doc, "notes": .doc, "video": .video,
        "videos": .video, "clip": .video, "movie": .video, "audio": .audio, "song": .audio, "podcast": .audio,
        "voice": .audio, "sound": .audio,
        "স্ক্রিনশট": .screenshot, "ছবি": .image, "পিডিএফ": .pdf, "নোট": .doc, "ভিডিও": .video, "অডিও": .audio,
        "গান": .audio, "রেকর্ডিং": .audio,
        "لقطة": .screenshot, "صورة": .image, "صور": .image, "مستند": .doc, "ملاحظات": .doc, "فيديو": .video,
        "مقطع": .video, "صوت": .audio, "تسجيل": .audio, "اغنية": .audio,
    ]

    /// Kind words of German, French, Spanish, Italian and Portuguese, without their accents (`plain`: "vidéo" and
    /// "grabación" are found typed either way), whole words only ("Bild" is not in "Bildung"). Dropped from a query's
    /// words as the English ones are, except `keptKindWords`.
    static let europeanKindWords: [String: FileKind] = [
        // de
        "foto": .image, "fotos": .image, "bild": .image, "bilder": .image, "fotografie": .image,
        "fotografien": .image, "bildschirmfoto": .screenshot, "bildschirmfotos": .screenshot,
        "bildschirmaufnahme": .video, "bildschirmaufnahmen": .video, "film": .video, "filme": .video,
        "aufnahme": .audio, "aufnahmen": .audio, "tonaufnahme": .audio, "tonaufnahmen": .audio,
        "sprachaufnahme": .audio, "sprachaufnahmen": .audio, "audioaufnahme": .audio, "sprachnachricht": .audio,
        "sprachnachrichten": .audio, "sprachmemo": .audio, "sprachmemos": .audio,
        // fr (photo, image, vidéo, audio as in English)
        "photographie": .image, "enregistrement": .audio, "enregistrements": .audio,
        // es, it, pt
        "fotografia": .image, "fotografias": .image, "imagen": .image, "imagenes": .image, "immagine": .image,
        "immagini": .image, "imagem": .image, "imagens": .image, "schermata": .screenshot, "schermate": .screenshot,
        "grabacion": .audio, "grabaciones": .audio, "registrazione": .audio, "registrazioni": .audio,
        "gravacao": .audio, "gravacoes": .audio,
    ]

    /// Kind words that are everyday words too ("Aufnahme" is also an admission, "enregistrement" and "registrazione" a
    /// registration): a hint, and still words of the query.
    static let keptKindWords: Set<String> = [
        "aufnahme", "aufnahmen", "film", "filme", "enregistrement", "enregistrements", "registrazione", "registrazioni",
    ]

    /// Kind words of more than one word, without accents. All their words are dropped from the query's words.
    static let kindPhrases: [(words: [String], kind: FileKind)] = [
        (["capture", "d", "ecran"], .screenshot), (["captures", "d", "ecran"], .screenshot),
        (["copie", "d", "ecran"], .screenshot), (["captura", "de", "pantalla"], .screenshot),
        (["capturas", "de", "pantalla"], .screenshot), (["captura", "de", "tela"], .screenshot),
        (["capturas", "de", "tela"], .screenshot),
        (["message", "vocal"], .audio), (["messages", "vocaux"], .audio), (["memo", "vocal"], .audio),
        (["mensaje", "de", "voz"], .audio), (["mensajes", "de", "voz"], .audio), (["nota", "de", "voz"], .audio),
        (["notas", "de", "voz"], .audio), (["mensagem", "de", "voz"], .audio), (["mensagens", "de", "voz"], .audio),
        (["messaggio", "vocale"], .audio), (["messaggi", "vocali"], .audio), (["nota", "vocale"], .audio),
        (["note", "vocali"], .audio), (["memo", "vocale"], .audio),
    ]

    /// A word as kind words are compared: without the accents of Latin letters (U+0300–U+036F once decomposed).
    /// Bengali and Arabic words stay as they are.
    static func plain(_ word: String) -> String {
        guard !word.allSatisfy(\.isASCII) else { return word }
        let scalars = word.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !(0x300...0x36F).contains($0.value) }
        return String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
    }

    /// The kind words in a query's words (normalized and lowercased, split as keyword search splits them): the kinds,
    /// and the positions of the words that say only that (`terms` drops them).
    static func kindWordsIn(_ words: [String]) -> (kinds: Set<FileKind>, dropped: Set<Int>) {
        var kinds = Set<FileKind>(), dropped = Set<Int>()
        let plainWords = words.map(plain)
        var index = 0
        while index < words.count {
            if let phrase = kindPhrases.first(where: { plainWords[index...].starts(with: $0.words) }) {
                kinds.insert(phrase.kind)
                dropped.formUnion(index..<index + phrase.words.count)
                index += phrase.words.count
                continue
            }
            let word = words[index]
            if let kind = kindWords[word] {
                kinds.insert(kind)
            } else if let kind = europeanKindWords[plainWords[index]] ?? kindWords[plainWords[index]] {   // "vidéo"
                kinds.insert(kind)
                if !keptKindWords.contains(plainWords[index]) { dropped.insert(index) }
            } else if let kind = kindWords.first(where: { key, _ in
                SearchText.inflects(key) && key.unicodeScalars.count >= 3 && word.hasPrefix(key)
            })?.value {
                kinds.insert(kind)
            }
            index += 1
        }
        return (kinds, dropped)
    }

    /// Kinds the query asks for ("…in a video", "screenshot of…", "Bildschirmfoto", "capture d'écran", "ভিডিওতে"): a
    /// soft boost, not a filter. Bengali attaches case endings, so a Bengali kind word also counts at the start of a
    /// longer word.
    static func kindHints(_ text: String) -> Set<FileKind> {
        kindWordsIn(SearchText.normalized(text).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }).kinds
    }
}
