import Foundation

/// Debug-only diagnostics written to ~/Library/Logs/LocalDictation/debug.log.
/// Never pass transcript text or typed keys here.
nonisolated enum DebugTrace {
    #if DEBUG
    private static let queue = DispatchQueue(label: "com.rajan.localdictation.debugtrace")
    private static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/LocalDictation", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "debug.log")
    }()
    #endif

    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = "\(Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))) \(message())\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        #endif
    }
}
