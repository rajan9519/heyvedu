#if DEBUG
import Foundation

/// Debug harness for AI Assist (AI-ASSIST-PLAN §3.5). Prints only canned golden-set text.
///
/// - `HeyVedu --assist-selftest dictionary.learn [claude|codex] [model] [effort]` runs the golden
///   set on one route and prints precision, recall and p50/p95 latency. With no provider it
///   uses the first route the router would pick.
/// - `HeyVedu --assist-selftest dictionary.learn pick` runs the model picker and saves its choice;
///   `--assist-selftest dictation.cleanup pick` does the same for cleanup, whose quality is
///   then checked with `--cleanup-selftest assist`.
/// - `--golden <path>` reads another golden file.
enum AssistSelfTest {
    static let flag = "--assist-selftest"

    struct GoldenCase: Decodable {
        struct Pair: Decodable, Hashable {
            var heard: String
            var term: String
        }

        var pasted: String
        var edited: String
        var expected: [Pair]
        var note: String?
    }

    static let defaultGoldenFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("HeyVeduTests/Fixtures/assist/dictionary-learn.jsonl")

    static func loadGolden(_ url: URL = defaultGoldenFile) throws -> [GoldenCase] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(GoldenCase.self, from: Data($0.utf8))
        }
    }

    static func run() async {
        var arguments = Array(CommandLine.arguments.drop { $0 != flag }.dropFirst())
        var goldenFile = defaultGoldenFile
        if let index = arguments.firstIndex(of: "--golden"), index + 1 < arguments.count {
            goldenFile = URL(fileURLWithPath: arguments[index + 1])
            arguments.removeSubrange(index...index + 1)
        }
        var parallel = 1
        if let index = arguments.firstIndex(of: "--parallel"), index + 1 < arguments.count {
            parallel = max(1, Int(arguments[index + 1]) ?? 1)
            arguments.removeSubrange(index...index + 1)
        }
        // A prompt variant to benchmark instead of `CleanupTask.systemPrompt`.
        var systemOverride: String?
        if let index = arguments.firstIndex(of: "--system-file"), index + 1 < arguments.count {
            systemOverride = try? String(contentsOf: URL(fileURLWithPath: arguments[index + 1]), encoding: .utf8)
            arguments.removeSubrange(index...index + 1)
        }
        let router = AssistRouter()
        defer { router.shutdown() }
        if arguments.first == CleanupTask.id, arguments.dropFirst().first == "run", arguments.count >= 4 {
            await runCleanupBenchmark(input: arguments[2], output: arguments[3], router: router, parallel: parallel,
                                      system: systemOverride,
                                      route: arguments.count > 4 ? AssistProviderID(rawValue: arguments[4]).map {
                                          AssistRoute(provider: $0, model: arguments.count > 5 ? arguments[5] : nil,
                                                      effort: arguments.count > 6 ? arguments[6] : nil)
                                      } : nil)
            return
        }
        if arguments.first == CleanupTask.id, arguments.dropFirst().first == "pick" {
            let started = ContinuousClock.now
            await AssistModelPicker(router: router) { print($0) }.pick(CleanupTask.self)
            print(String(format: "Picker finished in %.0f s", started.duration(to: .now).seconds))
            return
        }
        guard arguments.first == DictionaryLearnTask.id else {
            print("Usage: --assist-selftest \(DictionaryLearnTask.id) [pick | claude|codex [model] [effort]] [--golden path]")
            print("       --assist-selftest \(CleanupTask.id) pick")
            print("       --assist-selftest \(CleanupTask.id) run <in.jsonl> <out.jsonl> [claude|codex [model] [effort]] [--parallel N]")
            return
        }
        if arguments.dropFirst().first == "pick" {
            let started = ContinuousClock.now
            await AssistModelPicker(router: router) { print($0) }.pick(DictionaryLearnTask.self)
            print(String(format: "Picker finished in %.0f s; saved to %@", started.duration(to: .now).seconds, AssistPaths.picksFile.path))
            return
        }
        var route = router.routes(for: DictionaryLearnTask.self).first ?? AssistRoute(provider: .claude)
        if let name = arguments.dropFirst().first, let provider = AssistProviderID(rawValue: name) {
            let rest = Array(arguments.dropFirst(2))
            route = AssistRoute(provider: provider, model: rest.first, effort: rest.dropFirst().first)
        }
        let golden: [GoldenCase]
        do { golden = try loadGolden(goldenFile) } catch {
            print("Couldn't read \(goldenFile.path): \(error)")
            return
        }
        await evaluate(golden, on: route, router: router)
    }

    /// Cleans every row of a benchmark file (`id`, `raw`, plus anything else, copied through)
    /// exactly as the app would, and writes `pred` and `latency_ms` per row in the format of
    /// local-dictation-cleanup-training's `eval/score.py`. Resumable: ids already in `output`
    /// are skipped. A failed row gets the raw transcript, as the app would paste, and `error`.
    /// `parallel` workers each run their own CLI process, as that many app instances would.
    private static func runCleanupBenchmark(input: String, output: String, router: AssistRouter, parallel: Int,
                                            system: String?, route: AssistRoute?) async {
        guard let route = route ?? router.routes(for: CleanupTask.self, engine: .cli).first else {
            print("No Claude Code or Codex route")
            return
        }
        let lines = (try? String(contentsOf: URL(fileURLWithPath: input), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let done = Set(((try? String(contentsOf: URL(fileURLWithPath: output), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"] as? String
            })
        if !FileManager.default.fileExists(atPath: output) { FileManager.default.createFile(atPath: output, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: output) else { return print("Can't write \(output)") }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let queue = BenchmarkQueue(rows: lines.compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, row["raw"] is String, !done.contains(id) else { return nil }
            return row
        }, handle: handle, total: lines.count, alreadyDone: done.count)
        print("Route: \(route.key) effort \(route.effort ?? "default") · \(lines.count) rows, \(done.count) already done · \(parallel) at once")
        let settings = AssistSettings(defaults: UserDefaults(suiteName: "HeyVeduBenchmark") ?? .standard)
        let workers = (0..<parallel).map { _ in
            AssistRouter(providers: [route.provider == .codex ? CodexAppServerProvider() : ClaudeCLIProvider()],
                         settings: settings, picks: AssistPickStore(fileURL: nil))
        }
        await withTaskGroup(of: Void.self) { group in
            for worker in workers {
                group.addTask { await work(worker, route: route, system: system, queue: queue) }
            }
        }
        workers.forEach { $0.shutdown() }
        print("Done: \(queue.written) new rows, \(queue.failures) failed")
    }

    private static func work(_ worker: AssistRouter, route: AssistRoute, system: String?, queue: BenchmarkQueue) async {
        while let row = queue.next() {
            let started = ContinuousClock.now
            var result = row
            let input = CleanupTask.Input(transcript: row["raw"] as? String ?? "")
            do {
                if let system, let provider = worker.providers[route.provider] {
                    // Same call as the app makes, with only the system prompt swapped.
                    let call = AssistCall(system: system, user: try CleanupTask.userMessage(for: input),
                                          schema: CleanupTask.schemaData, timeout: CleanupTask.timeout)
                    let raw = try await provider.run(call, route: route)
                    let output = try JSONDecoder().decode(CleanupTask.Output.self, from: raw.json)
                    result["pred"] = CleanupTask.validate(output, for: input)?.text ?? ""
                } else {
                    result["pred"] = try await worker.runOnce(CleanupTask.self, input, route: route).output.text
                }
            } catch {
                result["pred"] = row["raw"]
                result["error"] = "\(error)"
            }
            result["latency_ms"] = (started.duration(to: .now).seconds * 1000).rounded()
            result["model"] = route.key
            queue.write(result)
        }
    }

    /// Hands rows to the parallel workers and appends their results, one line each.
    private final class BenchmarkQueue {
        private var rows: [[String: Any]]
        private var index = 0
        private let handle: FileHandle
        private let total: Int
        private let alreadyDone: Int
        private(set) var written = 0
        private(set) var failures = 0

        init(rows: [[String: Any]], handle: FileHandle, total: Int, alreadyDone: Int) {
            self.rows = rows
            self.handle = handle
            self.total = total
            self.alreadyDone = alreadyDone
        }

        func next() -> [String: Any]? {
            guard index < rows.count else { return nil }
            defer { index += 1 }
            return rows[index]
        }

        func write(_ row: [String: Any]) {
            if row["error"] != nil { failures += 1 }
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.withoutEscapingSlashes]) {
                handle.write(data + Data("\n".utf8))
            }
            written += 1
            if written % 100 == 0 { print("\(written + alreadyDone)/\(total) · \(failures) failed") }
        }
    }

    private static func evaluate(_ golden: [GoldenCase], on route: AssistRoute, router: AssistRouter) async {
        print("Route: \(route.key) effort \(route.effort ?? "default") · \(golden.count) cases")
        router.providers[route.provider]?.warmUp(
            AssistCall(system: DictionaryLearnTask.systemPrompt, user: "", schema: DictionaryLearnTask.schemaData,
                       timeout: DictionaryLearnTask.timeout), route: route)
        try? await Task.sleep(for: .seconds(2))
        var truePositives = 0, falsePositives = 0, falseNegatives = 0, failures = 0
        var latencies: [Double] = [], tokens = 0, cost: Double?
        for (index, item) in golden.enumerated() {
            let input = DictionaryLearnTask.Input(edits: [.init(pasted: item.pasted, edited: item.edited)])
            let expected = Set(item.expected.map(\.term))
            do {
                let outcome = try await router.runOnce(DictionaryLearnTask.self, input, route: route)
                latencies.append(outcome.raw.latency.seconds)
                tokens += outcome.raw.inputTokens ?? 0
                if let callCost = outcome.raw.costUSD { cost = (cost ?? 0) + callCost }
                let got = Set(outcome.output.suggestions.map(\.term))
                truePositives += got.intersection(expected).count
                falsePositives += got.subtracting(expected).count
                falseNegatives += expected.subtracting(got).count
                let mark = got == expected ? "✓" : "✗"
                let pairs = outcome.output.suggestions.map { "\($0.heard)→\($0.term)" }.joined(separator: ", ")
                print(String(format: "%@ %2d  %.2f s  got [%@]", mark, index + 1, outcome.raw.latency.seconds, pairs)
                      + (got == expected ? "" : "  expected [\(expected.sorted().joined(separator: ", "))]"))
            } catch {
                failures += 1
                falseNegatives += expected.count
                print("! \(index + 1)  \(error)")
            }
        }
        let precision = truePositives + falsePositives == 0 ? 1 : Double(truePositives) / Double(truePositives + falsePositives)
        let recall = truePositives + falseNegatives == 0 ? 1 : Double(truePositives) / Double(truePositives + falseNegatives)
        let sorted = latencies.sorted()
        let p50 = AssistModelPicker.median(sorted) ?? 0
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        let costText = cost.map { String(format: "$%.4f", $0) } ?? "cost not reported"
        print(String(format: "\nprecision %.2f · recall %.2f · p50 %.2f s · p95 %.2f s · %d failed · %d input tokens · %@",
                     precision, recall, p50, p95, failures, tokens, costText))
    }
}
#endif
