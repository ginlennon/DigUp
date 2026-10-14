import Foundation
import Testing
@testable import DigUpKit

/// Files like a file (`Searcher.similar`), from its vectors in the index or from the file itself (`FileVector`).
@Suite final class SimilarTests {
    /// In Caches, not the temporary folder: the walk reports /private/var/… for /var/… on a Mac, and the test looks
    /// files up by the paths it wrote.
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func store() throws -> IndexStore { try IndexStore(directory: folder.appendingPathComponent("index")) }

    /// `weight` of the way from noise to `target`, as a unit vector.
    func near(_ target: [Float], _ weight: Float, seed: String) -> [Float] {
        let mixed = zip(target, FakeEmbedder.vector(for: seed)).map { weight * $0 + (1 - weight) * $1 }
        let norm = mixed.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return mixed.map { $0 / norm }
    }

    @Test func aFileInTheIndexIsFoundByItsVectorsAndLeftOutOfItsResults() throws {
        let store = try store()
        let topic = FakeEmbedder.vector(for: "sailing")
        var inode: UInt64 = 0
        func add(_ path: String, _ kind: FileKind, _ vectors: [[Float]]) throws {
            inode += 1
            let id = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1, inode: inode, device: 1))
            for (page, vector) in vectors.enumerated() {
                try store.addSegment(file: id, kind: .page, modality: .text, loc: Double(page + 1), vector: vector)
            }
        }
        try store.db.transaction {
            for index in 0..<100 { try add("/t/noise/\(index).pdf", .pdf, [FakeEmbedder.vector(for: "\(index)")]) }
            try add("/t/book.pdf", .pdf, [near(topic, 0.8, seed: "p1"), near(topic, 0.8, seed: "p2")])
            try add("/t/log.pdf", .pdf, [FakeEmbedder.vector(for: "cover"), near(topic, 0.7, seed: "log")])
            try add("/t/notes.txt", .doc, [near(topic, 0.6, seed: "notes")])
            try add("/t/elsewhere/trip.pdf", .pdf, [near(topic, 0.65, seed: "trip")])
        }
        let searcher = try Searcher(store: store)
        let own = try searcher.files(at: "/t/book.pdf")
        #expect(own.count == 1)
        #expect(try searcher.files(at: "/t/missing.pdf").isEmpty)
        // The mean of its two pages, unit length again: nearer the topic than either page.
        let vector = try #require(try searcher.storedVector(of: own))
        #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 1e-4)
        let cosine = zip(vector, topic).reduce(0) { $0 + $1.0 * $1.1 }
        #expect(cosine > zip(near(topic, 0.8, seed: "p1"), topic).reduce(0) { $0 + $1.0 * $1.1 })

        let hits = try searcher.similar(to: vector, excluding: own, limit: 3)
        #expect(hits.map(\.path) == ["/t/log.pdf", "/t/elsewhere/trip.pdf", "/t/notes.txt"])
        #expect(hits[0].loc == 2)   // the page most like it
        #expect(hits.allSatisfy { $0.keywordRank == nil && $0.z != nil })
        #expect(try searcher.similar(to: vector, excluding: own, kinds: [.doc]).map(\.path) == ["/t/notes.txt"])
        #expect(try searcher.similar(to: vector, excluding: own, folders: ["/t/elsewhere"]).map(\.path)
                == ["/t/elsewhere/trip.pdf"])
        #expect(try searcher.similar(to: vector).first?.path == "/t/book.pdf")   // most like itself
    }

    @Test func aFileOutsideTheIndexIsEmbeddedAsIndexingWould() throws {
        // Index a document and a PDF, then make their vectors again from the files: the same as the first ones stored.
        let files = folder.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let words = ["river", "garden", "morning", "letter", "window", "harbour", "kitchen", "mountain", "station"]
        let prose = (0..<600).map { words[$0 * 7 % words.count] }.joined(separator: " ")
        let doc = files.appendingPathComponent("Trip notes.md")
        try Data(prose.utf8).write(to: doc)
        let pdf = files.appendingPathComponent("Field guide.pdf")
        try TextPDF.write(["Page one. " + prose.prefix(900), "Page two. " + prose.prefix(500)], to: pdf)

        let store = try store()
        let embedder = FakeEmbedder()
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { embedder })
        _ = try indexer.sync([files])
        #expect(try indexer.run()["done"] == 2)
        for (url, kind) in [(doc, FileKind.doc), (pdf, .pdf)] {
            #expect(FileVector.kind(of: url) == kind)
            var first: [Float] = []
            try store.db.query("""
                SELECT s.vec FROM segments s JOIN files f ON f.id = s.file
                WHERE f.path = ? AND s.vec IS NOT NULL ORDER BY s.id LIMIT 1
                """, [.text(url.path)]) { row in
                let blob = row.blob(0) ?? Data()
                first = blob.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)).map(Float.init) }
            }
            let made = try FileVector.embed(url, kind: kind, embedder: embedder)
            #expect(first.count == made.count)
            #expect(zip(first, made).allSatisfy { abs($0 - $1) < 1e-3 }, "\(url.lastPathComponent)")
        }
        #expect(FileVector.kind(of: files.appendingPathComponent("tool.py")) == .doc)   // loose code, as a document
        #expect(FileVector.kind(of: files.appendingPathComponent("archive.zip")) == nil)
        #expect(!FileVector.needsMedia(.doc) && FileVector.needsMedia(.pdf))
    }
}
