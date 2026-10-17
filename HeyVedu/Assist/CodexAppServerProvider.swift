import Foundation
import os

/// Codex through one long-running `codex app-server`, spoken to in JSON-RPC over stdio, the
/// way the official Python SDK does it: `initialize` → `thread/start` → `turn/start` → wait
/// for `turn/completed`. Each request gets its own ephemeral, read-only thread; every
/// approval the server asks for is declined. Restarted after errors, idle time or
/// `maxRequests` (AI-ASSIST-PLAN §3.2).
final class CodexAppServerProvider: AssistProvider {
    let id = AssistProviderID.codex
    let isLocal = false

    static let maxRequests = 200
    static let idleLimit: Duration = .seconds(600)

    private final class Server {
        let process: LineProcess
        var nextID = 0
        var pending: [Int: CheckedContinuation<RPCResult, any Error>] = [:]
        var turns: [String: CodexTurn] = [:]
        var turnWaiters: [String: CheckedContinuation<CodexTurn, any Error>] = [:]
        var requests = 0
        var lastUsed = ContinuousClock.now
        var ended = false

        init(process: LineProcess) {
            self.process = process
        }
    }

    /// A JSON-RPC result, handed from the reader to the waiting request on the main actor.
    private struct RPCResult: @unchecked Sendable {
        let object: [String: Any]
    }

    private var server: Server?
    private var starting: Task<Server, any Error>?
    private var binary: URL?
    private let logger = Logger(subsystem: "com.heyvedu.app", category: "Assist")

    func availability() async -> AssistAvailability {
        guard let binary = await locate() else { return .notInstalled }
        let version = await CLILocator.run(binary, ["--version"])?.output
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").last.map(String.init)
        guard let login = await CLILocator.run(binary, ["login", "status"]) else {
            return .failed("Couldn't run codex login status")
        }
        guard login.status == 0, login.output.localizedCaseInsensitiveContains("logged in") else {
            return .signedOut("Sign in to Codex: run codex login in Terminal")
        }
        if let version, let cacheVersion = Self.modelCacheClientVersion(),
           Self.compareVersions(version, cacheVersion) == .orderedAscending {
            return .outdated(version: version, message: "Update Codex to use its newest models: run codex update")
        }
        return .available(version: version)
    }

    func models() async throws -> [AssistModel] {
        let server = try await readyServer()
        var models: [AssistModel] = []
        var cursor: String?
        try await withDeadline(server.process, .seconds(30)) {
            repeat {
                var params: [String: Any] = ["includeHidden": false]
                if let cursor { params["cursor"] = cursor }
                let page = try await request(server, "model/list", params)
                models += Self.parseModels(page)
                cursor = page["nextCursor"] as? String
            } while cursor != nil
        }
        return models
    }

    func warmUp(_ call: AssistCall, route: AssistRoute) {
        Task { _ = try? await readyServer() }
    }

    func shutdown() {
        if let server { end(server) }
    }

    func run(_ call: AssistCall, route: AssistRoute) async throws -> AssistRawResult {
        let server = try await readyServer()
        let started = ContinuousClock.now
        do {
            let result = try await withDeadline(server.process, call.timeout) {
                try await turn(on: server, call: call, route: route)
            }
            server.requests += 1
            server.lastUsed = .now
            if server.requests >= Self.maxRequests { end(server) }
            guard let text = result.text else { throw AssistError.badOutput("No reply") }
            return AssistRawResult(json: Data(text.utf8), latency: started.duration(to: .now),
                                   inputTokens: result.inputTokens, outputTokens: result.outputTokens,
                                   costUSD: nil)
        } catch let error as AssistError {
            // A failed turn leaves the server healthy; anything else gets a fresh one.
            if case .modelRejected = error {} else if case .capacity = error {} else { end(server) }
            throw error
        }
    }

    private func turn(on server: Server, call: AssistCall, route: AssistRoute) async throws -> CodexTurn {
        var threadParams: [String: Any] = [
            "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never",
            "baseInstructions": call.system, "cwd": AssistPaths.workingDirectory.path,
            "config": ["web_search": "disabled"],
        ]
        if let model = route.model { threadParams["model"] = model }
        if let tier = route.serviceTier { threadParams["serviceTier"] = tier }
        let thread = try await request(server, "thread/start", threadParams)
        guard let threadID = (thread["thread"] as? [String: Any])?["id"] as? String else {
            throw AssistError.badOutput("thread/start returned no thread")
        }
        server.turns[threadID] = CodexTurn()
        defer { server.turns[threadID] = nil }
        var turnParams: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": call.user]],
            "outputSchema": (try? JSONSerialization.jsonObject(with: call.schema)) ?? [:],
        ]
        if let effort = route.effort { turnParams["effort"] = effort }
        _ = try await request(server, "turn/start", turnParams)
        let turn: CodexTurn
        if let finished = server.turns[threadID], finished.finished {
            turn = finished
        } else {
            turn = try await withCheckedThrowingContinuation { server.turnWaiters[threadID] = $0 }
        }
        if let failure = turn.failure { throw failure }
        return turn
    }

    // MARK: - Server lifecycle

    private func locate() async -> URL? {
        if let binary { return binary }
        binary = await Task.detached { CLILocator.find("codex") }.value
        return binary
    }

    private func readyServer() async throws -> Server {
        if let server, !server.ended, server.process.isRunning,
           server.lastUsed.duration(to: .now) < Self.idleLimit {
            return server
        }
        if let server { end(server) }
        if let starting { return try await starting.value }
        let task = Task { try await self.startServer() }
        starting = task
        defer { starting = nil }
        let server = try await task.value
        self.server = server
        return server
    }

    private func startServer() async throws -> Server {
        guard let binary = await locate() else { throw AssistError.unavailable("Codex isn't installed") }
        let process = try LineProcess(executable: binary,
                                      arguments: ["app-server", "--listen", "stdio://", "-c", "web_search=\"disabled\""],
                                      environment: CLILocator.environment(for: binary),
                                      directory: AssistPaths.workingDirectory)
        let server = Server(process: process)
        Task { [weak self] in
            while let line = await process.nextLine() {
                self?.handle(line, on: server)
            }
            self?.ended(server)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        _ = try await withDeadline(process, .seconds(30)) {
            try await request(server, "initialize", [
                "clientInfo": ["name": "heyvedu", "title": "HeyVedu", "version": version],
                "capabilities": ["experimentalApi": true],
            ])
        }
        try process.write(json: ["method": "initialized"])
        logger.debug("codex app-server started")
        return server
    }

    private func end(_ server: Server) {
        server.process.terminate()
        ended(server)
    }

    /// Fails everything still waiting on a server whose process is gone.
    private func ended(_ server: Server) {
        if self.server === server { self.server = nil }
        guard !server.ended else { return }
        server.ended = true
        let error = server.process.endedBecause
            ?? AssistError.classify(server.process.stderrText.isEmpty ? "Codex stopped" : server.process.stderrText)
        server.pending.values.forEach { $0.resume(throwing: error) }
        server.turnWaiters.values.forEach { $0.resume(throwing: error) }
        server.pending = [:]
        server.turnWaiters = [:]
    }

    // MARK: - JSON-RPC

    private func request(_ server: Server, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard !server.ended else { throw server.process.endedBecause ?? AssistError.unavailable("Codex stopped") }
        server.nextID += 1
        let id = server.nextID
        try server.process.write(json: ["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { server.pending[id] = $0 }.object
    }

    private func handle(_ line: Data, on server: Server) {
        guard let message = ClaudeCLIProvider.object(line) else { return }
        let method = message["method"] as? String
        if let id = message["id"] {
            if let method {
                // The server asks us something (an approval, user input): always say no.
                let reply: [String: Any] = method.localizedCaseInsensitiveContains("approval")
                    ? ["id": id, "result": ["decision": "decline"]]
                    : ["id": id, "error": ["code": -32601, "message": "HeyVedu doesn't support \(method)"]]
                try? server.process.write(json: reply)
            } else if let id = id as? Int, let continuation = server.pending.removeValue(forKey: id) {
                if let error = message["error"] as? [String: Any] {
                    continuation.resume(throwing: AssistError.classify(error["message"] as? String ?? "Codex error"))
                } else {
                    continuation.resume(returning: RPCResult(object: message["result"] as? [String: Any] ?? [:]))
                }
            }
            return
        }
        guard let method, let params = message["params"] as? [String: Any],
              let threadID = params["threadId"] as? String, var turn = server.turns[threadID] else { return }
        turn.apply(method: method, params: params)
        server.turns[threadID] = turn
        if turn.finished, let waiter = server.turnWaiters.removeValue(forKey: threadID) {
            waiter.resume(returning: turn)
        }
    }

    // MARK: - Parsing (pure, unit-tested)

    nonisolated static func parseModels(_ page: [String: Any]) -> [AssistModel] {
        (page["data"] as? [[String: Any]] ?? []).flatMap { model -> [AssistModel] in
            guard let id = model["id"] as? String else { return [] }
            let efforts = (model["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String }
            let base = AssistModel(provider: .codex, id: id, resolvedID: model["model"] as? String ?? id,
                                   displayName: model["displayName"] as? String ?? id,
                                   description: model["description"] as? String ?? "",
                                   hidden: model["hidden"] as? Bool ?? false,
                                   specialty: model["modelSpecialty"] as? String,
                                   efforts: efforts)
            // A speed tier trades more usage for speed, so it's measured as its own candidate.
            let tiers = (model["serviceTiers"] as? [[String: Any]] ?? []).compactMap { tier -> AssistModel? in
                guard let tierID = tier["id"] as? String else { return nil }
                var variant = base
                variant.serviceTier = tierID
                variant.displayName += " (\(tier["name"] as? String ?? tierID))"
                variant.description += " " + (tier["description"] as? String ?? "")
                return variant
            }
            return [base] + tiers
        }
    }

    /// `client_version` of the CLI that last wrote the account's model list.
    nonisolated static func modelCacheClientVersion() -> String? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("models_cache.json")),
              let cache = ClaudeCLIProvider.object(data) else { return nil }
        return cache["client_version"] as? String
    }

    nonisolated static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let parts = { (version: String) in version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let (left, right) = (parts(a), parts(b))
        for index in 0..<max(left.count, right.count) {
            let (l, r) = (index < left.count ? left[index] : 0, index < right.count ? right[index] : 0)
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// What one Codex turn produced, built from the server's notifications.
nonisolated struct CodexTurn {
    var text: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var finished = false
    var failure: AssistError?

    mutating func apply(method: String, params: [String: Any]) {
        switch method {
        case "item/completed":
            if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage" {
                text = item["text"] as? String
            }
        case "thread/tokenUsage/updated":
            let last = (params["tokenUsage"] as? [String: Any])?["last"] as? [String: Any]
            inputTokens = last?["inputTokens"] as? Int ?? inputTokens
            outputTokens = last?["outputTokens"] as? Int ?? outputTokens
        case "turn/completed":
            finished = true
            let turn = params["turn"] as? [String: Any]
            switch turn?["status"] as? String {
            case "failed": failure = Self.classify(turn?["error"] as? [String: Any])
            case "interrupted": failure = .cancelled
            default: break
            }
        default:
            break
        }
    }

    /// Codex's structured error code first, then the message text (which may itself be the
    /// API's JSON error).
    static func classify(_ error: [String: Any]?) -> AssistError {
        var message = error?["message"] as? String ?? "Codex turn failed"
        if let inner = ClaudeCLIProvider.object(Data(message.utf8)),
           let text = (inner["error"] as? [String: Any])?["message"] as? String {
            message = text
        }
        switch error?["codexErrorInfo"] {
        case let code as String:
            switch code {
            case "usageLimitExceeded", "rateLimitExceeded", "serverOverloaded", "sessionBudgetExceeded",
                 "flexUnavailable", "internalServerError":
                return .capacity(message)
            case "unauthorized": return .unavailable(message)
            default: return AssistError.classify(message)
            }
        case is [String: Any]:
            return .capacity(message)  // connection failures
        default:
            return AssistError.classify(message)
        }
    }
}
