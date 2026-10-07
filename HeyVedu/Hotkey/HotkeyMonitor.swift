import AppKit
import CoreGraphics
import os

/// Push-to-talk detection for the configured modifier hotkey via a session event tap.
///
/// Lifecycle of one press:
/// - `.pressed`   hotkey went down: start the mic now so device warm-up overlaps the hold.
/// - `.activated` hotkey held past `activationDelay`: this is a real dictation.
/// - `.released`  hotkey released after activation, or tapped again while locked: finish
///                and transcribe.
/// - `.cancelled` released early, another key/modifier pressed, or Esc: discard.
///
/// With hands-free mode on, a quick tap followed by a second press within
/// `doubleTapWindow` sends `.locked` instead: recording continues without holding the
/// keys until the next press of the hotkey (or Esc to cancel).
final class HotkeyMonitor {
    enum Event {
        case pressed
        case activated
        case locked
        case released
        case cancelled
    }

    var onEvent: ((Event) -> Void)?

    var hotkey: Hotkey = .default {
        didSet {
            guard hotkey != oldValue else { return }
            cancel(reason: "hotkey changed")
            phase = .idle
        }
    }

    var handsFreeEnabled = true

    /// Ignores all input while true, e.g. while the user records a new hotkey.
    var isSuspended = false {
        didSet {
            guard isSuspended, !oldValue else { return }
            cancel(reason: "suspended")
            phase = .idle
        }
    }

    private enum Phase {
        case idle
        /// Held, not yet past the activation delay.
        case arming
        /// Held past the activation delay (push-to-talk).
        case active
        /// Released quickly; waiting briefly for a second press.
        case tapped
        /// Second press of a double-tap is still held.
        case lockHeld
        /// Hands-free recording; the next press finishes it.
        case locked
        /// Finished on a press; waiting for all of the hotkey's keys to come up before
        /// arming again.
        case awaitingRelease
    }

    private static let activationDelay: Duration = .milliseconds(250)
    private static let doubleTapWindow: Duration = .milliseconds(350)
    private static let escapeKeyCode: Int64 = 53

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var phase: Phase = .idle
    private var timer: Task<Void, Never>?
    private var swallowEscapeKeyUp = false
    /// Whether the hotkey was held as of the latest modifier change.
    private var hotkeyHeld = false
    private let logger = Logger(subsystem: "com.heyvedu.app", category: "Hotkey")

    /// Returns false if the tap could not be created (usually missing Accessibility trust).
    func start() -> Bool {
        if tap != nil { return true }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        cancel(reason: "monitor stopped")
        phase = .idle
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// Forgets the current press without sending an event, for when a recording ended or
    /// was refused for some other reason (so a later press isn't taken as "finish").
    func reset() {
        timer?.cancel()
        timer = nil
        phase = hotkeyHeld ? .awaitingRelease : .idle
    }

    /// Returns true if the event should be swallowed.
    fileprivate func handle(type: CGEventType, flags: CGEventFlags, keyCode: Int64) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            DebugTrace.write("hotkey: tap disabled type=\(type.rawValue)")
            logger.notice("Event tap disabled (type \(type.rawValue, privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .flagsChanged:
            guard !isSuspended else { return false }
            handleFlags(flags.rawValue)
            return false

        case .keyDown:
            guard !isSuspended else { return false }
            let isEscape = keyCode == Self.escapeKeyCode
            switch phase {
            case .idle, .awaitingRelease:
                return false
            case .locked:
                // Typing while hands-free is fine; only Esc cancels.
                guard isEscape else { return false }
            case .arming, .active, .tapped, .lockHeld:
                break
            }
            // Key identity is deliberately not logged beyond Esc vs other.
            cancel(reason: isEscape ? "escape" : "other key pressed")
            if isEscape {
                swallowEscapeKeyUp = true
                return true
            }
            // Any other key means the hotkey was part of a shortcut; let it through.
            return false

        case .keyUp:
            if swallowEscapeKeyUp && keyCode == Self.escapeKeyCode {
                swallowEscapeKeyUp = false
                return true
            }
            return false

        default:
            return false
        }
    }

    private func handleFlags(_ rawFlags: UInt64) {
        let held = hotkey.isHeld(in: rawFlags)
        hotkeyHeld = held

        switch phase {
        case .idle:
            if held { arm() }

        case .arming:
            if held { return }
            if handsFreeEnabled && !hotkey.isPartOfOtherShortcut(in: rawFlags) {
                // A quick tap: keep the mic warm in case a second press locks recording.
                timer?.cancel()
                phase = .tapped
                timer = Task { [weak self] in
                    try? await Task.sleep(for: Self.doubleTapWindow)
                    guard let self, !Task.isCancelled, self.phase == .tapped else { return }
                    self.cancel(reason: "single tap")
                }
            } else {
                cancel(reason: "released or modifier changed before activation")
            }

        case .active:
            if held { return }
            // Extra modifier added on top of the hotkey → it's a shortcut, not a release.
            if hotkey.isPartOfOtherShortcut(in: rawFlags) {
                cancel(reason: "extra modifier added")
            } else {
                DebugTrace.write("hotkey: released")
                logger.notice("Released after activation")
                phase = .idle
                onEvent?(.released)
            }

        case .tapped:
            guard held else { return }
            timer?.cancel()
            timer = nil
            phase = .lockHeld
            DebugTrace.write("hotkey: locked")
            logger.notice("Locked for hands-free recording")
            onEvent?(.locked)

        case .lockHeld:
            if !held { phase = .locked }

        case .locked:
            guard held else { return }
            DebugTrace.write("hotkey: finished hands-free")
            logger.notice("Hands-free recording finished")
            phase = .awaitingRelease
            onEvent?(.released)

        case .awaitingRelease:
            if Hotkey.Modifiers(rawFlags: rawFlags).isDisjoint(with: hotkey.modifiers) { phase = .idle }
        }
    }

    private func arm() {
        phase = .arming
        onEvent?(.pressed)
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.activationDelay)
            guard let self, !Task.isCancelled, self.phase == .arming else { return }
            self.phase = .active
            DebugTrace.write("hotkey: activated")
            self.logger.notice("Activated")
            self.onEvent?(.activated)
        }
    }

    private func cancel(reason: String) {
        timer?.cancel()
        timer = nil
        switch phase {
        case .idle, .awaitingRelease:
            return
        case .arming, .active, .tapped, .lockHeld, .locked:
            DebugTrace.write("hotkey: cancelled (\(reason))")
            logger.notice("Cancelled: \(reason, privacy: .public)")
            phase = hotkeyHeld ? .awaitingRelease : .idle
            onEvent?(.cancelled)
        }
    }
}

/// C callback for the event tap. The tap's run loop source is on the main run loop,
/// so it is safe to assume main-actor isolation here.
private nonisolated func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let address = UInt(bitPattern: refcon)
    let swallow = MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return false }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
        return monitor.handle(type: type, flags: flags, keyCode: keyCode)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
