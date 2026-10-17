import Foundation
import Testing
@testable import HeyVedu

struct CorrectionDetectorTests {
    private func edits(_ pasted: String, _ edited: String) -> [String] {
        CorrectionDetector.edits(pasted: pasted, edited: edited).map { "\($0.pasted) => \($0.edited)" }
    }

    @Test func keepsSmallWordSwaps() {
        #expect(edits("Push the fix to get hub and ping Ravi.", "Push the fix to GitHub and ping Ravi.")
                == ["Push the fix to get hub and ping Ravi. => Push the fix to GitHub and ping Ravi."])
    }

    @Test func sendsOnlyTheSentenceAroundTheChange() {
        let result = CorrectionDetector.edits(
            pasted: "Thanks for the update. Deploy it on cuber netties tonight. See you tomorrow.",
            edited: "Thanks for the update. Deploy it on Kubernetes tonight. See you tomorrow.")
        #expect(result.map(\.pasted) == ["Deploy it on cuber netties tonight."])
        #expect(result.map(\.edited) == ["Deploy it on Kubernetes tonight."])
    }

    @Test func ignoresCaseAndPunctuationOnlyEdits() {
        #expect(edits("we need to fix the login page", "We need to fix the login page.").isEmpty)
        #expect(edits("page the on call engineer now", "page the on-call engineer now").isEmpty)
    }

    @Test func ignoresRewrites() {
        #expect(edits("I think we should go there tomorrow", "Let's head over there on Friday morning instead").isEmpty)
        #expect(edits("send it", "send it").isEmpty)
    }

    @Test func ignoresLongReplacements() {
        #expect(edits("Ask the team about the rollout plan for next quarter and the budget",
                      "Ask the whole engineering and design team about the rollout plan for next quarter and the budget").isEmpty)
    }

    @Test func snapshotFindsThePasteBeforeTheCaret() throws {
        let field = "Dear Ana, push the fix to get hub. Thanks"
        let pasted = "push the fix to get hub."
        let caret = (field as NSString).range(of: pasted).upperBound
        let snapshot = try #require(CorrectionDetector.Snapshot(text: field, caret: caret, pasted: pasted))
        #expect(snapshot.before == "Dear Ana, ")
        #expect(snapshot.after == " Thanks")
        #expect(CorrectionDetector.Snapshot(text: field, caret: 4, pasted: pasted) == nil)
    }

    @Test func editedSpanIsFoundBetweenTheAnchors() {
        let snapshot = CorrectionDetector.Snapshot(before: "Dear Ana, ", pasted: "push the fix to get hub.", after: " Thanks")
        #expect(CorrectionDetector.editedSpan(of: snapshot, in: "Dear Ana, push the fix to GitHub. Thanks") == "push the fix to GitHub.")
        #expect(CorrectionDetector.editedSpan(of: snapshot, in: "Something else entirely") == nil)
    }

    @Test func snapshotAtTheStartAndEndOfAField() throws {
        let snapshot = try #require(CorrectionDetector.Snapshot(text: "get hub", caret: 7, pasted: "get hub"))
        #expect(snapshot.before.isEmpty && snapshot.after.isEmpty)
        #expect(CorrectionDetector.editedSpan(of: snapshot, in: "GitHub") == "GitHub")
    }
}
