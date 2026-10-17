import Foundation

/// Picks the dictionary terms worth showing Vedu Scribe for one chunk of speech: the
/// `[vocab: …]` line of its control header (round 5, training repo
/// `docs/CONDITIONING_DESIGN.md` 4.4). The model writes a listed term's exact spelling where
/// the speech has it or a mishearing of it ("cooper netties" → Kubernetes), and was trained
/// with mostly unrelated terms listed, so a loose pre-match is fine. Never the whole
/// dictionary: at most `limit` terms, best matches first.
///
/// A term qualifies when the transcript has it word for word, or
/// a run of 1–4 words that sounds like it (`PhoneticKey`) and is spelled close to it.
/// Lowercase-only terms are spelling fixes ("teh" → "the"), which `DictionaryMatcher`
/// applies exactly, so they're never sent; terms under 4 letters sound like too much, so
/// they're sent only when said exactly. A term whose alternative was said is left out: `DictionaryMatcher` rewrites
/// that exactly, as it still rewrites and guards every term after cleanup.
nonisolated struct VocabularyMatcher: Sendable {
    static let limit = 12

    private struct Candidate: Sendable {
        let term: String
        let words: [String]
        let alternatives: [[String]]
        /// Sound of the term with its spaces removed; nil when it's matched exactly only.
        let key: String?
        let letters: String
        let wordCount: Int
    }

    private let candidates: [Candidate]

    static let empty = VocabularyMatcher(entries: [])

    var isEmpty: Bool { candidates.isEmpty }

    init(entries: [PersonalDictionary.Entry]) {
        var seen = Set<String>()
        candidates = entries.compactMap { entry in
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = Self.words(of: term)
            // A term can't contain the header's own delimiters.
            guard !words.isEmpty, !term.contains(where: { "[];\n".contains($0) }),
                  seen.insert(words.joined(separator: " ")).inserted else { return nil }
            let alternatives = entry.alternatives.map(Self.words(of:)).filter { !$0.isEmpty && $0 != words }
            let letters = words.joined()
            // Spelling fixes ("teh" → "the") aren't vocabulary: `DictionaryMatcher` applies them.
            guard term != term.lowercased() || term.contains(where: \.isNumber) else { return nil }
            // Short terms (acronyms like "BP") are matched exactly only: too many words sound
            // like them.
            let key = PhoneticKey.of(letters)
            let fuzzy = letters.count >= 4 && key.count >= 2
            return Candidate(term: term, words: words, alternatives: alternatives, key: fuzzy ? key : nil,
                             letters: letters, wordCount: words.count)
        }
    }

    /// The terms to list for `transcript`, best first: exact hits, then the closest-sounding.
    func terms(for transcript: String) -> [String] {
        guard !candidates.isEmpty else { return [] }
        let words = Self.words(of: transcript)
        guard !words.isEmpty else { return [] }
        let windows = Self.windows(of: words)
        var scored: [(score: Double, index: Int)] = []
        for (index, candidate) in candidates.enumerated() {
            // An alternative the user listed is rewritten to the term exactly after cleanup;
            // listing the term too made the model keep the alternative's words next to it
            // ("hey we do" → "HeyVedu, we do").
            if candidate.alternatives.contains(where: { Self.contains(words, $0) }) { continue }
            if Self.contains(words, candidate.words) {
                scored.append((0, index))
            } else if let key = candidate.key, let distance = Self.closest(candidate, key: key, in: windows) {
                scored.append((distance, index))
            }
        }
        // Stable for equal scores: dictionary order.
        return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }
            .prefix(Self.limit).map { candidates[$0.index].term }
    }

    // MARK: Matching

    private struct Window {
        let letters: String
        let key: String
        let wordCount: Int
    }

    /// Every run of 1–4 consecutive words, spaces removed ("cooper netties" → "coopernetties").
    private static func windows(of words: [String]) -> [Window] {
        var windows: [Window] = []
        for start in words.indices {
            var letters = ""
            for end in start..<min(start + 4, words.count) {
                letters += words[end]
                windows.append(Window(letters: letters, key: PhoneticKey.of(letters), wordCount: end - start + 1))
            }
        }
        return windows
    }

    /// The best normalized distance of a window that sounds like the term and is spelled
    /// close to it, or nil. Both are needed: sound keys alone collide too often ("its" and
    /// Etsy), and spelling alone misses the mishearings ("cooper netties").
    private static func closest(_ candidate: Candidate, key: String, in windows: [Window]) -> Double? {
        let allowed = key.count >= 8 ? 2 : key.count >= 5 ? 1 : 0
        let letters = candidate.letters
        var best: Double?
        for window in windows where window.wordCount <= candidate.wordCount + 2 {
            // Roughly as long as the term, so "a son" can match Asana but not a whole sentence.
            let ratio = Double(window.letters.count) / Double(letters.count)
            guard ratio >= 0.7, ratio <= 1.5 else { continue }
            let soundDistance = levenshtein(key, window.key)
            guard soundDistance <= allowed else { continue }
            let spelling = Double(levenshtein(letters, window.letters)) / Double(max(letters.count, window.letters.count))
            guard spelling <= (key.count >= 3 ? 0.5 : 0.4) else { continue }
            // Exact sound is still behind an exact hit (0).
            let score = 0.1 + Double(soundDistance) / Double(key.count) + spelling
            best = min(best ?? score, score)
        }
        return best
    }

    private static func contains(_ words: [String], _ phrase: [String]) -> Bool {
        guard phrase.count <= words.count else { return false }
        return (0...(words.count - phrase.count)).contains { start in
            words[start..<(start + phrase.count)].elementsEqual(phrase)
        }
    }

    /// Lowercase letter-and-digit runs without accents ("Joaquín's" → "joaquins").
    static func words(of text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// A rough English sound key: consonant skeleton with voiced and unvoiced pairs merged, so
/// common speech-recognition mishearings collide ("coopernetties" and "kubernetes" are both
/// "kprnts"). Lowercase letters in, key out.
nonisolated enum PhoneticKey {
    static func of(_ letters: String) -> String {
        // "X" stands for the "sh"/"ch"/"j" sounds.
        var text = letters.lowercased().filter { $0.isASCII && $0.isLetter }
        guard !text.isEmpty else { return "" }
        for (prefix, replacement) in [("kn", "n"), ("wr", "r"), ("ps", "s"), ("pn", "n"), ("gn", "n")]
            where text.hasPrefix(prefix) {
            text = replacement + text.dropFirst(prefix.count)
        }
        for (pattern, replacement) in [("tch", "X"), ("sch", "sk"), ("ch", "X"), ("sh", "X"), ("ph", "f"),
                                       ("th", "t"), ("ck", "k"), ("qu", "kw"), ("wh", "w"), ("gh", "g"),
                                       ("dg", "j")] {
            text = text.replacingOccurrences(of: pattern, with: replacement)
        }
        let characters = Array(text)
        var key = ""
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            var sound: Character?
            switch character {
            case "a", "e", "i", "o", "u", "y", "h", "w":
                // Only a leading vowel counts; it marks how the word starts.
                sound = index == 0 ? "a" : nil
            case "c": sound = next.map { "eiy".contains($0) } == true ? "s" : "k"
            case "b": sound = "p"
            case "d": sound = "t"
            case "g", "q": sound = "k"
            case "v": sound = "f"
            case "z": sound = "s"
            case "j": sound = "X"
            case "x": sound = "k"
            default: sound = character
            }
            if let sound, key.last != sound { key.append(sound) }
        }
        return key
    }
}
