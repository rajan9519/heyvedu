import Foundation

/// Finds the `claude` and `codex` binaries and builds the environment they run with.
///
/// Apps launched from the Dock get a minimal `PATH`, so a plain lookup misses both CLIs.
/// We check the usual install folders, then ask a login shell once, and cache the answer.
nonisolated enum CLILocator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: URL] = [:]
    nonisolated(unsafe) private static var loginPath: String?

    static let searchFolders = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin", "~/.bun/bin"]

    /// Blocks for up to a few seconds the first time (login shell); call off the main actor.
    static func find(_ name: String) -> URL? {
        if let cached = lock.withLock({ cache[name] }) { return cached }
        let fileManager = FileManager.default
        let folders = searchFolders.map { NSString(string: $0).expandingTildeInPath }
        var found = folders.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
        if found == nil, let path = shell("command -v \(name)")?.split(separator: "\n").last,
           path.hasPrefix("/"), fileManager.isExecutableFile(atPath: String(path)) {
            found = URL(fileURLWithPath: String(path))
        }
        if let found { lock.withLock { cache[name] = found } }
        return found
    }

    /// The app's environment with a usable `PATH` (Codex installed through npm needs `node`),
    /// minus variables a parent Claude Code session sets, which would change how `claude` runs.
    static func environment(for binary: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("CLAUDECODE") && !key.hasPrefix("CLAUDE_CODE_") && key != "CODEX_SANDBOX"
        }
        let login = lock.withLock { loginPath } ?? {
            let path = shell("printf %s \"$PATH\"") ?? ""
            lock.withLock { loginPath = path }
            return path
        }()
        let inherited = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var folders: [String] = [binary.deletingLastPathComponent().path]
        folders += searchFolders.map { NSString(string: $0).expandingTildeInPath }
        folders += login.split(separator: ":").map(String.init)
        folders += inherited.split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = folders.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    /// Runs a short command (`--version`, `auth status`) and returns its exit status and output
    /// (stdout and stderr together; `codex login status` writes to stderr).
    static func run(_ binary: URL, _ arguments: [String], timeout: Duration = .seconds(10)) async -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment(for: binary)
        process.currentDirectoryURL = AssistPaths.workingDirectory
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = Task.detached {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        let data = await Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        killer.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// `zsh -lc <command>` with a 5 s limit; nil on failure.
    private static func shell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
