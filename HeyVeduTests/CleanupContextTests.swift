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

    @Test func mailAppsGetEmail() {
        for id in ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.SparkDesktop", "com.superhuman.electron"] {
            #expect(CleanupContext.for(bundleID: id, host: nil) == CleanupContext(format: .email), "\(id)")
        }
    }

    @Test func chatAppsGetMessage() {
        for id in ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
                   "com.hnc.Discord", "com.microsoft.teams2"] {
            #expect(CleanupContext.for(bundleID: id, host: nil) == CleanupContext(format: .message), "\(id)")
        }
    }

    @Test func noteAppsGetNotes() {
        for id in ["com.apple.Notes", "notion.id", "md.obsidian", "net.shinyfrog.bear", "com.apple.reminders"] {
            #expect(CleanupContext.for(bundleID: id, host: nil) == CleanupContext(format: .notes), "\(id)")
        }
    }

    @Test func editorsTerminalsAndUnknownAppsArePlain() {
        for id in ["com.microsoft.VSCode", "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2",
                   "com.apple.iWork.Pages", "com.example.unknown"] {
            #expect(CleanupContext.for(bundleID: id, host: nil) == .plain, "\(id)")
        }
        #expect(CleanupContext.for(bundleID: nil, host: nil) == .plain)
    }

    // MARK: Sites

    @Test func webMailGetsEmail() {
        for host in ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com"] {
            #expect(CleanupContext.for(bundleID: "com.google.Chrome", host: host) == CleanupContext(format: .email), "\(host)")
        }
    }

    @Test func webChatGetsMessage() {
        for host in ["app.slack.com", "myteam.slack.com", "web.whatsapp.com", "discord.com", "teams.microsoft.com"] {
            #expect(CleanupContext.for(bundleID: "com.apple.Safari", host: host) == CleanupContext(format: .message), "\(host)")
        }
    }

    @Test func hostsMatchWholeDomainLabels() {
        #expect(CleanupContext.for(bundleID: "com.apple.Safari", host: "www.notion.so") == CleanupContext(format: .notes))
        #expect(CleanupContext.for(bundleID: "com.apple.Safari", host: "MAIL.GOOGLE.COM") == CleanupContext(format: .email))
        // Not a subdomain of slack.com, and other Google apps aren't mail.
        #expect(CleanupContext.for(bundleID: "com.apple.Safari", host: "notslack.com") == .plain)
        #expect(CleanupContext.for(bundleID: "com.apple.Safari", host: "docs.google.com") == .plain)
        #expect(CleanupContext.for(bundleID: "com.apple.Safari", host: "google.com") == .plain)
    }

    @Test func browserWithoutAKnownHostIsPlain() {
        #expect(CleanupContext.for(bundleID: "com.google.Chrome", host: nil) == .plain)
        #expect(CleanupContext.for(bundleID: "com.google.Chrome", host: "example.com") == .plain)
    }

    @Test func siteFormatWinsOverTheApp() {
        // An app with its own format showing a web view of another kind (e.g. a mail link in Notion).
        #expect(CleanupContext.for(bundleID: "notion.id", host: "mail.google.com") == CleanupContext(format: .email))
        // An unknown host leaves the app's format.
        #expect(CleanupContext.for(bundleID: "com.apple.mail", host: "example.com") == CleanupContext(format: .email))
    }

    @Test func noDomainIsListedTwice() {
        let domains = CleanupContext.siteFormats.flatMap(\.domains)
        #expect(Set(domains).count == domains.count)
        #expect(domains.allSatisfy { $0 == $0.lowercased() })
    }

    // MARK: Targets

    @Test func targetMapsBrowsersByHost() {
        let gmail = DictationTarget(bundleID: "com.brave.Browser", processID: 1, host: "mail.google.com")
        #expect(gmail.isBrowser)
        #expect(gmail.context == CleanupContext(format: .email))
        #expect(gmail.summary == "app com.brave.Browser, host mail.google.com (none), format email")
        let mail = DictationTarget(bundleID: "com.apple.mail", processID: 1)
        #expect(!mail.isBrowser)
        #expect(mail.summary == "app com.apple.mail, format email")
    }

    @Test func nativeAppsAreDetectedWithoutLookingForAHost() async {
        let target = await DictationTarget.detect(bundleID: "com.apple.MobileSMS", processID: -1)
        #expect(target.host == nil)
        #expect(target.hostSource == nil)
        #expect(target.context == CleanupContext(format: .message))
    }

    @Test func browserLookupFailsGracefully() async {
        // No such process, and Firefox has no Apple Events: no host, and the text is plain.
        let target = await DictationTarget.detect(bundleID: "org.mozilla.firefox", processID: 999_999)
        #expect(target.host == nil)
        #expect(target.context == .plain)
    }
}
