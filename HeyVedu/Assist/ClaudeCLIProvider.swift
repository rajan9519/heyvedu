import Foundation
import os

/// Claude Code through one long-running `claude -p --input-format stream-json` process.
///
/// A stream-json process is one conversation with a fixed system prompt and schema, so each
/// (task, model, effort) gets its own process, restarted after `maxRequests`, idle time or
/// any error to keep earlier edits from piling up in its context (AI-ASSIST-PLAN §3.2).
/// Tools, MCP, settings and saved sessions are all off; the user's text goes on stdin only.
final class ClaudeCLIProvider: AssistProvider {
    let id = AssistProviderID.claude
    let isLocal = false

    static let maxRequests = 30
    static let idleLimit: Duration = .seconds(600)

    private struct SessionKey: Equatable {
        var system: String
        var schema: Data
        var model: String?
        var effort: String?
    }

    private final class Session {
        let process: LineProcess
        let key: SessionKey
        var requests = 0
        var lastUsed = ContinuousClock.now
        /// `total_cost_usd` is cumulative for the process; per-call cost is the difference.
        var reportedCost = 0.0

        init(process: LineProcess, key: SessionKey) {
            self.process = process
            self.key = key
        }
    }

    private var session: Session?
    private var binary: URL?
    private let logger = Logger(subsystem: "com.heyvedu.app", category: "Assist")

    /// Flags every `claude` call shares: no tools, MCP, user settings or saved sessions.
    static let lockedDownArguments = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
    ]

    func availability() async -> AssistAvailability {
        guard let binary = await locate() else { return .notInstalled }
        let version = await CLILocator.run(binary, ["--version"])?.output
            .split(separator: " ").first.map(String.init)
        guard let auth = await CLILocator.run(binary, ["auth", "status"]) else {
            return .failed("Couldn't run claude auth status")
        }
        let status = try? JSONSerialization.jsonObject(with: Data(auth.output.utf8)) as? [String: Any]
        guard status?["loggedIn"] as? Bool == true else {
            return .signedOut("Sign in to Claude Code: run claude in Terminal and use /login")
        }
        return .available(version: version)
    }

    func models() async throws -> [AssistModel] {
        guard let binary = await locate() else { throw AssistError.unavailable("Claude Code isn't installed") }
        let process = try LineProcess(executable: binary, arguments: Self.lockedDownArguments,
                                      environment: CLILocator.environment(for: binary),
                                      directory: AssistPaths.workingDirectory)
        defer { process.terminate() }
        try process.write(json: ["type": "control_request", "request_id": "models",
                                 "request": ["subtype": "initialize"]])
        let response = try await withDeadline(process, .seconds(30)) {
            while let line = await process.nextLine() {
                guard let object = Self.object(line), object["type"] as? String == "control_response",
                      let outer = object["response"] as? [String: Any] else { continue }
                return outer["response"] as? [String: Any] ?? outer
            }
            throw process.endedBecause ?? AssistError.classify(process.stderrText)
        }
        return Self.parseModels(response)
    }

    func warmUp(_ call: AssistCall, route: AssistRoute) {
        Task { _ = try? await session(for: call, route: route) }
    }

    func shutdown() {
        session?.process.terminate()
        session = nil
    }

    func run(_ call: AssistCall, route: AssistRoute) async throws -> AssistRawResult {
        let session = try await session(for: call, route: route)
        let process = session.process
        let started = ContinuousClock.now
        do {
            try process.write(json: ["type": "user", "message": ["role": "user", "content": call.user]])
            let result = try await withDeadline(process, call.timeout) {
                while let line = await process.nextLine() {
                    if let object = Self.object(line), object["type"] as? String == "result" { return object }
                }
                throw process.endedBecause ?? AssistError.classify(process.stderrText)
            }
            let parsed = try Self.parseResult(result)
            let cost = parsed.totalCost.map { max(0, $0 - session.reportedCost) }
            session.reportedCost = parsed.totalCost ?? session.reportedCost
            session.requests += 1
            session.lastUsed = .now
            if session.requests >= Self.maxRequests { endSession(session) }
            return AssistRawResult(json: parsed.json, latency: started.duration(to: .now),
                                   inputTokens: parsed.inputTokens, outputTokens: parsed.outputTokens,
                                   costUSD: cost)
        } catch {
            endSession(session)
            throw error
        }
    }

    // MARK: - Processes

    private func locate() async -> URL? {
        if let binary { return binary }
        binary = await Task.detached { CLILocator.find("claude") }.value
        return binary
    }

    private func session(for call: AssistCall, route: AssistRoute) async throws -> Session {
        let key = SessionKey(system: call.system, schema: call.schema, model: route.model, effort: route.effort)
        if let session = reusable(key) { return session }
        guard let binary = await locate() else { throw AssistError.unavailable("Claude Code isn't installed") }
        if let session = reusable(key) { return session }  // a warm-up finished while we looked
        if let session { endSession(session) }
        var arguments = Self.lockedDownArguments
        if let model = route.model { arguments += ["--model", model] }
        if let effort = route.effort { arguments += ["--effort", effort] }
        arguments += ["--system-prompt", call.system, "--json-schema", String(decoding: call.schema, as: UTF8.self)]
        let process = try LineProcess(executable: binary, arguments: arguments,
                                      environment: CLILocator.environment(for: binary),
                                      directory: AssistPaths.workingDirectory)
        logger.debug("claude process started for \(route.key, privacy: .public)")
        let session = Session(process: process, key: key)
        self.session = session
        return session
    }

    private func reusable(_ key: SessionKey) -> Session? {
        guard let session, session.key == key, session.process.isRunning,
              session.requests < Self.maxRequests,
              session.lastUsed.duration(to: .now) < Self.idleLimit else { return nil }
        return session
    }

    private func endSession(_ ended: Session) {
        ended.process.terminate()
        if session === ended { session = nil }
    }

    // MARK: - Parsing (pure, unit-tested)

    nonisolated struct ParsedResult {
        var json: Data
        var inputTokens: Int?
        var outputTokens: Int?
        var totalCost: Double?
    }

    nonisolated static func object(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    /// Reads a `"type":"result"` line: the structured output, or the error it reports.
    nonisolated static func parseResult(_ result: [String: Any]) throws -> ParsedResult {
        let message = result["result"] as? String ?? result["subtype"] as? String ?? "Claude Code failed"
        if result["is_error"] as? Bool == true || (result["subtype"] as? String).map({ $0 != "success" }) == true {
            switch result["api_error_status"] as? Int {
            case 401, 403: throw AssistError.unavailable(message)
            case 404: throw AssistError.modelRejected(message)
            case 429, 503, 529: throw AssistError.capacity(message)
            default: throw AssistError.classify(message)
            }
        }
        let json: Data
        if let structured = result["structured_output"], !(structured is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            json = data
        } else if let text = result["result"] as? String, object(Data(text.utf8)) != nil {
            json = Data(text.utf8)
        } else {
            throw AssistError.badOutput("No structured output")
        }
        let usage = result["usage"] as? [String: Any] ?? [:]
        let input = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .compactMap { usage[$0] as? Int }
        return ParsedResult(json: json, inputTokens: input.isEmpty ? nil : input.reduce(0, +),
                            outputTokens: usage["output_tokens"] as? Int,
                            totalCost: result["total_cost_usd"] as? Double)
    }

    /// The `initialize` control response's model list, aliases kept (the picker merges them).
    nonisolated static func parseModels(_ response: [String: Any]) -> [AssistModel] {
        (response["models"] as? [[String: Any]] ?? []).compactMap { model in
            guard let value = model["value"] as? String else { return nil }
            return AssistModel(provider: .claude, id: value,
                               resolvedID: model["resolvedModel"] as? String ?? value,
                               displayName: model["displayName"] as? String ?? value,
                               description: model["description"] as? String ?? "",
                               efforts: model["supportedEffortLevels"] as? [String] ?? [])
        }
    }
}
