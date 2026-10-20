import AppKit
import Observation

/// Short sounds for starting, finishing and cancelling a dictation. Off by default.
@Observable
final class SoundCues {
    enum Cue: String {
        case start
        case stop
        case cancel
    }

    /// A set of start, finish and cancel sounds: HeyVedu's own, shipped in the app, or
    /// built from macOS system sounds.
    enum Theme: String, CaseIterable, Identifiable {
        case soft
        case glass
        case wood
        case bubble
        case bell
        case kalimba
        case airy
        case classic
        case bright

        var id: String { rawValue }

        var title: String {
            switch self {
            case .soft: return "Soft"
            case .glass: return "Glass"
            case .wood: return "Wood"
            case .bubble: return "Bubble"
            case .bell: return "Bell"
            case .kalimba: return "Kalimba"
            case .airy: return "Airy"
            case .classic: return "Classic (macOS)"
            case .bright: return "Bright (macOS)"
            }
        }

        fileprivate func sound(for cue: Cue) -> NSSound? {
            switch self {
            case .soft, .glass, .wood, .bubble, .bell, .kalimba, .airy:
                guard let url = Bundle.main.url(forResource: "\(rawValue)-\(cue.rawValue)", withExtension: "caf") else { return nil }
                return NSSound(contentsOf: url, byReference: true)
            case .classic, .bright:
                return NSSound(named: systemName(for: cue))
            }
        }

        private func systemName(for cue: Cue) -> NSSound.Name {
            switch (self, cue) {
            case (.bright, .start): return "Ping"
            case (.bright, .stop): return "Glass"
            case (.bright, .cancel): return "Funk"
            case (_, .start): return "Tink"
            case (_, .stop): return "Pop"
            case (_, .cancel): return "Bottle"
            }
        }
    }

    var isEnabled = UserDefaults.standard.bool(forKey: SoundCues.key) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.key) }
    }

    var theme = UserDefaults.standard.string(forKey: SoundCues.themeKey).flatMap(Theme.init(rawValue:)) ?? .bell {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    /// Quiet, since the start cue plays while the microphone is already open.
    private static let volume: Float = 0.2
    private static let key = "soundCuesEnabled"
    private static let themeKey = "soundCueTheme"

    @ObservationIgnored private var cache: [String: NSSound] = [:]

    func play(_ cue: Cue) {
        guard isEnabled else { return }
        preview(cue)
    }

    /// Plays the theme's start, finish and cancel cues one after another.
    func previewAll() {
        Task {
            for cue in [Cue.start, .stop, .cancel] {
                preview(cue)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    /// Plays a cue of the current theme even when sounds are off, for trying themes out.
    func preview(_ cue: Cue = .start) {
        let key = "\(theme.rawValue)-\(cue.rawValue)"
        guard let sound = cache[key] ?? theme.sound(for: cue) else { return }
        cache[key] = sound
        // Restart it if the previous cue is still playing.
        sound.stop()
        sound.volume = Self.volume
        sound.play()
    }
}
