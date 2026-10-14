// Transcripts of recordings without Apple's speech recognition (Linux, Windows): whisper.cpp's whisper-cli, run as a
// program, as ffmpeg and tesseract are, with its own ggml linked in (scripts/linux/build-whisper.sh builds it
// statically, so it never meets llama.cpp's libggml beside digup). It's looked for in $DIGUP_WHISPER (the program, or
// its folder), beside the helper, in a dev build's Vendor/whisper/bin, then on PATH. Transcripts are optional and off
// unless turned on (`IndexOptions.transcripts`); `Indexer.transcribeRecordings` runs `transcribe` file by file.
#if !canImport(AVFoundation)
import Foundation

extension Transcriber {
    static let name = "whisper-cli"

    static let whisper: String? = find(chosen: ProcessInfo.processInfo.environment["DIGUP_WHISPER"],
                                       executable: Bundle.main.executableURL)

    /// `chosen` (a program, or a folder with one), beside `executable`, in the checkout's Vendor/whisper/bin when
    /// `executable` is a dev build in .build/, then on PATH.
    static func find(chosen: String?, executable: URL?) -> String? {
        var folders: [String] = []
        if let chosen, !chosen.isEmpty {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: chosen, isDirectory: &isFolder), !isFolder.boolValue,
               FileManager.default.isExecutableFile(atPath: chosen) {
                return chosen
            }
            folders.append(chosen)
        }
        if let executable {
            folders.append(executable.deletingLastPathComponent().path)
            if let build = executable.path.range(of: "/.build/") {
                folders.append(executable.path[..<build.lowerBound] + "/Vendor/whisper/bin")
            }
        }
        for folder in folders {
            let candidate = folder + "/" + FileSystem.program(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return FileSystem.executable(name)
    }

    static var isAvailable: Bool { whisper != nil }

    /// whisper.cpp's version ("1.9.5"), as `whisper-cli --version` says it; nil when it's missing or doesn't run.
    static let version: String? = {
        guard let whisper, let said = try? run(whisper, ["--version"], seconds: 10) else { return nil }
        // "whisper.cpp version: 1.9.5"
        guard let line = said.split(whereSeparator: \.isNewline).first(where: { $0.contains("version: ") }) else {
            return nil
        }
        return line.components(separatedBy: "version: ").last?.trimmingCharacters(in: .whitespaces)
    }()

    /// What `mode` runs with: whisper-cli, its speech model (large-v3-turbo on the GPU, small on the CPU) and the
    /// VAD, from `models` (`TranscriptModels.folder`). Nil when it's off or anything is missing: then nothing is
    /// transcribed, and transcripts made before stay as they are.
    public static func engine(for mode: TranscriptMode, models: URL = TranscriptModels.folder) -> Engine? {
        guard mode != .off, let whisper, let version else { return nil }
        let model = models.appendingPathComponent((mode == .cpu ? TranscriptModels.small : TranscriptModels.turbo).name)
        let vad = models.appendingPathComponent(TranscriptModels.vad.name)
        guard FileManager.default.fileExists(atPath: model.path), FileManager.default.fileExists(atPath: vad.path)
        else { return nil }
        // As many threads as the embedder takes (`DIGUP_THREADS`, else up to 8): the GPU does the work, or, on the CPU,
        // the background pass mustn't take the whole machine.
        let chosen = ProcessInfo.processInfo.environment["DIGUP_THREADS"].flatMap(Int.init).map { max(1, $0) }
        return Engine(program: whisper, model: model, vad: vad, gpu: mode == .gpu,
                      threads: chosen ?? min(8, ProcessInfo.processInfo.activeProcessorCount), version: version)
    }

    /// Transcribes the file at `url` (`duration` seconds long, 0 when unknown), a chunk at a time (`chunks`): ffmpeg
    /// writes the chunk as 16 kHz mono WAV in `folder`, whisper-cli transcribes it (`-l auto --vad`, beam search),
    /// and the chunk's text is kept if the language was heard surely enough (`minimumProbability`). `shouldStop` is
    /// asked between chunks (nil back: stopped, nothing kept) and `onChunk` hears of each one starting, for the
    /// watchdog. Throws when ffmpeg or whisper-cli fails or takes too long.
    public static func transcribe(_ url: URL, duration: Double, engine: Engine, in folder: URL,
                                  shouldStop: () -> Bool = { false }, onChunk: (Int, Int) -> Void = { _, _ in })
        throws -> Transcript? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard try MediaInfo.streams(of: url).audio else { return Transcript(noSound: true) }
        var length = duration
        if length <= 0 { length = MediaInfo.duration(of: url) ?? 0 }
        let ranges = chunks(duration: length)
        var transcript = Transcript()
        var heard: [(range: ClosedRange<Double>, segments: [Segment])] = []
        for (index, range) in ranges.enumerated() {
            if index > 0, shouldStop() { return nil }
            onChunk(index, ranges.count)
            let reading = try read(url, range: range, whole: ranges.count == 1, engine: engine, in: folder,
                                   name: "chunk-\(index)")
            // No language said, yet words: a whisper-cli that logs otherwise. Better none than unguarded text.
            if !reading.segments.isEmpty, reading.probability == nil {
                throw ExtractError.unreadable("\(name) didn't say how sure it was of the language")
            }
            let kept = (reading.probability ?? 0) >= minimumProbability
            transcript.chunks.append(Transcript.Chunk(start: range.lowerBound, end: range.upperBound,
                                                      language: reading.language, probability: reading.probability,
                                                      segments: reading.segments.count, kept: kept))
            heard.append((range, kept ? reading.segments : []))
        }
        transcript.segments = merge(heard)
        return transcript
    }

    /// One chunk: decoded by ffmpeg (all of the file when `whole`), transcribed by whisper-cli, its files removed.
    private static func read(_ url: URL, range: ClosedRange<Double>, whole: Bool, engine: Engine, in folder: URL,
                             name file: String) throws -> Reading {
        let wav = folder.appendingPathComponent(file + ".wav")
        let json = folder.appendingPathComponent(file + ".json")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: json)
        }
        let span = range.upperBound - range.lowerBound
        guard let ffmpeg = FFmpeg.ffmpeg else { throw ExtractError.unreadable(FFmpeg.missing("ffmpeg")) }
        var decode = ["-v", "error", "-nostdin", "-y"]
        if !whole { decode += ["-ss", String(format: "%.3f", range.lowerBound), "-t", String(format: "%.3f", span)] }
        decode += ["-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path]
        _ = try run(ffmpeg, decode, in: folder, seconds: 120 + span / 2)
        var arguments = ["-m", engine.model.path, "-l", "auto", "--vad", "-vm", engine.vad.path, "-oj",
                         "-of", folder.appendingPathComponent(file).path, "-t", "\(engine.threads)", "-f", wav.path]
        if !engine.gpu { arguments.append("-ng") }
        // 2 minutes for loading and the language pass, then as long as the audio: turbo on a GPU runs at ~5× real
        // time, small on a CPU at ~3.7×.
        let log = try run(engine.program, arguments, in: folder, seconds: 120 + (whole && span == 0 ? 3600 : span))
        guard let data = FileManager.default.contents(atPath: json.path) else {
            throw ExtractError.unreadable("\(name) wrote no transcript")
        }
        return try reading(json: data, log: log)
    }

    /// Runs `tool` with `folder` as its current directory (a folder of DigUp's own: nothing there for it to load, such
    /// as a stray libggml), its standard output thrown away and its standard error, which whisper-cli logs to, kept in
    /// a file there and returned. Stopped after `seconds` (and killed 5 s later if it's still there); throws then,
    /// and when it fails.
    static func run(_ tool: String, _ arguments: [String], in folder: URL, seconds: Double) throws -> String {
        let log = folder.appendingPathComponent("log-\(UUID().uuidString).txt")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let tooLong = Atomic()
        let stop = DispatchWorkItem {
            guard process.isRunning else { return }
            tooLong.set()
            process.terminate()
            #if !os(Windows)
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(pid, SIGKILL) } }
            #endif
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: stop)
        process.waitUntilExit()
        stop.cancel()
        let tool = (tool as NSString).lastPathComponent
        if tooLong.isSet { throw ExtractError.unreadable("\(tool) took more than \(Int(seconds)) s") }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ExtractError.unreadable("\(tool) failed (\(process.terminationStatus))")
        }
        return String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
    }

    /// A flag one thread sets and another reads.
    private final class Atomic: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Runs whisper-cli and returns what it wrote on stdout; stopped after `seconds`. Throws when it can't start or
    /// fails.
    static func run(_ tool: String, _ arguments: [String], seconds: Double) throws -> String {
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
            throw ExtractError.unreadable("\(name) failed (\(process.terminationStatus))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A song by its tags (`isSong(probeJSON:)`): ffprobe's container and stream tags. Not one when ffprobe can't say.
    static func isSong(_ url: URL) -> Bool {
        guard let text = try? FFmpeg.output(FFmpeg.ffprobe, ["-v", "error", "-show_entries", "format_tags:stream_tags",
                                                            "-of", "json", url.path]) else { return false }
        return isSong(probeJSON: Data(text.utf8))
    }
}
#endif
