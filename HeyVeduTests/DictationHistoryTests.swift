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
        .init(date: .now, duration: 1.5, transcript: "um \(text)", modelOutput: text, cleanedText: text,
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
