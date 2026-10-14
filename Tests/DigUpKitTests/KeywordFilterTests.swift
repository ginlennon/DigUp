import Foundation
import Testing
@testable import DigUpKit

/// The keyword filter beside the search field: its language, which files it lets through, how they're ranked, and
/// where a hit points (PLANS/KEYWORD_FILTER_PLAN.md).
@Suite struct KeywordFilterTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: The language

    func read(_ text: String) -> String? { KeywordFilter(text).expression?.description }

    @Test func termsAndOperators() {
        #expect(read("Rechnung Uster") == "(rechnung AND uster)")                  // AND between terms is implied
        #expect(read("Rechnung AND Uster") == "(rechnung AND uster)")
        #expect(read("A OR B AND C") == "(a OR (b AND c))")                         // AND before OR
        #expect(read("NOT A B") == "(NOT a AND b)")                                 // NOT before AND
        #expect(read("-Mahnung") == "NOT mahnung")
        #expect(read("A -(B OR C)") == "(a AND NOT (b OR c))")
        #expect(read("Rechnung* AND (Uster OR Winterthur) NOT Mahnung")
                == "(rechnung* AND (uster OR winterthur) AND NOT mahnung)")
        #expect(read("Uster or und Winterthur") == "(uster AND or AND und AND winterthur)")   // capitals only
        #expect(read("((A))") == "a")
    }

    @Test func wordsPhrasesStarsAndCodes() {
        #expect(KeywordFilter("Rechnung*").expression == .term(.init(.prefix, ["rechnung"])))
        #expect(KeywordFilter("*karte").expression == .term(.init(.suffix, ["karte"])))
        #expect(KeywordFilter("*Kaution*").expression == .term(.init(.infix, ["kaution"])))
        #expect(KeywordFilter("*_delay").expression == .term(.init(.suffix, ["_delay"])))       // as typed, for code
        #expect(KeywordFilter("\"Bahnhofstraße 12\"").expression == .term(.init(.words, ["bahnhofstrasse", "12"])))
        #expect(KeywordFilter("„Bahnhofstrasse 12“").expression == .term(.init(.words, ["bahnhofstrasse", "12"])))
        #expect(KeywordFilter("\"RE 20\"*").expression == .term(.init(.prefix, ["re", "20"])))
        #expect(KeywordFilter("RE-2041").expression == .term(.init(.words, ["re", "2041"])))   // its parts side by side
        #expect(KeywordFilter("2'380.50").expression == .term(.init(.words, ["2380", "50"])))
        #expect(KeywordFilter("Größe").expression == .term(.init(.words, ["grösse"])))
        #expect(KeywordFilter("Café").expression == .term(.init(.words, ["café"])))   // accents: the tokenizer's
        // Too short for a piece of a word: a word, and said so.
        let short = KeywordFilter("*ab")
        #expect(short.expression == .term(.init(.words, ["ab"])))
        #expect(short.note?.contains("three letters") == true)
        #expect(KeywordFilter("").expression == nil && KeywordFilter("").note == nil)
        #expect(KeywordFilter("* - ...").expression == nil)
    }

    @Test func whatCantBeReadIsReadAsPlainWords() {
        let quote = KeywordFilter("\"Bahnhofstrasse 12")
        #expect(quote.expression?.description == "(bahnhofstrasse AND 12)")
        #expect(quote.note == "unclosed quote: read as plain words")
        for typed in ["(Uster OR Winterthur", "Uster OR Winterthur)", "Uster AND", "OR Uster", "()"] {
            let filter = KeywordFilter(typed)
            #expect(filter.note?.contains("read as plain words") == true, "\(typed)")
        }
        #expect(read("(Uster OR Winterthur") == "(uster AND winterthur)")
        #expect(read("Rechnung* NOT") == "rechnung*")
        #expect(KeywordFilter("NOT").expression == nil)
    }

    @Test func positiveTermsAreTheOnesLookedFor() {
        #expect(KeywordFilter("A NOT (B OR NOT C) -D").positiveTerms.map(\.description) == ["a", "c"])
        #expect(KeywordFilter("A OR A").positiveTerms.count == 1)
    }

    @Test func marksAreWholeWordsAsWritten() {
        func marked(_ filter: String, _ text: String) -> [String] {
            KeywordFilter(filter).marks(in: text).map { String(text[$0]) }
        }
        #expect(marked("Rechnung*", "Rechnungen und eine Rechnung, verrechnet") == ["Rechnungen", "Rechnung"])
        #expect(marked("*karte", "Versichertenkarte, Kartei, Karte") == ["Versichertenkarte", "Karte"])
        #expect(marked("*kaution*", "Mietkautionskonto") == ["Mietkautionskonto"])
        #expect(marked("2'380.50", "CHF 230.50, total CHF 2'380.50") == ["2'380.50"])   // the code, not a stray 50
        #expect(marked("RE-2041", "Rechnung RE 2041 und INV-2041") == ["RE 2041"])
        #expect(marked("Seestrasse", "an der Seestraße 4") == ["Seestraße"])
        #expect(marked("A NOT B", "A B") == ["A"])
    }

    // MARK: In an index

    /// A small index: a two-page invoice PDF, a reminder, a note, a recording with a transcript, and an unrelated
    /// document with a similar code. Every segment with words has a vector of its own text (`FakeEmbedder`), so a query
    /// vector made from one of the texts stands out at that segment.
    struct Fixture {
        let store: IndexStore
        let searcher: Searcher
        var files: [String: Int64] = [:]
        static let pages = ["Rechnung Nr. 17 an Familie Lüthi, Bahnhofstrasse 12, 8610 Uster.",
                            "Mietvertrag: die Mietkaution geht auf ein Mietkautionskonto. Bahnhofstrasse 12, Uster."]
        static let windows = ["Guten Tag Frau Brunner, hier ist die Schreinerei.", "Die Rechnung RE-2041 ist fällig.",
                              "Die Stühle kommen nach Winterthur."]
    }

    func fixture() throws -> Fixture {
        let store = try IndexStore(directory: folder)
        var files: [String: Int64] = [:]
        func add(_ name: String, _ kind: FileKind, mtime: Double = 1) throws -> Int64 {
            let id = try store.insert(Candidate(path: "/t/\(name)", kind: kind, size: 1, mtime: mtime,
                                                inode: UInt64(files.count + 1), device: 1))
            files[name] = id
            return id
        }
        let pdf = try add("Schreinerei Gubler.pdf", .pdf, mtime: 5)
        for (index, text) in Fixture.pages.enumerated() {
            try store.addSegment(file: pdf, kind: .page, modality: .text, loc: Double(index + 1), text: text,
                                 vector: FakeEmbedder.vector(for: text))
        }
        for (name, text, mtime) in [("Mahnung.txt", "Zweite Mahnung zur Rechnung Nr. 17", 4.0),
                                    ("Notizen.txt", "Versichertenkarten nicht vergessen", 3.0),
                                    ("Zahlung.txt", "Payment INV-2041 failed", 2.0)] {
            let id = try add(name, .doc, mtime: mtime)
            try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1, text: text,
                                 vector: FakeEmbedder.vector(for: text))
        }
        let memo = try add("Memo.m4a", .audio, mtime: 6)
        for (index, text) in Fixture.windows.enumerated() {
            try store.addSegment(file: memo, kind: .audio, modality: .audio, loc: Double(index * 25),
                                 locEnd: Double(index * 25 + 30), vector: FakeEmbedder.vector(for: text))
        }
        let windows = try store.audioWindows(of: memo)
        try store.setTranscript(file: memo, texts: zip(windows, Fixture.windows).map { ($0.id, $1) },
                                info: ["transcript": "done"])
        return Fixture(store: store, searcher: try Searcher(store: store), files: files)
    }

    func names(_ hits: [SearchHit]) -> [String] { hits.map { ($0.path as NSString).lastPathComponent } }

    func search(_ fixture: Fixture, _ filter: String, _ text: String = "", vector: String? = nil,
                kinds: Set<FileKind>? = nil, folders: [String]? = nil) throws -> [SearchHit] {
        try fixture.searcher.search(text, queryVector: vector.map(FakeEmbedder.vector(for:)), kinds: kinds,
                                    folders: folders, filter: KeywordFilter(filter))
    }

    @Test func theFilterSaysWhichFiles() throws {
        let index = try fixture()
        func files(_ filter: String, kinds: Set<FileKind>? = nil) throws -> Set<String> {
            Set(names(try search(index, filter, kinds: kinds)))
        }
        #expect(try files("Rechnung*") == ["Schreinerei Gubler.pdf", "Mahnung.txt", "Memo.m4a"])
        #expect(try files("Rechnung* NOT Mahnung") == ["Schreinerei Gubler.pdf", "Memo.m4a"])
        #expect(try files("Rechnung* -Mahnung*") == ["Schreinerei Gubler.pdf", "Memo.m4a"])   // its name too
        #expect(try files("NOT Rechnung*") == ["Notizen.txt", "Zahlung.txt"])                  // all the others
        #expect(try files("Uster AND Mietkaution") == ["Schreinerei Gubler.pdf"])              // anywhere in the file
        #expect(try files("Brunner OR Lüthi") == ["Memo.m4a", "Schreinerei Gubler.pdf"])
        #expect(try files("*kaution*") == ["Schreinerei Gubler.pdf"])
        #expect(try files("*karten") == ["Notizen.txt"])
        #expect(try files("*karte").isEmpty)                         // "Versichertenkarten" doesn't end with it
        #expect(try files("Versichertenkarte*") == ["Notizen.txt"])  // a plural, by its start
        #expect(try files("RE-2041") == ["Memo.m4a"])                // not INV-2041
        #expect(try files("2041") == ["Memo.m4a", "Zahlung.txt"])
        #expect(try files("\"Bahnhofstrasse 12\"") == ["Schreinerei Gubler.pdf"])
        #expect(try files("\"12 Bahnhofstrasse\"").isEmpty)           // side by side, in order
        #expect(try files("*stühle*") == ["Memo.m4a"])               // what's only said
        #expect(try files("Schreinerei") == ["Schreinerei Gubler.pdf", "Memo.m4a"])   // a name, and what's said
        #expect(try files("Rechnung*", kinds: [.audio]) == ["Memo.m4a"])
        #expect(Set(names(try search(index, "Rechnung*", folders: ["/elsewhere"]))).isEmpty)
        // A prefix is what's typed, not what the stemmer makes of it ("facture*" isn't "factur*").
        #expect(try files("Rechnungen*").isEmpty)
        #expect(try files("Versichertenkarte*") == files("Versichertenkarten*"))
    }

    @Test func theMainQueryRanksEveryFileTheFilterLetsThrough() throws {
        let index = try fixture()
        // Meaning: the note's text. No file the filter allows stands out (z < 2), and all of them are listed anyway.
        let note = "Versichertenkarten nicht vergessen"
        let unfiltered = try index.searcher.search("Karten", queryVector: FakeEmbedder.vector(for: note))
        #expect(names(unfiltered) == ["Notizen.txt"])
        let filtered = try search(index, "Rechnung*", "Karten", vector: note)
        #expect(Set(names(filtered)) == ["Schreinerei Gubler.pdf", "Mahnung.txt", "Memo.m4a"])
        #expect(filtered.allSatisfy { ($0.z ?? 0) < 2 })
        // Ranked by meaning below the gate too: the order of their z.
        let z = filtered.map { $0.z ?? -.infinity }
        #expect(z == z.sorted(by: >))
        // A query that matches one of them puts it first.
        let reminder = try search(index, "Rechnung*", "Mahnung", vector: "Zweite Mahnung zur Rechnung Nr. 17")
        #expect(names(reminder).first == "Mahnung.txt")
    }

    @Test func aHitPointsWhereTheFilterMatches() throws {
        let index = try fixture()
        // Both pages have "Uster": the one that fits the query; without one, the better match for the filter.
        let page2 = try search(index, "Uster", "deposit", vector: Fixture.pages[1])
        #expect(page2.first?.loc == 2)
        let page1 = try search(index, "Uster", "invoice", vector: Fixture.pages[0])
        #expect(page1.first?.loc == 1)
        // Only page 2 has the filter's word, though page 1 fits the query best.
        #expect(try search(index, "*kaution*", "invoice", vector: Fixture.pages[0]).first?.loc == 2)
        #expect(try search(index, "*kaution*").first?.excerpt?.contains("«Mietkaution»") == true)
        // A recording: the moment it's said.
        let moment = try search(index, "RE-2041")
        #expect(moment.first?.segment == .audio && moment.first?.loc == 25)
        #expect(moment.first?.excerpt?.contains("«RE-2041»") == true)
        // Without a query, the segment with most of the filter's terms; with one, the moment that fits it.
        #expect(try search(index, "Rechnung* OR fällig OR Winterthur").first { $0.kind == .audio }?.loc == 25)
        #expect(try search(index, "Rechnung* OR Winterthur", "chairs", vector: Fixture.windows[2]).first?.loc == 50)
        // Only the file's name matched: the meaning's own segment, else its name.
        let named = try search(index, "Gubler", "deposit", vector: Fixture.pages[1])
        #expect(named.first?.segment == .page && named.first?.loc == 2)
        #expect(try search(index, "Gubler").first?.segment == .name)
    }

    @Test func withoutAQueryTheFilterRanksAndNothingIsFolded() throws {
        let index = try fixture()
        let hits = try search(index, "Rechnung*")
        #expect(hits.count == 3)
        #expect(Searcher.strongCount(hits) == 3)
        #expect(hits.allSatisfy { $0.score >= 1 })
        // Found only by a piece of a word or a NOT: newest first.
        #expect(names(try search(index, "NOT Rechnung*")) == ["Notizen.txt", "Zahlung.txt"])
        // No filter and no query: nothing.
        #expect(try index.searcher.search("", queryVector: nil).isEmpty)
        #expect(try index.searcher.search("  ", queryVector: nil, filter: KeywordFilter("")).isEmpty)
    }

    @Test func codeHasTheFilterToo() throws {
        let store = try IndexStore(directory: folder, file: IndexStore.codeFile)
        let id = try store.insert(Candidate(path: "/repo/retry.py", kind: .doc, size: 1, mtime: 1, inode: 1, device: 1))
        let text = "import time\n\ndef retry(attempts=5, base_delay=0.5):\n    time.sleep(base_delay)\n"
        try store.addSegment(file: id, kind: .lines, modality: .text, loc: 1, locEnd: 4, text: text,
                             vector: FakeEmbedder.vector(for: text))
        let searcher = try Searcher(store: store)
        #expect(searcher.isCode)
        let hits = try searcher.search("", queryVector: nil, filter: KeywordFilter("*_delay"))
        #expect(hits.map(\.path) == ["/repo/retry.py"])
        #expect(hits.first?.focus == 3)   // the line with it
        #expect(try searcher.search("", queryVector: nil, filter: KeywordFilter("*_delays")).isEmpty)
    }
}
