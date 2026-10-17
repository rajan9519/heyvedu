import Foundation
import Testing
@testable import HeyVedu

struct CleanupContextTests {
    // MARK: Header (must match the training repo's train/ctrl_header.py byte for byte)

    @Test func plainContextSendsNoHeader() {
        #expect(CleanupContext.plain.header == nil)
        #expect(CleanupContext.plain.userMessage(for: "hi olga um thanks") == "hi olga um thanks")
        // Explicit defaults are left out too, as the app sends only non-default keys.
        #expect(CleanupContext(format: .general, tone: .casual).header == nil)
    }

    @Test func headerUsesTheTrainedKeysAndOrder() {
        #expect(CleanupContext(format: .email).header == "[format: email]")
        #expect(CleanupContext(format: .message).header == "[format: message]")
        #expect(CleanupContext(format: .notes).header == "[format: notes]")
        #expect(CleanupContext(tone: .formal).header == "[tone: formal]")
        #expect(CleanupContext(format: .email, tone: .formal).header == "[format: email] [tone: formal]")
    }

    @Test func userMessageIsHeaderNewlineTranscript() {
        let message = CleanupContext(format: .email, tone: .formal).userMessage(for: "hi olga um thanks rajan")
        #expect(message == "[format: email] [tone: formal]\nhi olga um thanks rajan")
    }

    @Test func rawValuesAreTheTrainedValues() {
        #expect(CleanupContext.Format.allCases.map(\.rawValue) == ["general", "message", "email", "notes"])
        #expect(CleanupContext.Tone.allCases.map(\.rawValue) == ["casual", "formal"])
    }

    // MARK: Apps

    private func destination(_ bundleID: String?, _ host: String? = nil) -> Destination {
        Destination.for(bundleID: bundleID, host: host)
    }

    @Test func mailAppsAreEmail() {
        for id in ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.SparkDesktop", "com.superhuman.electron"] {
            #expect(destination(id) == .email, "\(id)")
        }
    }

    @Test func slackAndTeamsAreWorkChat() {
        for id in ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.google.Chat"] {
            #expect(destination(id) == .workChat, "\(id)")
        }
    }

    @Test func messengersArePersonalChat() {
        for id in ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "com.hnc.Discord", "ru.keepcoder.Telegram",
                   "org.whispersystems.signal-desktop"] {
            #expect(destination(id) == .personalChat, "\(id)")
        }
    }

    @Test func noteAppsAreNotes() {
        for id in ["com.apple.Notes", "notion.id", "md.obsidian", "net.shinyfrog.bear", "com.apple.reminders"] {
            #expect(destination(id) == .notes, "\(id)")
        }
    }

    @Test func editorsTerminalsAndUnknownAppsAreOther() {
        for id in ["com.microsoft.VSCode", "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2",
                   "com.apple.iWork.Pages", "com.example.unknown"] {
            #expect(destination(id) == .other, "\(id)")
        }
        #expect(destination(nil) == .other)
    }

    // MARK: Sites

    @Test func webMailIsEmail() {
        for host in ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com"] {
            #expect(destination("com.google.Chrome", host) == .email, "\(host)")
        }
    }

    @Test func webChatIsSplitIntoWorkAndPersonal() {
        for host in ["app.slack.com", "myteam.slack.com", "teams.microsoft.com", "chat.google.com"] {
            #expect(destination("com.apple.Safari", host) == .workChat, "\(host)")
        }
        for host in ["web.whatsapp.com", "discord.com", "web.telegram.org", "www.messenger.com"] {
            #expect(destination("com.apple.Safari", host) == .personalChat, "\(host)")
        }
    }

    @Test func hostsMatchWholeDomainLabels() {
        #expect(destination("com.apple.Safari", "www.notion.so") == .notes)
        #expect(destination("com.apple.Safari", "MAIL.GOOGLE.COM") == .email)
        // Not a subdomain of slack.com, and other Google apps aren't mail.
        #expect(destination("com.apple.Safari", "notslack.com") == .other)
        #expect(destination("com.apple.Safari", "docs.google.com") == .other)
        #expect(destination("com.apple.Safari", "google.com") == .other)
    }

    @Test func browserWithoutAKnownHostIsOther() {
        #expect(destination("com.google.Chrome") == .other)
        #expect(destination("com.google.Chrome", "example.com") == .other)
    }

    @Test func siteWinsOverTheApp() {
        // An app with its own destination showing a web view of another kind.
        #expect(destination("notion.id", "mail.google.com") == .email)
        // An unknown host leaves the app's destination.
        #expect(destination("com.apple.mail", "example.com") == .email)
    }

    @Test func noDomainOrAppIsListedTwice() {
        let domains = Destination.sites.flatMap(\.domains)
        #expect(Set(domains).count == domains.count)
        #expect(domains.allSatisfy { $0 == $0.lowercased() })
    }

    // MARK: Destinations → header

    @Test func destinationsUseTrainedFormats() {
        #expect(Destination.email.format == .email)
        #expect(Destination.workChat.format == .message)
        #expect(Destination.personalChat.format == .message)
        #expect(Destination.notes.format == .notes)
        #expect(Destination.other.format == .general)
    }

    @Test func emailAndWorkChatAreFormalByDefault() {
        #expect(Destination.allCases.filter { $0.defaultTone == .formal } == [.email, .workChat])
    }

    // MARK: Targets

    @Test func targetMapsBrowsersByHost() {
        let gmail = DictationTarget(bundleID: "com.brave.Browser", processID: 1, host: "mail.google.com")
        #expect(gmail.isBrowser)
        #expect(gmail.destination == .email)
        #expect(gmail.summary == "app com.brave.Browser, host mail.google.com (none), destination email")
        let slack = DictationTarget(bundleID: "com.tinyspeck.slackmacgap", processID: 1)
        #expect(!slack.isBrowser)
        #expect(slack.summary == "app com.tinyspeck.slackmacgap, destination workChat")
    }

    @Test func nativeAppsAreDetectedWithoutLookingForAHost() async {
        let target = await DictationTarget.detect(bundleID: "com.apple.MobileSMS", processID: -1)
        #expect(target.host == nil)
        #expect(target.hostSource == nil)
        #expect(target.destination == .personalChat)
    }

    @Test func browserLookupFailsGracefully() async {
        // No such process, and Firefox has no Apple Events: no host, and the destination is other.
        let target = await DictationTarget.detect(bundleID: "org.mozilla.firefox", processID: 999_999)
        #expect(target.host == nil)
        #expect(target.destination == .other)
    }
}
