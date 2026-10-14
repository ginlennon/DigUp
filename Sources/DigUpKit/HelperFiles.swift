import Foundation

/// Files a helper leaves in a folder other helpers use too: `digup search-service`'s previews and its query encoder's
/// log. Several search helpers can share an index (the app's, an MCP server's, an HTTP API's), so each marks its files
/// with its process id and, at its start, clears only its own and anyone's over a day old (what helpers that ended
/// left). A process id comes back only once its process is gone, so what a helper finds with its own mark is an
/// earlier one's.
public enum HelperFiles {
    /// Removes the files in `folder` whose names `mine` says are this helper's, and the day-old ones `ofItsKind` says
    /// are files of this sort (the other files there are left alone).
    public static func clear(in folder: URL, mine: (String) -> Bool, ofItsKind: (String) -> Bool = { _ in true },
                             now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            let path = folder.appendingPathComponent(name).path
            if mine(name) {
                try? FileManager.default.removeItem(atPath: path)
                continue
            }
            guard ofItsKind(name) else { continue }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
                ?? .distantPast
            if now.timeIntervalSince(modified) > 86_400 { try? FileManager.default.removeItem(atPath: path) }
        }
    }
}
