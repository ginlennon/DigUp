// Transcripts of recordings without Apple's speech recognition (Linux, Windows): whisper.cpp's whisper-cli, run as a
// program, as ffmpeg and tesseract are, with its own ggml linked in (scripts/linux/build-whisper.sh builds it
// statically, so it never meets llama.cpp's libggml beside digup). It's looked for in $DIGUP_WHISPER (the program, or
// its folder), beside the helper, in a dev build's Vendor/whisper/bin, then on PATH. Transcripts are optional and off
// unless turned on; nothing runs it for indexing yet (TRANSCRIPTS_PLAN.md, Stage 2).
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
}
#endif
