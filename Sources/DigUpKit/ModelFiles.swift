#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// The EmbeddingGemma 2 files the app runs: ggml-org's Q8_0 GGUF conversion at one pinned revision of the repo (made
/// from google/embeddinggemma-2 at 914f7f8, the weights the mlx-vlm reference runs). Never the F16 files: the model's
/// activations overflow float16.
///
/// The app downloads them on first launch (`ModelDownload`) and the helper loads them (`LlamaModels`); this is what
/// both agree on.
public enum ModelFiles {
    public static let repository = "ggml-org/embeddinggemma-2-GGUF"
    public static let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"

    public struct File: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
        /// The Hugging Face repo and the pinned revision it comes from (EmbeddingGemma's, unless said otherwise).
        public let repository: String
        public let revision: String

        public init(name: String, bytes: Int64, sha256: String, repository: String = ModelFiles.repository,
                    revision: String = ModelFiles.revision) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
            self.repository = repository
            self.revision = revision
        }

        /// Hugging Face's address for this file at the pinned revision (it redirects to a CDN that takes HTTP ranges).
        public var url: URL {
            URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)")!
        }
    }

    /// The text model (310 MB): all that queries need.
    public static let text = File(name: "embeddinggemma-2-Q8_0.gguf", bytes: 309_855_456,
                                  sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135")
    /// The image and audio encoders (555 MB).
    public static let media = File(name: "mmproj-embeddinggemma-2-Q8_0.gguf", bytes: 554_821_024,
                                   sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
    /// In download order.
    public static let all = [text, media]
    public static let totalBytes = all.reduce(0) { $0 + $1.bytes }

    /// Where the app keeps them (`AppPaths`).
    public static let installed = AppPaths.applicationSupport.appendingPathComponent("Models")

    /// The pinned revision's folder in the Hugging Face cache (`hf download` puts the files there): `$HF_HUB_CACHE`,
    /// `$HF_HOME/hub`, or `~/.cache/huggingface/hub`.
    public static var huggingFaceSnapshot: URL { huggingFaceSnapshot(repository: repository, revision: revision) }

    /// A revision's folder of a repo in the Hugging Face cache.
    public static func huggingFaceSnapshot(repository: String, revision: String) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let hub = environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? environment["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        return hub.appendingPathComponent("models--\(repository.replacingOccurrences(of: "/", with: "--"))/snapshots/\(revision)")
    }

    /// `file` in the Hugging Face cache, when it's there at the right size (its checksum is for the caller to check).
    public static func cachedCopy(of file: File) -> URL? {
        let url = huggingFaceSnapshot(repository: file.repository, revision: file.revision)
            .appendingPathComponent(file.name).resolvingSymlinksInPath()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size == file.bytes ? url : nil
    }

    /// The files that aren't in `folder` yet. Only verified files get their final name, so being there is enough.
    public static func missing(in folder: URL) -> [File] { missing(all, in: folder) }

    public static func missing(_ files: [File], in folder: URL) -> [File] {
        files.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
    }

    /// The SHA-256 of a file as lowercase hex, read in 8 MB pieces (a 555 MB file takes about half a second).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done = try autoreleasepool { () -> Bool in
                guard let data = try handle.read(upToCount: 8 << 20), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The whisper.cpp files for transcripts of recordings (optional, off unless turned on: PLANS/TRANSCRIPTS_PLAN.md),
/// each at a pinned revision of its Hugging Face repo, checked as the model's files are. `digup download-model
/// --transcripts` puts them in `folder`; whisper-cli runs them (`Transcriber`).
public enum TranscriptModels {
    /// large-v3-turbo quantized to q5_0 (574 MB): the default, about 5× real time on the GPU (ASR_SPIKE.md).
    public static let turbo = ModelFiles.File(
        name: "ggml-large-v3-turbo-q5_0.bin", bytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        repository: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1")
    /// small (488 MB): the light choice, for the CPU (3.7× real time there, less exact).
    public static let small = ModelFiles.File(
        name: "ggml-small.bin", bytes: 487_601_967,
        sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        repository: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1")
    /// Silero VAD v6.2.0 (0.9 MB): what's speech, so that silence, noise and music get no made-up text.
    public static let vad = ModelFiles.File(
        name: "ggml-silero-v6.2.0.bin", bytes: 885_098,
        sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
        repository: "ggml-org/whisper-vad", revision: "9ffd54a1e1ee413ddf265af9913beaf518d1639b")
    public static let all = [turbo, small, vad]

    /// What transcripts need, in download order: one speech model (turbo, or small) and the VAD.
    public static func needed(small light: Bool) -> [ModelFiles.File] { [light ? small : turbo, vad] }

    /// `<Models>/whisper`: in $DIGUP_MODELS when that's set (the app's choice, as for the model), else in DigUp's own
    /// Models folder.
    public static var folder: URL {
        let chosen = ProcessInfo.processInfo.environment["DIGUP_MODELS"].flatMap { $0.isEmpty ? nil : $0 }
        return (chosen.map { URL(fileURLWithPath: $0) } ?? ModelFiles.installed).appendingPathComponent("whisper")
    }
}
