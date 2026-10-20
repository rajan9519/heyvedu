import CoreGraphics
import Testing
@testable import HeyVedu

/// Drives `HotkeyMonitor.handle` with synthetic events and records what it reports.
/// Timing-dependent steps wait past the monitor's activation delay (250 ms).
@MainActor
final class MonitorHarness {
    let monitor = HotkeyMonitor()
    private(set) var events: [HotkeyMonitor.Event] = []

    init(hotkey: Hotkey = .default, handsFree: Bool = true) {
        monitor.hotkey = hotkey
        monitor.handsFreeEnabled = handsFree
        monitor.onEvent = { [unowned self] in events.append($0) }
    }

    func flags(_ raw: UInt64) {
        _ = monitor.handle(type: .flagsChanged, flags: CGEventFlags(rawValue: raw), keyCode: 0)
    }

    @discardableResult
    func keyDown(_ keyCode: Int64) -> Bool {
        monitor.handle(type: .keyDown, flags: [], keyCode: keyCode)
    }

    @discardableResult
    func keyUp(_ keyCode: Int64) -> Bool {
        monitor.handle(type: .keyUp, flags: [], keyCode: keyCode)
    }

    func press() { flags(Flags.leftControl | Flags.leftOption) }
    func release() { flags(0) }

    func wait(ms: Int) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }
}

@MainActor
@Suite(.serialized)
struct HotkeyMonitorTests {
    static let escape: Int64 = 53
    static let letterC: Int64 = 8
    /// Past the activation delay.
    static let hold = 400
    /// Well past the activation delay.
    static let pause = 500

    @Test func holdAndReleaseDictates() async throws {
        let h = MonitorHarness()
        h.press()
        #expect(h.events == [.pressed])
        try await h.wait(ms: Self.hold)
        #expect(h.events == [.pressed, .activated])
        h.release()
        #expect(h.events == [.pressed, .activated, .released])
    }


    @Test func quickReleaseWithoutHandsFreeCancelsImmediately() {
        let h = MonitorHarness(handsFree: false)
        h.press()
        h.release()
        #expect(h.events == [.pressed, .cancelled])
    }

    @Test func tapLocksAndNextPressFinishes() async throws {
        let h = MonitorHarness()
        h.press()
        h.release()
        #expect(h.events == [.pressed, .locked])
        try await h.wait(ms: Self.pause)
        #expect(h.events == [.pressed, .locked], "locked recording keeps going without the keys")
        h.press()
        #expect(h.events == [.pressed, .locked, .released])
        // The finishing press doesn't start a new dictation until the keys come up.
        try await h.wait(ms: Self.hold)
        h.release()
        #expect(h.events == [.pressed, .locked, .released])
        h.press()
        #expect(h.events == [.pressed, .locked, .released, .pressed])
    }

    @Test func typingWhileLockedIsAllowedButEscapeCancels() {
        let h = MonitorHarness()
        h.press(); h.release()
        #expect(h.events == [.pressed, .locked])
        #expect(h.keyDown(Self.letterC) == false)
        #expect(h.events == [.pressed, .locked])
        #expect(h.keyDown(Self.escape) == true, "Esc is swallowed")
        #expect(h.keyUp(Self.escape) == true)
        #expect(h.events == [.pressed, .locked, .cancelled])
    }

    @Test func otherKeyDuringHoldIsAShortcut() async throws {
        let h = MonitorHarness()
        h.press()
        try await h.wait(ms: Self.hold)
        #expect(h.keyDown(Self.letterC) == false, "the shortcut's key passes through")
        #expect(h.events == [.pressed, .activated, .cancelled])
        h.release()
        #expect(h.events == [.pressed, .activated, .cancelled])
    }

    @Test func escapeDuringHoldCancels() async throws {
        let h = MonitorHarness()
        h.press()
        try await h.wait(ms: Self.hold)
        #expect(h.keyDown(Self.escape) == true)
        #expect(h.events == [.pressed, .activated, .cancelled])
    }

    @Test func addingAModifierCancels() async throws {
        let h = MonitorHarness()
        h.press()
        try await h.wait(ms: Self.hold)
        h.flags(Flags.leftControl | Flags.leftOption | Flags.leftCommand)
        #expect(h.events == [.pressed, .activated, .cancelled])
    }

    @Test func modifierAddedBeforeActivationCancels() {
        let h = MonitorHarness()
        h.press()
        h.flags(Flags.leftControl | Flags.leftOption | Flags.leftShift)
        #expect(h.events == [.pressed, .cancelled])
    }

    @Test func keysWhileIdleAreIgnored() {
        let h = MonitorHarness()
        #expect(h.keyDown(Self.escape) == false)
        #expect(h.keyDown(Self.letterC) == false)
        h.flags(Flags.leftControl)
        #expect(h.events.isEmpty)
    }

    @Test func rightCommandIgnoresLeftCommand() async throws {
        let h = MonitorHarness(hotkey: try #require(Hotkey(rawFlags: Flags.rightCommand)))
        h.flags(Flags.leftCommand)
        #expect(h.events.isEmpty)
        h.flags(0)
        h.flags(Flags.rightCommand)
        try await h.wait(ms: Self.hold)
        h.flags(0)
        #expect(h.events == [.pressed, .activated, .released])
    }

    @Test func suspendedMonitorIgnoresInputAndCancelsAPress() {
        let h = MonitorHarness()
        h.press()
        h.monitor.isSuspended = true
        #expect(h.events == [.pressed, .cancelled])
        h.release()
        h.press()
        #expect(h.events == [.pressed, .cancelled])
    }

    @Test func resetForgetsThePress() async throws {
        let h = MonitorHarness()
        h.press()
        try await h.wait(ms: Self.hold)
        h.monitor.reset()
        h.release()
        #expect(h.events == [.pressed, .activated])
        h.press()
        #expect(h.events == [.pressed, .activated, .pressed])
    }
}
