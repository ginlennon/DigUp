import Foundation

// What every platform shares of transcripts (PLANS/TRANSCRIPTS_PLAN.md): what a transcript is, how a long file is cut
// into chunks and put together again, the guards against made-up text, and how the words find the audio windows
// they're stored on. Running a speech recognizer is the platform's (Platform/Portable/Transcribe+Portable.swift:
// whisper-cli; macOS has none yet).

extension Transcriber {
    /// A stretch of speech: seconds into the file (or into the chunk, straight from whisper), and what was said.
    public struct Segment: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }

        var middle: Double { (start + end) / 2 }
    }

    /// What one run of the recognizer said about one chunk: its segments (seconds into the chunk), and the language it
    /// heard with how sure it was (nil when it heard no speech at all).
    struct Reading: Sendable {
        var segments: [Segment]
        var language: String?
        var probability: Double?
    }

    /// A file's transcript.
    public struct Transcript: Sendable {
        /// A chunk of the file (all of it, unless it's over `chunkLength`): where it lies, the language heard in it and
        /// how sure the recognizer was, how many segments it had, and whether they passed `minimumProbability`.
        public struct Chunk: Sendable {
            public let start: Double
            public let end: Double
            public let language: String?
            public let probability: Double?
            public let segments: Int
            public let kept: Bool
        }

        /// The segments that passed the guards, in seconds into the file, chunk seams settled (`merge`).
        public var segments: [Segment] = []
        public var chunks: [Chunk] = []
        /// The file has no sound to transcribe (a video without an audio track).
        public var noSound = false

        /// The language of the chunks kept, the one with the most of them when they differ.
        public var language: String? {
            let kept = chunks.filter(\.kept).compactMap(\.language)
            return Dictionary(grouping: kept, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        }
    }

    /// The recognizer and model a mode runs with (`engine(for:)`), as the index names them.
    public struct Engine: Sendable {
        public let program: String
        public let model: URL
        public let vad: URL
        /// On the GPU (else `-ng`: the CPU only).
        public let gpu: Bool
        public let threads: Int
        /// The program's version ("1.9.5").
        public let version: String

        /// What meta "transcripts" holds: a new model is a new id, and every recording is transcribed again. A new
        /// whisper.cpp alone isn't: it would cost a whole pass for what's at most a little better.
        public var id: String { "whisper \(model.lastPathComponent)" }
        /// What a file's `transcript_model` holds, the version included: a file that failed twice is tried again
        /// with a new whisper.cpp.
        public var build: String { "whisper.cpp-\(version) \(model.lastPathComponent)" }
    }

    // MARK: Chunks

    /// Files longer than this are transcribed a chunk at a time: memory and the time one call takes stay bounded, and
    /// stopping (pausing, new files) waits for one chunk at most. One call per file keeps context and one language
    /// (ASR_SPIKE.md), so chunks are long.
    static let chunkLength = 600.0
    /// Chunks overlap by this much, so a word cut by a seam is whole in one of them (`merge`).
    static let chunkOverlap = 5.0

    /// Where the chunks of a file `duration` seconds long lie: one for the whole file up to `chunkLength` (also when
    /// the length isn't known: 0), else `chunkLength` apart less `chunkOverlap`. A last chunk shorter than a minute
    /// joins the one before.
    static func chunks(duration: Double, length: Double = chunkLength, overlap: Double = chunkOverlap)
        -> [ClosedRange<Double>] {
        guard duration > length else { return [0...max(duration, 0)] }
        var chunks: [ClosedRange<Double>] = []
        var start = 0.0
        while true {
            let next = start + length - overlap
            if start + length >= duration || duration - next < 60 {
                chunks.append(start...duration)
                return chunks
            }
            chunks.append(start...(start + length))
            start = next
        }
    }

    /// The segments of all chunks in seconds into the file, each once: a segment in the overlap of two chunks is kept
    /// from the chunk whose half of the overlap holds its middle (the halfway point between one chunk's end and the
    /// next one's start). Both chunks heard it; each one's own half is where it heard it with more context.
    static func merge(_ chunks: [(range: ClosedRange<Double>, segments: [Segment])]) -> [Segment] {
        var out: [Segment] = []
        for (index, chunk) in chunks.enumerated() {
            let from = index == 0 ? -Double.infinity : (chunks[index - 1].range.upperBound + chunk.range.lowerBound) / 2
            let to = index == chunks.count - 1 ? Double.infinity
                : (chunk.range.upperBound + chunks[index + 1].range.lowerBound) / 2
            for segment in chunk.segments {
                let moved = Segment(start: segment.start + chunk.range.lowerBound,
                                    end: segment.end + chunk.range.lowerBound, text: segment.text)
                if moved.middle >= from && moved.middle < to { out.append(moved) }
            }
        }
        return out
    }

    // MARK: Guards (TRANSCRIPTS_PLAN.md A4: wrong text in the index is worse than none)

    /// A chunk whose language the recognizer is less sure of than this gets no text: speech came out at ≥ 0.997 in the
    /// spike, silence, noise and music at 0.38–0.78.
    static let minimumProbability = 0.9

    /// What whisper writes for silence, noise and music (it was trained on subtitled video): dropped when it's all a
    /// window holds, never from inside real speech. Compared lowercased, without the punctuation around it.
    static let madeUp: Set<String> = [
        "", "you", "bye", "thank you", "thank you very much", "thanks", "thanks for watching", "thank you for watching",
        "thanks for listening", "thank you for listening", "please subscribe", "subscribe",
        "vielen dank", "danke", "danke schön", "dankeschön", "danke fürs zuschauen", "tschüss",
        "merci", "merci beaucoup", "merci d'avoir regardé", "grazie", "grazie mille", "gracias", "muchas gracias",
        "obrigado", "obrigada",
    ]
    /// Subtitle credits ("Untertitel im Auftrag des ZDF", "Sous-titres réalisés par …"), by how they start.
    static let madeUpStarts = ["untertitel", "sous-titr", "subtitles by", "subtitled by", "sottotitoli", "subtítulos",
                               "legendas", "amara.org"]

    /// The whole text of a window is what whisper makes up for silence, noise or music: one of `madeUp`, a subtitle
    /// credit, or only notes in brackets or music signs ("[Music]", "(Musik)", "♪♪").
    static func isMadeUp(_ text: String) -> Bool {
        let core = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "„“”«»‹›\"'")).subtracting(CharacterSet(charactersIn: "[]()")))
        if madeUp.contains(core) || madeUpStarts.contains(where: core.hasPrefix) { return true }
        let notes = core.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|[♪♫*\s.]"#, with: "", options: .regularExpression)
        return notes.isEmpty
    }

    // MARK: Windows

    /// One of a file's audio windows in the index (`IndexStore.audioWindows`): its segment and where it lies.
    struct Window: Sendable, Equatable {
        let id: Int64
        let start: Double
        let end: Double
    }

    /// A segment goes to every window it overlaps by at least a second, and to the one its middle is in: so a sentence
    /// said in the 5 s two windows share is in both (keyword search ranks by file, so that costs nothing), one longer
    /// than a window is in each it spans, and a short word that just touches the next window stays where it was said.
    static func belongs(_ segment: Segment, to window: Window) -> Bool {
        let overlap = min(segment.end, window.end) - max(segment.start, window.start)
        return overlap >= 1 || (segment.middle >= window.start && segment.middle < window.end)
    }

    /// The words for each window that has any: its segments' text in order, unless all of it is made up
    /// (`isMadeUp`). A segment that falls in no window (in a stretch so quiet that pass 1 left it out) is lost.
    static func texts(of segments: [Segment], in windows: [Window]) -> [(window: Int64, text: String)] {
        windows.compactMap { window in
            let text = segments.filter { belongs($0, to: window) }.map(\.text).joined(separator: " ")
            return text.isEmpty || isMadeUp(text) ? nil : (window.id, text)
        }
    }

    // MARK: Reading whisper's output

    /// whisper-cli's JSON (`-oj`): its segments in seconds and the language it heard. Read with invalid UTF-8 replaced
    /// (whisper small wrote broken JSON on music, ASR_SPIKE.md), and the replacement characters dropped from the text.
    /// `log` is what it wrote on standard error, the only place that says how sure it was of the language
    /// (`detectedLanguage`). Throws when it isn't JSON.
    static func reading(json data: Data, log: String) throws -> Reading {
        let text = String(decoding: data, as: UTF8.self)
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ExtractError.unreadable("whisper-cli wrote no JSON")
        }
        var segments: [Segment] = []
        for item in object["transcription"] as? [[String: Any]] ?? [] {
            guard let offsets = item["offsets"] as? [String: Any],
                  let from = (offsets["from"] as? NSNumber)?.doubleValue,
                  let to = (offsets["to"] as? NSNumber)?.doubleValue else { continue }
            let words = (item["text"] as? String ?? "").replacingOccurrences(of: "\u{FFFD}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            segments.append(Segment(start: from / 1000, end: max(from, to) / 1000, text: words))
        }
        let detected = detectedLanguage(in: log)
        // Where it heard nothing, the JSON still names a language (its default, "en"): no language then.
        let said = segments.isEmpty ? nil : (object["result"] as? [String: Any])?["language"] as? String
        return Reading(segments: segments, language: detected?.code ?? said, probability: detected?.probability)
    }

    /// "whisper_full_with_state: auto-detected language: de (p = 0.999282)": the language and how sure, from the log
    /// (the JSON names the language but not that). The last such line: the one for the audio itself.
    static func detectedLanguage(in log: String) -> (code: String, probability: Double)? {
        let pattern = #"auto-detected language: ([A-Za-z-]+) \(p = ([0-9.]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).last,
              let code = Range(match.range(at: 1), in: log), let p = Range(match.range(at: 2), in: log),
              let probability = Double(log[p]) else { return nil }
        return (String(log[code]), probability)
    }

    /// Whether ffprobe's tags (`-show_entries format_tags:stream_tags -of json`) make a file a song: an artist and an
    /// album, in the container's tags or a stream's (Ogg keeps them on the stream). By tags, not by folder: voice
    /// memos land in Music folders too.
    static func isSong(probeJSON data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(String(decoding: data, as: UTF8.self).utf8))
            as? [String: Any] else { return false }
        var tags: [[String: Any]] = []
        if let format = object["format"] as? [String: Any], let found = format["tags"] as? [String: Any] {
            tags.append(found)
        }
        for stream in object["streams"] as? [[String: Any]] ?? [] {
            if let found = stream["tags"] as? [String: Any] { tags.append(found) }
        }
        func has(_ key: String) -> Bool {
            tags.contains { set in
                set.contains { $0.key.lowercased() == key
                    && !(($0.value as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            }
        }
        return has("artist") && has("album")
    }
}
