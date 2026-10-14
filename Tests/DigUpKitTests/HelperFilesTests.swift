import Foundation
import Testing
@testable import DigUpKit

/// What a search helper clears at its start in the folders it shares with others (`HelperFiles`).
@Suite final class HelperFilesTests {
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func make(_ name: String, hoursOld: Double) throws {
        let path = folder.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-hoursOld * 3600)],
                                              ofItemAtPath: path)
    }

    private var left: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    @Test func itsOwnGoAndOthersOnlyOnceTheyreADayOld() throws {
        try make("worker-query-41.log", hoursOld: 1)    // an earlier helper with this one's process id
        try make("worker-query-42.log", hoursOld: 1)    // another helper's, running
        try make("worker-query-43.log", hoursOld: 30)   // a helper's that ended long ago
        try make("worker.log", hoursOld: 30)            // not a query log: left alone
        try make("index.sqlite", hoursOld: 30)
        HelperFiles.clear(in: folder, mine: { $0 == "worker-query-41.log" },
                          ofItsKind: { $0.hasPrefix("worker-query-") && $0.hasSuffix(".log") })
        #expect(left == ["worker-query-42.log", "worker.log", "index.sqlite"])
    }

    @Test func everythingInAFolderOfItsOwnKind() throws {
        try make("p41-a.jpg", hoursOld: 1)
        try make("p42-b.jpg", hoursOld: 1)
        try make("p43-c.jpg", hoursOld: 30)
        HelperFiles.clear(in: folder, mine: { $0.hasPrefix("p41-") })
        #expect(left == ["p42-b.jpg"])
    }
}
