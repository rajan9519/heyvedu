import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os
import Tokenizers

/// Cleans transcripts on-device with S1-mini by Superwhisper, a 0.6B text normalizer
/// fine-tuned from Qwen3-0.6B, run with MLX on Apple silicon.
///
/// S1-mini is not a chat model: it ignores instructions and only normalizes the transcript
/// (fillers, self-corrections, punctuation, numbers), steered by a control line. That also
/// means a spoken question or command is cleaned, never answered or followed.
///
/// Weights are downloaded once from Hugging Face at a pinned revision (see `PinnedModel`).
@Observable
final class S1MiniBackend {
    /// Register (the control line's `Styling` axis).
    nonisolated enum Styling: String, CaseIterable, Identifiable {
        case casual
        case semiCasual = "semi-casual"
        case semiFormal = "semi-formal"
        case formal

        var id: String { rawValue }

        var title: String {
            switch self {
            case .casual: return "Casual"
            case .semiCasual: return "Semi-casual"
            case .semiFormal: return "Semi-formal"
            case .formal: return "Formal"
            }
        }
    }

    enum State: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    nonisolated enum BackendError: LocalizedError {
        case notReady(String)

        var errorDescription: String? {
            switch self {
            case .notReady(let reason): return reason
            }
        }
    }

    private(set) var state: State = .idle

    /// Called on every state change so the cleaner can refresh its availability.
    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.heyvedu.app", category: "S1Mini")

    // MARK: Pinned model

    /// Only what MLX needs to load the model (the chat template is in tokenizer_config.json).
    private nonisolated static let model = PinnedModel(
        displayName: "S1-mini",
        folder: "s1-mini",
        repository: "superwhisper/s1-mini",
        revision: "88f6b15896c73bbb13a3b596e0afe8ea0d5150b4",
        files: [
            .init(name: "config.json", size: 726,
                  sha256: "660db3b73d788119c04535e48cf9be5f55bc3100841a718637ae695b442f27dd"),
            .init(name: "generation_config.json", size: 181,
                  sha256: "6ca52b0bcb818c9e52db8ea18413494110c5f2def581b769f621dda951a7863b"),
            .init(name: "tokenizer.json", size: 11_422_654,
                  sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            .init(name: "tokenizer_config.json", size: 9_732,
                  sha256: "d5d09f07b48c3086c508b30d1c9114bd1189145b74e982a265350c923acd8101"),
            .init(name: "model.safetensors", size: 1_503_300_328,
                  sha256: "69d2057077ab4dc738aaaab75d2a8ffa141e3a09fb9d956198cfce46f381131a"),
        ]
    )

    /// The model card's required system prompt, verbatim.
    private nonisolated static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    /// The model handles ~1,000 input tokens per pass; leave room for the system prompt
    /// and control line.
    nonisolated static let chunkTokenBudget = 800

    // MARK: Lifecycle

    func availability() -> TextCleaner.Availability {
        switch state {
        case .ready: return .available
        case .idle: return .unavailable("S1-mini isn't loaded yet")
        case .downloading(let fraction):
            return .unavailable("Downloading S1-mini (1.5 GB)… \(Int(fraction * 100))%")
        case .loading: return .unavailable("Loading S1-mini…")
        case .failed(let reason): return .unavailable(reason)
        }
    }

    /// Downloads (first run only) and loads the model in the background. Safe to call
    /// repeatedly; retries after a failure.
    func prepare() {
        guard container == nil, loadTask == nil else { return }
        loadTask = Task {
            defer { loadTask = nil }
            do {
                let directory = try await Self.model.ensureDownloaded { [weak self] fraction in
                    Task { @MainActor in self?.setState(.downloading(fraction)) }
                }
                setState(.loading)
                let started = ContinuousClock.now
                // Keep MLX's buffer cache small: the app idles in the menu bar most of the time.
                Memory.cacheLimit = 64 * 1024 * 1024
                container = try await LLMModelFactory.shared.loadContainer(
                    from: directory, using: TransformersTokenizerLoader())
                DebugTrace.write("s1-mini: loaded in \(ContinuousClock.now - started)")
                setState(.ready)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("S1-mini load failed: \(reason, privacy: .public)")
                setState(.failed(reason))
            }
        }
    }

    /// Frees the model's memory (engine switched away, or app quitting).
    func shutdown() {
        loadTask?.cancel()
        loadTask = nil
        container = nil
        if state != .idle { setState(.idle) }
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?()
    }

    // MARK: Cleanup

    /// Token count of `text`, for chunking. Nil until the model is loaded.
    func tokenCount(_ text: String) async -> Int? {
        guard let container else { return nil }
        return await container.encode(text).count
    }

    /// Normalizes one chunk. An empty result is valid: filler-only input ("um") has no
    /// written form.
    func clean(_ chunk: String, styling: Styling) async throws -> String {
        guard let container else { throw BackendError.notReady(availability().reason ?? "S1-mini isn't loaded") }

        let transcript = Self.sanitize(chunk)
        let control = "[Styling: \(styling.rawValue)] [Structure: lists] [Context: general]"
        let input = UserInput(
            chat: [.system(Self.systemPrompt), .user("\(control)\n\(transcript)")],
            // Required: with thinking on (the template default) the model returns nothing.
            additionalContext: ["enable_thinking": false]
        )
        let transcriptTokens = await container.encode(transcript).count
        // Model card: greedy decoding, output capped at ~1.3× the input plus headroom.
        let parameters = GenerateParameters(
            maxTokens: Int(ceil(Double(transcriptTokens) * 1.3)) + 32,
            temperature: 0
        )

        let prepared = try await container.prepare(input: input)
        var output = ""
        for await generation in try await container.generate(input: prepared, parameters: parameters) {
            if case .chunk(let text) = generation { output += text }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcripts are plain speech; strip anything that looks like a chat-template token
    /// so the input can't end the user turn early.
    private nonisolated static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: " ", options: .regularExpression)
    }
}

extension TextCleaner.Availability {
    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Tokenizer bridge

/// Adapts swift-transformers' tokenizer to MLXLMCommon's protocol (what the
/// MLXHuggingFace macros generate, written out to avoid the swift-syntax dependency).
nonisolated struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    /// False falls back to the BPE tokenizer for tokenizer classes swift-transformers
    /// doesn't list by name.
    var strict = true

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory, strict: strict))
    }
}

private nonisolated struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
