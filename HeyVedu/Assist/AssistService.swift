import Foundation
import Observation

/// The app's AI Assist layer: settings the UI binds to, provider status, the measured model
/// chain, and the router features call. Off until the user turns it on.
@Observable
final class AssistService {
    @ObservationIgnored let router: AssistRouter
    @ObservationIgnored private let settings: AssistSettings
    @ObservationIgnored private lazy var picker = AssistModelPicker(router: router) { line in
        DebugTrace.write("assist picker: \(line)")
    }

    var isEnabled: Bool {
        didSet {
            settings.isEnabled = isEnabled
            if isEnabled { refresh() } else { router.shutdown() }
        }
    }

    var engine: AssistSettings.Engine {
        didSet {
            settings.engine = engine
            router.shutdown()
            refresh()
        }
    }

    var dailyCap: Int {
        didSet { settings.dailyCap = dailyCap }
    }

    /// A model the user chose instead of the measured fastest, for every task; nil follows
    /// the measurement.
    var pinnedRoute: AssistRoute? {
        didSet { settings.setPinnedRoute(pinnedRoute, for: "default") }
    }

    /// Transcript cleanup goes through Claude Code or Codex (`TextCleaner.Engine.assist`).
    /// Set by the cleaner; its own opt-in, separate from the AI Assist switch.
    var cleansDictations = false {
        didSet { if cleansDictations, !oldValue { refresh() } }
    }

    /// The dictionary and snippets sent with each transcript to clean. Set by the controller.
    @ObservationIgnored var cleanupVocabulary: () -> CleanupTask.Vocabulary = { .empty }

    private(set) var statuses: [AssistProviderID: AssistAvailability] = [:]
    private(set) var pick: AssistPick?
    /// The measured chain for cleanup, once it has one of its own.
    private(set) var cleanupPick: AssistPick?
    private(set) var isMeasuring = false
    private(set) var requestsToday: Int
    /// The route that answered most recently, for the counts-only activity line.
    private(set) var lastRoute: AssistRoute?

    init(router: AssistRouter = AssistRouter(), settings: AssistSettings = .shared) {
        self.router = router
        self.settings = settings
        isEnabled = settings.isEnabled
        engine = settings.engine
        dailyCap = settings.dailyCap
        pinnedRoute = settings.pinnedRoute(for: "default")
        requestsToday = settings.requestsToday()
        pick = router.picks.pick(for: DictionaryLearnTask.id)
        cleanupPick = router.picks.pick(for: CleanupTask.id)
    }

    /// The CLIs are needed: for AI Assist on the CLI engine, or for cleanup.
    private var usesCLIs: Bool { (isEnabled && engine == .cli) || cleansDictations }

    /// App launch: check the CLIs and measure models in the background if anything changed.
    func start() {
        guard isEnabled || cleansDictations else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))  // stay out of the way of launch
            refresh()
        }
    }

    /// Re-reads provider status, then measures models when the CLI engine needs it.
    func refresh() {
        Task {
            await refreshStatus()
            guard usesCLIs, !isMeasuring else { return }
            if isEnabled, engine == .cli, await picker.needsMeasurement(DictionaryLearnTask.self) {
                await measure(DictionaryLearnTask.self)
            }
            if cleansDictations, await picker.needsMeasurement(CleanupTask.self) {
                await measure(CleanupTask.self)
            }
        }
    }

    func refreshStatus() async {
        var statuses: [AssistProviderID: AssistAvailability] = [:]
        for (id, provider) in router.providers { statuses[id] = await provider.availability() }
        self.statuses = statuses
    }

    /// The Re-check models button.
    func recheckModels() {
        guard !isMeasuring else { return }
        Task {
            await refreshStatus()
            if isEnabled, engine == .cli { await measure(DictionaryLearnTask.self) }
            if cleansDictations { await measure(CleanupTask.self) }
        }
    }

    private func measure<T: AssistTask>(_ task: T.Type) async {
        isMeasuring = true
        defer { isMeasuring = false }
        await picker.pick(task)
        pick = router.picks.pick(for: DictionaryLearnTask.id)
        cleanupPick = router.picks.pick(for: CleanupTask.id)
    }

    /// The model cleanup will use next: the pin, its own measurement, or a borrowed one.
    var cleanupRoute: AssistRoute? {
        router.routes(for: CleanupTask.self, engine: .cli).first { !router.isBenched($0) }
    }

    /// Recording started: get the cleanup model's process running while the user speaks.
    func prepareCleanup() {
        router.warmUp(CleanupTask.self, engine: .cli)
    }

    /// Cleans one transcript chunk, applying the dictionary and snippets. At most two models are tried, so a stuck CLI costs the
    /// user one timeout, not one per model.
    func clean(_ transcript: String) async throws -> String {
        let options = AssistRouter.Options(engine: .cli, requiresSwitch: false, countsTowardCap: false, maxAttempts: 2)
        let input = CleanupTask.Input(transcript: transcript, vocabulary: cleanupVocabulary())
        let outcome = try await router.run(CleanupTask.self, input, options: options)
        lastRoute = outcome.route
        return outcome.output.text
    }

    /// True when Claude Code or Codex is installed and signed in, as of the last check.
    /// Unknown until the first check finishes, which counts as usable.
    var hasUsableCLI: Bool {
        let cli = [AssistProviderID.claude, .codex].compactMap { statuses[$0] }
        return cli.isEmpty || cli.contains(where: \.isUsable)
    }

    func run<T: AssistTask>(_ task: T.Type, _ input: T.Input) async throws -> AssistRouter.Outcome<T.Output> {
        defer { requestsToday = settings.requestsToday() }
        let outcome = try await router.run(task, input)
        lastRoute = outcome.route
        return outcome
    }

    /// Display name for a route, from the last measurement when it has one.
    func name(of route: AssistRoute) -> String {
        if route.provider == .apple { return "Apple Intelligence" }
        let measured = ([pick, cleanupPick].compactMap { $0 }.flatMap(\.measurements)).first { $0.route == route }?.name
        return "\(route.provider.title) \(measured ?? route.model ?? "default model")"
    }
}
