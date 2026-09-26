import CryptoKit
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
/// Weights are downloaded once from Hugging Face at a pinned revision into Application
/// Support, and every file is checked against a pinned SHA-256 before it is used.
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
        case download(String)
        case integrity(String)

        var errorDescription: String? {
            switch self {
            case .notReady(let reason): return reason
            case .download(let reason): return "S1-mini download failed: \(reason)"
            case .integrity(let file): return "S1-mini file failed verification: \(file)"
            }
        }
    }

    private(set) var state: State = .idle

    /// Called on every state change so the cleaner can refresh its availability.
    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.rajan.heyvedu", category: "S1Mini")

    // MARK: Pinned model

    private nonisolated static let repository = "superwhisper/s1-mini"
    private nonisolated static let revision = "88f6b15896c73bbb13a3b596e0afe8ea0d5150b4"

    private nonisolated struct ModelFile {
        let name: String
        let size: Int64
        let sha256: String
    }

    /// Only what MLX needs to load the model (the chat template is in tokenizer_config.json).
    private nonisolated static let files = [
        ModelFile(name: "config.json", size: 726,
                  sha256: "660db3b73d788119c04535e48cf9be5f55bc3100841a718637ae695b442f27dd"),
        ModelFile(name: "generation_config.json", size: 181,
                  sha256: "6ca52b0bcb818c9e52db8ea18413494110c5f2def581b769f621dda951a7863b"),
        ModelFile(name: "tokenizer.json", size: 11_422_654,
                  sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        ModelFile(name: "tokenizer_config.json", size: 9_732,
                  sha256: "d5d09f07b48c3086c508b30d1c9114bd1189145b74e982a265350c923acd8101"),
        ModelFile(name: "model.safetensors", size: 1_503_300_328,
                  sha256: "69d2057077ab4dc738aaaab75d2a8ffa141e3a09fb9d956198cfce46f381131a"),
    ]

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
                let directory = try await ensureDownloaded()
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

        let control = "[Styling: \(styling.rawValue)] [Structure: prose] [Context: general]"
        let input = UserInput(
            chat: [.system(Self.systemPrompt), .user("\(control)\n\(Self.sanitize(chunk))")],
            // Required: with thinking on (the template default) the model returns nothing.
            additionalContext: ["enable_thinking": false]
        )
        let transcriptTokens = await container.encode(chunk).count
        // Model card: greedy decoding, output capped at ~1.3× the input plus headroom.
        let parameters = GenerateParameters(
            maxTokens: Int(Double(transcriptTokens) * 1.3) + 32,
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

    // MARK: Download

    private nonisolated static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "HeyVedu/Models/s1-mini/\(revision)", directoryHint: .isDirectory)
    }

    /// Marker written after every file has passed its hash check, so later launches only
    /// compare sizes instead of re-hashing 1.5 GB.
    private nonisolated static var verifiedMarker: URL {
        modelDirectory.appending(path: ".verified")
    }

    private func ensureDownloaded() async throws -> URL {
        let directory = Self.modelDirectory
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: Self.verifiedMarker.path),
           Self.files.allSatisfy({ Self.size(of: directory.appending(path: $0.name)) == $0.size }) {
            return directory
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: Self.verifiedMarker)

        let total = Self.files.reduce(0) { $0 + $1.size }
        var completed: Int64 = 0
        setState(.downloading(0))
        for file in Self.files {
            try Task.checkCancellation()
            let destination = directory.appending(path: file.name)
            if Self.size(of: destination) == file.size, try await Self.sha256(of: destination) == file.sha256 {
                completed += file.size
                continue
            }
            try? fileManager.removeItem(at: destination)

            let base = completed
            let temporary = try await Self.download(file.name) { [weak self] written in
                let fraction = Double(base + min(written, file.size)) / Double(total)
                Task { @MainActor in self?.setState(.downloading(fraction)) }
            }
            defer { try? fileManager.removeItem(at: temporary) }
            guard try await Self.sha256(of: temporary) == file.sha256 else {
                throw BackendError.integrity(file.name)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            completed += file.size
        }
        try Data(Self.revision.utf8).write(to: Self.verifiedMarker, options: .atomic)
        DebugTrace.write("s1-mini: downloaded and verified \(Self.files.count) files")
        return directory
    }

    private nonisolated static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// HTTPS from the pinned revision only. Redirects to Hugging Face's CDN are followed;
    /// integrity comes from the SHA-256 check, not from where the bytes were served.
    @concurrent
    private nonisolated static func download(
        _ name: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)") else {
            throw BackendError.download("bad URL for \(name)")
        }
        let delegate = DownloadProgressDelegate(progress: progress)
        let (location, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: location)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BackendError.download("HTTP \(status) for \(name)")
        }
        // The system deletes `location` once this returns; move it somewhere we control.
        let kept = FileManager.default.temporaryDirectory.appending(path: "s1-mini-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: location, to: kept)
        return kept
    }

    /// Streams the file through SHA-256 in 4 MB blocks, off the main actor.
    @concurrent
    private nonisolated static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension TextCleaner.Availability {
    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Reports bytes written for one download task.
private nonisolated final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progress: @Sendable (Int64) -> Void

    init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async `download(from:delegate:)` call.
    }
}

// MARK: - Tokenizer bridge

/// Adapts swift-transformers' tokenizer to MLXLMCommon's protocol (what the
/// MLXHuggingFace macros generate, written out to avoid the swift-syntax dependency).
private nonisolated struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
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
