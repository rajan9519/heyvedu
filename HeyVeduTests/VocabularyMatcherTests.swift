import Foundation
import Testing
@testable import HeyVedu

struct VocabularyMatcherTests {
    private func matcher(_ terms: [String], alternatives: [String: [String]] = [:]) -> VocabularyMatcher {
        VocabularyMatcher(entries: terms.map { .init(term: $0, alternatives: alternatives[$0] ?? []) })
    }

    private let names = ["Kubernetes", "Priya", "Yevgeny", "Hadassah", "PostgreSQL", "Figma", "Jira", "HeyVedu",
                         "Mercer", "Asana", "Zerodha", "Bartholomew"]

    // MARK: Phonetic key

    @Test func mishearingsShareAKey() {
        #expect(PhoneticKey.of("kubernetes") == PhoneticKey.of("coopernetties"))
        #expect(PhoneticKey.of("yevgeny") == PhoneticKey.of("yevghenny"))
        #expect(PhoneticKey.of("hadassah") == PhoneticKey.of("hadassa"))
        #expect(PhoneticKey.of("kubernetes") == "kprnts")
    }

    @Test func differentWordsKeepDifferentKeys() {
        #expect(PhoneticKey.of("mercy") != PhoneticKey.of("mercer"))
        #expect(PhoneticKey.of("figma") != PhoneticKey.of("finger"))
    }

    // MARK: Picking terms

    @Test func exactTermsAreSent() {
        let vocabulary = matcher(names)
        #expect(vocabulary.terms(for: "file a jira ticket") == ["Jira"])
        #expect(vocabulary.terms(for: "i love heyvedu") == ["HeyVedu"])
        #expect(vocabulary.terms(for: "Jira, Figma.") == ["Figma", "Jira"])
    }

    @Test func termsWhoseAlternativeWasSaidAreLeftToTheDictionary() {
        let vocabulary = matcher(names, alternatives: ["HeyVedu": ["hey we do"], "Kubernetes": ["k eights"]])
        #expect(vocabulary.terms(for: "i love hey we do") == [])
        #expect(vocabulary.terms(for: "deploy it to k eights and tell pria") == ["Priya"])
    }

    @Test func soundAlikesAreSent() {
        let vocabulary = matcher(names)
        #expect(vocabulary.terms(for: "can you send me the cooper netties logs") == ["Kubernetes"])
        #expect(Set(vocabulary.terms(for: "yev ghenny and ha dassa are coming for dinner")) == ["Yevgeny", "Hadassah"])
        #expect(vocabulary.terms(for: "tell pria the migration is done") == ["Priya"])
        #expect(vocabulary.terms(for: "check the post gress q l replica") == ["PostgreSQL"])
    }

    @Test func unrelatedSpeechSendsNothing() {
        let vocabulary = matcher(names)
        #expect(vocabulary.terms(for: "the judge showed no mercy at all") == [])
        #expect(vocabulary.terms(for: "lets grab lunch at noon and talk about the budget") == [])
        #expect(vocabulary.terms(for: "") == [])
        #expect(VocabularyMatcher.empty.terms(for: "kubernetes") == [])
    }

    @Test func exactHitsComeBeforeSoundAlikes() {
        let vocabulary = matcher(["Kubernetes", "Jira"])
        #expect(vocabulary.terms(for: "cooper netties and jira") == ["Jira", "Kubernetes"])
    }

    @Test func atMostTwelveTermsAreSent() {
        let terms = (1...20).map { "Term\($0)" }
        let transcript = terms.joined(separator: " ")
        let picked = matcher(terms).terms(for: transcript)
        #expect(picked.count == VocabularyMatcher.limit)
        #expect(picked == Array(terms.prefix(12)))
    }

    @Test func spellingFixesAreNeverSent() {
        let vocabulary = VocabularyMatcher(entries: [.init(term: "the", alternatives: ["teh"]), .init(term: "S3")])
        #expect(vocabulary.terms(for: "teh cat the dog") == [])
        #expect(vocabulary.isEmpty == false)
    }

    @Test func shortTermsAreSentOnlyWhenSaidExactly() {
        let vocabulary = matcher(["BP", "S3"])
        #expect(vocabulary.terms(for: "put it in s3") == ["S3"])
        #expect(vocabulary.terms(for: "be patient with the setup") == [])
    }

    @Test func termsThatWouldBreakTheHeaderAreSkipped() {
        let vocabulary = matcher(["A;B", "[x]", "Figma", "figma"])
        #expect(vocabulary.terms(for: "a b x figma") == ["Figma"])
    }

    @Test func accentsAndCaseAreIgnored() {
        let vocabulary = matcher(["Joaquín"])
        #expect(vocabulary.terms(for: "ask joaquin about it") == ["Joaquín"])
    }
}

struct VocabHeaderTests {
    // Byte-for-byte what training repo train/ctrl_header.py renders.

    @Test func vocabAloneIsItsOwnLine() {
        let context = CleanupContext(vocab: ["Priya Raman", "Kubernetes"])
        #expect(context.userMessage(for: "hi pria") == "[vocab: Priya Raman; Kubernetes]\nhi pria")
    }

    @Test func vocabFollowsFormatAndTone() {
        let context = CleanupContext(format: .email, tone: .formal, vocab: ["Priya Raman", "Kubernetes", "HeyVedu"])
        #expect(context.userMessage(for: "hi priya")
                == "[format: email] [tone: formal]\n[vocab: Priya Raman; Kubernetes; HeyVedu]\nhi priya")
        #expect(CleanupContext(format: .notes, vocab: ["Neil"]).header == "[format: notes]\n[vocab: Neil]")
    }

    @Test func summaryCountsTermsWithoutNamingThem() {
        #expect(CleanupContext(format: .email, vocab: ["Priya", "Olga"]).summary == "email, 2 terms")
    }
}
