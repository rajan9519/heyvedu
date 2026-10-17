import Foundation

/// Cleanup through the user's Claude Code or Codex sign-in, on the model the AI Assist
/// picker measured fastest for cleanup. The model applies the dictionary and snippets too,
/// and its answer is pasted as is. Opt-in and slower than the on-device engines, and each
/// transcript (with the dictionary and snippets) leaves the Mac; `GeneralSettings` says so
/// before it can be chosen.
final class AssistCleanupBackend: CleanupBackend {
    let outputIsFinal = true

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    var onStateChange: (() -> Void)?
    private let assist: AssistService

    init(assist: AssistService) {
        self.assist = assist
    }

    func availability() -> TextCleaner.Availability {
        assist.hasUsableCLI ? .available : .unavailable("Sign in to Claude Code or Codex to use it for cleanup")
    }

    /// Selected: check the CLIs and measure cleanup models in the background.
    func warmUp() {
        assist.cleansDictations = true
        Task {
            await assist.refreshStatus()
            onStateChange?()
        }
    }

    func prepare(instructions: String) {
        assist.prepareCleanup()
    }

    func shutdown() {
        assist.cleansDictations = false
    }

    func clean(_ chunk: String, instructions: String) async throws -> String {
        do {
            return try await assist.clean(chunk)
        } catch let error as AssistError {
            throw Failure(errorDescription: Self.reason(error))
        }
    }

    /// Shown after "Pasted raw text — ", and written to the debug log, so never the text.
    static func reason(_ error: AssistError) -> String {
        switch error {
        case .timeout: "Claude Code or Codex took too long"
        case .unavailable: "Claude Code or Codex isn't signed in"
        case .capacity: "Claude Code or Codex hit a usage limit"
        case .modelRejected: "the chosen model isn't available"
        case .cancelled: "cleanup was cancelled"
        case .badOutput: "Claude Code or Codex returned no text"
        }
    }
}
