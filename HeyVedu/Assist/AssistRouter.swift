import Foundation

/// Picks where each AI Assist request goes and what happens when that fails.
///
/// Routes come from, in order: the user's pin, the model picker's measured chain, then each
/// CLI on its own default model. Errors are sorted the Hermes way (AI-ASSIST-PLAN §2):
/// - `unavailable`: skip the provider's other routes, no bench;
/// - `capacity`: bench the route for a few minutes, try the next;
/// - `modelRejected`: never try that route again this launch;
/// - `timeout`: try the next;
/// - `badOutput`, `cancelled`: stop; the feature falls back.
/// A route that fails `failuresBeforeBench` times in a row is benched until the next measurement.
final class AssistRouter {
    struct Outcome<Output> {
        var output: Output
        var route: AssistRoute
        var raw: AssistRawResult
    }

    static let benchDuration: Duration = .seconds(300)
    static let failuresBeforeBench = 3

    let providers: [AssistProviderID: any AssistProvider]
    let settings: AssistSettings
    let picks: AssistPickStore
    private let now: () -> ContinuousClock.Instant
    private var gates: [AssistProviderID: AsyncGate] = [:]
    private var benchedUntil: [String: ContinuousClock.Instant] = [:]
    private var rejected: Set<String> = []
    private var failures: [String: Int] = [:]
    private var benchedUntilRemeasure: Set<String> = []

    init(providers: [any AssistProvider] = [AppleIntelligenceProvider(), ClaudeCLIProvider(), CodexAppServerProvider()],
         settings: AssistSettings = .shared, picks: AssistPickStore = AssistPickStore(),
         now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.providers = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.settings = settings
        self.picks = picks
        self.now = now
    }

    /// How a feature calls the router.
    struct Options {
        /// Overrides the AI Assist engine setting, e.g. cleanup always uses the CLIs.
        var engine: AssistSettings.Engine?
        /// Needs the AI Assist switch on. Cleanup has its own opt-in (the cleanup engine).
        var requiresSwitch = true
        /// Counts against the daily cap. Cleanup doesn't: the user is waiting on it.
        var countsTowardCap = true
        /// Routes tried before giving up, so a waiting user isn't held for many timeouts.
        var maxAttempts = Int.max

        static let background = Options()
    }

    /// Every route worth trying for `task`, best first. Apple Intelligence never falls back
    /// to a CLI, so choosing it keeps every request on the Mac.
    func routes<T: AssistTask>(for task: T.Type, engine: AssistSettings.Engine? = nil) -> [AssistRoute] {
        if (engine ?? settings.engine) == .apple {
            return providers[.apple] == nil ? [] : [AssistRoute(provider: .apple)]
        }
        var chain: [AssistRoute] = []
        if let pin = settings.pinnedRoute(for: T.id) { chain.append(pin) }
        if let pick = picks.pick(for: T.id), pick.promptVersion == T.promptVersion {
            chain += pick.chain
        } else {
            // Not measured for this task yet: another task's measured order beats a CLI default.
            chain += picks.all.filter { $0.taskID != T.id }.sorted { $0.measuredAt > $1.measuredAt }.flatMap(\.chain)
        }
        // Nothing measured at all: each CLI on whatever model it defaults to.
        chain += [AssistProviderID.claude, .codex].filter { providers[$0] != nil }.map { AssistRoute(provider: $0) }
        var seen = Set<String>()
        return chain.filter { $0.provider != .apple && providers[$0.provider] != nil && seen.insert($0.key).inserted }
    }

    /// Runs `task` on the first route that works. Honors the master switch and daily cap.
    func run<T: AssistTask>(_ task: T.Type, _ input: T.Input, options: Options = .background) async throws -> Outcome<T.Output> {
        guard settings.isEnabled || !options.requiresSwitch else { throw AssistError.unavailable("AI Assist is off") }
        var lastError = AssistError.unavailable("No AI Assist provider is set up")
        var unavailable: Set<AssistProviderID> = []
        var attempts = 0
        for route in routes(for: task, engine: options.engine) where !unavailable.contains(route.provider) && !isBenched(route) {
            guard attempts < options.maxAttempts else { break }
            attempts += 1
            if options.countsTowardCap {
                guard settings.requestsToday() < settings.dailyCap else {
                    throw AssistError.capacity("Today's AI Assist limit is reached")
                }
                settings.countRequest()
            }
            do {
                let outcome = try await runOnce(task, input, route: route)
                failures[route.key] = 0
                return outcome
            } catch let error as AssistError {
                lastError = error
                switch error {
                case .unavailable:
                    unavailable.insert(route.provider)
                case .capacity:
                    benchedUntil[route.key] = now() + Self.benchDuration
                    noteFailure(route, task: task)
                case .modelRejected:
                    rejected.insert(route.key)
                case .timeout:
                    noteFailure(route, task: task)
                case .cancelled, .badOutput:
                    throw error
                }
            }
        }
        throw lastError
    }

    /// One request on exactly `route`: no fallback, bench, switch or cap. For the model
    /// picker and the self-test.
    func runOnce<T: AssistTask>(_ task: T.Type, _ input: T.Input, route: AssistRoute) async throws -> Outcome<T.Output> {
        guard let provider = providers[route.provider] else {
            throw AssistError.unavailable("\(route.provider.title) isn't available")
        }
        let call: AssistCall
        do { call = try self.call(for: task, input) } catch { throw AssistError.badOutput("Couldn't encode the request") }
        let gate = gate(for: route.provider)
        await gate.enter()
        defer { gate.leave() }
        let raw: AssistRawResult
        do {
            raw = try await provider.run(call, route: route)
        } catch let error as AssistError {
            DebugTrace.write("assist \(T.id) \(route.key) failed: \(Self.kind(of: error))")
            throw error
        } catch {
            throw AssistError.unavailable(error.localizedDescription)
        }
        guard let output = try? JSONDecoder().decode(T.Output.self, from: raw.json) else {
            throw AssistError.badOutput("The reply didn't match the schema")
        }
        guard let valid = T.validate(output, for: input) else {
            throw AssistError.badOutput("The reply failed validation")
        }
        DebugTrace.write("assist \(T.id) \(route.key) \(raw.latency) in=\(raw.inputTokens ?? -1) out=\(raw.outputTokens ?? -1)")
        return Outcome(output: valid, route: route, raw: raw)
    }

    /// Starts the process the first route will use, so the first request skips startup.
    func warmUp<T: AssistTask>(_ task: T.Type, engine: AssistSettings.Engine? = nil) {
        guard let route = routes(for: task, engine: engine).first(where: { !isBenched($0) }),
              let provider = providers[route.provider] else { return }
        provider.warmUp(AssistCall(system: T.systemPrompt, user: "", schema: T.schemaData, timeout: T.timeout), route: route)
    }

    /// A new measurement replaced the chains: give every route a fresh start.
    func picksChanged() {
        benchedUntilRemeasure = []
        failures = [:]
    }

    func shutdown() {
        providers.values.forEach { $0.shutdown() }
    }

    func isBenched(_ route: AssistRoute) -> Bool {
        if rejected.contains(route.key) || benchedUntilRemeasure.contains(route.key) { return true }
        if let until = benchedUntil[route.key], now() < until { return true }
        return false
    }

    private func noteFailure<T: AssistTask>(_ route: AssistRoute, task: T.Type) {
        let count = (failures[route.key] ?? 0) + 1
        failures[route.key] = count
        guard count >= Self.failuresBeforeBench else { return }
        benchedUntilRemeasure.insert(route.key)
        if picks.pick(for: T.id)?.chain.first == route { picks.markNeedsRemeasure(T.id) }
    }

    private func call<T: AssistTask>(for task: T.Type, _ input: T.Input) throws -> AssistCall {
        AssistCall(system: T.systemPrompt, user: try T.userMessage(for: input), schema: T.schemaData, timeout: T.timeout)
    }

    private func gate(for provider: AssistProviderID) -> AsyncGate {
        if let gate = gates[provider] { return gate }
        let gate = AsyncGate()
        gates[provider] = gate
        return gate
    }

    /// The error's case without its message, which can quote the request.
    static func kind(of error: AssistError) -> String {
        switch error {
        case .unavailable: "unavailable"
        case .capacity: "capacity"
        case .modelRejected: "modelRejected"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .badOutput: "badOutput"
        }
    }
}
