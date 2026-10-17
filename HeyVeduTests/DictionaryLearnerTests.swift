import Foundation
import Testing
@testable import HeyVedu

@MainActor
struct DictionaryLearnerTests {
    /// Without the real spell checker, whose first load blocks the main actor and delays the
    /// timing-based hotkey tests running alongside.
    private static let heuristic: (DictionaryLearnTask.Input) -> DictionaryLearnTask.Output = { input in
        HeuristicJudge.suggestions(for: input) { ["push", "the", "fix", "to", "open", "issues", "get", "hub"].contains($0.lowercased()) }
    }

    private static let github = DictionaryLearnTask.Edit(pasted: "Push the fix to get hub.", edited: "Push the fix to GitHub.")

    private func dictionary() -> PersonalDictionary {
        PersonalDictionary(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("dict-\(UUID()).json"))
    }

    private func assist(enabled: Bool, reply: String? = nil) -> AssistService {
        let settings = AssistSettings(defaults: UserDefaults(suiteName: "DictionaryLearnerTests.\(UUID())")!)
        settings.isEnabled = enabled
        settings.engine = .cli
        let claude = FakeAssistProvider(.claude)
        if let reply { claude.replies["default"] = [.success(reply)] }
        return AssistService(router: AssistRouter(providers: [claude], settings: settings, picks: AssistPickStore(fileURL: nil)),
                             settings: settings)
    }

    @Test func aiSuggestionsAreValidatedAndStored() async {
        let reply = #"{"suggestions":[{"heard":"hub","term":"GitHub","kind":"brand","confidence":0.97}]}"#
        let learner = DictionaryLearner(dictionary: dictionary(), assist: assist(enabled: true, reply: reply),
                                        store: SuggestionStore(fileURL: nil), heuristic: Self.heuristic)
        var offered: [String] = []
        learner.onReady = { offered.append($0.term) }
        learner.enqueue([Self.github])
        learner.flush()
        await learner.waitForJudging()
        #expect(learner.store.ready.map(\.heard) == ["get hub"])
        #expect(learner.store.suggestions.first?.source == "claude:default v\(DictionaryLearnTask.promptVersion)")
        #expect(offered == ["GitHub"])
    }

    @Test func heuristicJudgesWhenAIAssistIsOffAndNeedsTwoSightings() async {
        let learner = DictionaryLearner(dictionary: dictionary(), assist: assist(enabled: false),
                                        store: SuggestionStore(fileURL: nil), heuristic: Self.heuristic)
        learner.enqueue([Self.github])
        learner.flush()
        await learner.waitForJudging()
        #expect(learner.store.suggestions.map(\.source) == ["heuristic"])
        #expect(learner.store.ready.isEmpty)
        learner.enqueue([.init(pasted: "Open get hub issues.", edited: "Open GitHub issues.")])
        learner.flush()
        await learner.waitForJudging()
        #expect(learner.store.ready.map(\.term) == ["GitHub"])
    }

    @Test func failedProvidersFallBackToTheHeuristic() async {
        let learner = DictionaryLearner(dictionary: dictionary(), assist: assist(enabled: true),
                                        store: SuggestionStore(fileURL: nil), heuristic: Self.heuristic)
        learner.enqueue([Self.github])
        learner.flush()
        await learner.waitForJudging()
        #expect(learner.store.suggestions.map(\.source) == ["heuristic"])
    }

    @Test func acceptingAddsTheTermWithWhatWasHeard() async {
        let dictionary = dictionary()
        let store = SuggestionStore(fileURL: nil)
        store.record([.init(heard: "get hub", term: "GitHub", kind: .brand, confidence: 0.97)], source: "t", dictionary: [])
        let learner = DictionaryLearner(dictionary: dictionary, assist: assist(enabled: false), store: store,
                                        heuristic: Self.heuristic)
        learner.accept(store.ready[0])
        #expect(dictionary.entries.map(\.term) == ["GitHub"])
        #expect(dictionary.entries.first?.alternatives == ["get hub"])
        #expect(store.suggestions.isEmpty)
    }
}

struct SuggestionStoreTests {
    private let github = DictionaryLearnTask.Suggestion(heard: "get hub", term: "GitHub", kind: .brand, confidence: 0.85)

    @Test func lowConfidenceWaitsForASecondSighting() {
        let store = SuggestionStore(fileURL: nil)
        #expect(store.record([github], source: "heuristic", dictionary: []).isEmpty)
        #expect(store.record([github], source: "heuristic", dictionary: []).map(\.term) == ["GitHub"])
        #expect(store.suggestions.first?.count == 2)
    }

    @Test func neverAndKnownTermsAreNotSuggestedAgain() {
        let store = SuggestionStore(fileURL: nil)
        store.record([github, github], source: "t", dictionary: [])
        store.neverSuggest(store.suggestions[0].id)
        #expect(store.record([github], source: "t", dictionary: []).isEmpty)
        #expect(store.ready.isEmpty)
        let other = SuggestionStore(fileURL: nil)
        #expect(other.record([github, github], source: "t", dictionary: [.init(term: "GitHub")]).isEmpty)
    }

    @Test func snoozedStaysListedButIsNotOfferedAgain() {
        let store = SuggestionStore(fileURL: nil)
        store.record([github, github], source: "t", dictionary: [])
        store.snooze(store.suggestions[0].id)
        #expect(store.ready.count == 1)
        #expect(store.record([github], source: "t", dictionary: []).isEmpty)
    }

    @Test func savesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("suggestions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        SuggestionStore(fileURL: url).record([github], source: "heuristic", dictionary: [])
        let loaded = SuggestionStore(fileURL: url)
        #expect(loaded.suggestions.map(\.term) == ["GitHub"])
        let data = try String(contentsOf: url, encoding: .utf8)
        #expect(!data.contains("Push"))  // pairs only, never sentences
    }
}

@MainActor
struct HeuristicJudgeTests {
    private let known: @MainActor @Sendable (String) -> Bool = { ["the", "fix", "to", "get", "hub", "push", "cash", "cache", "go", "went", "linear"].contains($0.lowercased()) }

    private func terms(_ pasted: String, _ edited: String) -> [String] {
        HeuristicJudge.suggestions(for: .init(edits: [.init(pasted: pasted, edited: edited)]), isKnownWord: known)
            .suggestions.map { "\($0.heard)→\($0.term)" }
    }

    @Test func suggestsUnusualWordsThatSoundAlike() {
        #expect(terms("Push the fix to get hub", "Push the fix to GitHub") == ["get hub→GitHub"])
        #expect(terms("Deploy on cuber netties", "Deploy on Kubernetes") == ["cuber netties→Kubernetes"])
        #expect(terms("Fix it in see eye", "Fix it in CI") == ["see eye→CI"])
    }

    @Test func ignoresOrdinaryWords() {
        #expect(terms("Restart the cash", "Restart the cache").isEmpty)
        #expect(terms("Move it to lynn ear", "Move it to Linear").isEmpty)
        #expect(terms("We go now", "We went now").isEmpty)
    }

    @Test func ignoresUnrelatedNames() {
        #expect(terms("call me tomorrow", "call me Ravi").isEmpty)
    }
}
