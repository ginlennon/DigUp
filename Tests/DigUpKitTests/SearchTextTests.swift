import Foundation
import Testing
@testable import DigUpKit

@Suite struct SearchTextTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func normalizedFoldsWhatIsTypedDifferently() {
        #expect(SearchText.normalized("الْمَكْتَبَةَ") == "المكتبة")              // harakat
        #expect(SearchText.normalized("إلى الأردن") == "الى الاردن")              // alef forms
        #expect(SearchText.normalized("مـــرحبا") == "مرحبا")                      // tatweel
        #expect(SearchText.normalized("\u{FEFB}") == "\u{0644}\u{0627}")           // the lam-alef ligature → lam, alef
        #expect(SearchText.normalized("\u{FB01}le") == "file")                     // ﬁ
        #expect(SearchText.normalized("র\u{200D}্যাব") == "র্যাব")                  // zero-width joiner
        #expect(SearchText.normalized("\u{09C7}\u{09BE}") == "\u{09CB}")           // ে + া → ো
        #expect(SearchText.normalized("a\u{200B}b") == "a b")                      // zero-width space breaks words
    }

    @Test func germanAndSwissSpellingsMeet() throws {
        #expect(SearchText.normalized("Seestraße 4") == "Seestrasse 4")
        #expect(SearchText.normalized("GROẞ") == "GROss")
        #expect(SearchText.normalized("CHF 2'380.50") == "CHF 2380.50")                // Swiss
        #expect(SearchText.normalized("2’380 · 1\u{2009}250 · 3\u{202F}000") == "2380 · 1250 · 3000")
        #expect(SearchText.normalized("Seite 2 380 Gäste") == "Seite 2 380 Gäste")    // a plain space: two numbers
        #expect(SearchText.normalized("l'école, it's the '90s, 5'") == "l'école, it's the '90s, 5'")
        #expect(SearchText.normalized("\u{202F}x") == " x")                            // not between digits: NFKC's
        #expect(Searcher.terms("CHF 2'380.50 Seestraße") == ["chf", "2380", "50", "seestrasse"])
        // Marked on the text as it's written.
        let text = "Bitte an die Seestraße 4, Betrag CHF 2'380.50."
        #expect(SearchText.snippet(text, terms: ["seestrasse", "2380"])
                == "Bitte an die «Seestraße» 4, Betrag CHF «2'380».50.")

        let store = try IndexStore(directory: folder)
        let id = try store.insert(Candidate(path: "/notes/Arzttermin.odt", kind: .doc, size: 1, mtime: 1, inode: 1,
                                            device: 1))
        try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1, text: text)
        let searcher = try Searcher(store: store, loadVectors: false)
        let hits = try searcher.search("Seestrasse", queryVector: nil)
        #expect(hits.map(\.path) == ["/notes/Arzttermin.odt"])
        #expect(hits.first?.excerpt?.contains("«Seestraße»") == true)
        #expect(try searcher.search("2380", queryVector: nil).map(\.path) == ["/notes/Arzttermin.odt"])
        #expect(try searcher.text(ofSegment: hits[0].segmentID) == text)   // shown as it's written
    }

    @Test func queryWordsOfLanguagesWithEndingsArePrefixes() {
        #expect(Searcher.ftsQuery("কুমির") == "\"কুমির\"*")
        #expect(Searcher.ftsQuery("مدرسة الأطفال") == "\"مدرسة\"* OR \"الاطفال\"*")
        #expect(Searcher.ftsQuery("মা") == "\"মা\"*")   // a letter and its vowel sign: two, so it counts
        #expect(Searcher.ftsQuery("payment error") == "\"payment\" OR \"error\"")
        #expect(Searcher.kindHints("জেব্রার ভিডিওতে") == [.video])
        #expect(Searcher.kindHints("صورة حمار وحشي") == [.image])
    }

    @Test func bengaliAndArabicWordsStayWhole() throws {
        let store = try IndexStore(directory: folder)
        let id = try store.insert(Candidate(path: "/notes/trip.txt", kind: .doc, size: 1, mtime: 1, inode: 1, device: 1))
        try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1,
                             text: "সুন্দরবনে আমরা কুমিরও দেখেছি। قَالَ إِنَّ الْمَكْتَبَةَ تُغْلَقُ")
        let searcher = try Searcher(store: store, loadVectors: false)
        let bengali = try searcher.search("কুমির", queryVector: nil)
        #expect(bengali.map(\.path) == ["/notes/trip.txt"])
        #expect(bengali.first?.excerpt?.contains("«কুমিরও»") == true)   // the whole word, never a piece of it
        #expect(try searcher.search("المكتبة", queryVector: nil).map(\.path) == ["/notes/trip.txt"])
        #expect(try searcher.search("কলকাতা", queryVector: nil).isEmpty)
    }

    @Test func aWordInNoFileIsFoundAtTheStartOfLongerOnes() throws {
        let store = try IndexStore(directory: folder)
        func add(_ path: String, _ text: String, kind: FileKind = .doc, segment: SegmentKind = .chunk) throws {
            let id = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1, inode: UInt64(path.count),
                                                device: 1))
            try store.addSegment(file: id, kind: segment, modality: .text, loc: 1, text: text)
        }
        try add("/shots/settings.png", "Model picker: Grok4 (default)", kind: .screenshot, segment: .ocr)
        try add("/notes/wiki.txt", "Read the Grokipedia page about rivers.")
        try add("/notes/pets.txt", "The cat sleeps on the sofa.")
        try add("/notes/tags.txt", "Pick a category for each photo of rivers.")
        let searcher = try Searcher(store: store, loadVectors: false)
        // "grok" is in no file as a word. While it's typed (the last word as a prefix) and once typing stops, it finds
        // the same files.
        let typing = try searcher.search("grok", queryVector: nil, prefixLast: true)
        let stopped = try searcher.search("grok", queryVector: nil)
        #expect(Set(stopped.map(\.path)) == ["/shots/settings.png", "/notes/wiki.txt"])
        #expect(Set(typing.map(\.path)) == Set(stopped.map(\.path)))
        #expect(stopped.first { $0.path == "/shots/settings.png" }?.excerpt?.contains("«Grok4»") == true)
        // Another word with it, as rare: both count.
        #expect(try searcher.search("grok rivers", queryVector: nil).map(\.path)
                == ["/notes/wiki.txt", "/shots/settings.png", "/notes/tags.txt"])
        // A word that's in a file as typed stays whole: "cat" isn't "category". So do two letters.
        #expect(try searcher.search("cat", queryVector: nil).map(\.path) == ["/notes/pets.txt"])
        #expect(try searcher.search("gr", queryVector: nil).isEmpty)
    }

    @Test func garbledPageTextIsNoticed() {
        // As PDFKit reads Bengali and Arabic pages made by Quartz/WebKit (testbed/make_lang.swift).
        let glyphOrder = "বািড় ভাড়ার চিপ ধানমি ৭ নর রােডর িতন বডরেমর াট মািসক ২৫,০০০ টাকা ভাড়ায় দওয়া হেলা। ভাড়ায়া দুই মােসর"
        let bengali = "বাড়ি ভাড়ার চুক্তিপত্র। ধানমন্ডি ৭ নম্বর রোডের তিন বেডরুমের ফ্ল্যাটটি মাসিক ২৫,০০০ টাকা ভাড়ায় দেওয়া হলো।"
        let lost = "ارتفعت ا.بيعات بنسبة خمسة عشر با.ئة في الربع الثالث. زرنا مدينة البتراء ا?ثرية في جنوب ا?ردن."
        let arabic = "ارتفعت المبيعات بنسبة خمسة عشر بالمئة في الربع الثالث. زرنا مدينة البتراء الأثرية في جنوب الأردن."
        #expect(PageTextProblem.check(glyphOrder) == .glyphOrder)
        #expect(PageTextProblem.check(bengali) == nil)
        #expect(PageTextProblem.check(lost) == .lostLetters)
        #expect(PageTextProblem.check(arabic) == nil)
        #expect(PageTextProblem.check("Revenue grew 20%. See p.4?No. Done.") == nil)
    }

    @Test func schemaOneMigratesToTheCurrentSchema() throws {
        // An index as schema 1 made it: SQLite's default tokenizer, text as extracted, screenshots' OCR with a vector,
        // its vectors named by the llama.cpp build.
        let built = "google/embeddinggemma-2@bfcd298 llama.cpp-b11461-metal text-q8_0+mmproj-q8_0"
        let db = try Database(path: folder.appendingPathComponent("index.sqlite").path)
        try db.execute("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                size INTEGER NOT NULL, mtime REAL NOT NULL, inode INTEGER NOT NULL, device INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending', detail TEXT, info TEXT, indexed_at REAL);
            CREATE TABLE segments(id INTEGER PRIMARY KEY, file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, modality TEXT NOT NULL, loc REAL, loc_end REAL, excerpt TEXT, vec BLOB);
            CREATE VIRTUAL TABLE fts USING fts5(name, body, tokenize = 'porter unicode61 remove_diacritics 2');
            INSERT INTO files VALUES(1, '/d/notes.txt', 'doc', 1, 1, 1, 1, 'done', NULL, NULL, 1);
            INSERT INTO segments VALUES(1, 1, 'chunk', 'text', 1, NULL, NULL, NULL);
            INSERT INTO fts(rowid, name, body) VALUES(1, '', 'قَالَ إِنَّ الْمَكْتَبَةَ تُغْلَقُ');
            INSERT INTO files VALUES(2, '/d/rent.pdf', 'pdf', 1, 1, 2, 1, 'done', NULL, NULL, 1);
            INSERT INTO segments VALUES(2, 2, 'page', 'text', 1, NULL, NULL, NULL);
            INSERT INTO fts(rowid, name, body) VALUES(2, '', 'বািড় ভাড়ার চিপ ধানমি ৭ নর রােডর িতন বডরেমর াট মািসক ২৫,০০০ টাকা ভাড়ায় দওয়া হেলা।');
            INSERT INTO files VALUES(3, '/d/shot.png', 'screenshot', 1, 1, 3, 1, 'done', NULL, NULL, 1);
            INSERT INTO segments VALUES(3, 3, 'ocr', 'text', NULL, NULL, 'Booking K7Q2LM', zeroblob(1536));
            INSERT INTO fts(rowid, name, body) VALUES(3, '', 'Booking K7Q2LM');
            INSERT INTO meta VALUES('fingerprint', '\(built) | photo140 shot280 page280 frame70/3.0s audio30.0/25.0s');
            INSERT INTO meta VALUES('vector_source', '\(built)');
            PRAGMA user_version = 1;
            """)
        let store = try IndexStore(directory: folder)
        var version: Int64 = 0
        try store.db.query("PRAGMA user_version") { version = $0.int(0) }
        #expect(version == IndexStore.schemaVersion)
        let searcher = try Searcher(store: store, loadVectors: false)
        #expect(try searcher.search("المكتبة", queryVector: nil).map(\.path) == ["/d/notes.txt"])
        #expect(try store.pending(limit: nil).map(\.path) == ["/d/rent.pdf"])   // to be read again, as a picture
        // Schema 3: the screenshot's words are for keyword search only.
        var vectors = -1
        try store.db.query("SELECT COUNT(vec) FROM segments WHERE kind = 'ocr'") { vectors = Int($0.int(0)) }
        #expect(vectors == 0)
        #expect(try searcher.search("K7Q2LM", queryVector: nil).map(\.path) == ["/d/shot.png"])
        // Schema 4: the vectors are named by their version, not by the llama.cpp build that made them.
        let named = "google/embeddinggemma-2@bfcd298 llama.cpp-vectors1 text-q8_0+mmproj-q8_0"
        #expect(try store.meta("vector_source") == named)
        #expect(try store.meta("fingerprint")?.hasPrefix(named + " | ") == true)
        // Schema 5 (long files finished later, `LongFilesTests`) leaves short ones as they were.
        #expect(try store.unfinishedCount() == (0, 0))
    }

    @Test func schemaFiveGetsTheFilterTableFromWhatIsStored() throws {
        // An index as schema 5 left it: ß and "2'380" kept as they were, no `fts_tri`.
        let old = "Termin an der Seestraße, CHF 2'380.50"
        var vectors: [String] = []
        do {
            let store = try IndexStore(directory: folder)
            let id = try store.insert(Candidate(path: "/d/Straße.odt", kind: .doc, size: 1, mtime: 1, inode: 1, device: 1))
            try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1, text: "x",
                                 vector: FakeEmbedder.vector(for: "x"))
            try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 2, text: "قَالَ")   // harakat: has `original`
            try store.db.run("UPDATE fts SET body = ?, original = NULL WHERE rowid = 2", [.text(old)])
            try store.db.execute("""
                DROP TABLE fts_tri;
                UPDATE fts SET name = 'Straße.odt' WHERE rowid = 1;
                PRAGMA user_version = 5;
                """)
            try store.db.query("SELECT hex(vec) FROM segments ORDER BY id") { vectors.append($0.text(0) ?? "") }
        }
        let store = try IndexStore(directory: folder)
        var version: Int64 = 0
        try store.db.query("PRAGMA user_version") { version = $0.int(0) }
        #expect(version == 6)
        var rows: [String] = []
        try store.db.query("SELECT rowid, name, body, coalesce(original, '-') FROM fts ORDER BY rowid") { row in
            rows.append((0..<4).map { row.text(Int32($0)) ?? "" }.joined(separator: "|"))
        }
        #expect(rows == ["1|Strasse.odt|d|-", "2||Termin an der Seestrasse, CHF 2380.50|\(old)", "3||قال|قَالَ"])
        var after: [String] = []
        try store.db.query("SELECT hex(vec) FROM segments ORDER BY id") { after.append($0.text(0) ?? "") }
        #expect(after == vectors)   // nothing embedded again
        #expect(try trigramRowids(store) == [1, 2, 3])
        let searcher = try Searcher(store: store, loadVectors: false)
        #expect(try searcher.search("Seestrasse", queryVector: nil).map(\.path) == ["/d/Straße.odt"])
        #expect(try searcher.search("strasse", queryVector: nil).map(\.path) == ["/d/Straße.odt"])   // its name too
    }

    /// The rows of `fts_tri`, which must be `fts`'s.
    func trigramRowids(_ store: IndexStore) throws -> [Int64] {
        var tri: [Int64] = [], fts: [Int64] = []
        try store.db.query("SELECT rowid FROM fts_tri ORDER BY rowid") { tri.append($0.int(0)) }
        try store.db.query("SELECT rowid FROM fts ORDER BY rowid") { fts.append($0.int(0)) }
        #expect(tri == fts)
        return tri
    }

    @Test func theTrigramTableKeepsInStepWithKeywordSearch() throws {
        let store = try IndexStore(directory: folder)
        func trigrams(_ text: String) throws -> Set<Int64> {
            var rows = Set<Int64>()
            try store.db.query("SELECT rowid FROM fts_tri WHERE fts_tri MATCH ?", [.text(IndexStore.trigramQuery(text)!)]) {
                rows.insert($0.int(0))
            }
            return rows
        }
        let doc = try store.insert(Candidate(path: "/a/Mietvertrag.pdf", kind: .pdf, size: 1, mtime: 1, inode: 1,
                                             device: 1))
        try store.addSegment(file: doc, kind: .page, modality: .text, loc: 1, text: "Mietkautionskonto der Bank")
        let memo = try store.insert(Candidate(path: "/a/memo.m4a", kind: .audio, size: 1, mtime: 1, inode: 2, device: 1))
        try store.addSegment(file: memo, kind: .audio, modality: .audio, loc: 0, locEnd: 30,
                             vector: FakeEmbedder.vector(for: "memo"))
        #expect(try trigramRowids(store).count == 3)
        #expect(try trigrams("kaution").count == 1)
        #expect(try trigrams("KÄUTION").count == 1)   // case and accents don't matter

        // Transcripts in and out.
        let window = try store.audioWindows(of: memo)[0].id
        try store.setTranscript(file: memo, texts: [(window, "Die Kaution ist überwiesen")], info: ["transcript": "done"])
        #expect(try trigrams("kaution").count == 2)
        try store.removeTranscripts()
        #expect(try trigrams("kaution").count == 1)
        _ = try trigramRowids(store)

        // A move renames the name row in both; a change on disk drops the pages from both.
        try store.move(doc, to: "/a/Wohnung/Kautionsvertrag.pdf")
        #expect(try trigrams("kautionsvertrag").count == 1 && trigrams("mietvertrag").isEmpty)
        #expect(try trigrams("wohnung").count == 1)   // its folder
        try store.requeue(doc, as: Candidate(path: "/a/Wohnung/Kautionsvertrag.pdf", kind: .pdf, size: 2, mtime: 2,
                                             inode: 1, device: 1))
        #expect(try trigrams("mietkaution").isEmpty)
        _ = try trigramRowids(store)
        try store.addSegment(file: doc, kind: .page, modality: .text, loc: 1, text: "Mietkautionskonto")
        try store.resetAll()
        #expect(try trigrams("mietkaution").isEmpty)
        #expect(try trigramRowids(store).count == 2)   // the names stay
        try store.delete(memo)
        #expect(try store.prune(keepingUnder: []) == 1)
        #expect(try trigramRowids(store).isEmpty)
    }

    @Test func landmarkFindsThePageInPreview() {
        let pages = ["Quarterly business review\nRevenue grew in Japan and Europe.",
                     "Hiking trip to Mount Fuji\nWe took the Yoshida trail from the fifth station in Japan."]
        // A word that's on that page, preferring one that isn't on an earlier page…
        #expect(Landmark.find(page: 2, texts: pages, words: ["japan", "Yoshida"]) == "Yoshida")
        // …else any that is.
        #expect(Landmark.find(page: 2, texts: pages, words: ["japan", "bread"]) == "Japan")
        #expect(Landmark.find(page: 2, texts: pages, words: ["bread"]) == nil)
        #expect(Landmark.find(page: 1, texts: pages, words: ["japan"]) == nil)   // opens there anyway
        // Spelled as the page spells it; a word a garbled text layer lost isn't offered.
        let arabic = ["التقرير الربعي", "رحلة إلى البتراء\nزرنا مدينة البتراء الأثرية في جنوب الأردن"]
        #expect(Landmark.find(page: 2, texts: arabic, words: ["الاردن"]) == "الأردن")
        let garbled = ["التقرير الربعي", "زرنا مدينة البتراء ا?ثرية في جنوب ا?ردن"]
        #expect(Landmark.find(page: 2, texts: garbled, words: ["الاردن"]) == nil)
    }

    @Test func matchesAreFoundAsKeywordSearchFindsThemButShownAsWritten() {
        let arabic = "زرنا مدينة البتراء الأثرية في جنوب الأردن."
        let found = SearchText.matches(of: "الاردن", in: arabic).map { String(arabic[$0]) }
        #expect(found == ["الأردن"])                                     // the hamza is kept: it's how it's written
        let voweled = "إِنَّ الْمَكْتَبَةَ تُغْلَقُ"
        #expect(SearchText.matches(of: "المكتبة", in: voweled).map { String(voweled[$0]) } == ["الْمَكْتَبَةَ"])
        let bengali = "একটি বড় কুমিরের ছবি"
        #expect(SearchText.matches(of: "কুমির", in: bengali).map { String(bengali[$0]) } == ["কুমিরের"])   // never "কুমি"
        let english = "Sunday trip: day two"
        #expect(SearchText.matches(of: "day", in: english).map { String(english[$0]) } == ["day"])   // not in "Sunday"
        let turkish = String(repeating: "İ", count: 60) + " son kelime"
        #expect(SearchText.matches(of: "kelime", in: turkish).map { String(turkish[$0]) } == ["kelime"])
    }

    @Test func snippetsQuoteTheTextAsWritten() {
        let text = "قَالَ مُحَمَّدٌ إِنَّ الْمَكْتَبَةَ الْعَامَّةَ تُغْلَقُ فِي السَّاعَةِ الثَّامِنَةِ مَسَاءً يَوْمَ الْخَمِيسِ"
        let snippet = SearchText.snippet(text, terms: ["المكتبة"])
        #expect(snippet?.contains("«الْمَكْتَبَةَ»") == true)
        #expect(SearchText.snippet(text, terms: ["كلمة"]) == nil)
    }

    @Test func realArabicAbbreviationsAreNotLostLetters() {
        #expect(PageTextProblem.check("أ.د.محمد علي، أستاذ في الجامعة. د.خالد و د.سارة من شركة ذ.م.م للتجارة") == nil)
        let bullets = String(repeating: "\u{F0B7} Item one of the slide\n", count: 6)
        #expect(PageTextProblem.check(bullets) == nil)
    }
}
