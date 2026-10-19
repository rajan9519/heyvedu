import Foundation
import Testing
@testable import HeyVedu

struct DictationHistoryTests {
    private let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("HeyVeduHistoryTests-\(UUID().uuidString)/History.json")
    private let defaults = UserDefaults(suiteName: "HeyVeduHistoryTests-\(UUID().uuidString)")!

    private func history() -> DictationHistory {
        DictationHistory(fileURL: fileURL, defaults: defaults)
    }

    private func entry(_ text: String) -> DictationHistory.Entry {
        .init(date: .now, duration: 1.5, transcript: "um \(text)", modelOutput: text,
              cleanupEngine: "veduScribe", fallbackReason: nil, finalText: text)
    }

    @Test func offByDefaultAndRecordsNothing() {
        let h = history()
        #expect(!h.isEnabled)
        h.record(entry("hello"))
        #expect(h.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func recordsNewestFirstAndPersistsEveryStage() {
        let h = history()
        h.isEnabled = true
        h.record(entry("first"))
        h.record(entry("second"))
        #expect(h.entries.map(\.finalText) == ["second", "first"])

        let reloaded = history()
        #expect(reloaded.isEnabled)
        #expect(reloaded.entries.map(\.finalText) == ["second", "first"])
        #expect(reloaded.entries[0].transcript == "um second")
        #expect(reloaded.entries[0].modelOutput == "second")
        #expect(reloaded.entries[0].cleanupEngine == "veduScribe")
    }

    @Test func turningOffDeletesEverything() {
        let h = history()
        h.isEnabled = true
        h.record(entry("secret"))
        h.isEnabled = false
        #expect(h.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        h.isEnabled = true
        #expect(history().entries.isEmpty)
    }

    @Test func deletesOneEntry() {
        let h = history()
        h.isEnabled = true
        h.record(entry("keep"))
        h.record(entry("drop"))
        h.delete(h.entries[0].id)
        #expect(history().entries.map(\.finalText) == ["keep"])
    }

    @Test func keepsOnlyTheNewestUpToTheLimit() {
        let h = history()
        h.isEnabled = true
        for i in 0..<(DictationHistory.limit + 5) { h.record(entry("\(i)")) }
        #expect(h.entries.count == DictationHistory.limit)
        #expect(h.entries.first?.finalText == "\(DictationHistory.limit + 4)")
        #expect(h.entries.last?.finalText == "5")
    }
}

extension DictationHistoryTests {
    @Test func recordsTheUserEditOfAnEntry() {
        let h = history()
        h.isEnabled = true
        h.record(entry("ship it today"))
        h.recordEdit("ship it tomorrow", for: h.entries[0].id)
        #expect(history().entries[0].editedText == "ship it tomorrow")
        #expect(history().entries[0].finalText == "ship it today")
    }
}

struct ReplacementTests {
    private typealias Replacement = DictationHistory.Replacement

    @Test(arguments: [
        ("I love hey we do.", "I love HeyVedu."),
        ("Send my calendly link, thanks.", "Send https://calendly.com/rajan, thanks."),
        ("Ask pria and post gress q l team.", "Ask Priya and PostgreSQL team."),
        ("sig", "Rajan\nHeyVedu"),
        ("Café 🎉 hey vedu", "Café 🎉 HeyVedu"),
        ("", "added"),
        ("removed", ""),
    ])
    func roundTrips(original: String, changed: String) {
        let replacements = Replacement.between(original, and: changed)
        #expect(Replacement.apply(replacements, to: original) == changed)
    }

    @Test func recordsOnlyWhatChanged() {
        #expect(Replacement.between("Same text.", and: "Same text.").isEmpty)
        #expect(Replacement.between("I love hey we do.", and: "I love HeyVedu.")
            == [.init(offset: 7, length: 9, text: "HeyVedu")])
    }
}

extension DictationHistoryTests {
    @Test func storesReplacementsInsteadOfThePastedText() throws {
        let h = history()
        h.isEnabled = true
        h.record(.init(date: .now, duration: 1, transcript: "i love hey we do", modelOutput: "I love hey we do.",
                       cleanupEngine: "dictationModel", fallbackReason: nil, finalText: "I love HeyVedu."))
        let json = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!json.contains("finalText"))
        #expect(!json.contains("I love HeyVedu."))
        #expect(history().entries[0].finalText == "I love HeyVedu.")
    }

    @Test func readsTheOlderFormat() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            [{"id": "9F1C1C51-5A55-4C1B-9C8E-2B1D6C0A7E11", "date": "2026-10-13T16:28:26Z", "duration": 2,
              "transcript": "um hey we do", "modelOutput": "Hey we do.", "cleanedText": "Hey we do.",
              "cleanupEngine": "dictationModel", "finalText": "HeyVedu."}]
            """.utf8).write(to: fileURL)
        defaults.set(true, forKey: "historyEnabled")
        let entry = try #require(history().entries.first)
        #expect(entry.finalText == "HeyVedu.")
        #expect(entry.replacements.count == 1)
    }
}
