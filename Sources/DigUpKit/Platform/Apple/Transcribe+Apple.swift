// Transcripts on macOS: none yet (Apple's speech recognition could fill this one day, behind the same names as
// Platform/Portable's whisper-cli). With no engine, the transcript pass has nothing to do and the index stays as it is.
#if canImport(AVFoundation)
import Foundation

extension Transcriber {
    static var isAvailable: Bool { false }

    public static func engine(for mode: TranscriptMode, models: URL = TranscriptModels.folder) -> Engine? { nil }

    public static func transcribe(_ url: URL, duration: Double, engine: Engine, in folder: URL,
                                  shouldStop: () -> Bool = { false }, onChunk: (Int, Int) -> Void = { _, _ in })
        throws -> Transcript? {
        throw ExtractError.unreadable("no transcripts on macOS yet")
    }

    static func isSong(_ url: URL) -> Bool { false }
}
#endif
