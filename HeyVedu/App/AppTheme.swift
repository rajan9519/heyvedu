import AppKit

/// Light or dark appearance for HeyVedu's windows, or following macOS.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    private static let key = "appTheme"

    static var saved: AppTheme {
        UserDefaults.standard.string(forKey: key).flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }

    /// Sets the appearance app-wide, so every window (and its sheets and alerts) follows it.
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
