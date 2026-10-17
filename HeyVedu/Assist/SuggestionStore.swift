import Foundation
import Observation
import os

/// Dictionary words HeyVedu noticed the user correcting (AI-ASSIST-PLAN §4.5).
///
/// Stored in `Application Support/HeyVedu/DictionarySuggestions.json`: the word pairs,
/// counts, dates and which judge proposed them. Never the sentences they came from.
@Observable
final class SuggestionStore {
    enum Status: String, Codable {
        /// Waiting for the user; shown once `isReady`.
        case pending
        /// The user chose Never; kept so the pair is never suggested again.
        case never
    }

    struct Suggestion: Codable, Identifiable, Equatable {
        var id = UUID()
        var heard: String
        var term: String
        var kind: DictionaryLearnTask.Kind
        var count = 1
        var confidence: Double
        var firstSeen = Date.now
        var lastSeen = Date.now
        /// Who proposed it: "claude:haiku v1", "heuristic", … so a bad prompt version can be
        /// traced and its suggestions removed.
        var source: String
        var status = Status.pending
        /// The HUD already asked about it (Add, Not now or timed out).
        var prompted = false

        /// Shown right away when the judge is sure, otherwise once it's been seen twice.
        var isReady: Bool {
            status == .pending && (confidence >= SuggestionStore.immediateConfidence || count >= 2)
        }

        var key: String { SuggestionStore.key(heard: heard, term: term) }
    }

    static let immediateConfidence = 0.95

    private(set) var suggestions: [Suggestion]

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let logger = Logger(subsystem: "com.heyvedu.app", category: "Dictionary")

    /// A nil URL keeps suggestions in memory only (tests).
    init(fileURL: URL? = SuggestionStore.defaultFileURL) {
        self.fileURL = fileURL
        let data = fileURL.flatMap { try? Data(contentsOf: $0) }
        suggestions = data.flatMap { try? JSONDecoder.iso8601.decode([Suggestion].self, from: $0) } ?? []
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyVedu/DictionarySuggestions.json")
    }

    /// Pending suggestions ready to show, newest first.
    var ready: [Suggestion] {
        suggestions.filter(\.isReady).sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Adds what a judge found, merging repeats. Returns suggestions that just became ready
    /// and haven't been asked about yet.
    @discardableResult
    func record(_ found: [DictionaryLearnTask.Suggestion], source: String,
                dictionary: [PersonalDictionary.Entry], now: Date = .now) -> [Suggestion] {
        let known = Set(dictionary.flatMap { [$0.term] + $0.alternatives }.map { $0.lowercased() })
        var newlyReady: [Suggestion] = []
        for item in found where !known.contains(item.term.lowercased()) && !known.contains(item.heard.lowercased()) {
            let key = Self.key(heard: item.heard, term: item.term)
            if let index = suggestions.firstIndex(where: { $0.key == key }) {
                guard suggestions[index].status == .pending else { continue }
                let wasReady = suggestions[index].isReady
                suggestions[index].count += 1
                suggestions[index].confidence = max(suggestions[index].confidence, item.confidence)
                suggestions[index].lastSeen = now
                if !wasReady, suggestions[index].isReady, !suggestions[index].prompted { newlyReady.append(suggestions[index]) }
            } else {
                let suggestion = Suggestion(heard: item.heard, term: item.term, kind: item.kind,
                                            confidence: item.confidence, firstSeen: now, lastSeen: now, source: source)
                suggestions.append(suggestion)
                if suggestion.isReady { newlyReady.append(suggestion) }
            }
        }
        save()
        return newlyReady
    }

    /// Adds the term to the dictionary, with what was heard as an alternative.
    func accept(_ id: Suggestion.ID, into dictionary: PersonalDictionary) {
        guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
        if let index = dictionary.entries.firstIndex(where: { $0.term.caseInsensitiveCompare(suggestion.term) == .orderedSame }) {
            if !dictionary.entries[index].alternatives.contains(where: { $0.caseInsensitiveCompare(suggestion.heard) == .orderedSame }) {
                dictionary.entries[index].alternatives.append(suggestion.heard)
            }
        } else {
            dictionary.entries.append(.init(term: suggestion.term, alternatives: [suggestion.heard]))
        }
        suggestions.removeAll { $0.id == id }
        save()
    }

    /// Not now: stop asking in the HUD, keep it on the Dictionary page.
    func snooze(_ id: Suggestion.ID) {
        update(id) { $0.prompted = true }
    }

    func neverSuggest(_ id: Suggestion.ID) {
        update(id) { $0.status = .never }
    }

    /// Drops everything a judge proposed, e.g. after a bad prompt version.
    func remove(source: String) {
        suggestions.removeAll { $0.source == source && $0.status == .pending }
        save()
    }

    private func update(_ id: Suggestion.ID, _ change: (inout Suggestion) -> Void) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        change(&suggestions[index])
        save()
    }

    static func key(heard: String, term: String) -> String {
        DictionaryLearnTask.Text.key(heard) + "→" + term
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso8601.encode(suggestions).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Saving suggestions failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
