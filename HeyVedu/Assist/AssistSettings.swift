import Foundation

/// AI Assist preferences (UserDefaults). Everything is off until the user turns it on.
final class AssistSettings {
    static let shared = AssistSettings()

    private let defaults: UserDefaults
    private static let enabledKey = "assist.enabled"
    private static let dailyCapKey = "assist.dailyCap"
    private static let pinnedRoutesKey = "assist.pinnedRoutes"
    private static let usageKey = "assist.usage"
    private static let engineKey = "assist.engine"

    /// Where requests go. Apple Intelligence keeps everything on the Mac, so it's the default.
    enum Engine: String, CaseIterable, Identifiable {
        case apple
        /// The user's Claude Code or Codex sign-in, on the model the picker measured fastest.
        case cli

        var id: Self { self }

        var title: String {
            switch self {
            case .apple: "Apple Intelligence (on this Mac)"
            case .cli: "Claude Code or Codex"
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Master switch, off by default.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var engine: Engine {
        get { defaults.string(forKey: Self.engineKey).flatMap(Engine.init(rawValue:)) ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: Self.engineKey) }
    }

    var dailyCap: Int {
        get { defaults.object(forKey: Self.dailyCapKey) as? Int ?? 50 }
        set { defaults.set(newValue, forKey: Self.dailyCapKey) }
    }

    /// A route the user chose instead of the picker's. Key "default" applies to every task
    /// without its own pin (Hermes-style inheritance).
    func pinnedRoute(for taskID: String) -> AssistRoute? {
        let pins = pinnedRoutes
        return pins[taskID] ?? pins["default"]
    }

    func setPinnedRoute(_ route: AssistRoute?, for taskID: String) {
        var pins = pinnedRoutes
        pins[taskID] = route
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: Self.pinnedRoutesKey) }
    }

    private var pinnedRoutes: [String: AssistRoute] {
        guard let data = defaults.data(forKey: Self.pinnedRoutesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: AssistRoute].self, from: data)) ?? [:]
    }

    // MARK: - Daily usage (counts only)

    func requestsToday(now: Date = .now) -> Int {
        guard let usage = defaults.dictionary(forKey: Self.usageKey),
              usage["day"] as? String == Self.day(now) else { return 0 }
        return usage["count"] as? Int ?? 0
    }

    func countRequest(now: Date = .now) {
        defaults.set(["day": Self.day(now), "count": requestsToday(now: now) + 1], forKey: Self.usageKey)
    }

    private static func day(_ date: Date) -> String {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }
}
