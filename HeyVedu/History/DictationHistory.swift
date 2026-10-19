import Foundation
import Observation
import os

/// Opt-in record of past dictations. Off by default; while off nothing is written.
///
/// Stored only on this Mac, in `Application Support/HeyVedu/History.json`. Each entry keeps
/// the raw transcript, the cleanup model's output, how the pasted text differs from that
/// output (dictionary spellings, snippets) and what the user edited it into afterwards, so
/// a dictation can later be attached to feedback or an issue report, or used as training
/// data. The History view shows only the pasted text and when it was dictated.
@Observable
final class DictationHistory {
    struct Entry: Identifiable, Equatable {
        var id = UUID()
        /// When the recording finished.
        var date: Date
        /// Seconds of audio transcribed, after silence was trimmed.
        var duration: TimeInterval
        /// Exactly what the speech model returned.
        var transcript: String
        /// The cleanup engine's output, with the raw transcript for any chunk it failed on
        /// (`fallbackReason` says why); nil if cleanup was off.
        var modelOutput: String?
        /// The cleanup engine used, e.g. "veduScribe"; nil if cleanup was off.
        var cleanupEngine: String?
        /// Why the raw transcript was used for some or all of the text, if it was.
        var fallbackReason: String?
        /// What the dictionary and snippets changed in `modelOutput` (or in the transcript,
        /// when cleanup was off) to make the pasted text. Empty when they changed nothing.
        var replacements: [Replacement]
        /// What the user changed the pasted text into, in the field it was pasted into; nil
        /// if they didn't change it or the field couldn't be read. See `EditWatcher`.
        var editedText: String?

        /// What was pasted.
        var finalText: String { Replacement.apply(replacements, to: modelOutput ?? transcript) }

        init(
            id: UUID = UUID(), date: Date, duration: TimeInterval, transcript: String, modelOutput: String?,
            cleanupEngine: String?, fallbackReason: String?, finalText: String, editedText: String? = nil
        ) {
            self.id = id
            self.date = date
            self.duration = duration
            self.transcript = transcript
            self.modelOutput = modelOutput
            self.cleanupEngine = cleanupEngine
            self.fallbackReason = fallbackReason
            self.replacements = Replacement.between(modelOutput ?? transcript, and: finalText)
            self.editedText = editedText
        }
    }

    /// One span of text swapped for another, e.g. "hey we do" → "HeyVedu".
    nonisolated struct Replacement: Codable, Equatable, Sendable {
        /// Where the replaced span starts, in UTF-16 code units (`NSString` indexing).
        var offset: Int
        /// The replaced span's length, in UTF-16 code units.
        var length: Int
        /// What replaced it.
        var text: String

        /// The replacements that turn `original` into `changed`, found by a word-level diff.
        static func between(_ original: String, and changed: String) -> [Replacement] {
            guard original != changed else { return [] }
            let old = tokens(of: original)
            let new = tokens(of: changed)
            var removed = Set<Int>()
            var inserted = Set<Int>()
            for change in new.difference(from: old) {
                switch change {
                case .remove(let index, _, _): removed.insert(index)
                case .insert(let index, _, _): inserted.insert(index)
                }
            }
            // Unchanged tokens appear in the same order in both, so walk them in step and
            // turn each run of removed and inserted tokens between two of them into one span.
            var replacements: [Replacement] = []
            var offset = 0
            var i = 0
            var j = 0
            while i < old.count || j < new.count {
                guard removed.contains(i) || inserted.contains(j) else {
                    offset += old[i].utf16.count
                    i += 1
                    j += 1
                    continue
                }
                var replacement = Replacement(offset: offset, length: 0, text: "")
                while removed.contains(i) {
                    replacement.length += old[i].utf16.count
                    i += 1
                }
                while inserted.contains(j) {
                    replacement.text += new[j]
                    j += 1
                }
                offset += replacement.length
                replacements.append(replacement)
            }
            return replacements
        }

        static func apply(_ replacements: [Replacement], to text: String) -> String {
            guard !replacements.isEmpty else { return text }
            let source = text as NSString
            var result = ""
            var cursor = 0
            for replacement in replacements where replacement.offset >= cursor && NSMaxRange(replacement.range) <= source.length {
                result += source.substring(with: NSRange(location: cursor, length: replacement.offset - cursor))
                result += replacement.text
                cursor = NSMaxRange(replacement.range)
            }
            return result + source.substring(from: cursor)
        }

        private var range: NSRange { NSRange(location: offset, length: length) }

        /// Runs of letters and digits, and every other character on its own.
        private static func tokens(of text: String) -> [String] {
            var tokens: [String] = []
            var word = ""
            for character in text {
                if character.isLetter || character.isNumber {
                    word.append(character)
                } else {
                    if !word.isEmpty { tokens.append(word) }
                    word = ""
                    tokens.append(String(character))
                }
            }
            if !word.isEmpty { tokens.append(word) }
            return tokens
        }
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

    /// Adds the user's edit of a recorded dictation; does nothing if it's no longer recorded.
    func recordEdit(_ text: String, for id: Entry.ID) {
        guard isEnabled, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].editedText = text
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

extension DictationHistory.Entry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, date, duration, transcript, modelOutput, cleanupEngine, fallbackReason, replacements, editedText
        /// Older files stored the whole pasted text instead of `replacements`.
        case finalText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        transcript = try container.decode(String.self, forKey: .transcript)
        modelOutput = try container.decodeIfPresent(String.self, forKey: .modelOutput)
        cleanupEngine = try container.decodeIfPresent(String.self, forKey: .cleanupEngine)
        fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
        editedText = try container.decodeIfPresent(String.self, forKey: .editedText)
        if let finalText = try container.decodeIfPresent(String.self, forKey: .finalText) {
            replacements = DictationHistory.Replacement.between(modelOutput ?? transcript, and: finalText)
        } else {
            replacements = try container.decodeIfPresent([DictationHistory.Replacement].self, forKey: .replacements) ?? []
        }
    }

    /// Leaves out empty and missing fields, to keep the file small.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(duration, forKey: .duration)
        try container.encode(transcript, forKey: .transcript)
        try container.encodeIfPresent(modelOutput, forKey: .modelOutput)
        try container.encodeIfPresent(cleanupEngine, forKey: .cleanupEngine)
        try container.encodeIfPresent(fallbackReason, forKey: .fallbackReason)
        if !replacements.isEmpty { try container.encode(replacements, forKey: .replacements) }
        try container.encodeIfPresent(editedText, forKey: .editedText)
    }
}
