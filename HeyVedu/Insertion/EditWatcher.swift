import AppKit
import ApplicationServices

/// Learns what the user changes in a dictation after it's pasted, for later training.
///
/// Right after a paste, the focused text field's value is read over Accessibility and split
/// around the pasted text: the text before it, the pasted text, the text after it. The field
/// is then re-read every second; while the text before and after is unchanged, whatever sits
/// between them is the user's version of the dictation. Watching ends after
/// `watchDuration`, when the next dictation starts, or as soon as that split no longer holds
/// (the field was sent and cleared, text elsewhere was edited, the field went away). The
/// last version seen is reported if it differs from what was pasted.
///
/// Silent and best effort: fields that Accessibility can't read, or whose value doesn't
/// contain the pasted text as pasted, are not watched. Nothing is shown to the user.
final class EditWatcher {
    private static let settleDelay: Duration = .milliseconds(200)
    private static let locateAttempts = 5
    private static let pollInterval: Duration = .seconds(1)
    private static let watchDuration: Duration = .seconds(90)
    /// Larger fields (long documents) aren't re-read every second.
    private static let maximumLength = 100_000
    private static let messagingTimeout: Float = 0.25

    private var task: Task<Void, Never>?

    /// Starts watching the field `inserted` was just pasted into, ending any earlier watch.
    /// `onEdited` gets the user's version of the text, at most once.
    func watch(inserted: String, onEdited: @escaping (String) -> Void) {
        finish()
        task = Task {
            guard let anchors = await Self.locate(inserted) else {
                DebugTrace.write("edits: pasted text not readable, not watching")
                return
            }
            var latest = inserted
            let deadline = ContinuousClock.now + Self.watchDuration
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.pollInterval)
                guard let value = Self.value(of: anchors.element),
                      let span = Self.editedSpan(in: value, before: anchors.before, after: anchors.after) else { break }
                latest = span
            }
            guard Self.isEdit(latest, of: inserted) else { return }
            // Lengths only — never the text itself.
            DebugTrace.write("edits: \(inserted.count) → \(latest.count) characters")
            onEdited(latest)
        }
    }

    /// Ends the current watch, reporting what it has seen so far.
    func finish() {
        task?.cancel()
        task = nil
    }

    // MARK: Matching

    /// The text between `before` and `after` in `value`, if `value` still starts with
    /// `before` and ends with `after`. Nil when the field was emptied (a chat message sent)
    /// or the dictation was deleted outright: neither is an edit of the text.
    static func editedSpan(in value: String, before: String, after: String) -> String? {
        let value = value as NSString
        let prefix = (before as NSString).length
        let suffix = (after as NSString).length
        guard value.length > prefix + suffix,
              value.substring(to: prefix) == before,
              value.substring(from: value.length - suffix) == after else { return nil }
        return value.substring(with: NSRange(location: prefix, length: value.length - prefix - suffix))
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
    private static func locate(_ inserted: String) async -> Anchors? {
        for _ in 0..<locateAttempts {
            try? await Task.sleep(for: settleDelay)
            if Task.isCancelled { return nil }
            guard let element = focusedElement(), let value = value(of: element) else { continue }
            if let split = split(value, inserted: inserted, caret: caret(of: element)) {
                return Anchors(element: element, before: split.before, after: split.after)
            }
        }
        return nil
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func value(of element: AXUIElement) -> String? {
        var count: CFIndex = 0
        if AXUIElementGetAttributeValueCount(element, kAXValueAttribute as CFString, &count) == .success,
           count > maximumLength { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let string = raw as? String, (string as NSString).length <= maximumLength else { return nil }
        return string
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
