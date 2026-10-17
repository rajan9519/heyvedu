import AppKit
import ApplicationServices

/// Watches the field HeyVedu just pasted into for a short while, and reports the small
/// corrections the user makes there (AI-ASSIST-PLAN §4.2). Local and deterministic.
///
/// Polls the focused element every `pollInterval` instead of relying on
/// `kAXValueChangedNotification`, which many apps (Electron, web views) send late or never.
/// Reads only around the pasted range. Stops after `watchLimit`, when focus moves to another
/// field, or when the next dictation starts, and takes its final reading once the user has
/// stopped typing for `settleTime`.
final class EditWatcher {
    static let pollInterval: Duration = .milliseconds(500)
    static let settleTime: Duration = .milliseconds(1500)
    static let watchLimit: Duration = .seconds(20)
    /// Lets the pasted text land before the first reading.
    static let pasteSettle: Duration = .milliseconds(400)
    /// Text read on each side of the paste, beyond its own length.
    static let readPadding = 400
    private static let messagingTimeout: Float = 0.1

    /// Called once per watch with the corrections found (often none).
    var onEdits: (([DictionaryLearnTask.Edit]) -> Void)?

    private var task: Task<Void, Never>?

    /// Starts watching the focused field for edits to `pasted`. Replaces any watch in progress.
    func watch(pasted: String, in app: NSRunningApplication?) {
        stop()
        let appName = app?.localizedName
        // Enough on both sides to hold the whole paste and its anchors wherever the caret goes.
        let padding = pasted.utf16.count + Self.readPadding
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.pasteSettle)
            guard !Task.isCancelled, let field = FocusedField.current(),
                  let first = field.read(padding: padding),
                  let snapshot = CorrectionDetector.Snapshot(text: first.text, caret: first.caret, pasted: pasted)
            else {
                DebugTrace.write("learn: field not readable after paste")
                return
            }
            let edits = await Self.follow(field, snapshot: snapshot, initial: first.text, padding: padding, appName: appName)
            guard !Task.isCancelled else { return }
            DebugTrace.write("learn: \(edits.count) correction(s) found")
            if !edits.isEmpty { self?.onEdits?(edits) }
        }
    }

    /// The next dictation started: stop watching without reporting a half-typed edit.
    func stop() {
        task?.cancel()
        task = nil
    }

    private static func follow(_ field: FocusedField, snapshot: CorrectionDetector.Snapshot, initial: String,
                               padding: Int, appName: String?) async -> [DictionaryLearnTask.Edit] {
        let started = ContinuousClock.now
        var last = initial
        var lastChange: ContinuousClock.Instant?
        while started.duration(to: .now) < watchLimit {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return [] }
            guard FocusedField.current()?.isSame(as: field) == true, let reading = field.read(padding: padding) else {
                break  // focus moved on: judge what's there now
            }
            if reading.text != last {
                last = reading.text
                lastChange = .now
            } else if let lastChange, lastChange.duration(to: .now) >= settleTime {
                break
            }
        }
        guard lastChange != nil, let final = field.read(padding: padding),
              let span = CorrectionDetector.editedSpan(of: snapshot, in: final.text) else { return [] }
        return CorrectionDetector.edits(pasted: snapshot.pasted, edited: span, app: appName)
    }

    /// The focused text element of the frontmost app, read through Accessibility.
    struct FocusedField {
        let element: AXUIElement

        /// Nil for secure fields, HeyVedu's own windows, and anything that isn't text.
        static func current() -> FocusedField? {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, messagingTimeout)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            let element = value as! AXUIElement
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            let role = string(element, kAXRoleAttribute), subrole = string(element, kAXSubroleAttribute)
            guard role != "AXSecureTextField", subrole != kAXSecureTextFieldSubrole else { return nil }
            return FocusedField(element: element)
        }

        func isSame(as other: FocusedField) -> Bool {
            CFEqual(element, other.element)
        }

        /// Text around the caret, with the caret's position in that text.
        func read(padding: Int) -> (text: String, caret: Int)? {
            var rangeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
                  let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
            var selection = CFRange()
            guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return nil }
            var countValue: CFTypeRef?
            let total = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success
                ? (countValue as? Int) : nil
            let caret = selection.location + selection.length
            let start = max(0, caret - padding)
            let end = total.map { min($0, caret + padding) } ?? caret + padding
            var window = CFRange(location: start, length: max(0, end - start))
            if let parameter = AXValueCreate(.cfRange, &window) {
                var text: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                              parameter, &text) == .success, let text = text as? String {
                    return (text, caret - start)
                }
            }
            // Fallback: the whole value, only for fields small enough to read cheaply.
            guard let text = Self.string(element, kAXValueAttribute), (text as NSString).length <= 20_000,
                  caret <= (text as NSString).length else { return nil }
            return (text, caret)
        }

        private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
    }
}
