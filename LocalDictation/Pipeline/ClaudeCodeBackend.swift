import Foundation
import os

/// Cleans transcripts with the locally installed Claude Code CLI in headless mode.
///
/// The `claude` process is launched when recording starts (its ~2–3 s startup overlaps
/// the user speaking) and waits on stdin in `stream-json` mode; the transcript is sent
/// when the key is released. Hardening:
/// - No shell: executable + argument array only. The transcript goes over stdin, never
///   argv, so it doesn't appear in process listings.
/// - `--tools ""`, `--strict-mcp-config`, `--disable-slash-commands`: Claude can only
///   return text, so instructions spoken in a dictation can't trigger any action.
/// - `--setting-sources ""`, `--no-session-persistence`, an empty working directory and a
///   minimal environment: user hooks, CLAUDE.md files and session history are not used.
final class ClaudeCodeBackend {
    nonisolated enum Model: String, CaseIterable, Identifiable {
        case haiku
        case sonnet

        var id: String { rawValue }

        var title: String {
            switch self {
            case .haiku: return "Haiku (faster)"
            case .sonnet: return "Sonnet (more accurate)"
            }
        }
    }

    nonisolated enum BackendError: LocalizedError {
        case notInstalled
        case launchFailed(String)
        case failed(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Claude Code not found"
            case .launchFailed(let reason): return "couldn't launch claude: \(reason)"
            case .failed(let reason): return "claude failed: \(reason)"
            case .emptyResult: return "claude returned no text"
            }
        }
    }

    private var prepared: ClaudeProcess?
    private let logger = Logger(subsystem: "com.rajan.localdictation", category: "Claude")

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

    func prepare(model: Model, instructions: String) {
        discardPrepared()
        do {
            prepared = try launch(model: model, instructions: instructions)
        } catch {
            // Not fatal: clean() launches a fresh process.
            logger.error("Pre-launching claude failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func discardPrepared() {
        prepared?.terminate()
        prepared = nil
    }

    func clean(_ transcript: String, model: Model, instructions: String) async throws -> String {
        let signature = ClaudeProcess.signature(model: model, instructions: instructions)
        var process = prepared
        prepared = nil
        if process?.signature != signature || process?.isRunning != true {
            process?.terminate()
            process = nil
        }

        let started = ContinuousClock.now
        do {
            let result = try await (process ?? launch(model: model, instructions: instructions)).send(transcript)
            DebugTrace.write("claude: \(model.rawValue) responded in \(ContinuousClock.now - started)\(process == nil ? " (cold launch)" : "")")
            return result
        } catch let error as BackendError {
            // A pre-launched process may have exited while the user was speaking; retry once cold.
            guard process != nil else { throw error }
            DebugTrace.write("claude: pre-launched process failed (\(error.localizedDescription)); retrying cold")
            return try await launch(model: model, instructions: instructions).send(transcript)
        }
    }

    private func launch(model: Model, instructions: String) throws -> ClaudeProcess {
        guard let executable = Self.executableURL() else { throw BackendError.notInstalled }
        let systemPrompt = instructions + "\n\nReply with only the rewritten text: no quotes, tags, or commentary."
        let arguments = [
            "-p",
            "--model", model.rawValue,
            "--effort", "low",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--tools", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--setting-sources", "",
            "--system-prompt", systemPrompt,
        ]
        do {
            return try ClaudeProcess(
                executable: executable,
                arguments: arguments,
                workingDirectory: try Self.workingDirectory(),
                signature: ClaudeProcess.signature(model: model, instructions: instructions)
            )
        } catch {
            throw BackendError.launchFailed(error.localizedDescription)
        }
    }

    /// An empty directory, so Claude Code finds no project files or CLAUDE.md.
    private static func workingDirectory() throws -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LocalDictation/claude-workdir", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// One headless `claude -p` process handling exactly one transcript.
private nonisolated final class ClaudeProcess: @unchecked Sendable {
    let signature: String

    private let process = Process()
    private let stdin = Pipe()
    private let stdoutTask: Task<Data, Never>
    private let stderrTask: Task<Data, Never>

    var isRunning: Bool { process.isRunning }

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
        // Drain both pipes right away so the child can never block on a full pipe. Started
        // only after a successful launch, so a failed launch leaves no blocked readers.
        stdoutTask = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
        stderrTask = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
    }

    /// Sends the transcript as the single user message, closes stdin, and returns the
    /// final result text.
    func send(_ transcript: String) async throws -> String {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": CleanupPrompt.prompt(for: transcript)],
        ]
        do {
            var line = try JSONSerialization.data(withJSONObject: message)
            line.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: line)
            try stdin.fileHandleForWriting.close()
        } catch {
            terminate()
            throw ClaudeCodeBackend.BackendError.failed("could not write to claude (\(error.localizedDescription))")
        }

        let output = await stdoutTask.value
        let errorOutput = await stderrTask.value
        let status = await Task.detached { [process] in
            process.waitUntilExit()
            return process.terminationStatus
        }.value

        guard let result = Self.finalResult(in: output) else {
            let detail = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(200)
            throw ClaudeCodeBackend.BackendError.failed(detail.isEmpty ? "exit status \(status)" : String(detail))
        }
        if result.isError {
            throw ClaudeCodeBackend.BackendError.failed(String(result.text.prefix(200)))
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeCodeBackend.BackendError.emptyResult }
        return text
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// The last `{"type":"result",...}` line of the stream-json output.
    private static func finalResult(in output: Data) -> (text: String, isError: Bool)? {
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "result" else { continue }
            let isError = (object["is_error"] as? Bool ?? false) || (object["subtype"] as? String != "success")
            return (object["result"] as? String ?? "", isError)
        }
        return nil
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
