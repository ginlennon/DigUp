import Foundation
import Testing
@testable import DigUpKit

/// The main field's words (KEYWORD_FILTER_PLAN.md F4): rare words count more, codes stay whole, kind words in German,
/// French, Spanish, Italian and Portuguese.
@Suite struct QueryWordsTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A store with one text segment per file.
    func index(_ files: [(path: String, text: String, kind: FileKind)]) throws -> Searcher {
        let store = try IndexStore(directory: folder)
        for (number, file) in files.enumerated() {
            let id = try store.insert(Candidate(path: file.path, kind: file.kind, size: 1, mtime: 1,
                                                inode: UInt64(number + 1), device: 1))
            try store.addSegment(file: id, kind: file.kind == .screenshot ? .ocr : .chunk, modality: .text, loc: 1,
                                 text: file.text)
        }
        return try Searcher(store: store, loadVectors: false)
    }

    // MARK: Rare words count more

    @Test func rareWordsCountMore() {
        let (rank, gate) = Searcher.weights([1, 50, 100, 0], of: 100)
        #expect(rank[0] > rank[1] && rank[1] > rank[2])
        #expect(rank[2] > 0)                                         // a word in every file still counts a little
        #expect(abs(rank[3] - (rank[0] + rank[1] + rank[2]) / 3) < 1e-12)   // in no file: an average word
        #expect(gate[3] == gate[0])                                  // … but at the gate as rare as a word in one file
        #expect(Array(gate.prefix(3)) == Array(rank.prefix(3)))
        // Words as common as each other count the same: their shares are what they were.
        let same = Searcher.weights([40, 40, 40], of: 100).rank
        #expect(same[0] == same[1] && same[1] == same[2])
    }

    @Test func commonWordsAloneDontLetAFileIn() throws {
        let filler = (1...10).map { number in
            (path: "/notes/Brief \(number).txt", text: "Die Unterlagen für die Sitzung des Vereins, Nummer \(number).",
             kind: FileKind.doc)
        }
        let searcher = try index(filler + [("/notes/Bootssteg.txt", "Zwei Offerten für den Bootssteg liegen vor.", .doc)])
        // Half of the query's words are "für", "die", "des": every letter has them, and they used to let all ten in.
        let hits = try searcher.search("Offerten für die Sanierung des Bootsstegs", queryVector: nil)
        #expect(hits.map(\.path) == ["/notes/Bootssteg.txt"])
        // A query of only common words still finds the files that have them (both: the ten letters).
        #expect(try searcher.search("für die", queryVector: nil).count == 10)
    }

    // MARK: Codes kept together

    @Test func codesAreTheirPartsSideBySide() {
        let keep = { (_: String) in true }
        #expect(Searcher.terms("Rechnung RE-2041", keepingCodes: keep) == ["rechnung", "re 2041"])
        #expect(Searcher.terms("Rechnung RE-2041") == ["rechnung", "re", "2041"])        // codes not kept: as before
        #expect(Searcher.terms("CHF 2'380.50", keepingCodes: keep) == ["chf", "2380 50"])
        #expect(Searcher.terms("OF-2026-118 (FA-1187)", keepingCodes: keep) == ["of 2026 118", "fa 1187"])
        #expect(Searcher.terms("e-mail l'école", keepingCodes: keep) == ["mail", "école"])   // no digit: words
        #expect(Searcher.terms("LX 1074", keepingCodes: keep) == ["lx", "1074"])          // typed apart: two words
        #expect(Searcher.codeParts(["k7q2lm"]) == nil)
        #expect(Searcher.isLookup(["re 2041"]))
    }

    @Test func aCodeDoesNotFindItsTwin() throws {
        let searcher = try index([
            ("/shots/payment.png", "Invoice INV-2041 - Acme Design Studio - $249.00", .screenshot),
            ("/memos/call.txt", "Ich rufe wegen der Rechnung RE 2041 über 1250 Franken an.", .doc),
            ("/memos/lyon.txt", "Au sujet de la facture FAM 1187 de 3450 euros.", .doc),
        ])
        let hits = try searcher.search("RE-2041", queryVector: nil)
        #expect(hits.map(\.path) == ["/memos/call.txt"])
        #expect(hits.first?.excerpt?.contains("«RE 2041»") == true)
        #expect(try searcher.search("INV-2041", queryVector: nil).first?.excerpt?.contains("«INV-2041»") == true)
        // A code that isn't in the index as written is its parts, as before: "FA-1187" still finds "FAM 1187".
        #expect(try searcher.search("FA-1187", queryVector: nil).map(\.path) == ["/memos/lyon.txt"])
    }

    // MARK: Kind words

    @Test func kindWordsInOtherLanguages() {
        #expect(Searcher.kindHints("Fotos vom Strand") == [.image])
        #expect(Searcher.kindHints("Bild von einem Pinguin") == [.image])
        #expect(Searcher.kindHints("Bildschirmfoto Zahlung abgelehnt") == [.screenshot])
        #expect(Searcher.kindHints("Sprachnachricht von Thomas") == [.audio])
        #expect(Searcher.kindHints("capture d'écran paiement refusé") == [.screenshot])
        #expect(Searcher.kindHints("message vocal de Julien") == [.audio])
        #expect(Searcher.kindHints("captura de pantalla de una transferencia") == [.screenshot])
        #expect(Searcher.kindHints("grabación de una llamada") == [.audio])
        #expect(Searcher.kindHints("grabacion de una llamada") == [.audio])          // typed without the accent
        #expect(Searcher.kindHints("schermata del pagamento") == [.screenshot])
        #expect(Searcher.kindHints("gravação sobre a fatura") == [.audio])
        #expect(Searcher.kindHints("captura de tela do pagamento") == [.screenshot])
        #expect(Searcher.kindHints("Vidéo du concert") == [.video])
        #expect(Searcher.kindHints("Bildung und Schule").isEmpty)                    // whole words only
        #expect(Searcher.kindHints("capture du drapeau").isEmpty)                    // a phrase needs all its words
    }

    @Test func kindWordsAreNotSearchedForButEverydayOnesAre() {
        #expect(Searcher.terms("Fotos vom Strand") == ["vom", "strand"])
        #expect(Searcher.terms("capture d'écran paiement refusé") == ["paiement", "refusé"])
        #expect(Searcher.terms("Vidéo du concert") == ["du", "concert"])           // as "video"
        #expect(Searcher.terms("nota de voz de Lucía") == ["de", "lucía"])           // the phrase's "de" goes with it
        // "Aufnahme" is also an admission, "registrazione" a registration: a hint, and still words.
        #expect(Searcher.terms("Aufnahme in die Schule") == ["aufnahme", "die", "schule"])
        #expect(Searcher.kindHints("Aufnahme in die Schule") == [.audio])
        #expect(Searcher.terms("registrazione al corso di yoga").first == "registrazione")
    }
}
