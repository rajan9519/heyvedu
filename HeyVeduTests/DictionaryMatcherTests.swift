import Foundation
import Testing
@testable import HeyVedu

struct DictionaryMatcherTests {
    private func matcher(_ entries: [(String, [String])]) -> DictionaryMatcher {
        DictionaryMatcher(entries: entries.map { PersonalDictionary.Entry(term: $0.0, alternatives: $0.1) })
    }

    @Test func rewritesAlternativesToTheTerm() {
        let m = matcher([("HeyVedu", ["hey vedu", "hay vedu"])])
        #expect(m.apply(to: "I use hey vedu daily") == "I use HeyVedu daily")
        #expect(m.apply(to: "Hay Vedu is great") == "HeyVedu is great")
    }

    @Test func fixesTheTermsOwnCasing() {
        let m = matcher([("HeyVedu", [])])
        #expect(m.apply(to: "try heyvedu now") == "try HeyVedu now")
    }

    @Test func toleratesPunctuationBetweenWords() {
        let m = matcher([("HeyVedu", ["hey vedu"])])
        #expect(m.apply(to: "Hey, vedu.") == "HeyVedu.")
        #expect(m.apply(to: "say hey. Vedu please") == "say HeyVedu please")
    }

    @Test func ignoresMatchesInsideLongerWords() {
        let m = matcher([("the", ["teh"])])
        #expect(m.apply(to: "tehran and teh cat") == "tehran and the cat")
        #expect(m.apply(to: "teh2") == "teh2")
    }

    @Test func lowercaseTermKeepsLeadingCapital() {
        let m = matcher([("the", ["teh"])])
        #expect(m.apply(to: "Teh cat") == "The cat")
    }

    @Test func mixedCaseTermIsWrittenExactly() {
        let m = matcher([("iPhone", ["eye phone"])])
        #expect(m.apply(to: "Eye phone sales") == "iPhone sales")
    }

    @Test func longestPhraseWins() {
        let m = matcher([("HeyVedu", ["hey vedu"]), ("HeyVedu Pro", ["hey vedu pro"])])
        #expect(m.apply(to: "buy hey vedu pro today") == "buy HeyVedu Pro today")
        #expect(m.apply(to: "buy hey vedu today") == "buy HeyVedu today")
    }

    @Test func firstEntryClaimingAPhraseWins() {
        let m = matcher([("Alpha", ["shared"]), ("Beta", ["Shared"])])
        #expect(m.apply(to: "shared") == "Alpha")
    }

    @Test func emptyAndBlankEntriesAreIgnored() {
        let m = matcher([("", ["x"]), ("Term", ["", "  ", ","])])
        #expect(m.apply(to: "x Term") == "x Term")
        #expect(DictionaryMatcher.empty.isEmpty)
        #expect(DictionaryMatcher.empty.apply(to: "unchanged") == "unchanged")
    }

    @Test func innerPunctuationInPhrasesIsKept() {
        let m = matcher([("Node.js", ["node js"]), ("C++", [])])
        #expect(m.apply(to: "I write node js and c++") == "I write Node.js and C++")
    }

    @Test func normalizedIgnoresCaseAndSurroundingPunctuation() {
        #expect(DictionaryMatcher.normalized("Hey,  Vedu!") == "hey vedu")
        #expect(DictionaryMatcher.normalized(" , ") == "")
    }
}

struct PersonalDictionaryTests {
    @Test func savesAndReloadsEntries() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "HeyVeduTests-\(UUID().uuidString)/Dictionary.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let dictionary = PersonalDictionary(fileURL: url)
        #expect(dictionary.entries.isEmpty)
        dictionary.entries = [.init(term: "HeyVedu", alternatives: ["hey vedu"])]
        #expect(dictionary.matcher.apply(to: "hey vedu") == "HeyVedu")

        let reloaded = PersonalDictionary(fileURL: url)
        #expect(reloaded.entries == dictionary.entries)
        #expect(reloaded.matcher.apply(to: "hey vedu") == "HeyVedu")
    }

    @Test func unreadableFileLoadsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "HeyVeduTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(PersonalDictionary(fileURL: url).entries.isEmpty)
    }
}
