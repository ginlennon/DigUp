// Text recognition without Vision (Linux, Windows): tesseract, run as a program, as ffmpeg is. It's looked for in
// $DIGUP_TESSERACT (the program, or its folder), beside the helper, then on PATH. Without it there's no OCR: screenshots
// and scans have their picture vector and their name, and `IndexStore.readAgainOnce` reads them again once it's there.
#if !canImport(ImageIO)
import Foundation

extension OCR {
    static let tesseract: String? = {
        var folders: [String] = []
        if let chosen = ProcessInfo.processInfo.environment["DIGUP_TESSERACT"], !chosen.isEmpty {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: chosen, isDirectory: &isFolder), !isFolder.boolValue,
               FileManager.default.isExecutableFile(atPath: chosen) {
                return chosen
            }
            folders.append(chosen)
        }
        if let executable = Bundle.main.executableURL { folders.append(executable.deletingLastPathComponent().path) }
        for folder in folders {
            let candidate = folder + "/" + FileSystem.program("tesseract")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return FileSystem.executable("tesseract")
    }()

    /// The languages tesseract reads, as its "-l" takes them ("eng+deu"): those named in $DIGUP_OCR_LANGS that are
    /// installed, or else the system's language, English, German, French, Spanish, Italian, Portuguese and Arabic, the
    /// first three of them that are installed. Every language makes it slower (eng+deu takes 1.5× as long as eng), and
    /// one it doesn't have isn't read at all. On Ubuntu, `sudo apt install tesseract-ocr-<code>` (fra, ara…) adds one.
    static let languages: [String] = {
        guard let tesseract, let listed = try? run(tesseract, ["--list-langs"], seconds: 30) else { return [] }
        // The first line says where they are; then one name a line. osd (orientation) and equ (equations) aren't
        // languages.
        let installed = listed.split(whereSeparator: \.isNewline).dropFirst().map(String.init)
            .filter { !$0.isEmpty && $0 != "osd" && $0 != "equ" }
        let environment = ProcessInfo.processInfo.environment
        if let chosen = environment["DIGUP_OCR_LANGS"] {
            let wanted = chosen.split(whereSeparator: { $0 == "+" || $0 == "," || $0 == " " }).map(String.init)
                .filter(installed.contains)
            if !wanted.isEmpty { return wanted }
        }
        let system = [environment["LC_ALL"], environment["LC_MESSAGES"], environment["LANG"]].compactMap { $0 }
            .first { !$0.isEmpty }.flatMap { codes[String($0.prefix(2))] }
        var order: [String] = []
        for language in [system, "eng", "deu", "fra", "spa", "ita", "por", "ara"].compactMap({ $0 })
            where installed.contains(language) && !order.contains(language) {
            order.append(language)
        }
        return Array(order.prefix(3))
    }()

    /// Tesseract's names for the system's languages (ISO 639-1, as in LANG=de_CH.UTF-8).
    private static let codes = [
        "en": "eng", "de": "deu", "fr": "fra", "es": "spa", "it": "ita", "pt": "por", "nl": "nld", "sv": "swe",
        "da": "dan", "nb": "nor", "fi": "fin", "pl": "pol", "cs": "ces", "hu": "hun", "ro": "ron", "tr": "tur",
        "el": "ell", "ru": "rus", "uk": "ukr", "ar": "ara", "fa": "fas", "he": "heb", "hi": "hin", "bn": "ben",
        "ja": "jpn", "ko": "kor", "zh": "chi_sim",
    ]

    static let isAvailable = tesseract != nil && !languages.isEmpty

    /// Arabic is among the languages read (`PDFExtractor.pages` reads a text layer that lost letters by OCR then).
    static let readsArabic = languages.contains("ara")

    /// Formats tesseract opens itself (through Leptonica); others are decoded here first.
    private static let readable: Set<String> = ["png", "jpg", "jpeg", "jpe", "jfif", "bmp", "gif", "tif", "tiff",
                                                "webp", "pnm", "ppm", "pgm"]

    /// The text in the image at `url`, for keyword search, read at full resolution (small UI text is what screenshots
    /// are full of). ~0.3–0.5 s for a 1440×900 screenshot with eng+deu on a Ryzen laptop (2026-10-14).
    static func text(ofImageAt url: URL) -> String {
        guard isAvailable else { return "" }
        if readable.contains(url.pathExtension.lowercased()) { return text(ofFile: url.path) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).pgm")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let image = try? ImageExtractor.fullImage(url), (try? image.writeGray(to: scratch)) != nil else { return "" }
        return text(ofFile: scratch.path)
    }

    /// The text in a picture made here (a scanned page), written to `folder` for tesseract to read.
    static func text(in image: RGBImage, folder: URL) -> String {
        guard isAvailable else { return "" }
        let scratch = folder.appendingPathComponent("ocr-\(UUID().uuidString).pgm")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? image.writeGray(to: scratch)) != nil else { return "" }
        return text(ofFile: scratch.path)
    }

    /// Lines in reading order (page segmentation 3: columns and blocks found by themselves), blank ones left out. A
    /// picture tesseract can't read, or doesn't finish within a minute, has no text.
    private static func text(ofFile path: String) -> String {
        guard let tesseract, let read = try? run(tesseract, [path, "stdout", "-l", languages.joined(separator: "+"),
                                                             "--psm", "3"], seconds: 60)
        else { return "" }
        return read.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "\u{0C}" }.joined(separator: "\n")
    }

    /// Runs tesseract and returns what it wrote; stopped after `seconds`. Throws when it can't start or fails.
    private static func run(_ tool: String, _ arguments: [String], seconds: Double) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: stop)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ExtractError.unreadable("tesseract failed (\(process.terminationStatus))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension RGBImage {
    /// As an 8-bit gray PGM: tesseract works in gray anyway, and it's written in no time (a PNG of a page at 300 dpi
    /// takes longer to compress than to read).
    func writeGray(to url: URL) throws {
        var data = Data("P5\n\(width) \(height)\n255\n".utf8)
        data.reserveCapacity(data.count + width * height)
        var gray = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let p = i * 3
            gray[i] = UInt8((Int(pixels[p]) * 299 + Int(pixels[p + 1]) * 587 + Int(pixels[p + 2]) * 114) / 1000)
        }
        data.append(contentsOf: gray)
        try data.write(to: url)
    }
}
#endif
