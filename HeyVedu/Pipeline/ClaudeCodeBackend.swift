import Foundation
import os

/// Cleans transcripts with the locally installed Claude Code CLI.
///
/// One long-lived headless session (`claude -p` in `stream-json` mode) serves every
/// dictation: each transcript is one user message and each `result` line is its answer.
/// This skips CLI startup and keeps the system prompt in the prompt cache (~2 s per
/// dictation with Opus at low effort, vs ~4–5 s with a process per dictation). The
/// session is recycled every `maxTurnsPerSession` dictations — a replacement is started
/// right away so it's warm by the next one — which bounds accumulated history.
///
/// Hardening:
/// - No shell: executable + argument array only. Transcripts go over stdin, never argv,
///   so they don't appear in process listings.
/// - `--tools ""`, `--strict-mcp-config`, `--disable-slash-commands`: Claude can only
///   return text, so instructions spoken in a dictation can't trigger any action.
/// - `--setting-sources ""`, `--no-session-persistence`, an empty working directory and a
///   minimal environment: user hooks, CLAUDE.md files and saved sessions are not used.
final class ClaudeCodeBackend {
    nonisolated enum Model: String, CaseIterable, Identifiable {
        case opus
        case sonnet
        case haiku

        var id: String { rawValue }

        var title: String {
            switch self {
            case .opus: return "Opus 5.5 (most accurate)"
            case .sonnet: return "Sonnet"
            case .haiku: return "Haiku (fastest)"
            }
        }

        /// Opus is pinned to 5.5; the others follow Claude Code's current aliases.
        var cliName: String {
            switch self {
            case .opus: return "claude-opus-5-5"
            case .sonnet: return "sonnet"
            case .haiku: return "haiku"
            }
        }
    }

    nonisolated enum BackendError: LocalizedError {
        case notInstalled
        case launchFailed(String)
        case sessionEnded(String)
        case busy
        case failed(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Claude Code not found"
            case .launchFailed(let reason): return "couldn't launch claude: \(reason)"
            case .sessionEnded(let reason): return "claude session ended: \(reason)"
            case .busy: return "claude is still working on the previous dictation"
            case .failed(let reason): return "claude failed: \(reason)"
            case .emptyResult: return "claude returned no text"
            }
        }
    }

    private static let maxTurnsPerSession = 20

    private var session: ClaudeSession?
    private let logger = Logger(subsystem: "com.rajan.heyvedu", category: "Claude")

    /// Where Claude Code's installers put the binary. Apps launched from Finder get a
    /// minimal PATH, so look in the known locations rather than relying on it.
    private static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/homebrew/bin/claude",
        ]
    }

    private static func executableURL() -> URL? {
        candidatePaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func availability() -> TextCleaner.Availability {
        Self.executableURL() == nil ? .unavailable("Claude Code not found (install the claude CLI)") : .available
    }

    /// Makes sure a session with this configuration is running (called at launch and when
    /// a dictation starts, so any startup overlaps the user speaking).
    func prepare(model: Model, instructions: String) {
        do {
            _ = try ensureSession(model: model, instructions: instructions)
        } catch {
            // Not fatal: clean() tries again.
            logger.error("Starting claude session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops the session (engine switched away, or app quitting).
    func shutdown() {
        session?.terminate()
        session = nil
    }

    func clean(_ transcript: String, model: Model, instructions: String) async throws -> String {
        let started = ContinuousClock.now
        let current = try ensureSession(model: model, instructions: instructions)
        let text: String
        do {
            text = try await current.send(transcript)
        } catch BackendError.sessionEnded(let reason) {
            // The session died (e.g. killed or crashed) — start a fresh one and retry once.
            DebugTrace.write("claude: session ended (\(reason)); retrying in a new session")
            shutdown()
            text = try await ensureSession(model: model, instructions: instructions).send(transcript)
        }
        DebugTrace.write("claude: \(model.rawValue) responded in \(ContinuousClock.now - started) (turn \(session?.turns ?? 0))")

        if let session, session.turns >= Self.maxTurnsPerSession {
            // Recycle now so the replacement is warm before the next dictation.
            DebugTrace.write("claude: recycling session after \(session.turns) turns")
            shutdown()
            prepare(model: model, instructions: instructions)
        }
        return text
    }

    private func ensureSession(model: Model, instructions: String) throws -> ClaudeSession {
        let signature = ClaudeSession.signature(model: model, instructions: instructions)
        if let session, session.isAlive, session.signature == signature { return session }
        shutdown()

        guard let executable = Self.executableURL() else { throw BackendError.notInstalled }
        let systemPrompt = instructions + """


        Each message is a new, independent transcript: never refer back to, repeat or merge \
        earlier transcripts. Reply with only the rewritten text: no quotes, tags, or commentary.
        """
        let arguments = [
            "-p",
            "--model", model.cliName,
            // Lowest effort and thinking off: cleanup needs no reasoning, only speed.
            "--effort", "low",
            "--settings", #"{"alwaysThinkingEnabled":false}"#,
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--tools", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--setting-sources", "",
            // Via a file rather than argv, so vocabulary terms don't show in process listings.
            "--system-prompt-file", try Self.writeSystemPrompt(systemPrompt).path,
        ]
        do {
            let session = try ClaudeSession(
                executable: executable,
                arguments: arguments,
                workingDirectory: try Self.workingDirectory(),
                signature: signature
            )
            self.session = session
            DebugTrace.write("claude: started \(model.rawValue) session")
            return session
        } catch {
            throw BackendError.launchFailed(error.localizedDescription)
        }
    }

    /// Written next to (not inside) the working directory, readable only by the user.
    private static func writeSystemPrompt(_ prompt: String) throws -> URL {
        let url = try workingDirectory().deletingLastPathComponent().appending(path: "claude-system-prompt.txt")
        do {
            try Data(prompt.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw BackendError.launchFailed("couldn't write system prompt (\(error.localizedDescription))")
        }
        return url
    }

    /// An empty directory, so Claude Code finds no project files or CLAUDE.md.
    private static func workingDirectory() throws -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "HeyVedu/claude-workdir", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A running `claude -p --input-format stream-json` process. One request at a time:
/// write a user message line, then wait for the next `result` line on stdout.
private final class ClaudeSession {
    let signature: String
    private(set) var turns = 0
    private(set) var isAlive = true

    private let process = Process()
    private let stdin = Pipe()
    private var pending: CheckedContinuation<String, Error>?
    private var stderrTail = ""
    private var stdoutReader: LineReader?
    private var stderrReader: LineReader?

    static func signature(model: ClaudeCodeBackend.Model, instructions: String) -> String {
        "\(model.rawValue)|\(instructions.hashValue)"
    }

    init(executable: URL, arguments: [String], workingDirectory: URL, signature: String) throws {
        self.signature = signature
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.minimalEnvironment()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Read stdout line by line for the session's lifetime; stderr is drained so the
        // child never blocks, keeping only a short tail for error messages. Lines are
        // delivered to the main queue in order.
        stdoutReader = LineReader(handle: stdout.fileHandleForReading) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch event {
                    case .line(let line): self?.handle(line: line)
                    case .end: self?.handleExit()
                    }
                }
            }
        }
        stderrReader = LineReader(handle: stderr.fileHandleForReading) { [weak self] event in
            guard case .line(let line) = event else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.recordStderr(line) }
            }
        }
    }

    func send(_ transcript: String) async throws -> String {
        guard isAlive else { throw ClaudeCodeBackend.BackendError.sessionEnded(exitDescription) }
        guard pending == nil else { throw ClaudeCodeBackend.BackendError.busy }

        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": CleanupPrompt.prompt(for: transcript)],
        ]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            do {
                try stdin.fileHandleForWriting.write(contentsOf: line)
            } catch {
                pending = nil
                continuation.resume(throwing: ClaudeCodeBackend.BackendError.sessionEnded("write failed"))
            }
        }
    }

    func terminate() {
        guard isAlive else { return }
        isAlive = false
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        resumePending(throwing: ClaudeCodeBackend.BackendError.sessionEnded("stopped"))
    }

    private func handle(line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "result" else { return }
        turns += 1
        let isError = (object["is_error"] as? Bool ?? false) || (object["subtype"] as? String != "success")
        let text = (object["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard let continuation = pending else { return }
        pending = nil
        if isError {
            continuation.resume(throwing: ClaudeCodeBackend.BackendError.failed(String(text.prefix(200))))
        } else if text.isEmpty {
            continuation.resume(throwing: ClaudeCodeBackend.BackendError.emptyResult)
        } else {
            continuation.resume(returning: text)
        }
    }

    private func handleExit() {
        isAlive = false
        resumePending(throwing: ClaudeCodeBackend.BackendError.sessionEnded(exitDescription))
    }

    private func recordStderr(_ line: String) {
        stderrTail = String((stderrTail + line + "\n").suffix(400))
    }

    private func resumePending(throwing error: Error) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(throwing: error)
    }

    private var exitDescription: String {
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? "process exited" : String(tail.suffix(200))
    }

    /// Only what Claude Code needs to find its login and config — nothing else from the
    /// app's environment is passed through.
    private static func minimalEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "LANG"] {
            if let value = inherited[key] { environment[key] = value }
        }
        return environment
    }
}

/// Splits a pipe's output into lines as data arrives (`FileHandle.bytes.lines` can hold
/// pipe output back until EOF). The handler runs on a background queue.
private nonisolated final class LineReader: @unchecked Sendable {
    enum Event: Sendable {
        case line(String)
        case end
    }

    private var buffer = Data()

    init(handle: FileHandle, onEvent: @escaping @Sendable (Event) -> Void) {
        // readabilityHandler invocations are serial, so `buffer` needs no lock.
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                if !buffer.isEmpty { onEvent(.line(String(decoding: buffer, as: UTF8.self))) }
                buffer.removeAll()
                onEvent(.end)
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                onEvent(.line(line))
            }
        }
    }
}
