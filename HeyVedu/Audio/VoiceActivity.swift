import CoreML
import FluidAudio
import Foundation
import os

/// Silero voice activity detection via FluidAudio. Loaded after the speech model (a small
/// extra download on first launch). Everything that uses it works without it: if it
/// isn't ready, recordings are neither trimmed nor auto-stopped.
final class VoiceActivity {
    /// Samples per VAD chunk (256 ms at 16 kHz); the recorder delivers audio in these.
    nonisolated static let chunkSize = VadManager.chunkSize

    private var manager: VadManager?
    private var loadTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.heyvedu.app", category: "VoiceActivity")

    var isReady: Bool { manager != nil }

    /// Downloads (if needed) and loads the model. Safe to call repeatedly.
    func prepare() {
        guard manager == nil, loadTask == nil else { return }
        loadTask = Task {
            defer { loadTask = nil }
            let started = ContinuousClock.now
            do {
                ModelRegistry.baseURL = "https://huggingface.co"
                // CPU only: the model is tiny, and the Neural Engine gave garbage for other
                // small FluidAudio models (see the 1.3 notes in docs/FEATURE-PLAN.md).
                manager = try await VadManager(config: VadConfig(computeUnits: .cpuOnly))
                DebugTrace.write("vad: ready in \(ContinuousClock.now - started)")
            } catch {
                logger.error("VAD failed to load: \(error.localizedDescription, privacy: .public)")
                DebugTrace.write("vad: failed: \(error.localizedDescription)")
            }
        }
    }

    /// Starts scoring one recording's audio as it arrives. Nil when the model isn't loaded.
    func track(_ chunks: AsyncStream<[Float]>) -> SpeechTracker? {
        manager.map { SpeechTracker(manager: $0, chunks: chunks) }
    }
}

/// Scores one recording chunk by chunk while the user speaks, so finishing costs at most
/// one chunk of VAD work.
final class SpeechTracker {
    /// Called after each chunk with how long the audio has been silent (since the last
    /// speech, or since the start if there was none yet).
    var onSilence: ((TimeInterval) -> Void)?

    private(set) var probabilities: [Float] = []
    private var failed = false
    private var task: Task<Void, Never>?

    fileprivate init(manager: VadManager, chunks: AsyncStream<[Float]>) {
        task = Task { [weak self] in
            var state = await manager.makeStreamState()
            for await chunk in chunks {
                guard let self, !self.failed else { continue }
                do {
                    let result = try await manager.processStreamingChunk(chunk, state: state)
                    state = result.state
                    self.probabilities.append(result.probability)
                    self.onSilence?(SpeechTrim.trailingSilence(self.probabilities))
                } catch {
                    // Never trim on partial data.
                    DebugTrace.write("vad: chunk failed: \(error.localizedDescription)")
                    self.failed = true
                }
            }
        }
    }

    /// Waits for the recording's last chunks to be scored. Nil if scoring failed.
    /// The chunk stream must be finished (the recorder stopped) or this never returns.
    func finish() async -> [Float]? {
        await task?.value
        onSilence = nil
        return failed ? nil : probabilities
    }
}

/// Decisions made from per-chunk speech probabilities. Pure, so it can be tested alone.
nonisolated enum SpeechTrim {
    /// Silero's usual thresholds: a chunk at or above `speech` is speech, one below
    /// `silence` is silence; in between keeps the previous state.
    static let speech: Float = 0.5
    static let silence: Float = 0.35
    static let chunkDuration = Double(VoiceActivity.chunkSize) / Recording.sampleRate

    /// Kept around the detected speech so soft word starts and endings aren't clipped.
    static let leadingPadding: TimeInterval = 0.3
    static let trailingPadding: TimeInterval = 0.4

    /// The part of a recording worth transcribing, or nil to keep all of it. Nil when no
    /// chunk sounded like speech: VAD can miss very quiet speech, and transcribing the
    /// whole clip is what HeyVedu did before VAD.
    static func range(probabilities: [Float], sampleCount: Int) -> Range<Int>? {
        guard let first = probabilities.firstIndex(where: { $0 >= speech }),
              let last = probabilities.lastIndex(where: { $0 >= speech }) else { return nil }
        let chunk = VoiceActivity.chunkSize
        let lead = Int(leadingPadding * Recording.sampleRate)
        let trail = Int(trailingPadding * Recording.sampleRate)
        let start = max(0, first * chunk - lead)
        // Audio after the last full chunk was never scored; keep it if speech ran up to it.
        let end = last == probabilities.count - 1 ? sampleCount : min(sampleCount, (last + 1) * chunk + trail)
        guard start < end else { return nil }
        return start..<end
    }

    /// Seconds of silence at the end of the audio scored so far.
    static func trailingSilence(_ probabilities: [Float]) -> TimeInterval {
        var count = 0
        for probability in probabilities.reversed() {
            guard probability < silence else { break }
            count += 1
        }
        return Double(count) * chunkDuration
    }
}
