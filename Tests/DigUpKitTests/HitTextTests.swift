import Foundation
import Testing
@testable import DigUpKit

/// A hit whose segment has no words of its own points at the one that has them (`SearchHit.textSegmentID`).
@Suite struct HitTextTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func picturesPointAtTheirWords() throws {
        let store = try IndexStore(directory: folder)
        let query = FakeEmbedder.vector(for: "query")
        func file(_ path: String, _ kind: FileKind, inode: UInt64) throws -> Int64 {
            try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1, inode: inode, device: 1))
        }
        try store.db.transaction {
            for index in 0..<30 {
                let id = try file("/t/noise/\(index).png", .image, inode: UInt64(100 + index))
                try store.addSegment(file: id, kind: .image, modality: .image, vector: FakeEmbedder.vector(for: "\(index)"))
            }
            // A screenshot: its picture's vector, and the words OCR read off it.
            let shot = try file("/t/shot.png", .screenshot, inode: 1)
            try store.addSegment(file: shot, kind: .image, modality: .image, vector: query)
            try store.addSegment(file: shot, kind: .ocr, modality: .text, text: "Error QX17: payment declined")
            // A scan whose page has its OCR'd words on the page's picture: they're its own.
            let scan = try file("/t/scan.pdf", .pdf, inode: 2)
            try store.addSegment(file: scan, kind: .pageImage, modality: .image, loc: 1, text: "Invoice 2026",
                                 vector: query.map { $0 * 0.99 + 0.001 })
            // A page with garbled words: a vector of them without text, and its picture with what OCR read.
            let garbled = try file("/t/garbled.pdf", .pdf, inode: 3)
            try store.addSegment(file: garbled, kind: .page, modality: .text, loc: 2,
                                 vector: query.map { $0 * 0.98 + 0.002 })
            try store.addSegment(file: garbled, kind: .pageImage, modality: .image, loc: 1, text: "page one")
            try store.addSegment(file: garbled, kind: .pageImage, modality: .image, loc: 2, text: "page two")
        }
        let searcher = try Searcher(store: store)
        let hits = Dictionary(uniqueKeysWithValues: try searcher.search("", queryVector: query, limit: 5)
            .map { ($0.path, $0) })
        let shot = try #require(hits["/t/shot.png"])
        #expect(shot.segment == .image)
        #expect(try shot.textSegmentID.flatMap(searcher.text(ofSegment:)) == "Error QX17: payment declined")
        #expect(hits["/t/scan.pdf"]?.textSegmentID == nil)
        let page = try #require(hits["/t/garbled.pdf"])
        #expect(page.segment == .page && page.loc == 2)
        #expect(try page.textSegmentID.flatMap(searcher.text(ofSegment:)) == "page two")
    }
}
