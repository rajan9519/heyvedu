import Foundation
import Testing
@testable import HeyVedu

struct DictationStatsTests {
    private let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("HeyVeduStatsTests-\(UUID().uuidString)/Stats.json")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func stats() -> DictationStats {
        DictationStats(fileURL: fileURL, calendar: calendar)
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func countsWordsAndNeverStoresText() throws {
        let s = stats()
        s.record("Can we push the review to Thursday?", duration: 3, date: date(13))
        #expect(s.totalWords == 7)
        #expect(s.totalDictations == 1)
        #expect(s.totalSeconds == 3)

        let file = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!file.contains("Thursday"))
        #expect(stats().totalWords == 7)
    }

    @Test func ignoresDictationsWithoutWords() {
        let s = stats()
        s.record("  …  ", duration: 2, date: date(13))
        #expect(s.totalDictations == 0)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func groupsByLocalDay() {
        let s = stats()
        s.record("one two", duration: 1, date: date(13, hour: 0))
        s.record("three", duration: 1, date: date(13, hour: 23))
        s.record("four", duration: 1, date: date(14, hour: 1))
        #expect(s.day(on: date(13))?.words == 3)
        #expect(s.day(on: date(13))?.dictations == 2)
        #expect(s.day(on: date(14))?.words == 1)
        #expect(s.day(on: date(12)) == nil)
    }

    @Test func paceAndTimeSaved() {
        let s = stats()
        #expect(s.wordsPerMinute == nil)
        #expect(s.timeSaved == 0)
        // 90 words in 30 seconds: 180 wpm. Typing them at 45 wpm takes 120 seconds.
        s.record(Array(repeating: "word", count: 90).joined(separator: " "), duration: 30, date: date(13))
        #expect(s.wordsPerMinute == 180)
        #expect(s.timeSaved == 90)
    }

    @Test func streaks() {
        let s = stats()
        for day in [3, 4, 5, 6, 10, 11, 12] {
            s.record("hello", duration: 1, date: date(day))
        }
        // Nothing yet today: the streak still counts through yesterday.
        #expect(s.currentStreak(now: date(13)) == 3)
        s.record("hello", duration: 1, date: date(13))
        #expect(s.currentStreak(now: date(13)) == 4)
        #expect(s.currentStreak(now: date(15)) == 0)
        #expect(s.bestStreak == 4)
    }

    @Test func wordsThisWeekCoversSevenDays() {
        let s = stats()
        s.record("old", duration: 1, date: date(6))
        s.record("in range", duration: 1, date: date(7))
        s.record("today too", duration: 1, date: date(13))
        #expect(s.wordsThisWeek(now: date(13)) == 4)
    }

    @Test func importsSavedHistoryOnce() {
        let defaults = UserDefaults(suiteName: "HeyVeduStatsTests-\(UUID().uuidString)")!
        let entry = DictationHistory.Entry(
            date: date(12), duration: 2, transcript: "um hello there", modelOutput: nil,
            cleanedText: nil, cleanupEngine: nil, fallbackReason: nil, finalText: "hello there"
        )
        let s = stats()
        s.importOnce([entry, entry], defaults: defaults)
        #expect(s.day(on: date(12))?.words == 4)
        #expect(s.totalDictations == 2)
        s.importOnce([entry], defaults: defaults)
        #expect(s.totalDictations == 2)
    }

    @Test func resetDeletesEverything() {
        let s = stats()
        s.record("hello", duration: 1, date: date(13))
        s.reset()
        #expect(s.totalWords == 0)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}
