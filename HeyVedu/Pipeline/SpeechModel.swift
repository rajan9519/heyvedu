import FluidAudio
import Foundation
import Observation
import os

/// Parakeet TDT 0.6b v3 via FluidAudio (Core ML / Neural Engine). Downloads the model
/// on first launch (~600 MB, cached in ~/Library/Application Support/FluidAudio/Models),
/// then loads and warms it up so the first dictation is fast.
@Observable
final class SpeechModel: Transcriber {
    enum State: Equatable {
        case idle
        case downloading
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Fraction of the first-launch download completed, while `state == .downloading`.
    private(set) var downloadProgress: Double?

    /// Called once the model is ready (after a download or a load from cache).
    @ObservationIgnored var onReady: (() -> Void)?

    @ObservationIgnored private let engine = ParakeetEngine()
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.heyvedu.app", category: "SpeechModel")

    var isReady: Bool { state == .ready }

    /// Downloads (if needed) and loads the model. Safe to call repeatedly; also used to retry.
    func prepare() {
        guard prepareTask == nil, state != .ready else { return }
        prepareTask = Task {
            defer { prepareTask = nil }
            let started = ContinuousClock.now
            do {
                state = await engine.modelsCached() ? .loading : .downloading
                try await engine.load { [weak self] progress in
                    // Download phases → "downloading"; Core ML compilation → "loading".
                    let fraction = progress.fractionCompleted
                    guard case .compiling = progress.phase else {
                        Task { @MainActor in
                            if self?.state == .downloading { self?.downloadProgress = fraction }
                        }
                        return
                    }
                    Task { @MainActor in
                        if self?.state == .downloading { self?.state = .loading }
                        self?.downloadProgress = nil
                    }
                }
                state = .ready
                downloadProgress = nil
                onReady?()
                DebugTrace.write("model: ready in \(ContinuousClock.now - started)")
            } catch {
                logger.error("Speech model failed to load: \(error.localizedDescription, privacy: .public)")
                DebugTrace.write("model: failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    func transcribe(_ recording: Recording) async throws -> String {
        guard isReady else { throw TranscriberError.modelNotReady }
        let started = ContinuousClock.now
        let text = try await engine.transcribe(recording.samples)
        // Timing only — transcript content is never logged.
        DebugTrace.write("model: transcribed \(String(format: "%.2f", recording.duration))s audio in \(ContinuousClock.now - started)")
        return text
    }
}

/// Loads the models and holds the AsrManager. Each dictation is independent, so every
/// transcription gets a fresh decoder state.
private actor ParakeetEngine {
    private static let version: AsrModelVersion = .v3
    private var manager: AsrManager?

    func modelsCached() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: Self.version), version: Self.version)
    }

    func load(progress: @escaping ProgressHandler) async throws {
        guard manager == nil else { return }
        // Pin the model source: FluidAudio otherwise honours REGISTRY_URL / MODEL_REGISTRY_URL
        // environment overrides, which could redirect the download.
        ModelRegistry.baseURL = "https://huggingface.co"

        let models = try await AsrModels.downloadAndLoad(version: Self.version, progressHandler: progress)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        // Warm-up pass so the Neural Engine graph is ready before the first real dictation.
        var warmupState = TdtDecoderState.make()
        _ = try? await manager.transcribe(
            [Float](repeating: 0, count: Int(Recording.sampleRate)),
            decoderState: &warmupState
        )
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.modelNotReady }
        var decoderState = TdtDecoderState.make()
        // English-only: restrict decoding to Latin-script tokens.
        return try await manager.transcribe(samples, decoderState: &decoderState, language: .english).text
    }
}
