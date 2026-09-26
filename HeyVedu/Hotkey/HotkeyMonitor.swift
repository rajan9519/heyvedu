import AppKit
import CoreGraphics
import os

/// Push-to-talk detection for Control+Option via a session event tap.
///
/// Lifecycle of one press:
/// - `.pressed`   chord went down: start the mic now so device warm-up overlaps the hold.
/// - `.activated` chord held past `activationDelay`: this is a real dictation.
/// - `.released`  chord released after activation: finish and transcribe.
/// - `.cancelled` released early, another key/modifier pressed, or Esc: discard.
final class HotkeyMonitor {
    enum Event {
        case pressed
        case activated
        case released
        case cancelled
    }

    var onEvent: ((Event) -> Void)?

    private enum Phase {
        case idle
        case arming
        case active
    }

    private static let activationDelay: Duration = .milliseconds(250)
    private static let escapeKeyCode: Int64 = 53
    private static let chordFlags: CGEventFlags = [.maskControl, .maskAlternate]
    private static let trackedFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var phase: Phase = .idle
    private var activationTask: Task<Void, Never>?
    private var swallowEscapeKeyUp = false
    private let logger = Logger(subsystem: "com.rajan.heyvedu", category: "Hotkey")

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
        if phase != .idle { cancel(reason: "monitor stopped") }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
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
            handleFlags(flags)
            return false

        case .keyDown:
            guard phase != .idle else { return false }
            let isEscape = keyCode == Self.escapeKeyCode
            // Key identity is deliberately not logged beyond Esc vs other.
            cancel(reason: isEscape ? "escape" : "other key pressed")
            if isEscape {
                swallowEscapeKeyUp = true
                return true
            }
            // Any other key means Control+Option was part of a shortcut; let it through.
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

    private func handleFlags(_ flags: CGEventFlags) {
        let held = flags.intersection(Self.trackedFlags)
        let chordHeld = held == Self.chordFlags

        switch phase {
        case .idle:
            if chordHeld { arm() }
        case .arming:
            if !chordHeld { cancel(reason: "released or modifier changed before activation") }
        case .active:
            if chordHeld { return }
            // Extra modifier added on top of the chord → it's a shortcut, not a release.
            if held.isSuperset(of: Self.chordFlags) {
                cancel(reason: "extra modifier added")
            } else {
                DebugTrace.write("hotkey: released")
                logger.notice("Released after activation")
                phase = .idle
                onEvent?(.released)
            }
        }
    }

    private func arm() {
        phase = .arming
        onEvent?(.pressed)
        activationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.activationDelay)
            guard let self, !Task.isCancelled, self.phase == .arming else { return }
            self.phase = .active
            DebugTrace.write("hotkey: activated")
            self.logger.notice("Activated")
            self.onEvent?(.activated)
        }
    }

    private func cancel(reason: String) {
        activationTask?.cancel()
        activationTask = nil
        guard phase != .idle else { return }
        DebugTrace.write("hotkey: cancelled (\(reason))")
        logger.notice("Cancelled: \(reason, privacy: .public)")
        phase = .idle
        onEvent?(.cancelled)
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
