import DigUpKit
import Foundation

/// What `digup similar` and search-service's `similar` op search with: one vector for the file, and the file's own rows
/// to leave out of the results.
struct SimilarQuery {
    let vector: [Float]
    let own: Set<Int64>
    /// The vector came from the index: no model was needed.
    let stored: Bool

    /// A file in the index is found by what the index holds of it (`Searcher.storedVector`): nothing is read again, and
    /// no model starts. Any other file is read and embedded as indexing would (`FileVector`): by `textEncoder` when the
    /// text model is enough and one is running (search-service's query encoder), else by a model started for it and
    /// closed after (the whole model, 1 GB, when the file may need the image or audio encoder).
    init(_ path: String, searcher: Searcher, log: URL, textEncoder: () -> (any Embedder)? = { nil }) throws {
        own = try searcher.files(at: path)
        if let vector = try searcher.storedVector(of: own) {
            (self.vector, stored) = (vector, true)
            return
        }
        guard FileManager.default.fileExists(atPath: path) else { throw CLIError("no such file: \(path)") }
        let url = URL(fileURLWithPath: path)
        guard let kind = FileVector.kind(of: url) else { throw CLIError("DigUp doesn't read this type of file: \(path)") }
        let media = FileVector.needsMedia(kind)
        let shared = media ? nil : textEncoder()
        let embedder = try shared ?? makeEmbedder(textOnly: !media, log: log, qos: .userInitiated)
        defer { if shared == nil { embedder.close() } }
        // Vectors from another model or runtime must never meet (as for queries).
        if let source = searcher.vectorSource, source != embedder.info.vectorSource {
            throw CLIError("index vectors come from \(source) but the model here is \(embedder.info.vectorSource)")
        }
        vector = try FileVector.embed(url, kind: kind, embedder: embedder)
        stored = false
    }
}

/// `digup similar <file>`: the files most like it, by meaning alone (`Searcher.similar`).
func similar(_ args: Arguments) throws {
    guard let file = args.positional.first else {
        throw CLIError("similar to which file? e.g. digup similar ~/Pictures/beach.jpg")
    }
    let path = Arguments.folderURL(file).path
    let store = try IndexStore(directory: args.indexFolder, file: IndexStore.mainFile)
    let searcher = try Searcher(store: store)
    let started = Date()
    let query = try SimilarQuery(path, searcher: searcher,
                                 log: store.directory.appendingPathComponent("worker-query.log"))
    let embedded = Date()
    let filter = args.values["--filter"].map(KeywordFilter.init)
    if let note = filter?.note { FileHandle.standardError.write(Data("filter: \(note)\n".utf8)) }
    let hits = try searcher.similar(to: query.vector, excluding: query.own, kinds: try args.kinds(),
                                    folders: args.searchFolders, limit: args.values["-n"].flatMap(Int.init) ?? 10,
                                    zGate: args.values["--zgate"].flatMap(Double.init) ?? Searcher.similarZGate,
                                    filter: filter)
    let searched = Date()
    if args.flags.contains("--json") {
        printJSON(hits)
        return
    }
    if hits.isEmpty { print("nothing much like it") }
    printHits(hits)
    let source = query.stored ? "its vectors from the index"
        : String(format: "read and embedded in %.2f s incl. start-up", embedded.timeIntervalSince(started))
    print(String(format: "(%d vectors · %@ · search %.0f ms)", searcher.vectorCount, source,
                 searched.timeIntervalSince(embedded) * 1000))
}
