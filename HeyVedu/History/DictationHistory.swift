import Foundation
import Observation
import os

/// Opt-in record of past dictations. Off by default; while off nothing is written.
///
/// Stored only on this Mac, in `Application Support/HeyVedu/History.json`. Each entry keeps
/// every stage of the pipeline (raw transcript, the cleanup model's output, the text that
/// was pasted) so a dictation can later be attached to feedback or an issue report. The
/// History view shows only the pasted text and when it was dictated.
@Observable
final class DictationHistory {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        /// When the recording finished.
        var date: Date
        /// Seconds of audio transcribed, after silence was trimmed.
        var duration: TimeInterval
        /// Exactly what the speech model returned.
        var transcript: String
        /// The cleanup engine's raw output, before guards and polish; nil if no model ran.
        var modelOutput: String?
        /// The cleanup step's result, before snippets and the dictionary; nil if cleanup was off.
        var cleanedText: String?
        /// The cleanup engine used, e.g. "veduScribe"; nil if cleanup was off.
        var cleanupEngine: String?
        /// Why the raw transcript was used for some or all of the text, if it was.
        var fallbackReason: String?
        /// What was pasted.
        var finalText: String
    }

    /// User toggle; persisted. Turning it off deletes everything recorded so far.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { clear() }
        }
    }

    /// Newest first.
    private(set) var entries: [Entry]

    /// Oldest entries are dropped beyond this, so the file stays small.
    static let limit = 1000

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "com.heyvedu.app", category: "History")

    private static let enabledKey = "historyEnabled"

    init(fileURL: URL = DictationHistory.defaultFileURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        entries = enabled ? Self.load(from: fileURL) : []
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyVedu/History.json")
    }

    /// Adds a dictation if history is on; does nothing otherwise.
    func record(_ entry: Entry) {
        guard isEnabled else { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func delete(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Deletes every entry and the file itself.
    func clear() {
        entries = []
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            logger.error("Deleting history failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Readable by this user only.
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Never log the text itself.
            logger.error("Saving history failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
