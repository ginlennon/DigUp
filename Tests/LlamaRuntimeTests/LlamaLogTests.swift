import Foundation
import Testing
@testable import LlamaRuntime

/// Our own lines in llama.cpp's log wait for an embedder to say where they go (`LlamaLog`): none reach the terminal
/// of `digup status`, which only loads the backends.
@Suite struct LlamaLogTests {
    @Test func linesWaitForTheEmbeddersLog() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("digup-llama-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = LlamaLog()
        log.line("backends: CPU")   // loading the backends, before any embedder
        #expect(!FileManager.default.fileExists(atPath: url.path))
        log.send(to: url)
        log.line("devices: CPU (8 threads)")
        log.send(to: nil)           // closes the file
        #expect(try String(contentsOf: url, encoding: .utf8)
            == "[llama.cpp worker] backends: CPU\n[llama.cpp worker] devices: CPU (8 threads)\n")
    }
}
