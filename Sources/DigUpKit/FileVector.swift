import Foundation

/// A vector for a file the index hasn't embedded, to find files like it (`Searcher.similar`). It's made the way
/// indexing makes the file's first vector, with indexing's own readers, sizes and prompts, so it can be compared with
/// the index's: a picture at its budget (a photo's, or a screenshot's), a PDF's first page (its text, or the page as a
/// picture where indexing would take it so), a document's first chunk with the document prompt, the first 30 s window
/// of sound that isn't silent, and a video's first frame (where its keyframes start). One piece stands for the file:
/// quick, and for most files the part that says what they are.
public enum FileVector {
    /// What indexing would take the file for (loose code as a document); nil for a type it doesn't read.
    public static func kind(of url: URL) -> FileKind? {
        var options = IndexOptions()
        options.includeCode = true
        let values = try? url.resourceValues(forKeys: Set(FileSystem.crawlKeys))
        guard case .index(let kind) = Rules.classify(url, values: values, options: options) else { return nil }
        return kind
    }

    /// Whether the file's vector may need the image and audio encoders, not just the text model (a PDF's first page
    /// can be a scan).
    public static func needsMedia(_ kind: FileKind) -> Bool {
        kind != .doc && kind != .code
    }

    public static func embed(_ url: URL, kind: FileKind, embedder: any Embedder,
                             options: IndexOptions = IndexOptions()) throws -> [Float] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigUp-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let title = url.deletingPathExtension().lastPathComponent
        switch kind {
        case .image, .screenshot:
            let screenshot = kind == .screenshot
            let image = try ImageExtractor.prepare(url, maxPixel: screenshot ? 1536 : 1024, minSide: options.minImageSide,
                                                   to: folder, png: screenshot)
            return try only(embedder.embedImages([image.path],
                                                 budget: screenshot ? options.screenshotBudget : options.photoBudget))
        case .pdf:
            let read = try PDFExtractor.pages(of: url, range: { 0..<min($0, 1) }, minText: options.minPageText,
                                              renderPixels: 1400, to: folder)
            guard let page = read.pages.first else { throw ExtractError.empty("no pages") }
            if let picture = page.imagePath { return try only(embedder.embedImages([picture], budget: options.pageBudget)) }
            return try only(embedder.embedTexts([Prompts.document(title: read.title ?? title,
                                                                  text: String(page.text.prefix(4000)))]))
        case .doc:
            guard let chunk = DocExtractor.chunks(try DocExtractor.text(of: url), limit: 1).first else {
                throw ExtractError.empty("no text")
            }
            return try only(embedder.embedTexts([Prompts.document(title: title, text: chunk)]))
        case .code:
            let file = try CodeExtractor.read(url, options: options)
            guard let piece = file.pieces.first else { throw ExtractError.empty("no code") }
            return try only(embedder.embedTexts([Prompts.document(title: file.title, text: piece.text)]))
        case .audio:
            // Indexing's reader cuts the whole file into windows; the first one with sound in it is the one we want.
            let (window, hop) = (options.audioWindow, options.audioHop)
            let pieces = try runBlocking {
                try await AudioExtractor.windows(of: url, window: window, hop: hop, to: folder)
            }.pieces
            guard let first = pieces.first else { throw ExtractError.empty("silent or shorter than 2 s") }
            return try only(embedder.embedAudio([first.path]))
        case .video:
            let frame = folder.appendingPathComponent("frame.jpg")
            try runBlocking { try await VideoExtractor.frame(at: 0.5, of: url, pixels: 1024, to: frame) }
            return try only(embedder.embedImages([frame.path], budget: options.frameBudget))
        }
    }

    private static func only(_ embeddings: [Embedding]) throws -> [Float] {
        guard let vector = embeddings.first?.vector else {
            throw ExtractError.unreadable(embeddings.first?.error ?? "no vector")
        }
        return vector
    }

    private static func only(_ vectors: [[Float]]) throws -> [Float] {
        guard let vector = vectors.first, !vector.isEmpty else { throw ExtractError.unreadable("no vector") }
        return vector
    }
}
