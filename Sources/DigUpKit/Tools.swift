import Foundation

/// The programs DigUp runs beside its own code, where it found them, for `digup doctor`. On macOS Apple's frameworks
/// read media and text in pictures, and there are none of these but git.
public enum Tools {
    /// Audio, video and some pictures (HEIC, WebP, TIFF) are read by ffmpeg and ffprobe here.
    #if canImport(AVFoundation)
    public static let readsMediaWithFFmpeg = false
    public static var ffmpeg: String? { nil }
    public static var ffprobe: String? { nil }
    #else
    public static let readsMediaWithFFmpeg = true
    public static var ffmpeg: String? { FFmpeg.ffmpeg }
    public static var ffprobe: String? { FFmpeg.ffprobe }
    #endif

    /// The words in screenshots and scans are read by tesseract here, in `ocrLanguages`.
    #if canImport(ImageIO)
    public static let readsTextWithTesseract = false
    public static var tesseract: String? { nil }
    public static var ocrLanguages: [String] { [] }
    #else
    public static let readsTextWithTesseract = true
    public static var tesseract: String? { OCR.tesseract }
    public static var ocrLanguages: [String] { OCR.languages }
    #endif

    /// Transcripts of recordings (optional, off unless turned on) are made by whisper.cpp's whisper-cli here, version
    /// `whisperVersion` ("1.9.5"). macOS has none yet.
    #if canImport(AVFoundation)
    public static let transcribesWithWhisper = false
    public static var whisper: String? { nil }
    public static var whisperVersion: String? { nil }
    #else
    public static let transcribesWithWhisper = true
    public static var whisper: String? { Transcriber.whisper }
    public static var whisperVersion: String? { Transcriber.version }
    #endif

    /// git, which code search asks what a repo ignores.
    public static var git: String? { FileSystem.git }
}
