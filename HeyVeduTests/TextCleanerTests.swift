import Foundation
import Testing
@testable import HeyVedu

/// A cleanup engine that returns scripted output, so the fallback logic in
/// `TextCleaner.clean` can be tested without a model.
final class FakeBackend: CleanupBackend {
    struct Failure: LocalizedError {
        var errorDescription: String? { "fake failure" }
    }

    var onStateChange: (() -> Void)?
    var available: TextCleaner.Availability = .available
    /// Splits transcripts at "|" when set.
    var splitsAtBars = false
    /// Output for each chunk; a missing entry throws.
    var outputs: [String: String] = [:]
    private(set) var cleanedChunks: [String] = []
    private(set) var contexts: [CleanupContext] = []
    private(set) var discardCount = 0

    func availability() -> TextCleaner.Availability { available }

    func discardPrepared() { discardCount += 1 }

    func chunks(of transcript: String, instructions: String) async -> [String] {
        guard splitsAtBars else { return [transcript] }
        return transcript.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func clean(_ chunk: String, instructions: String, context: CleanupContext) async throws -> String {
        cleanedChunks.append(chunk)
        contexts.append(context)
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

    @Test func errorFallsBackToTheChunk() async {
        let backend = FakeBackend()
        let result = await cleaner(backend).clean("hello there")
        #expect(result.text == "hello there")
        #expect(result.fallbackReason == "fake failure")
    }

    @Test func outputIsUsedAsIs() async {
        let backend = FakeBackend()
        backend.outputs["new line test"] = "- list item"
        backend.outputs["um uh"] = ""
        let result = await cleaner(backend).clean("new line test")
        #expect(result.text == "- list item")
        #expect(await cleaner(backend).clean("um uh").text == "")
    }

    @Test func contextReachesTheBackendForEveryChunk() async {
        let backend = FakeBackend()
        backend.splitsAtBars = true
        backend.outputs["hi olga"] = "Hi Olga,"
        backend.outputs["thanks"] = "Thanks."
        let email = CleanupContext(format: .email)
        _ = await cleaner(backend).clean("hi olga | thanks", context: email)
        #expect(backend.contexts == [email, email])
        _ = await cleaner(backend).clean("hi olga")
        #expect(backend.contexts.last == .plain)
    }

    @Test func eachChunkGetsItsOwnVocab() async {
        let backend = FakeBackend()
        backend.splitsAtBars = true
        backend.outputs["ask pria"] = "Ask Priya."
        backend.outputs["deploy cooper netties"] = "Deploy Kubernetes."
        backend.outputs["lunch at noon"] = "Lunch at noon."
        let vocabulary = VocabularyMatcher(entries: [.init(term: "Kubernetes"), .init(term: "Priya")])
        let email = CleanupContext(format: .email)
        _ = await cleaner(backend).clean("ask pria | deploy cooper netties | lunch at noon", context: email, vocabulary: vocabulary)
        #expect(backend.contexts.map(\.vocab) == [["Priya"], ["Kubernetes"], []])
        #expect(backend.contexts.allSatisfy { $0.format == .email })
    }

    @Test func emailChunksKeepTheirLayout() async {
        let backend = FakeBackend()
        backend.splitsAtBars = true
        backend.outputs["one"] = "Hi Olga,\n\nCan you send the logs?"
        backend.outputs["two"] = "And the report."
        backend.outputs["three"] = "Thanks,\nRajan"
        let result = await cleaner(backend).clean("one | two | three", context: CleanupContext(format: .email))
        #expect(result.text == "Hi Olga,\n\nCan you send the logs?\n\nAnd the report.\n\nThanks,\nRajan")
    }

    @Test func plainAndChatChunksAreJoinedWithSpaces() {
        let pieces = ["Hi Mei,\nfirst.", "Second.", "Third."]
        #expect(TextCleaner.join(pieces, context: .plain) == "Hi Mei,\nfirst. Second. Third.")
        #expect(TextCleaner.join(pieces, context: CleanupContext(format: .message)) == "Hi Mei,\nfirst. Second. Third.")
        #expect(TextCleaner.join(["One.", "Two."], context: CleanupContext(format: .notes)) == "One. Two.")
        #expect(TextCleaner.join(["- One\n- Two", "Three."], context: CleanupContext(format: .notes)) == "- One\n- Two\n\nThree.")
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
