import CryptoKit
import Foundation

/// Chooses the model chain for a task by discovery and measurement, with no model names in
/// the code (AI-ASSIST-PLAN §3.3):
/// 1. discover models live from each signed-in CLI;
/// 2. drop hidden, specialty and extra-paid models, and merge aliases;
/// 3. ask a CLI, on its default model, to rank them for the task (keyword hints if that fails);
/// 4. measure the top few per CLI on the task's probes with a warm process;
/// 5. the highest-ranked model that passes is the default: the cheapest family, newest
///    version (user decision, 2026-10-15; it replaced "fastest wins").
final class AssistModelPicker {
    struct Measurement: Codable, Hashable {
        var route: AssistRoute
        var name: String
        var passed = 0
        var total = 0
        /// Median latency in seconds, first (cold) call left out.
        var typical: Double?
        var worst: Double?
        var inputTokens: Int?
        var costUSD: Double?
        var error: String?
        /// Position in the ranker's order, cheapest first.
        var rank: Int?

        /// The quality bar: at most one miss per round of probes.
        var passes: Bool { error == nil && total > 0 && passed >= total - AssistModelPicker.rounds }
    }

    static let measuredPerProvider = 3
    /// Bumped when the choosing rule changes, so saved picks are made again.
    static let version = 2
    /// Each probe runs this many times. One round gave 3 warm timings per model, too few to
    /// tell Haiku from Sonnet (1.3 s vs 2.4 s one run, the reverse the next).
    static let rounds = 2

    let router: AssistRouter
    private let log: (String) -> Void

    init(router: AssistRouter, log: @escaping (String) -> Void = { _ in }) {
        self.router = router
        self.log = log
    }

    /// The whole picker: discover, rank, measure, choose, save. Nil when no CLI is usable.
    @discardableResult
    func pick<T: AssistTask>(_ task: T.Type) async -> AssistPick? {
        let (found, versions) = await discover()
        let pool = Self.candidates(found)
        log("Discovered \(found.count) models, \(pool.count) usable")
        guard !pool.isEmpty else { return nil }

        let (order, rankedBy) = await rank(pool, hint: T.rankingHint)
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var measured: [Measurement] = []
        for provider in AssistProviderID.allCases {
            let mine = pool.filter { $0.provider == provider }
                .sorted { position[$0.route.key, default: .max] < position[$1.route.key, default: .max] }
            guard !mine.isEmpty else { continue }
            log("\(provider.title): " + mine.map(\.displayName).joined(separator: ", "))
            for model in mine.prefix(Self.measuredPerProvider) {
                var measurement = await measure(task, model)
                measurement.rank = position[model.route.key]
                log(Self.describe(measurement))
                measured.append(measurement)
            }
        }
        let chain = Self.choose(measured)
        let pick = AssistPick(taskID: T.id, promptVersion: T.promptVersion, measuredAt: .now,
                              cliVersions: versions, modelListHash: Self.hash(found), rankedBy: rankedBy,
                              chain: chain.map(\.route), measurements: measured, pickerVersion: Self.version)
        router.picks.save(pick)
        router.picksChanged()
        log("Chosen: " + (chain.isEmpty ? "none passed" : chain.map(\.name).joined(separator: ", ")))
        return pick
    }

    /// Whether `task` should be measured again: a CLI's version or model list changed, a
    /// week passed, the chosen model kept failing, or it was never measured.
    func needsMeasurement<T: AssistTask>(_ task: T.Type, now: Date = .now) async -> Bool {
        guard let pick = router.picks.pick(for: T.id) else { return true }
        let (found, versions) = await discover()
        return pick.isStale(promptVersion: T.promptVersion, versions: versions, modelListHash: Self.hash(found), now: now)
    }

    // MARK: - 1. Discover

    func discover() async -> (models: [AssistModel], versions: [String: String]) {
        var models: [AssistModel] = []
        var versions: [String: String] = [:]
        for id in AssistProviderID.allCases {
            guard let provider = router.providers[id], !provider.isLocal else { continue }
            let availability = await provider.availability()
            guard availability.isUsable else {
                log("\(id.title): \(availability)")
                continue
            }
            versions[id.rawValue] = availability.version ?? "unknown"
            do { models += try await provider.models() } catch { log("\(id.title) model list failed: \(error)") }
        }
        return (models, versions)
    }

    // MARK: - 2. Filter

    private static let paidPattern = try! Regex("(?i)requires (usage )?credits|extra usage")

    static func isUsable(_ model: AssistModel) -> Bool {
        !model.hidden && model.specialty == nil && model.description.firstMatch(of: paidPattern) == nil
    }

    /// Usable models with aliases merged. CLIs list their "default" alias first, so the later,
    /// named entry for the same model is kept.
    static func candidates(_ models: [AssistModel]) -> [AssistModel] {
        var kept: [AssistModel] = []
        for model in models where isUsable(model) {
            kept.removeAll { $0.provider == model.provider && $0.resolvedID == model.resolvedID
                             && $0.serviceTier == model.serviceTier }
            kept.append(model)
        }
        return kept
    }

    // MARK: - 3. Rank

    /// Route keys best first, and who ranked them ("claude", "codex" or "keywords").
    func rank(_ pool: [AssistModel], hint: String) async -> (order: [String], rankedBy: String) {
        let known = pool.map(\.route.key)
        let input = ModelRankTask.Input(task: hint, models: pool.map {
            ModelRankTask.Listing(id: $0.route.key, name: $0.displayName, description: $0.description, efforts: $0.efforts)
        })
        // Claude ranks in seconds; Codex took 40 s. Either is fine since ranking is rare.
        for ranker in [AssistProviderID.claude, .codex] where router.providers[ranker] != nil
            && pool.contains(where: { $0.provider == ranker }) {
            let started = ContinuousClock.now
            do {
                let outcome = try await router.runOnce(ModelRankTask.self, input, route: AssistRoute(provider: ranker))
                log(String(format: "Ranked by %@ in %.1f s", ranker.title, started.duration(to: .now).seconds))
                for item in outcome.output.ranked.prefix(8) { log("   \(item.id): \(item.reason)") }
                return (Self.mergeRanking(outcome.output.ranked.map(\.id), known: known), ranker.rawValue)
            } catch {
                log("Ranking by \(ranker.title) failed (\(error)); trying the next")
            }
        }
        log("Ranking by keywords")
        return (Self.keywordOrder(pool), "keywords")
    }

    /// The ranker's order, limited to ids we listed, without duplicates, with anything it left
    /// out appended in listing order.
    static func mergeRanking(_ ranked: [String], known: [String]) -> [String] {
        let knownSet = Set(known)
        var seen = Set<String>()
        let ordered = ranked.filter { knownSet.contains($0) && seen.insert($0).inserted }
        return ordered + known.filter { !seen.contains($0) }
    }

    private static let fastWords = try! Regex("(?i)\\b(fast(est)?|quick|affordable|efficient|cheap|lightweight|routine)\\b")
    private static let slowWords = try! Regex("(?i)\\b(frontier|most capable|hardest|demanding|complex|longest)\\b")
    private static let olderWords = try! Regex("(?i)\\b(older|previous)\\b")
    private static let usageMultiplier = try! Regex("(?i)~?(\\d+(?:\\.\\d+)?)\\s*[×x]\\s*usage")

    /// Fallback ranking from the CLI's own descriptions.
    static func keywordScore(_ model: AssistModel) -> Double {
        let text = model.description
        var score = 2.0 * Double(text.matches(of: fastWords).count) - 2.0 * Double(text.matches(of: slowWords).count)
        if text.firstMatch(of: olderWords) != nil { score -= 0.5 }
        if let match = text.firstMatch(of: usageMultiplier), let number = match.output[1].substring.flatMap({ Double($0) }) {
            score -= number
        }
        return score
    }

    static func keywordOrder(_ pool: [AssistModel]) -> [String] {
        pool.enumerated()
            .sorted { (keywordScore($0.element), -$0.offset) > (keywordScore($1.element), -$1.offset) }
            .map(\.element.route.key)
    }

    // MARK: - 4. Measure

    func measure<T: AssistTask>(_ task: T.Type, _ model: AssistModel) async -> Measurement {
        let route = model.route
        var measurement = Measurement(route: route, name: model.displayName, total: T.probes.count * Self.rounds)
        router.providers[route.provider]?.warmUp(
            AssistCall(system: T.systemPrompt, user: "", schema: T.schemaData, timeout: T.timeout), route: route)
        try? await Task.sleep(for: .seconds(2))  // measure a warm process, as the app uses it
        var latencies: [Double] = [], tokens: [Int] = [], costs: [Double] = []
        probes: for probe in Array(repeating: T.probes, count: Self.rounds).joined() {
            do {
                let outcome = try await router.runOnce(task, probe.input, route: route)
                latencies.append(outcome.raw.latency.seconds)
                if let input = outcome.raw.inputTokens { tokens.append(input) }
                if let cost = outcome.raw.costUSD { costs.append(cost) }
                if probe.passes(outcome.output) { measurement.passed += 1 }
            } catch AssistError.badOutput {
                continue  // a wrong answer, not a broken route
            } catch AssistError.timeout {
                continue  // one slow answer counts as a miss; the quality bar decides
            } catch {
                measurement.error = "\(error)"
                break probes
            }
        }
        let warm = latencies.count > 1 ? Array(latencies.dropFirst()) : latencies
        measurement.typical = Self.median(warm)
        measurement.worst = latencies.max()
        measurement.inputTokens = Self.median(tokens.map(Double.init)).map { Int($0) }
        measurement.costUSD = costs.isEmpty ? nil : costs.reduce(0, +) / Double(costs.count)
        return measurement
    }

    // MARK: - 5. Choose

    /// Passing measurements in the ranker's order: the cheapest model family first, its
    /// newest version first (Haiku 5.5 before Haiku 4.5, GPT-6-Luna before GPT-5.6-Luna).
    /// The first is the default; the user can pick any other in AI Assist.
    static func choose(_ measurements: [Measurement]) -> [Measurement] {
        measurements.filter(\.passes).enumerated().sorted { lhs, rhs in
            (lhs.element.rank ?? .max, lhs.offset) < (rhs.element.rank ?? .max, rhs.offset)
        }.map(\.element)
    }

    // MARK: - Helpers

    static func hash(_ models: [AssistModel]) -> String {
        let keys = models.map { "\($0.route.key)=\($0.resolvedID)" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(keys.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func describe(_ m: Measurement) -> String {
        if let error = m.error { return "\(m.route.key): error \(error)" }
        let seconds = { (value: Double?) in value.map { String(format: "%.2f s", $0) } ?? "–" }
        let cost = m.costUSD.map { String(format: "$%.5f", $0) } ?? "cost not reported"
        return "\(m.route.key) [\(m.route.effort ?? "default")]: \(m.passed)/\(m.total) · typical \(seconds(m.typical)) · worst \(seconds(m.worst)) · \(m.inputTokens ?? 0) input tokens · \(cost)"
    }
}

/// The result of one measurement, saved per task.
struct AssistPick: Codable, Equatable {
    var taskID: String
    var promptVersion: Int
    var measuredAt: Date
    var cliVersions: [String: String]
    var modelListHash: String
    var rankedBy: String
    var chain: [AssistRoute]
    var measurements: [AssistModelPicker.Measurement]
    /// Set when the chosen model failed `AssistRouter.failuresBeforeBench` times in a row.
    var needsRemeasure = false
    /// `AssistModelPicker.version` that chose `chain`; nil for picks made before it existed.
    var pickerVersion: Int?

    static let maxAge: TimeInterval = 7 * 24 * 3600

    func isStale(promptVersion: Int, versions: [String: String], modelListHash: String, now: Date = .now) -> Bool {
        needsRemeasure || (pickerVersion ?? 1) != AssistModelPicker.version
            || promptVersion != self.promptVersion || versions != cliVersions
            || modelListHash != self.modelListHash || now.timeIntervalSince(measuredAt) > Self.maxAge
    }
}

/// Saved picks, `Application Support/HeyVedu/Assist/ModelPicks.json`. Model names and
/// timings only.
final class AssistPickStore {
    private let fileURL: URL?
    private var picks: [String: AssistPick]

    /// A nil URL keeps picks in memory only (tests).
    init(fileURL: URL? = AssistPaths.picksFile) {
        self.fileURL = fileURL
        let data = fileURL.flatMap { try? Data(contentsOf: $0) }
        picks = data.flatMap { try? Self.decoder.decode([String: AssistPick].self, from: $0) } ?? [:]
    }

    func pick(for taskID: String) -> AssistPick? { picks[taskID] }

    var all: [AssistPick] { Array(picks.values) }

    func save(_ pick: AssistPick) {
        picks[pick.taskID] = pick
        write()
    }

    func markNeedsRemeasure(_ taskID: String) {
        guard picks[taskID]?.needsRemeasure == false else { return }
        picks[taskID]?.needsRemeasure = true
        write()
    }

    private func write() {
        guard let fileURL, let data = try? Self.encoder.encode(picks) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Asks a CLI's default model to order candidate models for a task (§3.3 step 3).
nonisolated enum ModelRankTask: AssistTask {
    struct Listing: Codable, Equatable {
        var id: String
        var name: String
        var description: String
        var efforts: [String]
    }

    struct Input: Encodable {
        var task: String
        var models: [Listing]
    }

    struct Item: Codable, Equatable {
        var id: String
        var reason: String
    }

    struct Output: Codable, Equatable {
        var ranked: [Item]
    }

    static let id = "models.rank"
    static let promptVersion = 1
    static let timeout: Duration = .seconds(120)
    static let dataSent = AssistDataClass.modelList
    static let rankingHint = ""
    static let probes: [AssistProbe<Self>] = []

    static let systemPrompt = """
        You rank AI models for a job in a dictation app. "task" describes the job; "models" \
        lists the candidates with their names, descriptions and effort levels. Use what you \
        know about these model families plus what is given. Return every id exactly once, \
        cheapest first: the lowest-cost model family that can do the job leads. Within one \
        family, put the newest version first (a 5.5 before a 4.5, a 6 before a 5.6). A paid \
        speed tier ("Fast", "priority", more usage) goes after every standard-tier model of \
        the cheaper families. Give each a one-line reason. Reply only with JSON matching the \
        schema.
        """

    static var outputSchema: [String: Any] {
        [
            "type": "object", "additionalProperties": false, "required": ["ranked"],
            "properties": [
                "ranked": [
                    "type": "array",
                    "items": [
                        "type": "object", "additionalProperties": false, "required": ["id", "reason"],
                        "properties": ["id": ["type": "string"], "reason": ["type": "string"]],
                    ],
                ],
            ],
        ]
    }

    static func validate(_ output: Output, for input: Input) -> Output? {
        let known = Set(input.models.map(\.id))
        let ranked = output.ranked.filter { known.contains($0.id) }
        return ranked.isEmpty ? nil : Output(ranked: ranked)
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
