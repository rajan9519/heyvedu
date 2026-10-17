import AppKit
import Observation

/// Dictionary auto-learn end to end (AI-ASSIST-PLAN §4.1):
/// paste → `EditWatcher` → `CorrectionDetector` → queue (dedupe, batch up to 10, flush when
/// idle) → AI Assist or `HeuristicJudge` → `DictionaryLearnTask.validate` → `SuggestionStore`
/// → the HUD prompt and the Dictionary page. The user confirms every addition.
@Observable
final class DictionaryLearner {
    static let batchSize = 10
    static let flushDelay: Duration = .seconds(30)
    private static let enabledKey = "autoLearn.enabled"
    private static let promptsKey = "autoLearn.promptInHUD"

    /// Off by default: it reads the field HeyVedu pasted into for a few seconds after a paste.
    var isEnabled = UserDefaults.standard.bool(forKey: DictionaryLearner.enabledKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { cancel() }
        }
    }

    /// Ask in the recording indicator as suggestions come up, besides listing them in Dictionary.
    var promptsInHUD = UserDefaults.standard.object(forKey: DictionaryLearner.promptsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(promptsInHUD, forKey: Self.promptsKey) }
    }

    let store: SuggestionStore
    /// A suggestion just became ready; the controller decides whether the HUD can ask now.
    @ObservationIgnored var onReady: ((SuggestionStore.Suggestion) -> Void)?

    @ObservationIgnored private let dictionary: PersonalDictionary
    @ObservationIgnored private let assist: AssistService
    @ObservationIgnored private let watcher = EditWatcher()
    @ObservationIgnored private var queue: [DictionaryLearnTask.Edit] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var judgeTask: Task<Void, Never>?
    /// The no-AI judge; tests swap out its spell checker.
    @ObservationIgnored private let heuristic: (DictionaryLearnTask.Input) -> DictionaryLearnTask.Output

    init(dictionary: PersonalDictionary, assist: AssistService, store: SuggestionStore = SuggestionStore(),
         heuristic: @escaping (DictionaryLearnTask.Input) -> DictionaryLearnTask.Output = { HeuristicJudge.suggestions(for: $0) }) {
        self.dictionary = dictionary
        self.assist = assist
        self.store = store
        self.heuristic = heuristic
        watcher.onEdits = { [weak self] edits in self?.enqueue(edits) }
    }

    /// HeyVedu pasted `text` into `app`: watch for corrections.
    func didPaste(_ text: String, in app: NSRunningApplication?) {
        guard isEnabled else { return }
        watcher.watch(pasted: text, in: app)
    }

    /// A new dictation started: the last paste's watch is over.
    func dictationStarted() {
        watcher.stop()
    }

    func enqueue(_ edits: [DictionaryLearnTask.Edit]) {
        for edit in edits where !queue.contains(edit) { queue.append(edit) }
        flushTask?.cancel()
        if queue.count >= Self.batchSize {
            flush()
        } else {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.flushDelay)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !queue.isEmpty else { return }
        let batch = Array(queue.prefix(Self.batchSize))
        queue.removeFirst(batch.count)
        let input = DictionaryLearnTask.Input(edits: batch, knownTerms: dictionary.entries.map(\.term))
        let previous = judgeTask
        judgeTask = Task { [weak self] in
            await previous?.value  // one batch at a time
            guard let self, !Task.isCancelled else { return }
            let (found, source) = await self.judge(input)
            guard !Task.isCancelled else { return }
            let ready = self.store.record(found, source: source, dictionary: self.dictionary.entries)
            DebugTrace.write("learn: \(batch.count) edit(s) → \(found.count) suggestion(s) from \(source), \(ready.count) ready")
            if let first = ready.first, self.promptsInHUD { self.onReady?(first) }
            if !self.queue.isEmpty { self.flush() }
        }
    }

    /// AI Assist when it's on, the heuristic judge otherwise or when every provider failed.
    private func judge(_ input: DictionaryLearnTask.Input) async -> ([DictionaryLearnTask.Suggestion], String) {
        if assist.isEnabled {
            do {
                let outcome = try await assist.run(DictionaryLearnTask.self, input)
                return (outcome.output.suggestions, "\(outcome.route.key) v\(DictionaryLearnTask.promptVersion)")
            } catch AssistError.cancelled {
                return ([], "cancelled")
            } catch {
                DebugTrace.write("learn: AI Assist failed (\(AssistRouter.kind(of: error as? AssistError ?? .badOutput(""))))")
            }
        }
        return (heuristic(input).suggestions, "heuristic")
    }

    /// Waits for batches already sent to a judge (tests).
    func waitForJudging() async {
        await judgeTask?.value
    }

    func accept(_ suggestion: SuggestionStore.Suggestion) {
        store.accept(suggestion.id, into: dictionary)
    }

    private func cancel() {
        watcher.stop()
        flushTask?.cancel()
        judgeTask?.cancel()
        queue = []
    }
}
