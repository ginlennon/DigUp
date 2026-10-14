import Foundation
import Testing
@testable import DigUpKit

/// Transcripts of recordings (PLANS/TRANSCRIPTS_PLAN.md, Stage 2): chunks and seams, the guards, how segments find the
/// audio windows, reading whisper-cli's output, songs by their tags, and what the index keeps.
@Suite final class TranscriptTests {
    typealias Segment = Transcriber.Segment
    typealias Window = Transcriber.Window

    /// In Caches, as in `LongFilesTests`: a crawl reports paths there as they're given.
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Chunks and seams

    @Test func longFilesAreCutIntoOverlappingChunks() {
        #expect(Transcriber.chunks(duration: 0) == [0...0])           // length unknown: the whole file at once
        #expect(Transcriber.chunks(duration: 162) == [0...162])
        #expect(Transcriber.chunks(duration: 600) == [0...600])
        #expect(Transcriber.chunks(duration: 1500) == [0...600, 595...1195, 1190...1500])
        // A last chunk under a minute joins the one before.
        #expect(Transcriber.chunks(duration: 1200) == [0...600, 595...1200])
        #expect(Transcriber.chunks(duration: 640) == [0...640])
    }

    @Test func segmentsInTheOverlapAreKeptOnce() {
        // Chunk 2 starts at 595 s; both heard 595–600, and the seam is at 597.5 s.
        let first: [Segment] = [Segment(start: 590, end: 594, text: "a"), Segment(start: 595.5, end: 597, text: "x"),
                                Segment(start: 596, end: 599, text: "y")]
        let second: [Segment] = [Segment(start: 0.5, end: 2, text: "x"), Segment(start: 1, end: 4, text: "y"),
                                 Segment(start: 6, end: 10, text: "b")]
        let merged = Transcriber.merge([(0...600, first), (595...1195, second)])
        #expect(merged.map(\.text) == ["a", "x", "y", "b"])
        #expect(merged[1].start == 595.5)                    // "x" from the first chunk (its middle before the seam)
        #expect(merged[2].start == 596 && merged[2].end == 599)   // "y" from the second, in seconds into the file
        #expect(merged[3].start == 601)
        // One chunk: its segments as they are.
        #expect(Transcriber.merge([(0...30, first)]) == first)
    }

    // MARK: Windows

    @Test func segmentsGoToTheWindowsTheyOverlap() {
        let windows = [Window(id: 1, start: 0, end: 30), Window(id: 2, start: 25, end: 55), Window(id: 3, start: 50, end: 62)]
        func landing(_ segment: Segment) -> [Int64] { windows.filter { Transcriber.belongs(segment, to: $0) }.map(\.id) }
        #expect(landing(Segment(start: 23, end: 27, text: "")) == [1, 2])        // in the 5 s two windows share
        #expect(landing(Segment(start: 29.5, end: 31, text: "")) == [2])         // 0.5 s in the first: too little
        #expect(landing(Segment(start: 10, end: 10.4, text: "")) == [1])         // short: by its middle
        #expect(landing(Segment(start: 0, end: 60, text: "")) == [1, 2, 3])      // longer than a window
        #expect(landing(Segment(start: 54.8, end: 56, text: "")) == [3])         // 0.2 s in window 2, its middle past it
        // A seam of chunks is no seam of windows: a segment from the second chunk, in seconds into the file, lands
        // where any other would.
        let merged = Transcriber.merge([(0...600, []), (595...1195, [Segment(start: 4, end: 8, text: "z")])])
        let late = [Window(id: 24, start: 575, end: 605), Window(id: 25, start: 600, end: 630)]
        #expect(late.filter { Transcriber.belongs(merged[0], to: $0) }.map(\.id) == [24, 25])
    }

    @Test func windowsGetTheirSegmentsTextInOrder() {
        let windows = [Window(id: 7, start: 0, end: 30), Window(id: 8, start: 50, end: 80)]   // 30–50 s was silent
        let segments = [Segment(start: 1, end: 4, text: "Guten Tag Frau Brunner."),
                        Segment(start: 5, end: 9, text: "Die Rechnung RE-2041."),
                        Segment(start: 35, end: 40, text: "lost")]   // in no window: nowhere to keep it
        let texts = Transcriber.texts(of: segments, in: windows)
        #expect(texts.map(\.window) == [7])
        #expect(texts[0].text == "Guten Tag Frau Brunner. Die Rechnung RE-2041.")
    }

    // MARK: Guards

    @Test func madeUpTextIsDroppedOnlyWhenItIsAllAWindowHas() {
        for text in ["Thank you.", " thank you ", "Thanks for watching!", "Vielen Dank.", "Untertitel im Auftrag des ZDF",
                     "Untertitelung des ZDF, 2020", "Sous-titres réalisés par la communauté d'Amara.org",
                     "Subtitles by the Amara.org community", "[Music]", "(Musik)", "[BLANK_AUDIO]", "♪ ♪", ".", "...",
                     "(upbeat music) [Applause]", "Merci."] {
            #expect(Transcriber.isMadeUp(text), "\(text)")
        }
        for text in ["Thank you. The invoice is RE 2041.", "Vielen Dank und freundliche Grüsse.", "Ja (lacht) genau.",
                     "Danke für den Anruf, Frau Brunner.", "Music lessons start on Monday."] {
            #expect(!Transcriber.isMadeUp(text), "\(text)")
        }
        // Whole windows only: "Thank you." beside real words stays.
        let windows = [Window(id: 1, start: 0, end: 30), Window(id: 2, start: 25, end: 55)]
        let texts = Transcriber.texts(of: [Segment(start: 2, end: 4, text: "Thank you."),
                                           Segment(start: 5, end: 9, text: "See you at nine."),
                                           Segment(start: 40, end: 42, text: "Thank you.")], in: windows)
        #expect(texts.map(\.window) == [1])
        #expect(texts[0].text == "Thank you. See you at nine.")
    }

    @Test func whisperOutputIsReadWithBrokenUTF8Replaced() throws {
        // whisper small wrote bytes that aren't UTF-8 on music (ASR_SPIKE.md): the rest is still read.
        var json = Data(#"{"result": {"language": "de"}, "transcription": [{"offsets": {"from": 70, "to": 4550}, "#.utf8)
        json.append(Data(#""text": " Guten Tag Frau Brunner."}, {"offsets": {"from": 4730, "to": 12810}, "#.utf8))
        json.append(Data(#""text": " Rechnung "#.utf8))
        json.append(contentsOf: [0xFF, 0xC3, 0x28])   // invalid sequences
        json.append(Data(#" RE-2041"}, {"offsets": {"from": 13000, "to": 13000}, "text": "   "}]}"#.utf8))
        let log = """
            whisper_full_with_state: auto-detected language: de (p = 0.999282)
            """
        let reading = try Transcriber.reading(json: json, log: log)
        #expect(reading.segments.count == 2)   // the empty one is left out
        #expect(reading.segments[0] == Segment(start: 0.07, end: 4.55, text: "Guten Tag Frau Brunner."))
        #expect(reading.segments[1].text.hasPrefix("Rechnung") && reading.segments[1].text.hasSuffix("RE-2041"))
        #expect(!reading.segments[1].text.contains("\u{FFFD}"))
        #expect(reading.language == "de" && reading.probability == 0.999282)

        // No speech heard (VAD): no segments, no language line, and the JSON's default language isn't taken.
        let silent = try Transcriber.reading(json: Data(#"{"result": {"language": "en"}, "transcription": []}"#.utf8),
                                             log: "whisper_full: VAD is enabled, processing speech segments only")
        #expect(silent.segments.isEmpty && silent.language == nil && silent.probability == nil)
        #expect(throws: (any Error).self) { try Transcriber.reading(json: Data("not json".utf8), log: "") }
        let detected = Transcriber.detectedLanguage(in: "auto-detected language: pt (p = 0.38)\n")
        #expect(detected?.code == "pt" && detected?.probability == 0.38)
    }

    @Test func songsAreKnownByArtistAndAlbum() {
        func song(_ json: String) -> Bool { Transcriber.isSong(probeJSON: Data(json.utf8)) }
        #expect(song(#"{"format": {"tags": {"artist": "Patent Ochsner", "album": "Gmües", "title": "W. Nuss vo Bümpliz"}}}"#))
        #expect(song(#"{"streams": [{"tags": {"ARTIST": "Stiller Has", "ALBUM": "Walliselle"}}], "format": {}}"#))   // Ogg
        #expect(song(#"{"format": {"tags": {"Artist": "A"}}, "streams": [{"tags": {"album": "B"}}]}"#))
        #expect(!song(#"{"format": {"tags": {"artist": "Voice Memos", "title": "New Recording 12"}}}"#))
        #expect(!song(#"{"format": {"tags": {"artist": "Me", "album": "  "}}}"#))
        #expect(!song(#"{"format": {}}"#))
        #expect(!song("ffprobe said nothing useful"))
    }

    // MARK: The index

    /// A recording as pass 1 leaves it: done, its name row, three audio windows with vectors.
    func recording(_ store: IndexStore, _ name: String = "memo.m4a", kind: FileKind = .audio, inode: UInt64 = 1)
        throws -> (file: Int64, windows: [Int64]) {
        let file = try store.insert(Candidate(path: folder.appendingPathComponent(name).path, kind: kind, size: 10,
                                              mtime: 1, inode: inode, device: 1))
        for (start, end) in [(0.0, 30.0), (25.0, 55.0), (50.0, 62.0)] {
            try store.addSegment(file: file, kind: .audio, modality: .audio, loc: start, locEnd: end,
                                 vector: FakeEmbedder.vector(for: "\(name) \(start)"))
        }
        try store.finish(file, state: "done", info: ["duration": "62.0"])
        return (file, try store.audioWindows(of: file).map(\.id))
    }

    func rows(_ store: IndexStore, _ sql: String) throws -> [String] {
        var out: [String] = []
        try store.db.query(sql) { row in out.append((0..<3).map { row.text(Int32($0)) ?? "-" }.joined(separator: "|")) }
        return out
    }

    @Test func transcriptsGoOntoTheAudioWindowsAndComeOutAgain() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let (file, windows) = try recording(store)
        let vectors = try rows(store, "SELECT id, hex(vec), modality FROM segments ORDER BY id")
        let names = try rows(store, "SELECT rowid, name, body FROM fts ORDER BY rowid")

        try store.setTranscript(file: file, texts: [(windows[0], "Guten Tag Frau Brunner, die Rechnung RE-2041."),
                                                    (windows[1], "Die Rechnung RE-2041 ist fällig.")],
                                info: ["transcript": "done", "transcript_lang": "de", "transcript_model": "m"])
        #expect(try rows(store, "SELECT id, hex(vec), modality FROM segments ORDER BY id") == vectors)   // no vector moved
        #expect(try rows(store, "SELECT rowid, name, body FROM fts ORDER BY rowid").prefix(names.count) == names[...])
        #expect(try store.counts().vectors == 3 && store.counts().segments == 3)                    // no new segment
        var excerpts: [String?] = []
        try store.db.query("SELECT excerpt FROM segments WHERE kind = 'audio' ORDER BY loc") { excerpts.append($0.text(0)) }
        #expect(excerpts == ["Guten Tag Frau Brunner, die Rechnung RE-2041.", "Die Rechnung RE-2041 ist fällig.", nil])
        let info = try store.info(of: file)
        #expect(info["duration"] == "62.0" && info["transcript"] == "done" && info["transcript_lang"] == "de")
        #expect(try store.transcriptCounts() == IndexStore.TranscriptCounts(done: 1))

        // Keyword search finds the moment, quotes the words, and the window's text is what was said.
        let searcher = try Searcher(store: store)
        let hits = try searcher.search("Brunner", queryVector: nil)
        #expect(hits.count == 1)
        #expect(hits.first?.segment == .audio && hits.first?.loc == 0)
        #expect(hits.first?.excerpt?.contains("«Brunner»") == true)
        #expect(try searcher.text(ofSegment: windows[1]) == "Die Rechnung RE-2041 ist fällig.")

        // Again (another model): replaced, not added.
        try store.setTranscript(file: file, texts: [(windows[2], "Bis bald.")], info: ["transcript": "done"])
        #expect(try rows(store, "SELECT rowid, body, '' FROM fts WHERE name = '' ORDER BY rowid").count == 1)
        #expect(try store.info(of: file)["transcript_lang"] == nil)

        // Off: the words, the excerpts and the info keys go; the rest stays as it was before transcripts.
        try store.setMeta("transcripts", "whisper m")
        try store.removeTranscripts()
        #expect(try rows(store, "SELECT rowid, name, body FROM fts ORDER BY rowid") == names)
        #expect(try rows(store, "SELECT id, hex(vec), modality FROM segments ORDER BY id") == vectors)
        #expect(try rows(store, "SELECT COUNT(excerpt), '', '' FROM segments") == ["0||"])
        #expect(try store.info(of: file) == ["duration": "62.0"])
        #expect(try store.meta("transcripts") == nil)
        #expect(try Searcher(store: store).search("Brunner", queryVector: nil).isEmpty)
    }

    @Test func whatWaitsForATranscript() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let memo = try recording(store, "memo.m4a", inode: 1).file
        let song = try recording(store, "song.mp3", inode: 2).file
        let talk = try recording(store, "talk.mp4", kind: .video, inode: 3).file
        let pending = try store.insert(Candidate(path: folder.appendingPathComponent("new.wav").path, kind: .audio,
                                                 size: 1, mtime: 1, inode: 4, device: 1))
        func waiting(_ build: String = "b1", music: Bool = false) throws -> Set<Int64> {
            Set(try store.untranscribed(build: build, music: music).map(\.id))
        }
        #expect(try waiting() == [memo, song, talk])   // done recordings only, not one pass 1 hasn't read
        #expect(try store.untranscribedCount(build: "b1", music: false) == 3)
        try store.setTranscript(file: song, texts: [], info: ["transcript": "none", "transcript_why": "music"])
        try store.setTranscript(file: talk, texts: [], info: ["transcript": "none", "transcript_why": "no speech"])
        #expect(try waiting() == [memo])
        #expect(try waiting(music: true) == [memo, song])   // "also music" turned on: songs get their turn
        // A failure is tried once more, then not again until whisper.cpp or the model changes.
        try store.failTranscript(file: memo, why: "whisper-cli failed (1)", build: "b1")
        #expect(try waiting() == [memo])
        try store.failTranscript(file: memo, why: "whisper-cli failed (1)", build: "b1")
        #expect(try waiting() == [])
        #expect(try store.info(of: memo)["transcript_tries"] == "2")
        #expect(try waiting("b2") == [memo])
        #expect(try store.transcriptCounts() == IndexStore.TranscriptCounts(none: 2, failed: 1))
        // The watchdog's note: a failure too.
        #expect(try store.failTranscript(at: folder.appendingPathComponent("talk.mp4").path, why: "took too long"))
        #expect(try store.info(of: talk)["transcript"] == "failed")
        #expect(try !store.failTranscript(at: "/nowhere.mp3", why: "took too long"))
        // A file that changed is read again by pass 1, and its transcript goes with what was extracted.
        try store.requeue(memo, as: Candidate(path: folder.appendingPathComponent("memo.m4a").path, kind: .audio,
                                              size: 11, mtime: 2, inode: 1, device: 1))
        #expect(try store.info(of: memo).isEmpty)
        _ = pending
    }

    @Test func turningTranscriptsOffCleansUpAndAnIndexWithoutThemStaysAsItIs() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let (file, windows) = try recording(store)
        let before = try rows(store, "SELECT rowid, name, body FROM fts ORDER BY rowid")
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        #expect(indexer.transcriber == nil)                   // off by default
        #expect(try indexer.checkTranscripts() == 0)
        #expect(try indexer.transcriptsWaiting() == 0)
        #expect(try indexer.transcribeRecordings().isEmpty)
        #expect(try rows(store, "SELECT rowid, name, body FROM fts ORDER BY rowid") == before)
        #expect(try store.meta("transcripts") == nil)

        // An index that has transcripts, opened with them off.
        try store.setTranscript(file: file, texts: [(windows[0], "Grüezi")], info: ["transcript": "done"])
        try store.setMeta("transcripts", "whisper ggml-large-v3-turbo-q5_0.bin")
        #expect(try indexer.checkTranscripts() == 0)
        #expect(try rows(store, "SELECT rowid, name, body FROM fts ORDER BY rowid") == before)
        #expect(try store.info(of: file) == ["duration": "62.0"])
        #expect(try store.meta("transcripts") == nil)
    }

    // MARK: With whisper-cli (only where it and a model are, and a recording is named)

    /// The whole pass on a real recording: DIGUP_TEST_TRANSCRIPT names one with speech, DIGUP_TEST_TRANSCRIPT_WORD a
    /// word said in it (e.g. the spike's syn_de_invoice.wav and "Brunner"). Pass 1 with the fake model, then the
    /// transcript pass with whisper-cli on the GPU; a noise clip beside it gets no words. Skipped without them (CI
    /// has no model).
    @Test func aRecordingIsTranscribedIntoTheIndex() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let clip = environment["DIGUP_TEST_TRANSCRIPT"], let word = environment["DIGUP_TEST_TRANSCRIPT_WORD"],
              Transcriber.engine(for: .gpu) != nil else { return }
        let files = folder.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let recording = files.appendingPathComponent("recording." + URL(fileURLWithPath: clip).pathExtension)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: clip), to: recording)
        // 20 s of soft noise: windows for pass 1, no speech for whisper.
        var state: UInt32 = 1
        let noise = (0..<320_000).map { _ -> Int16 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Int16(truncatingIfNeeded: Int32(state >> 16) % 1600 - 800)
        }
        try AudioExtractor.writeWAV(noise[...], to: files.appendingPathComponent("noise.wav"))

        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        var options = IndexOptions()
        options.transcripts = .gpu
        let indexer = try Indexer(store: store, options: options, makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([files])
        #expect(try indexer.run()["done"] == 2)
        #expect(try indexer.checkTranscripts() == 2)
        var steps: [Indexer.TranscriptStep] = []
        #expect(try indexer.transcribeRecordings(onStep: { steps.append($0) }) == ["done": 1, "none": 1])
        #expect(Set(steps.map(\.state)) == ["done", "none"])
        #expect(try indexer.transcriptsWaiting() == 0)
        let hits = try Searcher(store: store).search(word, queryVector: nil)
        #expect(hits.first?.path == recording.path && hits.first?.segment == .audio && hits.first?.loc != nil)
        var noiseInfo: [String: String] = [:]
        try store.db.query("SELECT id FROM files WHERE path LIKE '%noise.wav'") { noiseInfo = (try? store.info(of: $0.int(0))) ?? [:] }
        #expect(noiseInfo["transcript"] == "none")
    }
}
