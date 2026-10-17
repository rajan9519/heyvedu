import Foundation
import Observation

/// The tone the user wants for each destination. Defaults to `Destination.defaultTone`:
/// formal for email and work chat (grammar, spelling and "gonna"-style reductions fixed
/// with the smallest edit), casual elsewhere (the way the user talks). Only choices that
/// differ from the default are stored, so a later change of default reaches users who never
/// picked one.
@Observable
final class WritingStyle {
    private(set) var tones: [Destination: CleanupContext.Tone]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tones = Dictionary(uniqueKeysWithValues: Destination.allCases.compactMap { destination in
            defaults.string(forKey: Self.key(for: destination))
                .flatMap(CleanupContext.Tone.init(rawValue:))
                .map { (destination, $0) }
        })
    }

    func tone(for destination: Destination) -> CleanupContext.Tone {
        tones[destination] ?? destination.defaultTone
    }

    /// Picking the default again forgets the choice.
    func setTone(_ tone: CleanupContext.Tone, for destination: Destination) {
        if tone == destination.defaultTone {
            tones[destination] = nil
            defaults.removeObject(forKey: Self.key(for: destination))
        } else {
            tones[destination] = tone
            defaults.set(tone.rawValue, forKey: Self.key(for: destination))
        }
    }

    /// How to write a dictation going to `destination`.
    func context(for destination: Destination) -> CleanupContext {
        CleanupContext(format: destination.format, tone: tone(for: destination))
    }

    private static func key(for destination: Destination) -> String {
        "tone.\(destination.rawValue)"
    }
}

extension Destination {
    /// Settings label.
    var title: String {
        switch self {
        case .email: return "Email"
        case .workChat: return "Work chat"
        case .personalChat: return "Personal chat"
        case .notes: return "Notes"
        case .other: return "Other apps"
        }
    }

    var examples: String {
        switch self {
        case .email: return "Mail, Outlook, Gmail"
        case .workChat: return "Slack, Teams, Google Chat"
        case .personalChat: return "Messages, WhatsApp, Discord, Telegram"
        case .notes: return "Notes, Notion, Obsidian, Reminders"
        case .other: return "Everything else, including code editors"
        }
    }
}

extension CleanupContext.Tone {
    var title: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        }
    }
}
