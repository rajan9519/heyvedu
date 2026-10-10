import Foundation
import Observation
import os

/// Spoken shortcuts: saying a trigger ("my calendly link") anywhere in a dictation inserts
/// its expansion exactly as typed, line breaks included. Applied after cleanup, like the
/// dictionary, and cleanup output that drops a trigger is rejected for that chunk.
///
/// Stored in `Application Support/HeyVedu/Snippets.json`. Only what the user types here
/// is kept; dictated text never is.
@Observable
final class SnippetLibrary {
    struct Snippet: Codable, Identifiable, Equatable {
        var id = UUID()
        /// What the user says, e.g. "my calendly link". Matched without case.
        var trigger: String
        /// What gets inserted, verbatim.
        var expansion: String
    }

    var snippets: [Snippet] {
        didSet {
            guard snippets != oldValue else { return }
            expander = SnippetExpander(snippets: snippets)
            save()
        }
    }

    /// Rebuilt whenever the snippets change, so dictation never compiles patterns.
    private(set) var expander: SnippetExpander

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let logger = Logger(subsystem: "com.heyvedu.app", category: "Snippets")

    init(fileURL: URL = SnippetLibrary.defaultFileURL) {
        self.fileURL = fileURL
        let loaded = Self.load(from: fileURL)
        snippets = loaded
        expander = SnippetExpander(snippets: loaded)
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyVedu/Snippets.json")
    }

    private static func load(from url: URL) -> [Snippet] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Snippet].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snippets).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Saving snippets failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Immutable, precompiled snippet replacement.
///
/// Triggers are first swapped for placeholder tokens, the dictionary runs, then the tokens
/// become the expansions. So the dictionary can't rewrite text inside an expansion, and an
/// expansion is never re-capitalized or re-punctuated.
nonisolated struct SnippetExpander: Sendable {
    /// Matches triggers. Also the cleanup guard: a chunk whose cleanup loses a trigger is
    /// pasted raw, so the snippet still expands.
    let matcher: DictionaryMatcher
    private let expansions: [String]

    static let empty = SnippetExpander(snippets: [])

    init(snippets: [SnippetLibrary.Snippet]) {
        var expansions: [String] = []
        var rules: [DictionaryMatcher.Rule] = []
        for snippet in snippets {
            let expansion = snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expansion.isEmpty, !DictionaryMatcher.normalized(snippet.trigger).isEmpty else { continue }
            rules.append(.init(replacement: Self.token(expansions.count), phrases: [snippet.trigger], adaptsCapital: false))
            expansions.append(expansion)
        }
        matcher = DictionaryMatcher(rules: rules)
        self.expansions = expansions
    }

    /// Replaces triggers with their expansions and applies `dictionary` to everything else.
    /// A dictation that is nothing but a trigger (plus the punctuation cleanup added)
    /// becomes exactly the expansion.
    func expand(_ text: String, dictionary: DictionaryMatcher) -> String {
        guard !matcher.isEmpty else { return dictionary.apply(to: text) }
        let marked = dictionary.apply(to: matcher.apply(to: text))
        let bare = marked.trimmingCharacters(in: Self.surrounding)
        if let index = Self.index(ofToken: bare) { return expansions[index] }

        guard let regex = Self.tokenPattern else { return marked }
        let source = marked as NSString
        let result = NSMutableString()
        var cursor = 0
        for match in regex.matches(in: marked, range: NSRange(location: 0, length: source.length)) {
            result.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let token = source.substring(with: match.range)
            result.append(Self.index(ofToken: token).map { expansions[$0] } ?? token)
            cursor = match.range.location + match.range.length
        }
        result.append(source.substring(from: cursor))
        return result as String
    }

    // Private-use characters: never typed or transcribed, and neither letters nor digits,
    // so they don't change word boundaries for the dictionary.
    private static let open = "\u{E000}"
    private static let close = "\u{E001}"
    private static let tokenPattern = try? NSRegularExpression(pattern: "\u{E000}[0-9]+\u{E001}")
    private static let surrounding = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    private static func token(_ index: Int) -> String {
        "\(open)\(index)\(close)"
    }

    private static func index(ofToken text: String) -> Int? {
        guard text.hasPrefix(open), text.hasSuffix(close) else { return nil }
        return Int(text.dropFirst(open.count).dropLast(close.count))
    }
}
