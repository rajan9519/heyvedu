import Foundation

/// Speech-to-text stage.
protocol Transcriber {
    func transcribe(_ recording: Recording) async throws -> String
}

enum TranscriberError: LocalizedError {
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .modelNotReady: return "Speech model is not loaded yet"
        }
    }
}
