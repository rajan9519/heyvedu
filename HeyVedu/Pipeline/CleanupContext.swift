import Foundation

/// How a dictation should be written for where it's going. Vedu Scribe takes this as the
/// control header it was trained on in round 5 (training repo `docs/CONDITIONING_DESIGN.md`,
/// `train/ctrl_header.py`), in front of the transcript in the user message:
///
///     [format: email] [tone: formal]
///     [vocab: Olga; Kubernetes]
///     hi olga um can you send me the cooper netties logs from yesterday thanks rajan
///
/// Only non-default keys are sent, and the default context sends no header at all, which
/// gives exactly the plain cleanup. The model never sees app names or hosts: the app maps
/// them to a `Destination`, which picks the format and, with the user's settings, the tone.
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
    /// Personal dictionary terms that may be in this chunk's speech (`VocabularyMatcher`),
    /// at most 12. The model writes a term's exact spelling where the speech has it or a
    /// mishearing of it, and leaves unspoken terms out.
    ///
    /// Training never combined vocab with `[format: email]` or `[tone: formal]`, so both were
    /// measured on the r5b test split (2026-10-17) before sending all three together:
    /// - the 195 vocab rows under email, formal or both: misheard terms fixed 21/24 in every
    ///   case, as with the trained headers, and an unspoken term inserted in ≤ 2 rows;
    /// - the 108 email rows with 5 distractor terms added: layout right in 108/108, as
    ///   without them; 120 formal rows: exact matches 48 vs 49, 1 distractor inserted.
    var vocab: [String] = []

    static let plain = CleanupContext()

    /// The header lines, or nil for the plain cleanup. Keys in the trained order: format and
    /// tone on one line, vocab on its own.
    var header: String? {
        var lines: [String] = []
        var fields: [String] = []
        if format != .general { fields.append("[format: \(format.rawValue)]") }
        if tone != .casual { fields.append("[tone: \(tone.rawValue)]") }
        if !fields.isEmpty { lines.append(fields.joined(separator: " ")) }
        if !vocab.isEmpty { lines.append("[vocab: \(vocab.joined(separator: "; "))]") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The user message for one chunk: the header (repeated on every chunk), a newline, then
    /// the transcript.
    func userMessage(for transcript: String) -> String {
        header.map { "\($0)\n\(transcript)" } ?? transcript
    }

    /// Short description for the debug log, e.g. "email" or "email, formal, 3 terms". Never
    /// the terms themselves: they can name people.
    var summary: String {
        let values = [format != .general ? format.rawValue : nil, tone != .casual ? tone.rawValue : nil,
                      vocab.isEmpty ? nil : "\(vocab.count) terms"].compactMap { $0 }
        return values.isEmpty ? "plain" : values.joined(separator: ", ")
    }
}

// MARK: - Where text goes

/// The kinds of places a dictation goes. Each one has the model format it's written in and
/// the tone it gets unless the user picks another (`WritingStyle`): formal where the reader
/// is usually a colleague (email, work chat), casual everywhere else. The model never sees
/// these names, only the format and tone.
nonisolated enum Destination: String, CaseIterable, Sendable {
    case email
    /// Slack, Teams, Google Chat.
    case workChat
    /// Messages, WhatsApp, Telegram, Signal, Discord.
    case personalChat
    case notes
    /// Everything not listed, including code editors, terminals and documents.
    case other

    var format: CleanupContext.Format {
        switch self {
        case .email: return .email
        case .workChat, .personalChat: return .message
        case .notes: return .notes
        case .other: return .general
        }
    }

    var defaultTone: CleanupContext.Tone {
        switch self {
        case .email, .workChat: return .formal
        case .personalChat, .notes, .other: return .casual
        }
    }

    /// Where a dictation into the app `bundleID` goes, showing a web page from `host` when
    /// it is a browser. A known site wins over its app; unknown apps and sites are `other`.
    static func `for`(bundleID: String?, host: String?) -> Destination {
        if let host = host?.lowercased(),
           let site = sites.first(where: { site in site.domains.contains { matches(host, $0) } }) {
            return site.destination
        }
        return bundleID.flatMap { apps[$0] } ?? .other
    }

    /// Native apps by bundle ID. Code editors, terminals and document apps stay `other`:
    /// the model has no data for them yet.
    static let apps: [String: Destination] = {
        let groups: [(Destination, [String])] = [
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
            (.workChat, [
                "com.tinyspeck.slackmacgap",          // Slack
                "com.microsoft.teams2",
                "com.microsoft.teams",
                "com.google.Chat",
            ]),
            (.personalChat, [
                "com.apple.MobileSMS",                // Messages
                "net.whatsapp.WhatsApp",
                "desktop.WhatsApp",                   // the older Electron WhatsApp
                "com.hnc.Discord",
                "ru.keepcoder.Telegram",
                "org.telegram.desktop",
                "org.whispersystems.signal-desktop",
                "com.facebook.archon",                // Messenger
                "com.facebook.archon.developerID",
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
        return Dictionary(uniqueKeysWithValues: groups.flatMap { destination, ids in ids.map { ($0, destination) } })
    }()

    /// Web apps by host; a domain also matches its subdomains. Checked before the browser's
    /// own bundle ID, which is `other`.
    static let sites: [(destination: Destination, domains: [String])] = [
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
        (.workChat, [
            "slack.com",
            "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
            "chat.google.com",
        ]),
        (.personalChat, [
            "web.whatsapp.com",
            "discord.com",
            "web.telegram.org",
            "messenger.com",
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
