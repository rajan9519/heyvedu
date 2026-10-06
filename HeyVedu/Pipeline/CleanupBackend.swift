import Foundation

/// One transcript-cleanup engine. `TextCleaner` owns one instance per `TextCleaner.Engine`
/// and routes every call to the selected one.
///
/// To add an engine: implement this protocol in its own file, add a case to
/// `TextCleaner.Engine` with a title, and return the new backend from `makeBackend()`.
/// Only `availability()` and `clean(_:instructions:)` are required; the rest have defaults.
protocol CleanupBackend: AnyObject {
    /// True for models trained only to normalize dictation. Their output is trusted as-is:
    /// they own casing and punctuation, and may legitimately drop most of a transcript
    /// (filler-only speech, retractions), which the chat-model output guard would reject.
    var isNormalizer: Bool { get }

    /// For engines that download and load local weights; drives progress in the menu and
    /// the "model ready" notice. Nil for engines without a model lifecycle.
    var modelState: LocalModelState? { get }

    /// Set by `TextCleaner`; the backend calls it whenever its availability may have changed.
    var onStateChange: (() -> Void)? { get set }

    func availability() -> TextCleaner.Availability

    /// The engine was selected (or the app launched with it): start any slow setup, such as
    /// downloading or loading a model. Safe to call repeatedly.
    func warmUp()

    /// Recording started: get ready for the dictation that follows.
    func prepare(instructions: String)

    /// The prepared dictation was cancelled or had no speech.
    func discardPrepared()

    /// The engine was switched away from, or the app is quitting: free memory, stop work.
    func shutdown()

    /// Splits a transcript into pieces small enough for one `clean` call each.
    func chunks(of transcript: String, instructions: String) async -> [String]

    func clean(_ chunk: String, instructions: String) async throws -> String
}

extension CleanupBackend {
    var isNormalizer: Bool { false }
    var modelState: LocalModelState? { nil }
    func warmUp() {}
    func prepare(instructions: String) { warmUp() }
    func discardPrepared() {}
    func shutdown() {}
    func chunks(of transcript: String, instructions: String) async -> [String] { [transcript] }
}

/// Lifecycle of a downloaded, locally run model.
enum LocalModelState: Equatable {
    case idle
    /// Fraction of the weights downloaded so far (0...1).
    case downloading(Double)
    case loading
    case ready
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}
