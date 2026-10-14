import DigUpKit
import Foundation
import LlamaRuntime

/// `digup doctor [--deep] [--json]`: whether DigUp can work here, one line per check, with what to do about one that
/// fails. The essential checks (the model files, the model making the vectors it should, an index DigUp can open)
/// decide the exit code: 0 when they pass, 1 when one fails. The others say what some files or features are missing.
/// It takes a second or two, most of it the self-test loading the text model; `--deep` also checks the model files'
/// SHA-256 and the index's pages (seconds more). `--json`: one line,
/// {"ok":bool, "checks":[{"name","ok","essential","detail","fix"?}], "seconds":n}, for shells and the MCP server.
func doctor(_ args: Arguments) -> Int32 {
    let started = Date()
    let deep = args.flags.contains("--deep")
    let json = args.flags.contains("--json")
    var checks: [Check] = []
    func add(_ check: Check) {
        checks.append(check)
        if !json { print(check.line) }   // as they come: the self-test takes a moment
    }
    modelChecks(deep: deep).forEach(add)
    add(Check(name: "llama.cpp", ok: true, essential: false,
              detail: "\(LlamaEmbedder.buildTag), vectors \(LlamaEmbedder.vectorVersion) "
                  + "(\(LlamaEmbedder.modelInfo.vectorSource))"))
    add(computeCheck())
    add(selfTest())
    toolChecks().forEach(add)
    indexChecks(args.indexFolder, deep: deep).forEach(add)
    add(diskCheck(args.indexFolder))
    #if os(Linux)
    if let check = watchCheck(args.indexFolder) { add(check) }
    #endif
    let failed = checks.filter { $0.essential && !$0.ok }
    let seconds = (Date().timeIntervalSince(started) * 100).rounded() / 100
    if json {
        emit(["ok": failed.isEmpty, "checks": checks.map(\.fields), "seconds": seconds])
    } else {
        print(failed.isEmpty ? "all essential checks pass (\(seconds) s)"
              : "\(failed.count) essential \(failed.count == 1 ? "check fails" : "checks fail") (\(seconds) s)")
    }
    return failed.isEmpty ? 0 : 1
}

struct Check {
    let name: String
    let ok: Bool
    /// DigUp can't index or search without it.
    let essential: Bool
    let detail: String
    var fix: String? = nil

    var line: String {
        "\(ok ? "✓" : "✗") \(pad(name, 11)) \(detail)" + (ok ? "" : fix.map { " → \($0)" } ?? "")
    }

    var fields: [String: Any] {
        var fields: [String: Any] = ["name": name, "ok": ok, "essential": essential, "detail": detail]
        if let fix, !ok { fields["fix"] = fix }
        return fields
    }
}

// MARK: The model

/// Both files where the model is looked for (`LlamaModels`), at their size; with `deep`, their SHA-256 too (about a
/// second for both).
private func modelChecks(deep: Bool) -> [Check] {
    guard let models = try? LlamaModels.locate() else {
        return [Check(name: "model", ok: false, essential: true,
                      detail: "not in " + LlamaModels.folders.map { tilde($0.path) }.joined(separator: " or "),
                      fix: "digup download-model")]
    }
    let folder = models.text.deletingLastPathComponent()
    return ModelFiles.all.map { file in
        let name = file == ModelFiles.text ? "text model" : "media model"
        // The Hugging Face cache keeps them as links into its blobs.
        let url = folder.appendingPathComponent(file.name).resolvingSymlinksInPath()
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        else {
            return Check(name: name, ok: false, essential: true,
                         detail: "no \(file.name) in \(tilde(folder.path))", fix: "digup download-model")
        }
        var detail = "\(file.name), \(bytes(size)), in \(tilde(folder.path))"
        guard size == file.bytes else {
            return Check(name: name, ok: false, essential: true, detail: detail + ": should be \(bytes(file.bytes))",
                         fix: "delete it, then digup download-model")
        }
        if deep {
            guard (try? ModelFiles.sha256(of: url)) == file.sha256 else {
                return Check(name: name, ok: false, essential: true, detail: detail + ": its SHA-256 is wrong (damaged)",
                             fix: "delete it, then digup download-model")
            }
            detail += ", SHA-256 right"
        } else {
            detail += " (--deep checks its SHA-256)"
        }
        return Check(name: name, ok: true, essential: true, detail: detail)
    }
}

/// What the model runs on. No GPU isn't an error (everything runs on the CPU, more slowly), but it's worth knowing
/// why: no driver, no backend beside digup, or DIGUP_GPU saying so.
private func computeCheck() -> Check {
    let devices = LlamaEmbedder.devices
    #if os(macOS)
    return Check(name: "compute", ok: true, essential: false, detail: devices)
    #else
    let folder = ProcessInfo.processInfo.environment["DIGUP_BACKENDS"].map(tilde) ?? "beside digup"
    guard LlamaEmbedder.hasBackend else {
        return Check(name: "compute", ok: false, essential: true, detail: "no llama.cpp backend loaded from \(folder)",
                     fix: "the libggml-cpu-*.so files go beside digup, or DIGUP_BACKENDS names their folder")
    }
    if !LlamaEmbedder.useGPU {
        let chosen = ProcessInfo.processInfo.environment["DIGUP_GPU"] ?? ""
        return Check(name: "compute", ok: true, essential: false, detail: "\(devices) (DIGUP_GPU=\(chosen): no GPU)")
    }
    guard !LlamaEmbedder.gpus.isEmpty else {
        return Check(name: "compute", ok: false, essential: false, detail: "\(devices): no GPU backend loaded",
                     fix: "for the GPU, a Vulkan driver (Ubuntu: mesa-vulkan-drivers, or NVIDIA's) and "
                         + "libggml-vulkan in \(folder); DIGUP_GPU=0 says CPU on purpose")
    }
    return Check(name: "compute", ok: true, essential: false, detail: devices)
    #endif
}

/// The text model, loaded and asked for two vectors it knows the start of (`SelfTest`): the files, llama.cpp and the
/// backend it runs on together.
private func selfTest() -> Check {
    guard let models = try? LlamaModels.locate() else {
        return Check(name: "self-test", ok: false, essential: true, detail: "no model to test",
                     fix: "digup download-model")
    }
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("digup-doctor.log")
    let started = Date()
    do {
        let embedder = try LlamaEmbedder(models: models, textOnly: true, log: log)
        defer { embedder.close() }
        let results = try SelfTest.run(embedder)
        let ok = results.allSatisfy { $0.cosine >= SelfTest.agreement }
        let detail = "cosine " + results.map { "\(String(format: "%.5f", $0.cosine)) (\($0.name))" }
            .joined(separator: ", ") + String(format: ", %.2f s with loading", Date().timeIntervalSince(started))
        return Check(name: "self-test", ok: ok, essential: true, detail: detail,
                     fix: "the model makes other vectors than it should: digup doctor --deep checks the files; "
                         + "DIGUP_GPU=0 tries the CPU")
    } catch {
        return Check(name: "self-test", ok: false, essential: true, detail: "\(error)",
                     fix: "llama.cpp's log: \(tilde(log.path))")
    }
}

// MARK: Tools

private func toolChecks() -> [Check] {
    var checks: [Check] = []
    if Tools.readsMediaWithFFmpeg {
        if let ffmpeg = Tools.ffmpeg {
            // HEIC needs 8.1 (`ImageExtractor.decodeWithFFmpeg`); a build without a version number can't be told.
            let version = toolOutput(ffmpeg, ["-hide_banner", "-version"])?.split(separator: "\n").first
                .map { $0.replacingOccurrences(of: "ffmpeg version ", with: "") }
                .flatMap { $0.split(separator: " ").first.map(String.init) } ?? "?"
            let number = version.drop { $0 == "n" }.split(separator: ".").prefix(2).compactMap { Int($0) }
            let heic = number.count == 2 && (number[0], number[1]) >= (8, 1)
            checks.append(Check(name: "ffmpeg", ok: heic, essential: false,
                                detail: "\(tilde(ffmpeg)) \(version), " + (heic ? "reads HEIC" : "no HEIC"),
                                fix: "HEIC photos need ffmpeg 8.1 or newer (DIGUP_FFMPEG: a folder with one)"))
        } else {
            checks.append(Check(name: "ffmpeg", ok: false, essential: false, detail: "not found",
                                fix: "sudo apt install ffmpeg (audio, video, HEIC, WebP and TIFF need it)"))
        }
        checks.append(Tools.ffprobe.map { Check(name: "ffprobe", ok: true, essential: false, detail: tilde($0)) }
                      ?? Check(name: "ffprobe", ok: false, essential: false, detail: "not found",
                               fix: "sudo apt install ffmpeg (it comes with it; audio and video need it)"))
    } else {
        checks.append(Check(name: "media", ok: true, essential: false, detail: "AVFoundation and ImageIO"))
    }
    if Tools.readsTextWithTesseract {
        if let tesseract = Tools.tesseract {
            let version = toolOutput(tesseract, ["--version"])?.split(separator: "\n").first.map(String.init) ?? "?"
            let languages = Tools.ocrLanguages
            checks.append(Check(name: "tesseract", ok: !languages.isEmpty, essential: false,
                                detail: "\(tilde(tesseract)) (\(version)), "
                                    + (languages.isEmpty ? "no languages" : "reads " + languages.joined(separator: "+")),
                                fix: "sudo apt install tesseract-ocr-eng (and -deu, -fra… for more)"))
        } else {
            checks.append(Check(name: "tesseract", ok: false, essential: false, detail: "not found",
                                fix: "sudo apt install tesseract-ocr (the words in screenshots and scans)"))
        }
    } else {
        checks.append(Check(name: "ocr", ok: true, essential: false, detail: "Vision"))
    }
    if let git = Tools.git {
        let version = toolOutput(git, ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        checks.append(Check(name: "git", ok: true, essential: false, detail: "\(tilde(git)) (\(version))"))
    } else {
        checks.append(Check(name: "git", ok: false, essential: false, detail: "not found",
                            fix: "install git: without it, code search reads what .gitignore leaves out too"))
    }
    return checks
}

/// What a program prints (both streams: tesseract's version goes to stderr in older releases), or nil.
private func toolOutput(_ tool: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: The index

/// The main index and, when there is one, the code index: opened as DigUp opens them (no migration: an older one is
/// upgraded by the next DigUp that opens it for real), counted, and compared with this DigUp.
private func indexChecks(_ folder: URL, deep: Bool) -> [Check] {
    let main = folder.appendingPathComponent(IndexStore.mainFile)
    guard FileManager.default.fileExists(atPath: main.path) else {
        return [Check(name: "index", ok: false, essential: false, detail: "none yet in \(tilde(folder.path))",
                      fix: "digup index <folder> makes one (so does the app, once it starts)")]
    }
    var checks = [indexCheck(main, name: "index", deep: deep)]
    let code = folder.appendingPathComponent(IndexStore.codeFile)
    if FileManager.default.fileExists(atPath: code.path) { checks.append(indexCheck(code, name: "code index", deep: deep)) }
    return checks
}

private func indexCheck(_ file: URL, name: String, deep: Bool) -> Check {
    do {
        let db = try Database(path: file.path)
        var version: Int64 = 0, mode = "", states: [String: Int] = [:], vectors = 0, source: String?
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        try db.query("PRAGMA journal_mode") { mode = $0.text(0) ?? "" }
        guard version <= IndexStore.schemaVersion else {
            return Check(name: name, ok: false, essential: true,
                         detail: "\(tilde(file.path)) was made by a newer DigUp (schema \(version))",
                         fix: "update DigUp")
        }
        if version > 0 {
            try db.query("SELECT state, COUNT(*) FROM files GROUP BY state") { states[$0.text(0) ?? "?"] = Int($0.int(1)) }
            try db.query("SELECT COUNT(vec) FROM segments") { vectors = Int($0.int(0)) }
            try db.query("SELECT value FROM meta WHERE key = 'vector_source'") { source = $0.text(0) }
        }
        let files = states.values.reduce(0, +)
        let wal = (try? FileManager.default.attributesOfItem(atPath: file.path + "-wal")[.size] as? NSNumber)?
            .int64Value ?? 0
        var detail = "\(tilde(file.path)), \(bytes(IndexStore.size(of: file))): \(number(files)) files"
            + (files > 0 ? " (" + statesLine(states) + ")" : "") + ", \(number(vectors)) vectors, schema \(version)"
            + (version < IndexStore.schemaVersion ? " (DigUp upgrades it on opening)" : "")
            + ", \(mode == "wal" ? "WAL" : "journal \(mode)")" + (wal > 0 ? " (\(bytes(wal)) not folded in yet)" : "")
        guard mode == "wal" else {
            return Check(name: name, ok: false, essential: true, detail: detail,
                         fix: "it couldn't switch to WAL: is its folder read-only?")
        }
        if deep {
            var verdict = ""
            try db.query("PRAGMA quick_check(1)") { verdict = $0.text(0) ?? "" }
            guard verdict == "ok" else {
                return Check(name: name, ok: false, essential: true, detail: detail + ", damaged: \(verdict)",
                             fix: "delete \(tilde(file.path)) and index again")
            }
            detail += ", pages ok"
        }
        // Vectors from another model or runtime can't be searched with this one's queries.
        let now = LlamaEmbedder.modelInfo.vectorSource
        if let source, source != now, ProcessInfo.processInfo.environment["DIGUP_WORKER_DIR"] == nil {
            return Check(name: name, ok: false, essential: false, detail: detail + "; its vectors are \(source), "
                             + "this DigUp makes \(now)",
                         fix: "the app embeds everything again by itself; digup index --reindex <folder> does it here")
        }
        return Check(name: name, ok: true, essential: true, detail: detail)
    } catch {
        return Check(name: name, ok: false, essential: true, detail: "\(tilde(file.path)): \(error)",
                     fix: "if no other DigUp holds it, delete it and index again")
    }
}

/// Free space where the index is. Indexing writes there (about 1.5 KB a vector, and the log until it's folded in), and
/// below a gigabyte it may run out.
private func diskCheck(_ folder: URL) -> Check {
    var path = folder.path
    while !FileManager.default.fileExists(atPath: path), path.count > 1 { path = (path as NSString).deletingLastPathComponent }
    guard let free = (try? FileManager.default.attributesOfFileSystem(forPath: path)[.systemFreeSize] as? NSNumber)?
        .int64Value else {
        return Check(name: "disk", ok: false, essential: false, detail: "can't tell how much is free at \(tilde(path))")
    }
    return Check(name: "disk", ok: free >= 1 << 30, essential: false,
                 detail: "\(bytes(free)) free where the index is (\(tilde(path)))",
                 fix: "free some space: the index grows as it indexes")
}

#if os(Linux)
/// How many folders inotify may watch. The shell watches the chosen folders' folders to see new files at once; past
/// the limit it rescans now and then instead. The folders that hold indexed files are fewer than it watches, so half
/// the limit is where it gets tight.
private func watchCheck(_ folder: URL) -> Check? {
    guard let text = try? String(contentsOfFile: "/proc/sys/fs/inotify/max_user_watches", encoding: .utf8),
          let limit = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    var folders = Set<Substring>()
    let main = folder.appendingPathComponent(IndexStore.mainFile)
    if FileManager.default.fileExists(atPath: main.path), let db = try? Database(path: main.path) {
        try? db.query("SELECT path FROM files") { row in
            if let path = row.text(0), let slash = path.lastIndex(of: "/") { folders.insert(path[..<slash]) }
        }
    }
    return Check(name: "inotify", ok: folders.count * 2 <= limit, essential: false,
                 detail: "\(number(limit)) folder watches allowed"
                     + (folders.isEmpty ? "" : "; the indexed files are in \(number(folders.count)) folders"),
                 fix: "echo fs.inotify.max_user_watches=524288 | sudo tee /etc/sysctl.d/90-digup.conf && "
                     + "sudo sysctl --system (else new files wait for a rescan)")
}
#endif

private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
