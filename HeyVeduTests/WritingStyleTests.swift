import Foundation
import Testing
@testable import HeyVedu

@MainActor
struct WritingStyleTests {
    private func freshDefaults() -> UserDefaults {
        let name = "WritingStyleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsAreFormalForEmailAndWorkChatOnly() {
        let style = WritingStyle(defaults: freshDefaults())
        #expect(style.context(for: .email).header == "[format: email] [tone: formal]")
        #expect(style.context(for: .workChat).header == "[format: message] [tone: formal]")
        #expect(style.context(for: .personalChat).header == "[format: message]")
        #expect(style.context(for: .notes).header == "[format: notes]")
        // Casual in other apps is the plain cleanup: no header at all.
        #expect(style.context(for: .other).header == nil)
    }

    @Test func choicesArePerDestinationAndPersist() {
        let defaults = freshDefaults()
        let style = WritingStyle(defaults: defaults)
        style.setTone(.casual, for: .workChat)
        style.setTone(.formal, for: .other)
        let reloaded = WritingStyle(defaults: defaults)
        #expect(reloaded.tone(for: .workChat) == .casual)
        #expect(reloaded.tone(for: .email) == .formal)
        #expect(reloaded.context(for: .other).header == "[tone: formal]")
    }

    @Test func pickingTheDefaultAgainForgetsTheChoice() {
        let defaults = freshDefaults()
        let style = WritingStyle(defaults: defaults)
        style.setTone(.casual, for: .email)
        style.setTone(.formal, for: .email)
        #expect(style.tones.isEmpty)
        #expect(defaults.string(forKey: "tone.email") == nil)
    }
}
