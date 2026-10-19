import Foundation
import Testing
@testable import HeyVedu

struct SnippetExpanderTests {
    private func expander(_ pairs: [(String, String)]) -> SnippetExpander {
        SnippetExpander(snippets: pairs.map { SnippetLibrary.Snippet(trigger: $0.0, expansion: $0.1) })
    }

    private let calendly = ("my calendly link", "https://calendly.com/rajan/30min")
    private let signature = ("my signature", "Best,\nRajan\nHeyVedu")

    @Test func expandsATriggerMidSentence() {
        let e = expander([calendly])
        #expect(e.expand("Book a slot at my calendly link today.", dictionary: .empty)
            == "Book a slot at https://calendly.com/rajan/30min today.")
    }

    @Test func wholeDictationTriggerBecomesExactlyTheExpansion() {
        let e = expander([signature])
        #expect(e.expand("My signature.", dictionary: .empty) == "Best,\nRajan\nHeyVedu")
        #expect(e.expand("  my, signature!  ", dictionary: .empty) == "Best,\nRajan\nHeyVedu")
    }

    @Test func matchesAnyCaseAndPunctuationBetweenWords() {
        let e = expander([calendly])
        #expect(e.expand("Here: My Calendly, link.", dictionary: .empty)
            == "Here: https://calendly.com/rajan/30min.")
    }

    @Test func rejectsPartialWords() {
        let e = expander([("addr", "1 Main St")])
        #expect(e.expand("my address", dictionary: .empty) == "my address")
    }

    @Test func longestTriggerWins() {
        let e = expander([("my address", "HOME"), ("my address at work", "WORK")])
        #expect(e.expand("Send it to my address at work please", dictionary: .empty) == "Send it to WORK please")
        #expect(e.expand("Send it to my address please", dictionary: .empty) == "Send it to HOME please")
    }

    @Test func expandsSeveralTriggers() {
        let e = expander([calendly, signature])
        #expect(e.expand("Link: my calendly link. my signature", dictionary: .empty)
            == "Link: https://calendly.com/rajan/30min. Best,\nRajan\nHeyVedu")
    }

    @Test func dictionaryAppliesOutsideButNotInsideExpansions() {
        let dictionary = DictionaryMatcher(entries: [.init(term: "HeyVedu", alternatives: ["rajan"])])
        let e = expander([signature])
        #expect(e.expand("rajan wrote my signature", dictionary: dictionary)
            == "HeyVedu wrote Best,\nRajan\nHeyVedu")
    }

    @Test func emptySnippetsOnlyApplyTheDictionary() {
        let dictionary = DictionaryMatcher(entries: [.init(term: "the", alternatives: ["teh"])])
        #expect(SnippetExpander.empty.expand("teh end", dictionary: dictionary) == "the end")
    }

    @Test func blankTriggersAndExpansionsAreIgnored() {
        let e = expander([("", "x"), ("  ", "y"), ("blank", "   \n ")])
        #expect(e.matcher.isEmpty)
        #expect(e.expand("blank", dictionary: .empty) == "blank")
    }

    @Test func expansionEndsAreTrimmed() {
        let e = expander([("sig", "\n  Rajan  \n")])
        #expect(e.expand("sig", dictionary: .empty) == "Rajan")
    }

}

struct SnippetLibraryTests {
    @Test func savesAndReloadsSnippets() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "HeyVeduTests-\(UUID().uuidString)/Snippets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let library = SnippetLibrary(fileURL: url)
        library.snippets = [.init(trigger: "sig", expansion: "Rajan")]
        #expect(library.expander.expand("sig", dictionary: .empty) == "Rajan")

        let reloaded = SnippetLibrary(fileURL: url)
        #expect(reloaded.snippets == library.snippets)
        #expect(reloaded.expander.expand("sig", dictionary: .empty) == "Rajan")
    }
}
