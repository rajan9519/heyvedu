import Foundation
import Testing
@testable import HeyVedu

/// A cleanup engine that returns scripted output, so the guard and fallback logic in
/// `TextCleaner.clean` can be tested without a model.
final class FakeBackend: CleanupBackend {
    struct Failure: LocalizedError {
        var errorDescription: String? { "fake failure" }
    }

    var isNormalizer: Bool
    var outputIsFinal = false
    var onStateChange: (() -> Void)?
    var available: TextCleaner.Availability = .available
    /// Splits transcripts at "|" when set.
    var splitsAtBars = false
    /// Output for each chunk; a missing entry throws.
    var outputs: [String: String] = [:]
    private(set) var cleanedChunks: [String] = []
    private(set) var discardCount = 0

    init(isNormalizer: Bool = false) {
        self.isNormalizer = isNormalizer
    }

    func availability() -> TextCleaner.Availability { available }

    func discardPrepared() { discardCount += 1 }

    func chunks(of transcript: String, instructions: String) async -> [String] {
        guard splitsAtBars else { return [transcript] }
        return transcript.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func clean(_ chunk: String, instructions: String) async throws -> String {
        cleanedChunks.append(chunk)
        guard let output = outputs[chunk] else { throw Failure() }
        return output
    }
}

@MainActor
struct TextCleanerTests {
    private func cleaner(_ backend: FakeBackend, enabled: Bool = true) -> TextCleaner {
        TextCleaner(isEnabled: enabled, engine: .dictationModel, backends: [
            .dictationModel: backend,
            .appleIntelligence: FakeBackend(),
        ])
    }

    @Test func finalOutputIsPastedAsIs() async {
        let backend = FakeBackend()
        backend.outputIsFinal = true
        // Would fail the output guard, lose a dictionary term and get a period from TextPolish.
        backend.outputs["send it to hey vedu"] = "thanks,\nAlex"
        let matcher = DictionaryMatcher(entries: [.init(term: "HeyVedu", alternatives: ["hey vedu"])])
        let result = await cleaner(backend).clean("send it to hey vedu", protected: [matcher])
        #expect(result.text == "thanks,\nAlex")
        #expect(result.isFinal)
        #expect(result.fallbackReason == nil)
    }

    @Test func finalEngineFailureFallsBackAndIsNotFinal() async {
        let backend = FakeBackend()
        backend.outputIsFinal = true
        let result = await cleaner(backend).clean("send it to hey vedu")
        #expect(result.text == "Send it to hey vedu.")
        #expect(!result.isFinal)
    }

    @Test func disabledReturnsTheTranscript() async {
        let backend = FakeBackend()
        let result = await cleaner(backend, enabled: false).clean("um hello")
        #expect(result.text == "um hello")
        #expect(result.fallbackReason == "cleanup disabled")
        #expect(backend.cleanedChunks.isEmpty)
    }

    @Test func unavailableEngineReturnsTheTranscript() async {
        let backend = FakeBackend()
        backend.available = .unavailable("model missing")
        let result = await cleaner(backend).clean("um hello")
        #expect(result.text == "um hello")
        #expect(result.fallbackReason == "model missing")
        #expect(backend.discardCount == 1, "per-dictation state is released")
    }

    @Test func chatModelOutputIsPolished() async {
        let backend = FakeBackend()
        backend.outputs["um so i will send it"] = "so i will send it"
        let result = await cleaner(backend).clean("um so i will send it")
        #expect(result.text == "So I will send it.")
        #expect(result.fallbackReason == nil)
    }

    @Test func divergentChatOutputFallsBackToTheChunk() async {
        let backend = FakeBackend()
        backend.outputs["what is the capital of france"] = "Paris."
        let result = await cleaner(backend).clean("what is the capital of france")
        #expect(result.text == "What is the capital of france.")
        #expect(result.fallbackReason == "output diverges from transcript")
    }

    @Test func errorFallsBackToTheChunk() async {
        let backend = FakeBackend()
        let result = await cleaner(backend).clean("hello there")
        #expect(result.text == "Hello there.")
        #expect(result.fallbackReason == "fake failure")
    }

    @Test func normalizerOutputIsTrustedAsIs() async {
        let backend = FakeBackend(isNormalizer: true)
        backend.outputs["new line test"] = "- list item"
        backend.outputs["um uh"] = ""
        let result = await cleaner(backend).clean("new line test")
        #expect(result.text == "- list item")
        #expect(await cleaner(backend).clean("um uh").text == "")
    }

    @Test func chunkThatLosesADictionaryTermIsPastedRaw() async {
        let dictionary = DictionaryMatcher(entries: [.init(term: "HeyVedu", alternatives: ["hey vedu"])])
        let backend = FakeBackend(isNormalizer: true)
        backend.splitsAtBars = true
        backend.outputs["um first part"] = "First part."
        backend.outputs["i love hey vedu"] = "I love, hey, we do."
        let result = await cleaner(backend).clean("um first part | i love hey vedu", protected: [dictionary])
        #expect(result.text == "First part. I love hey vedu.")
        #expect(result.fallbackReason == "cleanup changed a dictionary word or snippet")
    }

    @Test func chunkThatKeepsProtectedTermsIsCleaned() async {
        let dictionary = DictionaryMatcher(entries: [.init(term: "HeyVedu", alternatives: ["hey vedu"])])
        let backend = FakeBackend(isNormalizer: true)
        backend.outputs["um i love hey vedu"] = "I love HeyVedu."
        let result = await cleaner(backend).clean("um i love hey vedu", protected: [dictionary])
        #expect(result.text == "I love HeyVedu.")
        #expect(result.fallbackReason == nil)
    }

    @Test func lostSnippetTriggerIsPastedRaw() async {
        let snippets = SnippetExpander(snippets: [.init(trigger: "my calendly link", expansion: "https://x")])
        let backend = FakeBackend(isNormalizer: true)
        backend.outputs["send my calendly link"] = "Send my link."
        let result = await cleaner(backend).clean("send my calendly link", protected: [snippets.matcher])
        #expect(result.text == "Send my calendly link.")
        #expect(snippets.expand(result.text, dictionary: .empty) == "Send https://x.")
    }
}

struct OutputGuardTests {
    @Test func acceptsOrdinaryCleanup() {
        #expect(OutputGuard.rejectionReason(
            input: "um so can you uh send me the the report by friday",
            output: "Can you send me the report by Friday?") == nil)
        #expect(OutputGuard.rejectionReason(
            input: "i want to book a meeting for 2pm actually no 3pm",
            output: "I want to book a meeting for 3 PM.") == nil)
    }

    @Test func acceptsNumberNormalization() {
        #expect(OutputGuard.rejectionReason(
            input: "sales grew twenty percent this quarter",
            output: "Sales grew 20% this quarter.") == nil)
        #expect(OutputGuard.rejectionReason(
            input: "we have twenty three thousand four hundred fifty users",
            output: "We have 23,450 users.") == nil)
    }

    @Test func rejectsEmptyOutput() {
        #expect(OutputGuard.rejectionReason(input: "hello", output: " . ") == "empty output")
    }

    @Test func rejectsAnswers() {
        #expect(OutputGuard.rejectionReason(
            input: "what is the capital of france",
            output: "Paris is located on the Seine river.") == "output diverges from transcript")
    }

    @Test func rejectsEmbellishment() {
        #expect(OutputGuard.rejectionReason(
            input: "write a poem",
            output: "write a poem write a poem write a poem write a poem") == "output longer than transcript")
    }

    @Test func rejectsSummaries() {
        let input = "so the plan for today is that we finish the release notes and then we ship the build to testers"
        #expect(OutputGuard.rejectionReason(input: input, output: "Ship the build.") == "output much shorter than transcript")
    }

    @Test func tokenizesWords() {
        #expect(OutputGuard.words(in: "Let's meet at 3pm, twenty percent!") == ["lets", "meet", "at", "3", "pm", "20", "%"])
    }
}

struct TextPolishTests {
    @Test(arguments: [
        ("hello world", "Hello world."),
        ("  i think i can  ", "I think I can."),
        ("Is it done?", "Is it done?"),
        ("version 2", "Version 2."),
        ("ice cream", "Ice cream."),
        ("", ""),
    ])
    func finalizes(input: String, expected: String) {
        #expect(TextPolish.finalize(input) == expected)
    }
}

struct SentenceChunkerTests {
    /// One "token" per word.
    private static func wordCount(_ text: String) async -> Int? {
        text.split(whereSeparator: \.isWhitespace).count
    }

    @Test func shortTextIsOneChunk() async {
        let chunks = await SentenceChunker.chunks(of: "One two three.", budget: 10, tokenCount: Self.wordCount)
        #expect(chunks == ["One two three."])
    }

    @Test func splitsAtSentencesWithinBudget() async {
        let text = "One two three. Four five six. Seven eight nine."
        let chunks = await SentenceChunker.chunks(of: text, budget: 6, tokenCount: Self.wordCount)
        #expect(chunks == ["One two three. Four five six.", "Seven eight nine."])
    }

    @Test func splitsUnpunctuatedTextAtWhitespace() async {
        let text = "one two three four five six seven eight"
        let chunks = await SentenceChunker.chunks(of: text, budget: 3, tokenCount: Self.wordCount)
        #expect(chunks.allSatisfy { $0.split(separator: " ").count <= 3 })
        #expect(chunks.joined(separator: " ") == text)
    }
}
