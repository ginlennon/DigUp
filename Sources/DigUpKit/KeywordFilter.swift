import Foundation

/// The filter beside the search field (PLANS/KEYWORD_FILTER_PLAN.md): a small boolean language over everything DigUp
/// keeps as text that says exactly which files may appear, while the main query ranks them (`Searcher.search`).
///
///     Rechnung Uster              both (AND between terms is implied)
///     A AND B · A OR B · NOT A    operators only in capitals, so French "or" and German "und" stay words; -A is NOT A
///     ( … )                       grouping; NOT binds tighter than AND, AND tighter than OR
///     "Bahnhofstrasse 12"         a phrase: these words side by side
///     Rechnung*                   a word starting with it
///     *karte · *kaution*          a word ending with it, a word with it inside (at least three letters)
///     RE-2041 · 2'380.50          a code or number as written: its parts side by side
///
/// Terms are normalized as the index is (`SearchText`: case, accents, ß, digit marks). A filter that can't be parsed
/// (an unclosed quote or bracket, an operator with nothing beside it) is read as plain words, and `note` says so.
public struct KeywordFilter: Sendable, Equatable {
    /// One thing a file's text may have.
    public struct Term: Sendable, Hashable, CustomStringConvertible {
        public enum Kind: Sendable, Hashable {
            /// `words` side by side (one for a word, more for a phrase or a code).
            case words
            /// The same, the last one as the start of a word.
            case prefix
            /// `words[0]` (letters and whatever else was typed between the stars) at the end of a word, or inside one.
            case suffix, infix
        }
        public let kind: Kind
        public let words: [String]

        public init(_ kind: Kind, _ words: [String]) {
            self.kind = kind
            self.words = words
        }

        public var description: String {
            switch kind {
            case .words: words.count == 1 ? words[0] : "\"\(words.joined(separator: " "))\""
            case .prefix: (words.count == 1 ? words[0] : "\"\(words.joined(separator: " "))\"") + "*"
            case .suffix: "*" + words[0]
            case .infix: "*" + words[0] + "*"
            }
        }

        /// The FTS5 query for a word, phrase or prefix (nil for a suffix or infix, which `fts_tri` finds).
        var ftsPattern: String? {
            switch kind {
            case .words: "\"\(words.joined(separator: " "))\""
            case .prefix: "\"\(words.joined(separator: " "))\"*"
            case .suffix, .infix: nil
            }
        }
    }

    public indirect enum Expression: Sendable, Equatable, CustomStringConvertible {
        case term(Term)
        case and([Expression])
        case or([Expression])
        case not(Expression)

        public var description: String {
            switch self {
            case .term(let term): term.description
            case .and(let parts): "(" + parts.map(\.description).joined(separator: " AND ") + ")"
            case .or(let parts): "(" + parts.map(\.description).joined(separator: " OR ") + ")"
            case .not(let part): "NOT " + part.description
            }
        }
    }

    /// What was typed.
    public let text: String
    /// Nil when nothing in it is a term (empty, or only operators and punctuation): no filter then.
    public let expression: Expression?
    /// Why it was read other than as written ("unclosed quote: read as plain words", "*ab: …"), for the panel.
    public let note: String?

    public init(_ text: String) {
        self.text = text
        var notes: [String] = []
        if let tokens = try? Self.tokens(text, notes: &notes) {
            var parser = Parser(tokens: tokens)
            do {
                expression = try parser.parse()   // nil when there's no term at all
                note = notes.isEmpty ? nil : notes.joined(separator: "; ")
                return
            } catch {
                notes = ["can't read “\(text.trimmingCharacters(in: .whitespaces))” as a filter: read as plain words"]
            }
        }
        // Plain words: every word a term, all of them needed; operators, quotes and brackets ignored.
        var ignored: [String] = []
        let words = text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: Self.quotes + "-")) }
            .filter { !$0.isEmpty && !["AND", "OR", "NOT"].contains($0) }
            .compactMap { Self.term($0, notes: &ignored) }.map(Expression.term)
        expression = words.isEmpty ? nil : words.count == 1 ? words[0] : .and(words)
        note = (notes + ignored).joined(separator: "; ")
    }

    /// The terms a file's text is looked for in, not the ones it must not have: what a hit points at and marks.
    public var positiveTerms: [Term] {
        var out: [Term] = []
        func walk(_ expression: Expression, positive: Bool) {
            switch expression {
            case .term(let term): if positive, !out.contains(term) { out.append(term) }
            case .and(let parts), .or(let parts): for part in parts { walk(part, positive: positive) }
            case .not(let part): walk(part, positive: !positive)
            }
        }
        if let expression { walk(expression, positive: true) }
        return out
    }

    /// Where `text` has the positive terms, as ranges of the text as it's written (whole words: `Rechnung*` marks all of
    /// "Rechnungen"). A phrase or a code is marked as one, from its first word to its last, where its words follow each
    /// other with nothing but spaces and punctuation between, as keyword search matched them: «RE-2041», «2'380.50».
    public func marks(in text: String) -> [Range<String.Index>] {
        let folded = SearchText.Folded(text)
        return positiveTerms.flatMap { term -> [Range<String.Index>] in
            switch term.kind {
            case .words, .prefix:
                let found = term.words.enumerated().map { index, word in
                    SearchText.matches(of: word, in: folded,
                                       as: term.kind == .prefix && index == term.words.count - 1 ? .start : .whole)
                }
                return found[0].compactMap { first in
                    var end = first.upperBound
                    for next in found.dropFirst() {
                        guard let following = next.first(where: { $0.lowerBound >= end }),
                              !text[end..<following.lowerBound].contains(where: Self.isWordCharacter) else { return nil }
                        end = following.upperBound
                    }
                    return first.lowerBound..<end
                }
            case .suffix: return SearchText.matches(of: term.words[0], in: folded, as: .end)
            case .infix: return SearchText.matches(of: term.words[0], in: folded, as: .inside)
            }
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    // MARK: Reading it

    static let quotes = "\"“”„"

    enum Token: Equatable {
        case open, close, and, or, not
        case term(Term)
    }

    struct Unreadable: Error {}

    /// The filter as tokens. Throws on an unclosed quote; brackets are the parser's.
    static func tokens(_ text: String, notes: inout [String]) throws -> [Token] {
        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0
        func isSpace(_ at: Int) -> Bool { at >= characters.count || characters[at].isWhitespace }
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "(" {
                tokens.append(.open)
                index += 1
            } else if character == ")" {
                tokens.append(.close)
                index += 1
            } else if character == "-", !isSpace(index + 1) {
                tokens.append(.not)   // -A, -"a b", -(a OR b)
                index += 1
            } else if quotes.contains(character) {
                guard let end = characters[(index + 1)...].firstIndex(where: { quotes.contains($0) }) else {
                    notes.append("unclosed quote: read as plain words")
                    throw Unreadable()
                }
                let inside = String(characters[(index + 1)..<end])
                index = end + 1
                let prefix = index < characters.count && characters[index] == "*"
                if prefix { index += 1 }
                let words = Self.words(inside)
                if !words.isEmpty { tokens.append(.term(Term(prefix ? .prefix : .words, words))) }
            } else {
                var end = index
                while end < characters.count, !characters[end].isWhitespace, !"()".contains(characters[end]),
                      !quotes.contains(characters[end]) { end += 1 }
                let word = String(characters[index..<end])
                index = end
                switch word {
                case "AND": tokens.append(.and)
                case "OR": tokens.append(.or)
                case "NOT": tokens.append(.not)
                default: if let term = term(word, notes: &notes) { tokens.append(.term(term)) }
                }
            }
        }
        return tokens
    }

    /// A word as typed (with its stars) as a term; nil when it has no letters or digits.
    static func term(_ typed: String, notes: inout [String]) -> Term? {
        let leading = typed.hasPrefix("*"), trailing = typed.hasSuffix("*") && typed.count > 1
        let core = typed.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        let words = Self.words(core)
        guard !words.isEmpty else { return nil }
        if leading {
            let piece = SearchText.normalized(core).lowercased()
            if piece.count >= 3 { return Term(trailing ? .infix : .suffix, [piece]) }
            notes.append("\(typed): at least three letters go with *, read as \(core)")
            return Term(.words, words)
        }
        return Term(trailing ? .prefix : .words, words)
    }

    /// The words keyword search keeps `text` as (`Searcher.terms`, without dropping any).
    static func words(_ text: String) -> [String] {
        SearchText.normalized(text).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// or := and ("OR" and)* · and := unary (["AND"] unary)* · unary := ("NOT" | "-") unary | "(" or ")" | term
    struct Parser {
        let tokens: [Token]
        var position = 0

        init(tokens: [Token]) { self.tokens = tokens }

        mutating func parse() throws -> Expression? {
            guard !tokens.isEmpty else { return nil }
            let expression = try or()
            guard position == tokens.count else { throw Unreadable() }   // a ")" too many
            return expression
        }

        private var next: Token? { position < tokens.count ? tokens[position] : nil }

        private mutating func or() throws -> Expression {
            var parts = [try and()]
            while next == .or {
                position += 1
                parts.append(try and())
            }
            return parts.count == 1 ? parts[0] : .or(parts)
        }

        private mutating func and() throws -> Expression {
            var parts = [try unary()]
            while let token = next, token != .or, token != .close {
                if token == .and { position += 1 }
                parts.append(try unary())
            }
            return parts.count == 1 ? parts[0] : .and(parts)
        }

        private mutating func unary() throws -> Expression {
            guard let token = next else { throw Unreadable() }
            position += 1
            switch token {
            case .not: return .not(try unary())
            case .open:
                let inside = try or()
                guard next == .close else { throw Unreadable() }
                position += 1
                return inside
            case .term(let term): return .term(term)
            case .close, .and, .or: throw Unreadable()
            }
        }
    }
}

/// What a filter matched in an index (`Searcher.search`): the files, and in each the segments with a positive term.
struct FilterMatch {
    /// The files the expression holds for: per file, `A AND B` is true when A is anywhere in it and B anywhere in it.
    private(set) var files = Set<Int64>()
    /// For each of `files`, its segments (not its name's row) with a positive term, and how many of those terms each has.
    private(set) var segments: [Int64: [Int64: Int]] = [:]
    /// bm25 of the positive words, phrases and prefixes, for each segment that has one (lower is better, as SQLite's),
    /// and each file's best, its name's row included.
    private(set) var segmentRank: [Int64: Double] = [:]
    private(set) var fileRank: [Int64: Double] = [:]

    /// `universe`: the files that may be results (the search's kinds and folders): what NOT takes away from.
    init(_ filter: KeywordFilter, store: IndexStore, universe: Set<Int64>) throws {
        guard let expression = filter.expression else { return }
        var found: [KeywordFilter.Term: [(file: Int64, segment: Int64, name: Bool)]] = [:]
        func hits(_ term: KeywordFilter.Term) throws -> [(file: Int64, segment: Int64, name: Bool)] {
            if let known = found[term] { return known }
            let rows = try Self.rows(of: term, in: store)
            found[term] = rows
            return rows
        }
        func evaluate(_ expression: KeywordFilter.Expression) throws -> Set<Int64> {
            switch expression {
            case .term(let term): return Set(try hits(term).map(\.file))
            case .and(let parts):
                var result = try evaluate(parts[0])
                for part in parts.dropFirst() where !result.isEmpty { result.formIntersection(try evaluate(part)) }
                return result
            case .or(let parts): return try parts.reduce(into: Set<Int64>()) { $0.formUnion(try evaluate($1)) }
            case .not(let part): return universe.subtracting(try evaluate(part))
            }
        }
        files = try evaluate(expression).intersection(universe)

        let positive = filter.positiveTerms
        for term in positive {
            for hit in try hits(term) where !hit.name && files.contains(hit.file) {
                segments[hit.file, default: [:]][hit.segment, default: 0] += 1
            }
        }
        let patterns = positive.compactMap(\.ftsPattern)
        guard !patterns.isEmpty, !files.isEmpty else { return }
        try store.db.query("""
            SELECT s.file, s.id, bm25(fts, 3.0, 1.0) FROM fts JOIN segments s ON s.id = fts.rowid WHERE fts MATCH ?
            """, [.text(patterns.joined(separator: " OR "))]) { row in
            let file = row.int(0), rank = row.double(2)
            guard files.contains(file) else { return }
            segmentRank[row.int(1)] = rank
            fileRank[file] = min(fileRank[file] ?? .infinity, rank)
        }
    }

    /// Every keyword row with `term`: words and phrases from `fts`; prefixes, suffixes and infixes from `fts_tri`'s
    /// candidates (rows with all of the term's threes), each checked on its text, as `fts_tri` doesn't know where they
    /// are. Not prefixes from `fts`: its Porter stemmer cuts the query's word too, so "facture*" was "factur*" and found
    /// the Spanish "factura", and "connecti*" missed "connection" (kept as "connect"). A prefix of two letters or of a
    /// phrase ("RE-20*") is `fts`'s.
    private static func rows(of term: KeywordFilter.Term, in store: IndexStore) throws
        -> [(file: Int64, segment: Int64, name: Bool)] {
        var out: [(file: Int64, segment: Int64, name: Bool)] = []
        let part: SearchText.WordPart? = switch term.kind {
        case .prefix where term.words.count == 1 && term.words[0].count >= 3: .start
        case .suffix: .end
        case .infix: .inside
        default: nil
        }
        if let pattern = term.ftsPattern, part == nil {
            try store.db.query("""
                SELECT s.file, s.id, s.kind = 'name' FROM fts JOIN segments s ON s.id = fts.rowid WHERE fts MATCH ?
                """, [.text(pattern)]) { out.append(($0.int(0), $0.int(1), $0.int(2) != 0)) }
            return out
        }
        guard let part, let candidates = IndexStore.trigramQuery(term.words[0]) else { return out }
        let needle = folded(term.words[0])
        try store.db.query("""
            SELECT s.file, s.id, s.kind = 'name', fts.name, fts.body FROM fts_tri JOIN fts ON fts.rowid = fts_tri.rowid
            JOIN segments s ON s.id = fts_tri.rowid WHERE fts_tri MATCH ?
            """, [.text(candidates)]) { row in
            if has(needle, in: row.text(3) ?? "", as: part) || has(needle, in: row.text(4) ?? "", as: part) {
                out.append((row.int(0), row.int(1), row.int(2) != 0))
            }
        }
        return out
    }

    /// Whether normalized `text` has `needle` (`folded`) as `part` of a word, case and accents aside as `fts_tri`
    /// compares: at its start (no letter, mark or digit before it), at its end (none after it), or anywhere. On bytes of
    /// folded text: Foundation's case- and accent-blind search took 37 ms for the 4,000 candidate rows of `*tion*` on the
    /// dev laptop's index (2026-10-14).
    static func has(_ needle: [UInt8], in text: String, as part: SearchText.WordPart) -> Bool {
        guard !needle.isEmpty else { return false }
        let haystack = folded(text)
        guard haystack.count >= needle.count else { return false }
        func isWordCharacter(before index: Int) -> Bool {
            var start = index - 1
            while start > 0, haystack[start] & 0xC0 == 0x80 { start -= 1 }
            return start >= 0 && isWord(haystack[start..<index])
        }
        func isWordCharacter(at index: Int) -> Bool {
            guard index < haystack.count else { return false }
            var end = index + 1
            while end < haystack.count, haystack[end] & 0xC0 == 0x80 { end += 1 }
            return isWord(haystack[index..<end])
        }
        let first = needle[0]
        var at = 0
        while at <= haystack.count - needle.count {
            if haystack[at] == first, haystack[at..<at + needle.count].elementsEqual(needle) {
                switch part {
                case .inside: return true
                case .start: if !isWordCharacter(before: at) { return true }
                case .end: if !isWordCharacter(at: at + needle.count) { return true }
                case .whole: if !isWordCharacter(before: at), !isWordCharacter(at: at + needle.count) { return true }
                }
            }
            at += 1
        }
        return false
    }

    /// Text as `has` compares it: lowercase, accents (the combining marks U+0300–U+036F) taken off, as UTF-8. ASCII
    /// byte by byte, the rest a character at a time, each kind once (Foundation's lowercasing and decomposing of the
    /// whole text took longer than the search).
    static func folded(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        var known: [UInt32: [UInt8]] = [:]
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value < 0x80 {
                out.append(UInt8(value >= 65 && value <= 90 ? value + 32 : value))
            } else if let bytes = known[value] {
                out += bytes
            } else {
                var bytes: [UInt8] = []
                for piece in String(scalar).lowercased().decomposedStringWithCanonicalMapping.unicodeScalars
                where !(0x0300...0x036F).contains(piece.value) {
                    bytes += Array(String(piece).utf8)
                }
                known[value] = bytes
                out += bytes
            }
        }
        return out
    }

    private static func isWord(_ bytes: ArraySlice<UInt8>) -> Bool {
        String(decoding: bytes, as: UTF8.self).unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
