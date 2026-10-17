import Foundation
import Testing
@testable import HeyVedu

/// An AI Assist provider with scripted replies, so routing, benching and validation can be
/// tested without a CLI.
final class FakeAssistProvider: AssistProvider {
    let id: AssistProviderID
    let isLocal = false
    var available: AssistAvailability = .available(version: "1.0")
    var listedModels: [AssistModel] = []
    /// Replies per model ("default" for nil), consumed in order; the last one repeats.
    var replies: [String: [Result<String, AssistError>]] = [:]
    private(set) var calls: [AssistRoute] = []

    init(_ id: AssistProviderID) {
        self.id = id
    }

    func availability() async -> AssistAvailability { available }

    func models() async throws -> [AssistModel] { listedModels }

    func run(_ call: AssistCall, route: AssistRoute) async throws -> AssistRawResult {
        calls.append(route)
        let key = route.model ?? "default"
        guard var queue = replies[key], let next = queue.first else { throw AssistError.unavailable("no reply") }
        if queue.count > 1 { queue.removeFirst(); replies[key] = queue }
        let json = try next.get()
        return AssistRawResult(json: Data(json.utf8), latency: .milliseconds(100), inputTokens: 10, outputTokens: 5, costUSD: nil)
    }
}

@MainActor
struct AssistRouterTests {
    static let github = #"{"suggestions":[{"heard":"get hub","term":"GitHub","kind":"brand","confidence":0.95}]}"#
    static let input = DictionaryLearnTask.Input(edits: [.init(pasted: "Push the fix to get hub", edited: "Push the fix to GitHub")])

    private func settings(enabled: Bool = true, cap: Int = 50) -> AssistSettings {
        let defaults = UserDefaults(suiteName: "AssistRouterTests.\(UUID().uuidString)")!
        let settings = AssistSettings(defaults: defaults)
        settings.isEnabled = enabled
        settings.dailyCap = cap
        settings.engine = .cli
        return settings
    }

    private func router(_ providers: [FakeAssistProvider], chain: [AssistRoute] = [],
                        settings: AssistSettings? = nil) -> AssistRouter {
        let picks = AssistPickStore(fileURL: nil)
        if !chain.isEmpty {
            picks.save(AssistPick(taskID: DictionaryLearnTask.id, promptVersion: DictionaryLearnTask.promptVersion,
                                  measuredAt: .now, cliVersions: [:], modelListHash: "", rankedBy: "test",
                                  chain: chain, measurements: []))
        }
        return AssistRouter(providers: providers, settings: settings ?? self.settings(), picks: picks)
    }

    @Test func offByDefault() async {
        let claude = FakeAssistProvider(.claude)
        let router = router([claude], settings: AssistSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        await #expect(throws: AssistError.unavailable("AI Assist is off")) {
            try await router.run(DictionaryLearnTask.self, Self.input)
        }
        #expect(claude.calls.isEmpty)
    }

    @Test func usesThePickedChainFirst() async throws {
        let claude = FakeAssistProvider(.claude)
        claude.replies["haiku"] = [.success(Self.github)]
        let router = router([claude], chain: [AssistRoute(provider: .claude, model: "haiku", effort: "low")])
        let outcome = try await router.run(DictionaryLearnTask.self, Self.input)
        #expect(outcome.route.model == "haiku")
        #expect(outcome.output.suggestions.map(\.term) == ["GitHub"])
    }

    @Test func capacityBenchesTheRouteAndFallsBack() async throws {
        let claude = FakeAssistProvider(.claude), codex = FakeAssistProvider(.codex)
        claude.replies["haiku"] = [.failure(.capacity("rate limited"))]
        codex.replies["luna"] = [.success(Self.github)]
        let haiku = AssistRoute(provider: .claude, model: "haiku")
        let router = router([claude, codex], chain: [haiku, AssistRoute(provider: .codex, model: "luna")])
        _ = try await router.run(DictionaryLearnTask.self, Self.input)
        #expect(router.isBenched(haiku))
        _ = try await router.run(DictionaryLearnTask.self, Self.input)
        #expect(claude.calls.count == 1)  // benched, not retried
        #expect(codex.calls.count == 2)
    }

    @Test func unavailableSkipsTheProvidersOtherRoutes() async throws {
        let claude = FakeAssistProvider(.claude), codex = FakeAssistProvider(.codex)
        claude.replies["haiku"] = [.failure(.unavailable("signed out"))]
        claude.replies["sonnet"] = [.success(Self.github)]
        codex.replies["luna"] = [.success(Self.github)]
        let router = router([claude, codex], chain: [
            AssistRoute(provider: .claude, model: "haiku"), AssistRoute(provider: .claude, model: "sonnet"),
            AssistRoute(provider: .codex, model: "luna"),
        ])
        let outcome = try await router.run(DictionaryLearnTask.self, Self.input)
        #expect(outcome.route.provider == .codex)
        #expect(claude.calls.map(\.model) == ["haiku"])
    }

    @Test func rejectedModelIsRememberedAndTheNextModelTried() async throws {
        let codex = FakeAssistProvider(.codex)
        codex.replies["new"] = [.failure(.modelRejected("not supported"))]
        codex.replies["old"] = [.success(Self.github)]
        let new = AssistRoute(provider: .codex, model: "new")
        let router = router([codex], chain: [new, AssistRoute(provider: .codex, model: "old")])
        let outcome = try await router.run(DictionaryLearnTask.self, Self.input)
        #expect(outcome.route.model == "old")
        #expect(router.isBenched(new))
    }

    @Test func badOutputStopsWithoutFallback() async {
        let claude = FakeAssistProvider(.claude), codex = FakeAssistProvider(.codex)
        claude.replies["haiku"] = [.success(#"{"nope":true}"#)]
        codex.replies["luna"] = [.success(Self.github)]
        let router = router([claude, codex], chain: [
            AssistRoute(provider: .claude, model: "haiku"), AssistRoute(provider: .codex, model: "luna"),
        ])
        await #expect(throws: AssistError.badOutput("The reply didn't match the schema")) {
            try await router.run(DictionaryLearnTask.self, Self.input)
        }
        #expect(codex.calls.isEmpty)
    }

    @Test func validationRunsBeforeTheFeatureSeesTheReply() async throws {
        let claude = FakeAssistProvider(.claude)
        claude.replies["haiku"] = [.success(#"{"suggestions":[{"heard":"hub","term":"GitHub","kind":"brand","confidence":0.9},{"heard":"fix","term":"Banana","kind":"other","confidence":0.99}]}"#)]
        let router = router([claude], chain: [AssistRoute(provider: .claude, model: "haiku")])
        let outcome = try await router.run(DictionaryLearnTask.self, Self.input)
        #expect(outcome.output.suggestions.map(\.heard) == ["get hub"])
    }

    @Test func threeTimeoutsBenchUntilTheNextMeasurement() async throws {
        let claude = FakeAssistProvider(.claude), codex = FakeAssistProvider(.codex)
        claude.replies["haiku"] = [.failure(.timeout)]
        codex.replies["luna"] = [.success(Self.github)]
        let haiku = AssistRoute(provider: .claude, model: "haiku")
        let router = router([claude, codex], chain: [haiku, AssistRoute(provider: .codex, model: "luna")])
        for _ in 0..<3 { _ = try await router.run(DictionaryLearnTask.self, Self.input) }
        #expect(router.isBenched(haiku))
        #expect(router.picks.pick(for: DictionaryLearnTask.id)?.needsRemeasure == true)
        router.picksChanged()
        #expect(!router.isBenched(haiku))
    }

    @Test func dailyCapStopsRequests() async throws {
        let claude = FakeAssistProvider(.claude)
        claude.replies["haiku"] = [.success(Self.github)]
        let router = router([claude], chain: [AssistRoute(provider: .claude, model: "haiku")], settings: settings(cap: 1))
        _ = try await router.run(DictionaryLearnTask.self, Self.input)
        await #expect(throws: AssistError.capacity("Today's AI Assist limit is reached")) {
            try await router.run(DictionaryLearnTask.self, Self.input)
        }
    }

    @Test func appleIntelligenceNeverFallsBackToACLI() {
        let settings = settings()
        settings.engine = .apple
        let router = router([FakeAssistProvider(.apple), FakeAssistProvider(.claude)],
                            chain: [AssistRoute(provider: .claude, model: "haiku")], settings: settings)
        #expect(router.routes(for: DictionaryLearnTask.self).map(\.key) == ["apple:default"])
    }

    @Test func pinComesFirstAndCLIDefaultsLast() {
        let settings = settings()
        settings.setPinnedRoute(AssistRoute(provider: .codex, model: "pinned"), for: DictionaryLearnTask.id)
        let router = router([FakeAssistProvider(.claude), FakeAssistProvider(.codex)],
                            chain: [AssistRoute(provider: .claude, model: "haiku")], settings: settings)
        #expect(router.routes(for: DictionaryLearnTask.self).map(\.key)
                == ["codex:pinned", "claude:haiku", "claude:default", "codex:default"])
    }
}
