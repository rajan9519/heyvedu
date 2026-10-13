import Foundation
import Observation
import os

/// Daily dictation counts behind the Home page's numbers and activity calendar.
///
/// Always on, because it never holds any text: only, per day, how many dictations were
/// pasted, how many words they had and how many seconds of speech they took. Stored on
/// this Mac in `Application Support/HeyVedu/Stats.json`.
@Observable
final class DictationStats {
    struct Day: Codable, Equatable {
        var dictations = 0
        var words = 0
        /// Seconds of speech, after silence was trimmed.
        var seconds: TimeInterval = 0
    }

    /// Typing speed the "time saved" figure compares against.
    static let typingWordsPerMinute = 45.0

    /// Keyed by local calendar day, "yyyy-MM-dd".
    private(set) var days: [String: Day]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let logger = Logger(subsystem: "com.heyvedu.app", category: "Stats")

    init(fileURL: URL = DictationStats.defaultFileURL, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
        days = Self.load(from: fileURL)
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyVedu/Stats.json")
    }

    /// Counts a pasted dictation. Only the word count of `text` is kept.
    func record(_ text: String, duration: TimeInterval, date: Date = .now) {
        guard add(words: Self.wordCount(text), duration: duration, on: date) else { return }
        save()
    }

    /// Counts dictations saved before stats existed, once, so Home isn't empty for people
    /// who already kept a history. Later calls do nothing.
    func importOnce(_ entries: [DictationHistory.Entry], defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.importedKey) else { return }
        defaults.set(true, forKey: Self.importedKey)
        guard days.isEmpty, !entries.isEmpty else { return }
        for entry in entries {
            add(words: Self.wordCount(entry.finalText), duration: entry.duration, on: entry.date)
        }
        save()
    }

    private static let importedKey = "statsImportedHistory"

    /// Deletes every count and the file itself.
    func reset() {
        days = [:]
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            logger.error("Deleting stats failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Figures

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalDictations: Int { days.values.reduce(0) { $0 + $1.dictations } }
    var totalSeconds: TimeInterval { days.values.reduce(0) { $0 + $1.seconds } }

    /// Words over the last seven days, today included.
    func wordsThisWeek(now: Date = .now) -> Int {
        (0..<7).reduce(0) { sum, offset in
            sum + (day(offset: -offset, from: now)?.words ?? 0)
        }
    }

    /// Speaking pace over all dictations; nil until there's any speech.
    var wordsPerMinute: Double? {
        guard totalSeconds >= 1 else { return nil }
        return Double(totalWords) / (totalSeconds / 60)
    }

    /// How much longer typing the same words would have taken than speaking them.
    var timeSaved: TimeInterval {
        max(0, Double(totalWords) / Self.typingWordsPerMinute * 60 - totalSeconds)
    }

    /// Consecutive days with a dictation, ending today, or yesterday if today has none yet.
    func currentStreak(now: Date = .now) -> Int {
        var offset = day(offset: 0, from: now) == nil ? -1 : 0
        var streak = 0
        while day(offset: offset, from: now) != nil {
            streak += 1
            offset -= 1
        }
        return streak
    }

    /// The longest run of consecutive days with a dictation.
    var bestStreak: Int {
        let dates = days.keys.compactMap(Self.formatter.date(from:)).sorted()
        var best = 0
        var run = 0
        var previous: Date?
        for date in dates {
            if let previous, Self.formatter.calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = date
        }
        return best
    }

    /// The counts for a calendar day; nil if nothing was dictated that day.
    func day(on date: Date) -> Day? { days[key(for: date)] }

    private func day(offset: Int, from date: Date) -> Day? {
        calendar.date(byAdding: .day, value: offset, to: date).flatMap(day(on:))
    }

    // MARK: - Storage

    /// Adds one dictation to its day; false (and nothing added) if it had no words.
    @discardableResult
    private func add(words: Int, duration: TimeInterval, on date: Date) -> Bool {
        guard words > 0 else { return false }
        let key = key(for: date)
        var day = days[key] ?? Day()
        day.dictations += 1
        day.words += words
        day.seconds += max(0, duration)
        days[key] = day
        return true
    }

    private func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Parses the keys back into dates; only their order and spacing matter.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    private static func load(from url: URL) -> [String: Day] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Day].self, from: data)) ?? [:]
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(days).write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            logger.error("Saving stats failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
