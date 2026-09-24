import Foundation

/// Speech-to-text stage. Phase 2 replaces the stub with FluidAudio + Parakeet v3.
protocol Transcriber {
    func transcribe(_ recording: Recording) async throws -> String
}

/// Phase 1 placeholder: proves the hotkey → record → paste loop end to end.
struct StubTranscriber: Transcriber {
    func transcribe(_ recording: Recording) async throws -> String {
        String(format: "Recorded %.1f seconds", recording.duration)
    }
}
