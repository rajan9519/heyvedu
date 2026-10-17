import Foundation

/// One kind of AI Assist job. Pure description: no process or network code.
///
/// `AssistRouter` encodes `Input` as the user message, asks a provider for JSON matching
/// `outputSchema`, decodes it into `Output`, and runs `validate` before any feature sees it.
protocol AssistTask {
    associatedtype Input: Encodable
    associatedtype Output: Decodable

    /// Stable key for route settings and saved model picks, e.g. "dictionary.learn".
    static var id: String { get }
    /// Bump when the prompt or schema changes; saved picks and suggestions record it.
    static var promptVersion: Int { get }
    static var systemPrompt: String { get }
    /// JSON Schema the CLI enforces on the reply.
    static var outputSchema: [String: Any] { get }
    static var timeout: Duration { get }
    /// What leaves the Mac, shown in settings.
    static var dataSent: AssistDataClass { get }
    /// One line describing the job to the model ranker (§3.3 of AI-ASSIST-PLAN).
    static var rankingHint: String { get }
    /// A few fixed cases the model picker measures candidates on. Canned text only.
    static var probes: [AssistProbe<Self>] { get }

    /// Rejects or repairs model output before any feature sees it. Nil rejects the reply.
    static func validate(_ output: Output, for input: Input) -> Output?

    /// The user message for `input`. JSON by default.
    static func userMessage(for input: Input) throws -> String
}

/// One measurement case: an input and whether a (validated) answer is right.
struct AssistProbe<Task: AssistTask> {
    var input: Task.Input
    var passes: (Task.Output) -> Bool
}

extension AssistTask {
    static var schemaData: Data {
        (try? JSONSerialization.data(withJSONObject: outputSchema, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Default: the input as JSON.
    static func userMessage(for input: Input) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(input), as: UTF8.self)
    }
}

nonisolated enum AssistDataClass: Sendable {
    case editedSentences
    case transcripts
    case modelList

    var summary: String {
        switch self {
        case .editedSentences: "The sentence you edited, before and after"
        case .transcripts: "Each dictation's transcript"
        case .modelList: "The names of the models your CLI offers"
        }
    }
}

nonisolated enum AssistProviderID: String, Codable, CaseIterable, Sendable {
    case apple, claude, codex, ollama

    var title: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .ollama: "Ollama"
        }
    }
}

nonisolated enum AssistAvailability: Equatable, Sendable {
    case available(version: String?)
    /// Usable, but older than the model list the account was given (Codex).
    case outdated(version: String?, message: String)
    case notInstalled
    case signedOut(String)
    case failed(String)

    var isUsable: Bool {
        switch self {
        case .available, .outdated: true
        default: false
        }
    }

    var version: String? {
        switch self {
        case .available(let version), .outdated(let version, _): version
        default: nil
        }
    }
}

/// A model as its CLI reports it. Nothing about models is written in the app.
nonisolated struct AssistModel: Codable, Hashable, Sendable {
    var provider: AssistProviderID
    /// The name to pass back to the CLI (`--model`, `thread/start.model`).
    var id: String
    /// The concrete model `id` resolves to, for merging aliases ("default" and "opus").
    var resolvedID: String
    var displayName: String
    var description: String
    var hidden = false
    var specialty: String?
    /// Lowest first, as the CLI lists them.
    var efforts: [String] = []
    /// A paid speed tier (Codex "fast"), measured as its own candidate.
    var serviceTier: String?

    var route: AssistRoute {
        AssistRoute(provider: provider, model: id, effort: efforts.first, serviceTier: serviceTier)
    }
}

/// Where one request goes. A nil model or effort means the CLI's own default.
nonisolated struct AssistRoute: Codable, Hashable, Sendable {
    var provider: AssistProviderID
    var model: String?
    var effort: String?
    var serviceTier: String?

    var key: String {
        "\(provider.rawValue):\(model ?? "default")" + (serviceTier.map { "@\($0)" } ?? "")
    }
}

/// Everything a provider needs for one request. Only `user` carries the user's text.
nonisolated struct AssistCall: Sendable {
    var system: String
    var user: String
    var schema: Data
    var timeout: Duration
}

nonisolated struct AssistRawResult: Sendable {
    var json: Data
    var latency: Duration
    var inputTokens: Int?
    var outputTokens: Int?
    /// What the call would cost through the API; Claude reports it, Codex doesn't.
    var costUSD: Double?
}

/// The router uses this to decide what happens next.
nonisolated enum AssistError: Error, Equatable, Sendable {
    /// Not installed / not signed in → next provider, no bench.
    case unavailable(String)
    /// Quota, rate limit, overloaded → bench, then next provider.
    case capacity(String)
    /// The account doesn't offer this model → remember it, try the next model.
    case modelRejected(String)
    case timeout
    case cancelled
    /// Didn't decode or validate → no retry, the feature falls back.
    case badOutput(String)

    /// Sorts a CLI's error text. Used by both CLI providers, which add their own structured
    /// signals (HTTP status, Codex's error codes) first.
    static func classify(_ message: String) -> AssistError {
        let text = message.lowercased()
        let has = { (needles: [String]) in needles.contains { text.contains($0) } }
        if has(["not logged in", "please log in", "please run /login", "login required", "unauthorized",
                "authentication", "invalid api key", "oauth token"]) {
            return .unavailable(message)
        }
        if has(["rate limit", "rate_limit", "usage limit", "quota", "overloaded", "too many requests",
                "capacity", "hit your limit", "429", "529"]) {
            return .capacity(message)
        }
        if has(["model"]) && has(["not supported", "not found", "not available", "does not exist",
                                  "issue with the selected model", "invalid model", "no access", "unknown model"]) {
            return .modelRejected(message)
        }
        return .capacity(message)  // unknown failures count as "can't serve now", like Hermes
    }
}

/// Paths the CLI providers run in.
nonisolated enum AssistPaths {
    /// Empty folder owned by the app, so a CLI never reads CLAUDE.md, AGENTS.md or git state
    /// from wherever HeyVedu happened to start.
    static var workingDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyVedu/Assist/Work", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var picksFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyVedu/Assist/ModelPicks.json")
    }
}
