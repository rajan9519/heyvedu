import AppKit
import ApplicationServices

/// Learns what the user changes in a dictation after it's pasted, for later training.
///
/// Right after a paste, the focused text field's value is read over Accessibility and split
/// around the pasted text: the text before it, the pasted text, the text after it. The field
/// is then re-read on every change Accessibility reports, and every second in case the app
/// reports none; while the text before and after is unchanged, whatever sits between them is
/// the user's version of the dictation. Reading on each change catches an edit made right
/// before the field is sent and cleared (a chat message sent with Return). Watching ends
/// after `watchDuration`, when the next dictation starts, or as soon as that split no longer
/// holds (the field was sent and cleared, text elsewhere was edited, the field went away).
/// The last version seen is reported if it differs from what was pasted.
///
/// Silent and best effort: fields that Accessibility can't read, or whose value doesn't
/// contain the pasted text as pasted, are not watched. Nothing is shown to the user.
final class EditWatcher {
    private static let settleDelay: Duration = .milliseconds(200)
    private static let locateAttempts = 5
    private static let pollInterval: Duration = .seconds(1)
    private static let watchDuration: Duration = .seconds(90)
    /// Larger fields (long documents) aren't re-read on every change.
    private static let maximumLength = 100_000
    private static let messagingTimeout: Float = 0.25

    private var task: Task<Void, Never>?

    /// Called when recording starts in `processID`'s app. Chromium-based apps (Electron apps
    /// such as Claude, Slack and VS Code) build their accessibility tree only for assistive
    /// apps that ask for it, so ask while the user speaks: the field is readable by the paste.
    /// It stays on for that app's process; VoiceOver and other dictation apps do the same.
    /// Other apps ignore the attribute.
    static func prepare(processID: pid_t) {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Starts watching the field in `processID`'s app that `inserted` was just pasted into,
    /// ending any earlier watch. `onEdited` gets the user's version of the text, at most once.
    func watch(inserted: String, processID: pid_t?, onEdited: @escaping (String) -> Void) {
        finish()
        task = Task {
            guard let anchors = await Self.locate(inserted, processID: processID) else {
                DebugTrace.write("edits: pasted text not readable, not watching")
                return
            }
            let tracker = Tracker(anchors: anchors, inserted: inserted)
            var notified = 0
            let changes = ChangeObserver(element: anchors.element) {
                notified += 1
                tracker.update()
            }
            DebugTrace.write("edits: watching \(Self.role(of: anchors.element) ?? "?"), \((anchors.before as NSString).length)+\((inserted as NSString).length)+\((anchors.after as NSString).length) chars\(changes == nil ? ", no change notifications" : "")")
            let deadline = ContinuousClock.now + Self.watchDuration
            while !Task.isCancelled, !tracker.isOver, ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.pollInterval)
                tracker.update()
            }
            changes?.stop()
            let end = Task.isCancelled ? "next dictation" : tracker.isOver ? tracker.endReason : "time limit"
            DebugTrace.write("edits: stopped (\(end)) after \(notified) notifications, \(tracker.changes) changes seen")
            guard Self.isEdit(tracker.latest, of: inserted) else { return }
            // Lengths only — never the text itself.
            DebugTrace.write("edits: \(inserted.count) → \(tracker.latest.count) characters")
            onEdited(tracker.latest)
        }
    }

    /// Ends the current watch, reporting what it has seen so far.
    func finish() {
        task?.cancel()
        task = nil
    }

    /// The user's version of the pasted text, as of the last read that still found it.
    private final class Tracker {
        private let anchors: Anchors
        private(set) var latest: String
        /// The field no longer holds the text around the dictation; later reads are ignored.
        private(set) var isOver = false
        /// Why it's over; debug log only.
        private(set) var endReason = ""
        /// Reads that found a different version than the one before; debug log only.
        private(set) var changes = 0

        init(anchors: Anchors, inserted: String) {
            self.anchors = anchors
            latest = inserted
        }

        func update() {
            guard !isOver else { return }
            guard let value = EditWatcher.value(of: anchors.element) else {
                isOver = true
                endReason = "value unreadable"
                return
            }
            guard let span = EditWatcher.editedSpan(in: value, before: anchors.before, after: anchors.after) else {
                isOver = true
                endReason = "text around it changed, value now \((value as NSString).length) chars"
                return
            }
            if span != latest { changes += 1 }
            latest = span
        }
    }

    /// Calls `onChange` on the main thread whenever Accessibility reports that the element's
    /// text or selection changed (selection changes too: some apps report only those while
    /// typing). Nil when the app can't report changes.
    private final class ChangeObserver {
        private let element: AXUIElement
        private let onChange: () -> Void
        private var observer: AXObserver?

        private static let notifications = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]

        init?(element: AXUIElement, onChange: @escaping () -> Void) {
            self.element = element
            self.onChange = onChange
            var processID: pid_t = 0
            var created: AXObserver?
            guard AXUIElementGetPid(element, &processID) == .success,
                  AXObserverCreate(processID, { _, _, _, context in
                      guard let context else { return }
                      let changes = Unmanaged<ChangeObserver>.fromOpaque(context).takeUnretainedValue()
                      MainActor.assumeIsolated { changes.onChange() }
                  }, &created) == .success, let created else { return nil }
            let context = Unmanaged.passUnretained(self).toOpaque()
            let added = Self.notifications.filter {
                AXObserverAddNotification(created, element, $0 as CFString, context) == .success
            }
            guard !added.isEmpty else { return nil }
            observer = created
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        }

        /// Must be called before this is released: the observer holds an unretained pointer.
        func stop() {
            guard let observer else { return }
            for notification in Self.notifications {
                AXObserverRemoveNotification(observer, element, notification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            self.observer = nil
        }
    }

    // MARK: Matching

    /// The text between `before` and `after` in `value`, if `value` still starts with
    /// `before` and ends with `after`. Nil when the field was emptied (a chat message sent;
    /// some editors, Claude's among them, then hold a lone line break) or the dictation was
    /// deleted outright: neither is an edit of the text.
    static func editedSpan(in value: String, before: String, after: String) -> String? {
        let value = value as NSString
        let prefix = (before as NSString).length
        let suffix = (after as NSString).length
        guard value.length > prefix + suffix,
              value.substring(to: prefix) == before,
              value.substring(from: value.length - suffix) == after else { return nil }
        let span = value.substring(with: NSRange(location: prefix, length: value.length - prefix - suffix))
        return span.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : span
    }

    /// Whether `edited` differs from `inserted` by more than surrounding whitespace.
    static func isEdit(_ edited: String, of inserted: String) -> Bool {
        let edited = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        return !edited.isEmpty && edited != inserted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits `value` around the pasted text, which ends at `caret` when the paste left the
    /// cursor after it, or is otherwise its last occurrence.
    static func split(_ value: String, inserted: String, caret: Int?) -> (before: String, after: String)? {
        let value = value as NSString
        let length = (inserted as NSString).length
        guard length > 0 else { return nil }
        var range = NSRange(location: NSNotFound, length: 0)
        if let caret, caret >= length, caret <= value.length,
           value.substring(with: NSRange(location: caret - length, length: length)) == inserted {
            range = NSRange(location: caret - length, length: length)
        } else {
            range = value.range(of: inserted, options: .backwards)
        }
        guard range.location != NSNotFound else { return nil }
        return (value.substring(to: range.location), value.substring(from: NSMaxRange(range)))
    }

    // MARK: Accessibility

    private struct Anchors {
        let element: AXUIElement
        let before: String
        let after: String
    }

    /// Finds the pasted text in the focused field, giving the target app a moment to apply
    /// the paste.
    private static func locate(_ inserted: String, processID: pid_t?) async -> Anchors? {
        for _ in 0..<locateAttempts {
            try? await Task.sleep(for: settleDelay)
            if Task.isCancelled { return nil }
            guard let element = focusedElement(processID: processID), let value = value(of: element) else { continue }
            if let split = split(value, inserted: inserted, caret: caret(of: element)) {
                return Anchors(element: element, before: split.before, after: split.after)
            }
        }
        return nil
    }

    /// The app's focused element, else the system-wide one.
    private static func focusedElement(processID: pid_t?) -> AXUIElement? {
        let owner = processID.map(AXUIElementCreateApplication) ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(owner, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return processID == nil ? nil : focusedElement(processID: nil)
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    fileprivate static func value(of element: AXUIElement) -> String? {
        var count: CFIndex = 0
        if AXUIElementGetAttributeValueCount(element, kAXValueAttribute as CFString, &count) == .success,
           count > maximumLength { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let string = raw as? String, (string as NSString).length <= maximumLength else { return nil }
        return string
    }

    fileprivate static func role(of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    /// Where the cursor is, when nothing is selected.
    private static func caret(of element: AXUIElement) -> Int? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.length == 0 else { return nil }
        return range.location
    }
}
