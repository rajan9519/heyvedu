import Foundation
import Testing
@testable import HeyVedu

struct DictionaryLearnTaskTests {
    private typealias Learn = DictionaryLearnTask

    private func validate(_ pasted: String, _ edited: String, _ pairs: [(String, String)],
                          confidence: Double = 0.9, known: [String] = []) -> [String] {
        let input = Learn.Input(edits: [.init(pasted: pasted, edited: edited)], knownTerms: known)
        let output = Learn.Output(suggestions: pairs.map {
            Learn.Suggestion(heard: $0.0, term: $0.1, kind: .other, confidence: confidence)
        })
        return Learn.validate(output, for: input)?.suggestions.map { "\($0.heard)→\($0.term)" } ?? []
    }

    @Test func widensAPartialMishearing() {
        #expect(validate("Push the fix to get hub", "Push the fix to GitHub", [("hub", "GitHub")]) == ["get hub→GitHub"])
        #expect(validate("sync with Shree ya today", "sync with Shreya today", [("Shree", "Shreya")]) == ["Shree ya→Shreya"])
    }

    @Test func keepsSeveralFixesInOneSentence() {
        let pairs = validate("Ask hey vedu team to sync with Shree ya about the cube control rollout",
                             "Ask HeyVedu team to sync with Shreya about the kubectl rollout today",
                             [("hey vedu", "HeyVedu"), ("Shree ya", "Shreya"), ("cube control", "kubectl")])
        #expect(pairs == ["hey vedu→HeyVedu", "Shree ya→Shreya", "cube control→kubectl"])
    }

    @Test func dropsCaseAndPunctuationOnlyChanges() {
        #expect(validate("book it for friday", "book it for Friday", [("friday", "Friday")]).isEmpty)
        #expect(validate("page the on call", "page the on-call", [("on call", "on-call")]).isEmpty)
        #expect(validate("meet at the cafe", "meet at the café", [("cafe", "café")]).isEmpty)
    }

    @Test func dropsTermsTheEditDoesNotSupport() {
        #expect(validate("Push the fix", "Push the fix", [("fix", "Fix")]).isEmpty)
        #expect(validate("Push the fix to get hub", "Push the fix to GitHub", [("get hub", "GitLab")]).isEmpty)
        #expect(validate("Push it", "Push it to GitHub", [("it", "GitHub")]).isEmpty)  // added words
    }

    @Test func dropsUnrelatedSwapsAndLowConfidence() {
        #expect(validate("call me tomorrow", "call me Ravi", [("tomorrow", "Ravi")]).isEmpty)
        #expect(validate("Push to get hub", "Push to GitHub", [("get hub", "GitHub")], confidence: 0.5).isEmpty)
    }

    @Test func dropsKnownTerms() {
        #expect(validate("Push to get hub", "Push to GitHub", [("get hub", "GitHub")], known: ["github"]).isEmpty)
    }

    @Test func acceptsSpelledOutAcronyms() {
        #expect(validate("Fix the test in see eye", "Fix the test in CI", [("see eye", "CI")]) == ["see eye→CI"])
        #expect(validate("call the a p i", "call the API", [("a p i", "API")]) == ["a p i→API"])
    }

    @Test func mergesDuplicatesAcrossEdits() {
        let input = Learn.Input(edits: [
            .init(pasted: "Push to get hub", edited: "Push to GitHub"),
            .init(pasted: "Open get hub issues", edited: "Open GitHub issues"),
        ])
        let output = Learn.Output(suggestions: [
            .init(heard: "get hub", term: "GitHub", kind: .brand, confidence: 0.85),
            .init(heard: "get hub", term: "GitHub", kind: .brand, confidence: 0.97),
        ])
        let kept = Learn.validate(output, for: input)?.suggestions
        #expect(kept?.count == 1)
        #expect(kept?.first?.confidence == 0.97)
    }

    /// A perfect model answer for every golden case survives validation, so the validator
    /// never throws away a right answer.
    @Test func goldenSetAnswersSurviveValidation() throws {
        let golden = try AssistSelfTest.loadGolden()
        #expect(golden.count >= 40)
        for item in golden {
            let kept = validate(item.pasted, item.edited, item.expected.map { ($0.heard, $0.term) }, confidence: 0.95)
            #expect(kept == item.expected.map { "\($0.heard)→\($0.term)" }, "\(item.pasted)")
        }
    }

    @Test func changesFindsReplacedSpans() {
        let changes = Learn.Text.changes(from: Learn.Text.words("the cube control rollout"),
                                        to: Learn.Text.words("the kubectl rollout today"))
        #expect(changes == [.init(removed: ["cube", "control"], added: ["kubectl"]), .init(removed: [], added: ["today"])])
    }
}
