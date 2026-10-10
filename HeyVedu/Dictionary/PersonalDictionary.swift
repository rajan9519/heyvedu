import Foundation
import Observation
import os

/// Words the user wants written a particular way. Applied deterministically, never through
/// the cleanup prompt (the old vocabulary feature relied on the model and was ignored):
/// - after cleanup, every match of a term or one of its alternatives is rewritten to the
///   term exactly (`DictionaryMatcher.apply`);
/// - cleanup output that loses a term the transcript had is rejected for that chunk
///   (`DictionaryMatcher.missingTerm`), so the model can't "correct" a name away.
///
/// Stored in `Application Support/HeyVedu/Dictionary.json`. Only what the user types here
/// is kept; dictated text never is.
@Observable
final class PersonalDictionary {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        /// The spelling to write, e.g. "HeyVedu".
        var term: String
        /// What gets written instead, e.g. "hey vedu", "hay vedu". Matched without case.
        var alternatives: [String] = []
    }

    var entries: [Entry] {
        didSet {
            guard entries != oldValue else { return }
            matcher = DictionaryMatcher(entries: entries)
            save()
        }
    }

    /// Rebuilt whenever the entries change, so dictation never compiles patterns.
    private(set) var matcher: DictionaryMatcher

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let logger = Logger(subsystem: "com.heyvedu.app", category: "Dictionary")

    init(fileURL: URL = PersonalDictionary.defaultFileURL) {
        self.fileURL = fileURL
        let loaded = Self.load(from: fileURL)
        entries = loaded
        matcher = DictionaryMatcher(entries: loaded)
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyVedu/Dictionary.json")
    }

    private static func load(from url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Saving the dictionary failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Immutable, precompiled matcher for a set of dictionary entries.
nonisolated struct DictionaryMatcher: Sendable {
    private struct Pattern: Sendable {
        let entryIndex: Int
        let source: String
    }

    private let terms: [String]
    private let patterns: [Pattern]
    /// One alternation of every pattern, longest first, each in its own capture group.
    private let regex: NSRegularExpression?

    static let empty = DictionaryMatcher(entries: [])

    var isEmpty: Bool { regex == nil }

    init(entries: [PersonalDictionary.Entry]) {
        var terms: [String] = []
        var patterns: [Pattern] = []
        var seen = Set<String>()
        for entry in entries {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let index = terms.count
            terms.append(term)
            // The term itself is matched too, so "heyvedu" is fixed to "HeyVedu".
            for phrase in [term] + entry.alternatives {
                let words = Self.words(of: phrase)
                guard !words.isEmpty else { continue }
                // The first entry claiming a phrase wins.
                guard seen.insert(words.joined(separator: " ").lowercased()).inserted else { continue }
                let body = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: Self.separator)
                patterns.append(Pattern(entryIndex: index, source: body))
            }
        }
        // Longest first so "hey vedu pro" wins over "hey vedu" at the same position.
        patterns.sort { $0.source.count > $1.source.count }
        self.terms = terms
        self.patterns = patterns
        if patterns.isEmpty {
            regex = nil
        } else {
            // Letters and digits on either side mean the phrase is part of a longer word.
            let alternation = patterns.map { "(\($0.source))" }.joined(separator: "|")
            regex = try? NSRegularExpression(
                pattern: #"(?<![\p{L}\p{N}])(?:"# + alternation + #")(?![\p{L}\p{N}])"#,
                options: [.caseInsensitive])
        }
    }

    /// Rewrites every match to its entry's term. A lowercase-only term keeps the matched
    /// text's leading capital ("Teh cat" → "The cat"); any other term is written exactly.
    func apply(to text: String) -> String {
        guard let regex else { return text }
        let source = text as NSString
        let result = NSMutableString()
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let index = entryIndex(of: match) else { continue }
            result.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let matched = source.substring(with: match.range)
            var term = terms[index]
            if term == term.lowercased(), matched.first?.isUppercase == true, let first = term.first {
                term = first.uppercased() + term.dropFirst()
            }
            result.append(term)
            cursor = match.range.location + match.range.length
        }
        result.append(source.substring(from: cursor))
        return result as String
    }

    /// A term that `original` contains (as itself or an alternative) but `cleaned` lost,
    /// or nil when cleanup kept every one.
    func missingTerm(from original: String, in cleaned: String) -> String? {
        let before = matchedEntries(in: original)
        guard !before.isEmpty else { return nil }
        let after = matchedEntries(in: cleaned)
        return before.subtracting(after).min().map { terms[$0] }
    }

    private func matchedEntries(in text: String) -> Set<Int> {
        guard let regex else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return Set(regex.matches(in: text, range: range).compactMap(entryIndex(of:)))
    }

    private func entryIndex(of match: NSTextCheckingResult) -> Int? {
        for (group, pattern) in patterns.enumerated() where match.range(at: group + 1).location != NSNotFound {
            return pattern.entryIndex
        }
        return nil
    }

    /// Between a phrase's words: whitespace and the punctuation that speech recognition and
    /// cleanup add or drop freely, so "hey we do" also matches "Hey, we do." and "Hey. We do".
    private static let separator = #"[\s,.;:!?\-–—]+"#

    /// Whitespace-separated words of a phrase, without surrounding punctuation
    /// ("Hey," → "Hey"). Inner punctuation stays ("C++", "Node.js", "e-mail").
    private static func words(of phrase: String) -> [String] {
        phrase.split(whereSeparator: \.isWhitespace).compactMap { word in
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"“”()-–—"))
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
