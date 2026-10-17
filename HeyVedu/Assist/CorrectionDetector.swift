import Foundation

/// Finds the small corrections a user made to text HeyVedu just pasted (AI-ASSIST-PLAN §4.2).
/// Pure and deterministic; nothing here leaves the Mac.
///
/// The field is read twice: right after the paste (`Snapshot`) and once the user stops
/// typing. The pasted text is found again between the text that surrounded it, compared
/// word by word, and only small word swaps are kept: 1–3 words for 1–3 words, under 30% of
/// the pasted words, not case- or punctuation-only. Each one is returned as the sentence
/// around it, before and after, never the whole field.
nonisolated enum CorrectionDetector {
    typealias Text = DictionaryLearnTask.Text

    /// Characters of surrounding text kept on each side to find the paste again.
    static let anchorLength = 40
    static let maxChangedWords = 3
    static let maxChangedShare = 0.3

    /// The field right after the paste, cut down to the pasted text and its anchors.
    struct Snapshot: Equatable {
        var before: String
        var pasted: String
        var after: String

        /// Nil when the field doesn't show `pasted` just before the caret (the app changed
        /// it, or the paste went somewhere else).
        init?(text: String, caret: Int, pasted: String) {
            let characters = Array(text.utf16)
            guard caret <= characters.count else { return nil }
            let expected = pasted.utf16.count
            guard caret >= expected else { return nil }
            let start = caret - expected
            let found = String(utf16CodeUnits: Array(characters[start..<caret]), count: expected)
            guard Self.loose(found) == Self.loose(pasted) else { return nil }
            before = String(utf16CodeUnits: Array(characters[max(0, start - anchorLength)..<start]),
                            count: start - max(0, start - anchorLength))
            after = String(utf16CodeUnits: Array(characters[caret..<min(characters.count, caret + anchorLength)]),
                           count: min(characters.count, caret + anchorLength) - caret)
            self.pasted = found
        }

        init(before: String, pasted: String, after: String) {
            self.before = before
            self.pasted = pasted
            self.after = after
        }

        /// Whitespace collapsed, so an app that turns "\n" into "\r" still matches.
        static func loose(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    /// The pasted span as it reads now, or nil when its anchors are gone.
    static func editedSpan(of snapshot: Snapshot, in text: String) -> String? {
        let start: String.Index
        if snapshot.before.isEmpty {
            start = text.startIndex
        } else if let range = text.range(of: snapshot.before) {
            start = range.upperBound
        } else {
            return nil
        }
        let end: String.Index
        if snapshot.after.isEmpty {
            end = text.endIndex
        } else if let range = text.range(of: snapshot.after, range: start..<text.endIndex) {
            end = range.lowerBound
        } else {
            return nil
        }
        return String(text[start..<end])
    }

    /// Small word swaps between what was pasted and what the span reads now.
    static func edits(pasted: String, edited: String, app: String? = nil) -> [DictionaryLearnTask.Edit] {
        // Raw tokens keep their punctuation, for sentence ends and for the model to read;
        // the diff compares them folded.
        let old = tokens(pasted), new = tokens(edited)
        guard !old.isEmpty, !new.isEmpty else { return [] }
        let spans = Text.spans(from: old, to: new)
        let changed = spans.reduce(0) { $0 + max($1.old.count, $1.new.count) }
        guard !spans.isEmpty, Double(changed) < Double(old.count) * maxChangedShare || changed == 1 else { return [] }

        var result: [DictionaryLearnTask.Edit] = []
        for span in spans {
            guard (1...maxChangedWords).contains(span.old.count), (1...maxChangedWords).contains(span.new.count) else { continue }
            let removed = old[span.old].joined(separator: " "), added = new[span.new].joined(separator: " ")
            guard Text.parts(removed) != Text.parts(added) else { continue }  // case or punctuation only
            let edit = DictionaryLearnTask.Edit(
                pasted: sentence(in: old, around: span.old),
                edited: sentence(in: new, around: span.new),
                app: app)
            if !result.contains(edit) { result.append(edit) }
        }
        return result
    }

    /// The words of the sentence containing `range`, from the end of the previous sentence
    /// to the next sentence end.
    static func sentence(in words: [String], around range: Range<Int>) -> String {
        var start = range.lowerBound
        while start > 0, !endsSentence(words[start - 1]) { start -= 1 }
        var end = max(range.upperBound, range.lowerBound + 1) - 1
        while end < words.count - 1, !endsSentence(words[end]) { end += 1 }
        return words[start...min(end, words.count - 1)].joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func endsSentence(_ word: String) -> Bool {
        word.last.map { ".!?".contains($0) } ?? false
    }
}
