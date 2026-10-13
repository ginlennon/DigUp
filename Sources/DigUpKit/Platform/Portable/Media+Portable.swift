// Audio and video without AVFoundation (Linux, Windows): ffmpeg decodes, ffprobe measures. They're looked for in
// $DIGUP_FFMPEG, beside the helper, in a dev build's Vendor/ffmpeg, then on PATH.
#if !canImport(AVFoundation)
import Foundation

enum FFmpeg {
    static let ffmpeg = find("ffmpeg")
    static let ffprobe = find("ffprobe")

    static func find(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        var folders: [String] = []
        if let chosen = environment["DIGUP_FFMPEG"], !chosen.isEmpty { folders.append(chosen) }
        if let executable = Bundle.main.executableURL {
            folders.append(executable.deletingLastPathComponent().path)
            // A dev build (or the tests) runs from the checkout's .build/: scripts/linux/fetch-ffmpeg.sh puts a newer
            // ffmpeg than the distribution's in Vendor/ffmpeg, as Package.swift finds Vendor's libraries.
            if let build = executable.path.range(of: "/.build/") {
                folders.append(executable.path[..<build.lowerBound] + "/Vendor/ffmpeg")
            }
        }
        for folder in folders {
            let candidate = folder + "/" + FileSystem.program(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return FileSystem.executable(name)
    }

    /// Runs a tool and hands its standard output to `read` as it comes (a long decode never sits in memory whole).
    /// Throws when the tool is missing or fails.
    static func run(_ tool: String?, _ arguments: [String], read: (Data) throws -> Void) throws {
        guard let tool else { throw ExtractError.unreadable(missing("ffmpeg")) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let reader = output.fileHandleForReading
        while true {
            let data = reader.readData(ofLength: 1 << 16)
            if data.isEmpty { break }
            try read(data)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExtractError.unreadable("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus))")
        }
    }

    /// The whole standard output, as text.
    static func output(_ tool: String?, _ arguments: [String]) throws -> String {
        var data = Data()
        try run(tool, arguments) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }
}

extension MediaInfo {
    static func duration(of url: URL) -> Double? {
        guard let text = try? FFmpeg.output(FFmpeg.ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of",
                                                             "default=noprint_wrappers=1:nokey=1", url.path])
        else { return nil }
        let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Which kinds of streams the file has. Throws when ffprobe isn't installed or can't read the file: either way
    /// nothing is known about it, and taking that for "no sound" would file a talk away as silent, never to be read
    /// again. Failed, it's read once more when the tools change (`IndexStore.readAgainOnce`).
    static func streams(of url: URL, probe: String? = FFmpeg.ffprobe) throws -> (audio: Bool, video: Bool) {
        guard let probe else { throw ExtractError.unreadable(FFmpeg.missing("ffprobe")) }
        let text = try FFmpeg.output(probe, ["-v", "error", "-show_entries", "stream=codec_type", "-of",
                                             "default=noprint_wrappers=1:nokey=1", url.path])
        return (text.contains("audio"), text.contains("video"))
    }
}

extension FFmpeg {
    /// A file's note when a tool isn't there ("… isn't installed", which `IndexStore.readAgainOnce` looks for).
    static func missing(_ tool: String) -> String { "\(tool) isn't installed (audio and video need it)" }

    /// Which ffmpeg and ffprobe these are (where, how big, how new): when that changes, what they couldn't read is read
    /// once more.
    static let tools: String = [ffmpeg, ffprobe].map { tool in
        guard let tool, let info = FileSystem.info(of: URL(fileURLWithPath: tool).resolvingSymlinksInPath().path)
        else { return "none" }
        return "\(tool) \(info.size) \(Int(info.mtime))"
    }.joined(separator: " | ")
}

extension Estimator {
    static func duration(of path: String) -> Double {
        MediaInfo.duration(of: URL(fileURLWithPath: path)) ?? 0
    }
}

extension AudioExtractor {
    /// Decodes audio (a file, or a video's soundtrack) to 16 kHz mono through ffmpeg and writes `window`-second WAV
    /// pieces `hop` seconds apart, skipping silent ones; one model input ignores anything past 30 s, so windows stay
    /// ≤ 30 s. Streams: memory stays at one window, even for a 3-hour podcast.
    static func windows(of url: URL, window: Double, hop: Double, minimum: Double = 2, to folder: URL) async throws
        -> (pieces: [MediaPiece], duration: Double) {
        guard try MediaInfo.streams(of: url).audio else { return ([], 0) }
        let duration = MediaInfo.duration(of: url) ?? 0
        let windowSamples = Int(window * sampleRate), hopSamples = Int(hop * sampleRate)
        var buffer: [Int16] = []
        var offset = 0   // sample index of buffer[0] in the file
        var pieces: [MediaPiece] = []
        func emit(_ count: Int) throws {
            let slice = buffer[0..<count]
            guard rms(slice) > 0.003 else { return }   // ≈ −50 dBFS: silence isn't worth a vector
            let out = folder.appendingPathComponent(UUID().uuidString + ".wav")
            try writeWAV(slice, to: out)
            pieces.append(MediaPiece(path: out.path, start: Double(offset) / sampleRate,
                                     end: Double(offset + count) / sampleRate))
        }
        var odd: UInt8?   // a byte left over when a read ends mid-sample
        try FFmpeg.run(FFmpeg.ffmpeg, ["-v", "error", "-nostdin", "-i", url.path, "-vn", "-ac", "1", "-ar",
                                       "\(Int(sampleRate))", "-f", "s16le", "-"]) { data in
            var bytes: [UInt8] = []
            bytes.reserveCapacity(data.count + 1)
            if let first = odd { bytes.append(first); odd = nil }
            bytes.append(contentsOf: data)
            if bytes.count % 2 == 1 { odd = bytes.removeLast() }
            buffer.reserveCapacity(buffer.count + bytes.count / 2)
            var i = 0
            while i + 1 < bytes.count {
                buffer.append(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))
                i += 2
            }
            while buffer.count >= windowSamples {
                try emit(windowSamples)
                buffer.removeFirst(hopSamples)
                offset += hopSamples
            }
        }
        // The tail: new audio beyond the previous window's overlap, or the whole file if it was shorter than a window.
        let alreadyCovered = offset == 0 ? 0 : windowSamples - hopSamples
        if buffer.count - alreadyCovered >= Int(minimum * sampleRate) { try emit(buffer.count) }
        return (pieces, duration > 0 ? duration : Double(offset + buffer.count) / sampleRate)
    }
}

extension VideoExtractor {
    /// Samples a frame every `interval` seconds through ffmpeg and keeps one per shot: a frame that looks like the
    /// previous kept one (8×8 average hash within 4 bits) only extends it.
    static func keyframes(of url: URL, every interval: Double, maxPixel: Int, maxFrames: Int = 1200, to folder: URL)
        async throws -> (frames: [MediaPiece], duration: Double, hasAudio: Bool) {
        let streams = try MediaInfo.streams(of: url)
        let duration = MediaInfo.duration(of: url) ?? 0
        guard duration > 0, streams.video else { return ([], duration, streams.audio) }
        let step = max(interval, duration / Double(maxFrames))
        let first = min(0.5, duration / 2)
        let prefix = "frame-\(UUID().uuidString)-"
        try FFmpeg.run(FFmpeg.ffmpeg, ["-v", "error", "-nostdin", "-ss", String(first), "-i", url.path, "-an", "-vf",
                                       "fps=\(1 / step),scale=\(maxPixel):\(maxPixel):force_original_aspect_ratio=decrease",
                                       "-q:v", "3", "-f", "image2", folder.appendingPathComponent(prefix + "%06d.jpg").path]) { _ in }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(prefix) }.sorted()
        var frames: [MediaPiece] = []
        var lastHash: UInt64?
        for (index, name) in names.enumerated() {
            let path = folder.appendingPathComponent(name).path
            if let image = RGBImage.load(path) {
                let hash = image.averageHash()
                if let lastHash, (hash ^ lastHash).nonzeroBitCount <= 4 {
                    try? FileManager.default.removeItem(atPath: path)
                    continue
                }
                lastHash = hash
            }
            frames.append(MediaPiece(path: path, start: first + Double(index) * step, end: duration))
        }
        // Each kept frame stands for the stretch until the next kept frame.
        for index in frames.indices.dropLast() { frames[index].end = frames[index + 1].start }
        return (frames, duration, streams.audio)
    }

    /// The frame shown at `seconds`, its long side at most `pixels`, as a JPEG for a preview.
    static func frame(at seconds: Double, of url: URL, pixels: Int, to out: URL) async throws {
        try FFmpeg.run(FFmpeg.ffmpeg, ["-v", "error", "-nostdin", "-ss", String(max(0, seconds)), "-i", url.path,
                                       "-frames:v", "1", "-vf",
                                       "scale='min(iw,\(pixels))':'min(ih,\(pixels))':force_original_aspect_ratio=decrease",
                                       "-q:v", "3", "-y", out.path]) { _ in }
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw ExtractError.unreadable("no frame at \(seconds) s")
        }
    }
}
#endif
