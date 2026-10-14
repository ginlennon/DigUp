import Foundation
import Testing
@testable import DigUpKit

/// A search kept to some folders (`Searcher.search(folders:)`): only files inside them, and still `limit` of them.
@Suite final class SearchFoldersTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func store() throws -> IndexStore { try IndexStore(directory: folder.appendingPathComponent("index")) }

    private var inode: UInt64 = 0

    @discardableResult
    func add(_ store: IndexStore, _ path: String, vector: [Float]? = nil, text: String? = nil) throws -> Int64 {
        inode += 1
        let id = try store.insert(Candidate(path: path, kind: .image, size: 1, mtime: 1, inode: inode, device: 1))
        if let vector { try store.addSegment(file: id, kind: .image, modality: .image, vector: vector) }
        if let text { try store.addSegment(file: id, kind: .ocr, modality: .text, text: text) }
        return id
    }

    /// `weight` of the way from noise to `target`, as a unit vector: the bigger, the closer.
    func near(_ target: [Float], _ weight: Float, seed: String) -> [Float] {
        let noise = FakeEmbedder.vector(for: seed)
        let mixed = zip(target, noise).map { weight * $0 + (1 - weight) * $1 }
        let norm = mixed.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return mixed.map { $0 / norm }
    }

    @Test func meaningMatchesOutsideAreLeftOutAndTheLimitIsFilledFromInside() throws {
        let store = try store()
        let query = FakeEmbedder.vector(for: "query")
        try store.db.transaction {
            for index in 0..<200 { try add(store, "/t/noise/\(index).png", vector: FakeEmbedder.vector(for: "\(index)")) }
            // The best matches are outside, and so is a sibling whose name starts like the folder's.
            for index in 0..<10 { try add(store, "/t/out/\(index).png", vector: near(query, 0.9, seed: "out\(index)")) }
            try add(store, "/t/inner/sibling.png", vector: near(query, 0.95, seed: "sibling"))
            for index in 0..<5 { try add(store, "/t/in/sub/\(index).png", vector: near(query, 0.6, seed: "in\(index)")) }
        }
        let searcher = try Searcher(store: store)
        let everywhere = try searcher.search("", queryVector: query, limit: 3)
        #expect(everywhere.count == 3 && everywhere.allSatisfy { !$0.path.hasPrefix("/t/in/") })
        let inside = try searcher.search("", queryVector: query, limit: 3, folders: ["/t/in"])
        #expect(inside.count == 3)
        #expect(inside.allSatisfy { $0.path.hasPrefix("/t/in/sub/") })
        #expect(try searcher.search("", queryVector: query, limit: 10, folders: ["/t/in"]).count == 5)
        #expect(try searcher.search("", queryVector: query, limit: 10, folders: ["/t/in", "/t/inner"]).count == 6)
        // No folders, or an empty list: everywhere.
        #expect(try searcher.search("", queryVector: query, limit: 3, folders: []).map(\.path) == everywhere.map(\.path))
    }

    @Test func keywordMatchesInsideAreFoundPastTheBestThousandOutside() throws {
        // Keyword search reads its best 1,000 matches: filtered afterwards, a folder whose files rank below a thousand
        // others would have none.
        let store = try store()
        try store.db.transaction {
            for index in 0..<1100 { try add(store, "/t/out/\(index).png", text: "quokka") }
            for index in 0..<2 {
                try add(store, "/t/in/\(index).png", text: "a quokka in the garden, among many other words that "
                        + "make this text long enough to rank below the short ones")
            }
        }
        let searcher = try Searcher(store: store)
        let hits = try searcher.search("quokka", queryVector: nil, limit: 20, folders: ["/t/in"])
        #expect(hits.map(\.path).sorted() == ["/t/in/0.png", "/t/in/1.png"])
        #expect(hits.allSatisfy { $0.keywordRank != nil && $0.excerpt?.contains("«quokka»") == true })
        #expect(try searcher.search("quokka", queryVector: nil, limit: 20).count == 20)
    }

    #if !os(Windows)
    @Test func aFolderReachedThroughALinkIsTheFolderItPointsTo() throws {
        // The index keeps paths as the walk reports them (the real ones); a folder can be named another way.
        let real = URL(fileURLWithPath: FolderSelection.realPath(folder.path)).appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = try store()
        let query = FakeEmbedder.vector(for: "query")
        try store.db.transaction {
            for index in 0..<50 { try add(store, "/t/noise/\(index).png", vector: FakeEmbedder.vector(for: "\(index)")) }
            try add(store, "/t/out/best.png", vector: near(query, 0.9, seed: "best"))
            try add(store, real.path + "/beach.png", vector: near(query, 0.7, seed: "beach"))
        }
        let hits = try Searcher(store: store).search("", queryVector: query, limit: 5, folders: [link.path])
        #expect(hits.map(\.path) == [real.path + "/beach.png"])
    }
    #endif
}
