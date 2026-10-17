import AppKit

/// Judges corrections without AI (AI-ASSIST-PLAN §4.1): a swap is a vocabulary fix when the
/// two sides sound alike and the new word isn't ordinary dictionary English (a name, brand
/// or acronym the spell checker doesn't know, or one with capitals inside like "GitHub").
/// Used when AI Assist is off or every provider failed; its suggestions need to be seen
/// twice before they're shown.
enum HeuristicJudge {
    static let confidence = 0.85

    static func suggestions(for input: DictionaryLearnTask.Input,
                            isKnownWord: @MainActor (String) -> Bool = HeuristicJudge.spellCheckerKnows) -> DictionaryLearnTask.Output {
        var found: [DictionaryLearnTask.Suggestion] = []
        for edit in input.edits {
            let old = CorrectionDetector.tokens(edit.pasted), new = CorrectionDetector.tokens(edit.edited)
            for span in DictionaryLearnTask.Text.spans(from: old, to: new) where !span.old.isEmpty && !span.new.isEmpty {
                let heard = old[span.old].joined(separator: " "), term = new[span.new].joined(separator: " ")
                let termWords = DictionaryLearnTask.Text.words(term)
                guard !termWords.isEmpty, termWords.contains(where: { isUnusual($0, isKnownWord: isKnownWord) }) else { continue }
                found.append(.init(heard: heard, term: termWords.joined(separator: " "),
                                   kind: termWords.allSatisfy(isAcronym) ? .acronym : .other, confidence: confidence))
            }
        }
        // The task's own validation does the sounds-alike, size and known-term checks.
        return DictionaryLearnTask.validate(.init(suggestions: found), for: input) ?? .init(suggestions: [])
    }

    static func isUnusual(_ word: String, isKnownWord: @MainActor (String) -> Bool) -> Bool {
        isAcronym(word) || hasInnerCapital(word) || word.contains(where: \.isNumber) || !isKnownWord(word)
    }

    static func isAcronym(_ word: String) -> Bool {
        word.count >= 2 && word.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    static func hasInnerCapital(_ word: String) -> Bool {
        word.dropFirst().contains(where: \.isUppercase)
    }

    /// True for words macOS's English spell checker accepts, ignoring the user's learned words.
    static func spellCheckerKnows(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word.lowercased(), startingAt: 0, language: "en",
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }
}
