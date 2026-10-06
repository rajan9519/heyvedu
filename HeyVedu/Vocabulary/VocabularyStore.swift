import Foundation
import Observation
import os

/// Preferred spellings for names, product terms and jargon, fed to the cleanup prompt.
/// Stored as JSON in ~/Library/Application Support/HeyVedu/vocabulary.json
/// (owner read/write only) so it can also be edited by hand.
@Observable
final class VocabularyStore {
    private(set) var terms: [String] = []
    /// Set when the file couldn't be read or written; shown in the vocabulary window.
    private(set) var lastError: String?

    /// Terms go into the instructions of a ~4K-token on-device model, so keep them bounded.
    static let maxTerms = 100
    static let maxTermLength = 60

    @ObservationIgnored private let fileURL: URL
    private let logger = Logger(subsystem: "com.heyvedu.app", category: "Vocabulary")

    private struct FileFormat: Codable {
        var version = 1
        var terms: [String]
    }

    init(fileURL: URL = VocabularyStore.defaultFileURL) {
        self.fileURL = fileURL
        reload()
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "HeyVedu/vocabulary.json")
    }

    /// Re-reads the file (picks up hand edits).
    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            terms = []
            lastError = nil
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(FileFormat.self, from: data)
            terms = Self.normalized(decoded.terms)
            lastError = nil
        } catch {
            // Keep the unreadable file untouched as a backup instead of overwriting it later.
            let backup = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            terms = []
            lastError = "vocabulary.json couldn't be read; it was moved to \(backup.lastPathComponent)"
            logger.error("Vocabulary file unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds a term. Returns a user-facing message if it was rejected.
    @discardableResult
    func add(_ raw: String) -> String? {
        guard let term = Self.sanitize(raw) else { return "Enter a word or phrase." }
        guard term.count <= Self.maxTermLength else {
            return "Terms can be at most \(Self.maxTermLength) characters."
        }
        guard !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else {
            return "\u{201C}\(term)\u{201D} is already in the list."
        }
        guard terms.count < Self.maxTerms else { return "The list is full (\(Self.maxTerms) terms)." }
        terms.append(term)
        terms.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        save()
        return nil
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        save()
    }

    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(FileFormat(terms: terms)).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastError = nil
        } catch {
            lastError = "Couldn't save vocabulary: \(error.localizedDescription)"
            logger.error("Vocabulary save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Terms are placed in the model's instructions, so strip anything that could break
    /// out of the list: control characters, newlines, and the <, > used for prompt tags.
    static func sanitize(_ raw: String) -> String? {
        let filtered = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
                && scalar != "<" && scalar != ">"
        }
        let collapsed = String(String.UnicodeScalarView(filtered))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Applies the same rules to terms loaded from disk (the file may be hand-edited).
    private static func normalized(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in raw {
            guard let term = sanitize(candidate), term.count <= maxTermLength,
                  seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == maxTerms { break }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
