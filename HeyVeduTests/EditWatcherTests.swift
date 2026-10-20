import Testing
@testable import HeyVedu

struct EditWatcherTests {
    @Test func splitsAtTheCaret() {
        let split = EditWatcher.split("Hi team. Ship it today. Thanks", inserted: "Ship it today.", caret: 23)
        #expect(split?.before == "Hi team. ")
        #expect(split?.after == " Thanks")
    }

    @Test func fallsBackToTheLastOccurrence() {
        let split = EditWatcher.split("ok ok", inserted: "ok", caret: nil)
        #expect(split?.before == "ok ")
        #expect(split?.after == "")
        #expect(EditWatcher.split("hello", inserted: "bye", caret: 5) == nil)
    }

    @Test func readsTheEditBetweenUnchangedText() {
        #expect(EditWatcher.editedSpan(in: "Hi team. Ship it tomorrow. Thanks", before: "Hi team. ", after: " Thanks") == "Ship it tomorrow.")
        #expect(EditWatcher.editedSpan(in: "Hello team. Ship it. Thanks", before: "Hi team. ", after: " Thanks") == nil)
    }

    @Test func emptiedFieldIsNotAnEdit() {
        #expect(EditWatcher.editedSpan(in: "", before: "", after: "") == nil)
        #expect(EditWatcher.editedSpan(in: "Hi  Thanks", before: "Hi ", after: " Thanks") == nil)
        // Claude's editor after sending a message.
        #expect(EditWatcher.editedSpan(in: "\n", before: "", after: "") == nil)
    }

    @Test func whitespaceOnlyChangesAreNotEdits() {
        #expect(!EditWatcher.isEdit("Ship it. ", of: "Ship it."))
        #expect(EditWatcher.isEdit("Ship it now.", of: "Ship it."))
    }
}
