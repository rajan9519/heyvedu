import AppKit
import Observation

/// Short system sounds for starting, finishing and cancelling a dictation. Off by default.
@Observable
final class SoundCues {
    enum Cue {
        case start
        case stop
        case cancel

        fileprivate var soundName: NSSound.Name {
            switch self {
            case .start: return "Tink"
            case .stop: return "Pop"
            case .cancel: return "Bottle"
            }
        }
    }

    var isEnabled = UserDefaults.standard.bool(forKey: SoundCues.key) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.key) }
    }

    /// Quiet, since the start cue plays while the microphone is already open.
    private static let volume: Float = 0.3
    private static let key = "soundCuesEnabled"

    func play(_ cue: Cue) {
        guard isEnabled, let sound = NSSound(named: cue.soundName) else { return }
        // NSSound(named:) is shared; restart it if the previous cue is still playing.
        sound.stop()
        sound.volume = Self.volume
        sound.play()
    }
}
