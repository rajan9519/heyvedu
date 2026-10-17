import Foundation
import Testing
@testable import HeyVedu

@MainActor
struct AssistModelPickerTests {
    typealias Measurement = AssistModelPicker.Measurement

    private func model(_ provider: AssistProviderID, _ id: String, resolved: String? = nil,
                       description: String = "", hidden: Bool = false, specialty: String? = nil) -> AssistModel {
        AssistModel(provider: provider, id: id, resolvedID: resolved ?? id, displayName: id,
                    description: description, hidden: hidden, specialty: specialty, efforts: ["low", "high"])
    }

    private func measurement(_ model: String, passed: Int = 4, typical: Double, rank: Int?) -> Measurement {
        Measurement(route: AssistRoute(provider: .claude, model: model), name: model, passed: passed, total: 4,
                    typical: typical, worst: typical, rank: rank)
    }

    @Test func dropsUnusableModelsAndMergesAliases() {
        let pool = AssistModelPicker.candidates([
            model(.claude, "default", resolved: "big-5"),
            model(.claude, "big", resolved: "big-5"),
            model(.claude, "small"),
            model(.codex, "secret", hidden: true),
            model(.codex, "reviewer", specialty: "autoReview"),
            model(.codex, "pricey", description: "Requires usage credits."),
        ])
        #expect(pool.map(\.id) == ["big", "small"])
    }

    @Test func mergeRankingKeepsKnownIdsOnceAndAppendsTheRest() {
        let order = AssistModelPicker.mergeRanking(["b", "made-up", "a", "b"], known: ["a", "b", "c"])
        #expect(order == ["b", "a", "c"])
    }

    @Test func keywordFallbackPrefersFastAndCheap() {
        let order = AssistModelPicker.keywordOrder([
            model(.claude, "big", description: "Most capable for your hardest tasks"),
            model(.claude, "mid", description: "Balanced for everyday work"),
            model(.claude, "small", description: "Fastest for quick answers"),
            model(.codex, "fast-tier", description: "Fast and efficient. 1.5x speed, ~2x usage"),
        ])
        #expect(order.first == "claude:small")
        #expect(order.last == "claude:big")
    }

    @Test func cheapestRankedModelWinsEvenWhenSlower() {
        // The ranker put the cheap family's newest version first; Sonnet measured faster.
        let chain = AssistModelPicker.choose([
            measurement("sonnet", typical: 1.29, rank: 4),
            measurement("haiku-4.5", typical: 2.6, rank: 2),
            measurement("haiku-5.5", typical: 2.1, rank: 0),
            measurement("luna-6", typical: 3.5, rank: 1),
        ])
        #expect(chain.map(\.name) == ["haiku-5.5", "luna-6", "haiku-4.5", "sonnet"])
    }

    @Test func failuresAreDroppedAndUnrankedGoLast() {
        let chain = AssistModelPicker.choose([
            measurement("unranked", typical: 0.5, rank: nil),
            measurement("wrong", passed: 1, typical: 0.9, rank: 0),
            measurement("ok", typical: 3.0, rank: 1),
        ])
        #expect(chain.map(\.name) == ["ok", "unranked"])
    }

    @Test func picksMadeByTheOldRuleAreRemade() {
        let old = AssistPick(taskID: "t", promptVersion: 1, measuredAt: .now, cliVersions: [:], modelListHash: "h",
                             rankedBy: "claude", chain: [], measurements: [])
        #expect(old.isStale(promptVersion: 1, versions: [:], modelListHash: "h"))
    }

    @Test func pickGoesStaleWhenItsInputsChange() {
        let pick = AssistPick(taskID: "t", promptVersion: 1, measuredAt: .now, cliVersions: ["claude": "2.1"],
                              modelListHash: "h", rankedBy: "claude", chain: [], measurements: [],
                              pickerVersion: AssistModelPicker.version)
        #expect(!pick.isStale(promptVersion: 1, versions: ["claude": "2.1"], modelListHash: "h"))
        #expect(pick.isStale(promptVersion: 2, versions: ["claude": "2.1"], modelListHash: "h"))
        #expect(pick.isStale(promptVersion: 1, versions: ["claude": "2.2"], modelListHash: "h"))
        #expect(pick.isStale(promptVersion: 1, versions: ["claude": "2.1"], modelListHash: "other"))
        #expect(pick.isStale(promptVersion: 1, versions: ["claude": "2.1"], modelListHash: "h",
                             now: .now.addingTimeInterval(8 * 24 * 3600)))
    }

    @Test func rankingValidationKeepsOnlyListedIds() {
        let input = ModelRankTask.Input(task: "x", models: [.init(id: "claude:haiku", name: "Haiku", description: "", efforts: [])])
        let output = ModelRankTask.Output(ranked: [.init(id: "claude:haiku", reason: "fast"), .init(id: "invented", reason: "?")])
        #expect(ModelRankTask.validate(output, for: input)?.ranked.map(\.id) == ["claude:haiku"])
        #expect(ModelRankTask.validate(.init(ranked: [.init(id: "invented", reason: "?")]), for: input) == nil)
    }
}

/// Parsing of recorded CLI output (claude 2.1.300, codex-cli 0.162.1).
struct AssistCLIParsingTests {
    private func object(_ json: String) -> [String: Any] {
        ClaudeCLIProvider.object(Data(json.utf8))!
    }

    @Test func claudeResultYieldsStructuredOutputAndUsage() throws {
        let line = #"{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"total_cost_usd":0.00029548,"usage":{"input_tokens":2,"cache_creation_input_tokens":959,"cache_read_input_tokens":698,"output_tokens":193},"structured_output":{"suggestions":[{"heard":"hub","term":"GitHub","kind":"brand","confidence":0.95}]}}"#
        let parsed = try ClaudeCLIProvider.parseResult(object(line))
        #expect(parsed.inputTokens == 1659)
        #expect(parsed.outputTokens == 193)
        #expect(parsed.totalCost == 0.00029548)
        let output = try JSONDecoder().decode(DictionaryLearnTask.Output.self, from: parsed.json)
        #expect(output.suggestions.first?.term == "GitHub")
    }

    @Test func claudeUnknownModelIsRejected() {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"There's an issue with the selected model (no-such-model). It may not exist or you may not have access to it.","total_cost_usd":0}"#
        #expect(throws: AssistError.modelRejected("There's an issue with the selected model (no-such-model). It may not exist or you may not have access to it.")) {
            try ClaudeCLIProvider.parseResult(object(line))
        }
    }

    @Test func claudeModelListKeepsEffortLevels() {
        let response = object(#"{"models":[{"value":"haiku","resolvedModel":"claude-haiku-5-5","displayName":"Haiku 5.5","description":"Fastest for quick answers","supportedEffortLevels":["low","medium"]},{"value":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5","description":"Fastest for quick answers"}]}"#)
        let models = ClaudeCLIProvider.parseModels(response)
        #expect(models.map(\.route.key) == ["claude:haiku", "claude:claude-haiku-4-5-20251001"])
        #expect(models[0].route.effort == "low")
        #expect(models[1].route.effort == nil)
    }

    @Test func codexModelListAddsSpeedTiersAsCandidates() {
        let page = object(#"{"data":[{"id":"gpt-6-luna","model":"gpt-6-luna","displayName":"GPT-6-Luna","description":"Fast, low-cost.","hidden":false,"modelSpecialty":null,"supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}],"serviceTiers":[{"id":"priority","name":"Fast","description":"1.5x speed, increased usage"}]}],"nextCursor":null}"#)
        let models = CodexAppServerProvider.parseModels(page)
        #expect(models.map(\.route.key) == ["codex:gpt-6-luna", "codex:gpt-6-luna@priority"])
        #expect(models[1].displayName == "GPT-6-Luna (Fast)")
    }

    @Test func codexTurnCollectsTheReplyAndUsage() {
        var turn = CodexTurn()
        turn.apply(method: "item/completed", params: object(#"{"item":{"type":"agentMessage","text":"{\"suggestions\":[]}"}}"#))
        turn.apply(method: "thread/tokenUsage/updated", params: object(#"{"tokenUsage":{"last":{"inputTokens":10655,"outputTokens":40}}}"#))
        #expect(!turn.finished)
        turn.apply(method: "turn/completed", params: object(#"{"turn":{"status":"completed","error":null}}"#))
        #expect(turn.finished)
        #expect(turn.failure == nil)
        #expect(turn.text == #"{"suggestions":[]}"#)
        #expect(turn.inputTokens == 10655)
    }

    @Test func codexFailedTurnsAreSorted() {
        var rejected = CodexTurn()
        rejected.apply(method: "turn/completed", params: object(#"{"turn":{"status":"failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-6-luna' model is not supported when using Codex with a ChatGPT account.\"}}","codexErrorInfo":"other"}}}"#))
        #expect(rejected.failure == .modelRejected("The 'gpt-6-luna' model is not supported when using Codex with a ChatGPT account."))

        var limited = CodexTurn()
        limited.apply(method: "turn/completed", params: object(#"{"turn":{"status":"failed","error":{"message":"You've hit your usage limit.","codexErrorInfo":"usageLimitExceeded"}}}"#))
        #expect(limited.failure == .capacity("You've hit your usage limit."))
    }

    @Test func versionsCompareNumerically() {
        #expect(CodexAppServerProvider.compareVersions("0.153.4", "0.162.0") == .orderedAscending)
        #expect(CodexAppServerProvider.compareVersions("0.162.1", "0.162.0") == .orderedDescending)
        #expect(CodexAppServerProvider.compareVersions("1.0", "1.0.0") == .orderedSame)
    }
}

@MainActor
struct CleanupRoutingTests {
    private func settings() -> AssistSettings {
        let settings = AssistSettings(defaults: UserDefaults(suiteName: "CleanupRoutingTests.\(UUID())")!)
        settings.engine = .apple  // AI Assist on Apple Intelligence must not stop CLI cleanup
        return settings
    }

    @Test func cleanupUsesCLIsWithoutTheSwitchOrCap() async throws {
        let settings = settings()
        settings.dailyCap = 0
        let claude = FakeAssistProvider(.claude)
        claude.replies["default"] = [.success(#"{"text":"Send it on Monday."}"#)]
        let assist = AssistService(router: AssistRouter(providers: [FakeAssistProvider(.apple), claude], settings: settings,
                                                        picks: AssistPickStore(fileURL: nil)), settings: settings)
        #expect(try await assist.clean("send it on monday") == "Send it on Monday.")
        #expect(claude.calls.count == 1)
        #expect(settings.requestsToday() == 0)
    }

    @Test func cleanupTriesAtMostTwoModels() async {
        let settings = settings()
        let claude = FakeAssistProvider(.claude), codex = FakeAssistProvider(.codex)
        claude.replies["default"] = [.failure(.timeout)]
        claude.replies["haiku"] = [.failure(.timeout)]
        codex.replies["default"] = [.success(#"{"text":"x"}"#)]
        let picks = AssistPickStore(fileURL: nil)
        picks.save(AssistPick(taskID: CleanupTask.id, promptVersion: CleanupTask.promptVersion, measuredAt: .now,
                              cliVersions: [:], modelListHash: "", rankedBy: "t",
                              chain: [AssistRoute(provider: .claude, model: "haiku")], measurements: []))
        let assist = AssistService(router: AssistRouter(providers: [claude, codex], settings: settings, picks: picks),
                                   settings: settings)
        await #expect(throws: AssistError.timeout) { try await assist.clean("hello there") }
        #expect(codex.calls.isEmpty)
    }

    @Test func unmeasuredTaskBorrowsAnotherTasksChain() {
        let picks = AssistPickStore(fileURL: nil)
        picks.save(AssistPick(taskID: DictionaryLearnTask.id, promptVersion: 1, measuredAt: .now, cliVersions: [:],
                              modelListHash: "", rankedBy: "t", chain: [AssistRoute(provider: .claude, model: "haiku")],
                              measurements: []))
        let router = AssistRouter(providers: [FakeAssistProvider(.claude)], settings: settings(), picks: picks)
        #expect(router.routes(for: CleanupTask.self, engine: .cli).map(\.key) == ["claude:haiku", "claude:default"])
    }

    @Test func cleanupMessageIsTheTranscriptInTags() throws {
        #expect(try CleanupTask.userMessage(for: .init(transcript: "um hi")) == "<transcript>um hi</transcript>")
    }

    @Test func cleanupMessageCarriesTheDictionaryAndSnippets() throws {
        let vocabulary = CleanupTask.Vocabulary(
            entries: [.init(term: "HeyVedu", alternatives: ["hey vedu"]), .init(term: "  ")],
            snippets: [.init(trigger: "my link", expansion: "https://cal.com/a\n"), .init(trigger: "x", expansion: " ")])
        let message = try CleanupTask.userMessage(for: .init(transcript: "hi", vocabulary: vocabulary))
        #expect(message == """
            <dictionary>[{"alsoHeardAs":["hey vedu"],"term":"HeyVedu"}]</dictionary>
            <snippets>[{"insert":"https://cal.com/a","say":"my link"}]</snippets>
            <transcript>hi</transcript>
            """)
    }
}
