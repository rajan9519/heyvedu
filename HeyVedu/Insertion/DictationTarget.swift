import AppKit
import ApplicationServices
import Carbon

/// The app a dictation goes into and, in a browser, the host of the page it's on. Read when
/// the hotkey is pressed (the cursor is in the target then) and mapped to how the text is
/// written (`Destination.for(bundleID:host:)`).
///
/// The page's host comes from Accessibility first: the focused element's enclosing web area
/// has the page URL (`AXURL`), which needs no extra permission. Browsers that don't expose it
/// are asked over Apple Events instead, which macOS lets the user allow or deny once per
/// browser. Anything that fails leaves the host unknown, and the app's own format (none, for
/// a browser) applies: the plain cleanup.
nonisolated struct DictationTarget: Equatable, Sendable {
    var bundleID: String?
    var processID: pid_t
    var host: String?
    /// How the host was found ("ax", "apple-events"), or why it wasn't; debug log only.
    var hostSource: String?

    var destination: Destination { .for(bundleID: bundleID, host: host) }

    var isBrowser: Bool { bundleID.flatMap { Self.browsers[$0] } != nil }

    /// Debug log line. The host only, never a full URL or anything typed.
    var summary: String {
        var parts = ["app \(bundleID ?? "unknown")"]
        if isBrowser { parts.append("host \(host ?? "unknown") (\(hostSource ?? "none"))") }
        parts.append("destination \(destination.rawValue)")
        return parts.joined(separator: ", ")
    }

    /// The frontmost app right now, with its page host when it's a browser. Slow or denied
    /// lookups end with no host. With `askConsent`, a browser that needs Apple Events and
    /// hasn't been allowed yet gets macOS's prompt, once per launch; this dictation goes on
    /// without its host meanwhile.
    @MainActor
    static func current(askConsent: Bool = false) async -> DictationTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return await detect(bundleID: app.bundleIdentifier, processID: app.processIdentifier, askConsent: askConsent)
    }

    static func detect(bundleID: String?, processID: pid_t, askConsent: Bool = false) async -> DictationTarget {
        var target = DictationTarget(bundleID: bundleID, processID: processID)
        guard let bundleID, let browser = browsers[bundleID] else { return target }
        let lookup = await Task.detached(priority: .userInitiated) {
            Self.lookUpHost(bundleID: bundleID, processID: processID, browser: browser, askConsent: askConsent)
        }.value
        target.host = lookup.host
        target.hostSource = lookup.source
        return target
    }

    // MARK: Browsers

    enum Browser: Sendable {
        /// `URL of current tab of front window`
        case safari
        /// `URL of active tab of front window`; Chromium also builds its accessibility tree
        /// only for assistive apps that ask for it.
        case chromium
        /// No Apple Events dictionary; Accessibility only.
        case firefox
    }

    static let browsers: [String: Browser] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.kagi.kagimacOS": .safari,                 // Orion
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.brave.Browser": .chromium,
        "com.brave.Browser.beta": .chromium,
        "com.brave.Browser.nightly": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.microsoft.edgemac.Beta": .chromium,
        "com.microsoft.edgemac.Dev": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        "company.thebrowser.Browser": .chromium,      // Arc
        "company.thebrowser.dia": .chromium,          // Dia
        "org.mozilla.firefox": .firefox,
        "org.mozilla.firefoxdeveloperedition": .firefox,
        "org.mozilla.nightly": .firefox,
        "app.zen-browser.zen": .firefox,
    ]

    /// Keeps a hung browser from holding up the dictation.
    private static let messagingTimeout: Float = 0.25

    private static func lookUpHost(
        bundleID: String, processID: pid_t, browser: Browser, askConsent: Bool
    ) -> (host: String?, source: String) {
        // A page Accessibility can see but that isn't a website (a new tab, a local file)
        // has no host to map, and no reason to ask for Apple Events.
        if let url = accessibilityURL(processID: processID, browser: browser) {
            return url.scheme?.hasPrefix("http") == true ? (url.host(), "ax") : (nil, "not a web page")
        }
        switch scriptedURL(bundleID: bundleID, browser: browser) {
        case .success(let url):
            if url.scheme?.hasPrefix("http") == true, let host = url.host() { return (host, "apple-events") }
            return (nil, "not a web page")
        case .failure(.awaitingConsent):
            if askConsent { requestConsentOnce(bundleID: bundleID) }
            return (nil, ScriptFailure.awaitingConsent.description)
        case .failure(let reason):
            return (nil, reason.description)
        }
    }

    // MARK: Accessibility

    private static func accessibilityURL(processID: pid_t, browser: Browser) -> URL? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        if browser == .chromium {
            // Chromium builds its web accessibility tree only when an assistive app asks. It
            // stays on for that browser process; VoiceOver and other dictation apps do the same.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        if let focused = element(app, kAXFocusedUIElementAttribute), let url = enclosingWebAreaURL(of: focused) {
            return url
        }
        // Focus in the address bar or toolbar: the focused window's web area.
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        if let document = value(window, kAXDocumentAttribute) as? String, let url = URL(string: document) {
            return url
        }
        return firstWebAreaURL(in: window, depth: 0, budget: 400).url
    }

    /// Walks up from the focused element to the web area that contains it.
    private static func enclosingWebAreaURL(of element: AXUIElement) -> URL? {
        var current: AXUIElement? = element
        for _ in 0..<80 {
            guard let node = current else { return nil }
            if role(of: node) == "AXWebArea", let url = webURL(node) { return url }
            current = Self.element(node, kAXParentAttribute)
        }
        return nil
    }

    /// Breadth-limited search for the first web area with a page URL.
    private static func firstWebAreaURL(in element: AXUIElement, depth: Int, budget: Int) -> (url: URL?, budget: Int) {
        var budget = budget - 1
        guard budget > 0, depth < 12 else { return (nil, budget) }
        if role(of: element) == "AXWebArea", let url = webURL(element) { return (url, budget) }
        guard let children = value(element, kAXChildrenAttribute) as? [AXUIElement] else { return (nil, budget) }
        for child in children {
            AXUIElementSetMessagingTimeout(child, messagingTimeout)
            let found = firstWebAreaURL(in: child, depth: depth + 1, budget: budget)
            budget = found.budget
            if let url = found.url { return (url, budget) }
            if budget <= 0 { break }
        }
        return (nil, budget)
    }

    private static func webURL(_ element: AXUIElement) -> URL? {
        let raw = value(element, kAXURLAttribute)
        let url: URL?
        if let raw, CFGetTypeID(raw) == CFURLGetTypeID() {
            url = (raw as! CFURL) as URL
        } else {
            url = (raw as? String).flatMap(URL.init(string:))
        }
        guard let url, url.scheme != nil else { return nil }
        return url
    }

    private static func role(of element: AXUIElement) -> String? {
        value(element, kAXRoleAttribute) as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let found = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(found, messagingTimeout)
        return found
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw
    }

    // MARK: Apple Events

    enum ScriptFailure: Error, CustomStringConvertible {
        case unsupported
        case notPermitted
        case awaitingConsent
        case failed(Int)

        var description: String {
            switch self {
            case .unsupported: return "no apple events"
            case .notPermitted: return "apple events denied"
            case .awaitingConsent: return "apple events not yet allowed"
            case .failed(let code): return "apple events error \(code)"
            }
        }
    }

    /// One script runs at a time: NSAppleScript isn't safe to run concurrently.
    private static let scriptLock = NSLock()

    /// Asks the browser for its front tab's URL. macOS asks the user once per browser; until
    /// they answer, and after they deny, this fails without asking again.
    private static func scriptedURL(bundleID: String, browser: Browser) -> Result<URL, ScriptFailure> {
        let source: String
        switch browser {
        case .safari: source = "tell application id \"\(bundleID)\" to get URL of current tab of front window"
        case .chromium: source = "tell application id \"\(bundleID)\" to get URL of active tab of front window"
        case .firefox: return .failure(.unsupported)
        }
        switch automationPermission(bundleID: bundleID) {
        case noErr: break
        case OSStatus(errAEEventNotPermitted): return .failure(.notPermitted)
        case OSStatus(errAEEventWouldRequireUserConsent): return .failure(.awaitingConsent)
        case let status: return .failure(.failed(Int(status)))
        }
        scriptLock.lock()
        defer { scriptLock.unlock() }
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            return .failure(.failed(error?[NSAppleScript.errorNumber] as? Int ?? 0))
        }
        guard let string = result.stringValue, let url = URL(string: string) else { return .failure(.failed(0)) }
        return .success(url)
    }

    /// Whether this app may send Apple Events to the browser, without prompting.
    private static func automationPermission(bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
    }

    /// Browsers asked for consent this launch.
    private nonisolated(unsafe) static var consentRequests: Set<String> = []
    private static let consentLock = NSLock()

    /// Shows macOS's "allow HeyVedu to control <browser>" prompt in the background, at most
    /// once per browser per launch. The prompt blocks its thread until answered, and macOS
    /// remembers the answer.
    private static func requestConsentOnce(bundleID: String) {
        guard consentLock.withLock({ consentRequests.insert(bundleID).inserted }) else { return }
        DispatchQueue.global(qos: .utility).async {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
            DebugTrace.write("target: apple events consent for \(bundleID): \(status)")
        }
    }
}
