import Foundation

/// How a dictation should be written for where it's going. Vedu Scribe takes this as the
/// control header it was trained on in round 5 (training repo `docs/CONDITIONING_DESIGN.md`,
/// `train/ctrl_header.py`), in front of the transcript in the user message:
///
///     [format: email] [tone: formal]
///     hi olga um can you send me the logs from yesterday thanks rajan
///
/// Only non-default keys are sent, and the default context sends no header at all, which
/// gives exactly the plain cleanup. The model never sees app names or hosts: the app maps
/// them to these few values (`CleanupContext.for(bundleID:host:)`).
nonisolated struct CleanupContext: Equatable, Sendable {
    /// Raw values are the trained header values; keep them exact.
    enum Format: String, CaseIterable, Sendable {
        /// Plain cleanup (the default).
        case general
        /// Chat: no paragraph breaks unless spoken, greeting kept inline, no sign-off added.
        case message
        /// Greeting and sign-off on their own lines, paragraphs at topic changes.
        case email
        /// Fragments are fine, no greeting handling.
        case notes
    }

    /// Raw values are the trained header values; keep them exact.
    enum Tone: String, CaseIterable, Sendable {
        /// The speaker's grammar and contractions are kept (the default).
        case casual
        /// Grammar, spelling and "gonna"-style reductions fixed with the smallest edit.
        case formal
    }

    var format: Format = .general
    var tone: Tone = .casual

    static let plain = CleanupContext()

    /// The header line, or nil for the plain cleanup. Keys in the trained order.
    var header: String? {
        var fields: [String] = []
        if format != .general { fields.append("[format: \(format.rawValue)]") }
        if tone != .casual { fields.append("[tone: \(tone.rawValue)]") }
        return fields.isEmpty ? nil : fields.joined(separator: " ")
    }

    /// The user message for one chunk: the header (repeated on every chunk), a newline, then
    /// the transcript.
    func userMessage(for transcript: String) -> String {
        header.map { "\($0)\n\(transcript)" } ?? transcript
    }

    /// Short description for the debug log, e.g. "email" or "email, formal".
    var summary: String {
        let values = [format != .general ? format.rawValue : nil, tone != .casual ? tone.rawValue : nil].compactMap { $0 }
        return values.isEmpty ? "plain" : values.joined(separator: ", ")
    }
}

// MARK: - Where text goes → format

nonisolated extension CleanupContext {
    /// The context for a dictation into the app `bundleID`, showing a web page from `host`
    /// when it is a browser. Unknown apps and sites get the plain cleanup.
    static func `for`(bundleID: String?, host: String?) -> CleanupContext {
        if let host = host?.lowercased(),
           let format = Self.siteFormats.first(where: { site in site.domains.contains { matches(host, $0) } })?.format {
            return CleanupContext(format: format)
        }
        if let bundleID, let format = Self.appFormats[bundleID] {
            return CleanupContext(format: format)
        }
        return .plain
    }

    /// Native apps by bundle ID. Code editors, terminals and document apps stay plain:
    /// the model has no data for them yet.
    static let appFormats: [String: Format] = {
        let groups: [(Format, [String])] = [
            (.email, [
                "com.apple.mail",
                "com.microsoft.Outlook",
                "com.readdle.SparkDesktop",           // Spark 3
                "com.readdle.smartemail-Mac",         // Spark Classic
                "com.superhuman.electron",
                "com.mimestream.Mimestream",
                "it.bloop.airmail2",
                "com.freron.MailMate",
                "com.canarymail.mac",
                "com.postbox-inc.postbox",
                "org.mozilla.thunderbird",
            ]),
            (.message, [
                "com.tinyspeck.slackmacgap",          // Slack
                "com.apple.MobileSMS",                // Messages
                "net.whatsapp.WhatsApp",
                "desktop.WhatsApp",                   // the older Electron WhatsApp
                "com.hnc.Discord",
                "com.microsoft.teams2",
                "com.microsoft.teams",
                "ru.keepcoder.Telegram",
                "org.telegram.desktop",
                "org.whispersystems.signal-desktop",
                "com.facebook.archon",                // Messenger
                "com.facebook.archon.developerID",
                "com.google.Chat",
                "com.apple.iChat",
            ]),
            (.notes, [
                "com.apple.Notes",
                "com.apple.reminders",
                "notion.id",
                "md.obsidian",
                "net.shinyfrog.bear",
                "com.agiletortoise.Drafts-OSX",
                "com.lukilabs.lukiapp",               // Craft
                "com.culturedcode.ThingsMac",
                "com.logseq.logseq",
            ]),
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { format, ids in ids.map { ($0, format) } })
    }()

    /// Web apps by host; a domain also matches its subdomains. Checked before the browser's
    /// own bundle ID, which has no format.
    static let siteFormats: [(format: Format, domains: [String])] = [
        (.email, [
            "mail.google.com",
            "outlook.live.com", "outlook.office.com", "outlook.office365.com", "outlook.cloud.microsoft",
            "mail.superhuman.com",
            "mail.proton.me",
            "app.fastmail.com",
            "mail.yahoo.com",
            "mail.zoho.com",
            "app.hey.com",
        ]),
        (.message, [
            "slack.com",
            "web.whatsapp.com",
            "discord.com",
            "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
            "web.telegram.org",
            "messenger.com",
            "chat.google.com",
            "messages.google.com",
        ]),
        (.notes, [
            "notion.so", "notion.com",
            "keep.google.com",
        ]),
    ]

    private static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
