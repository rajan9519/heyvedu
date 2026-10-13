import Foundation
import CoreGraphics
import Testing
@testable import HeyVedu

/// Raw modifier flags as a `CGEvent` carries them: the device-independent mask plus the
/// left/right device bits (IOLLEvent.h).
enum Flags {
    static let control = CGEventFlags.maskControl.rawValue
    static let option = CGEventFlags.maskAlternate.rawValue
    static let shift = CGEventFlags.maskShift.rawValue
    static let command = CGEventFlags.maskCommand.rawValue
    static let function = CGEventFlags.maskSecondaryFn.rawValue

    static let leftControl = control | 0x0000_0001
    static let rightControl = control | 0x0000_2000
    static let leftShift = shift | 0x0000_0002
    static let leftCommand = command | 0x0000_0008
    static let rightCommand = command | 0x0000_0010
    static let leftOption = option | 0x0000_0020
    static let rightOption = option | 0x0000_0040
}

struct HotkeyTests {
    @Test func defaultIsControlOptionOnEitherSide() {
        let hotkey = Hotkey.default
        #expect(hotkey.isHeld(in: Flags.leftControl | Flags.leftOption))
        #expect(hotkey.isHeld(in: Flags.rightControl | Flags.rightOption))
        #expect(hotkey.isHeld(in: Flags.leftControl | Flags.rightOption))
        #expect(!hotkey.isHeld(in: Flags.leftControl))
        #expect(!hotkey.isHeld(in: Flags.leftControl | Flags.leftOption | Flags.leftCommand))
        #expect(hotkey.symbols == "⌃⌥")
        #expect(hotkey.problem == nil)
    }

    @Test func extraModifierIsAnotherShortcut() {
        let hotkey = Hotkey.default
        #expect(hotkey.isPartOfOtherShortcut(in: Flags.leftControl | Flags.leftOption | Flags.leftShift))
        #expect(!hotkey.isPartOfOtherShortcut(in: Flags.leftControl | Flags.leftOption))
        #expect(!hotkey.isPartOfOtherShortcut(in: Flags.leftControl))
    }

    @Test func recordedRightCommandIsRightOnly() throws {
        let hotkey = try #require(Hotkey(rawFlags: Flags.rightCommand))
        #expect(hotkey.modifiers == .command)
        #expect(hotkey.side(of: .command) == .right)
        #expect(hotkey.isHeld(in: Flags.rightCommand))
        #expect(!hotkey.isHeld(in: Flags.leftCommand))
        #expect(!hotkey.isHeld(in: Flags.leftCommand | 0x10))
        #expect(hotkey.isPartOfOtherShortcut(in: Flags.leftCommand))
        #expect(hotkey.symbols == "Right ⌘")
        #expect(hotkey.spokenName == "the right ⌘ Command key")
        #expect(hotkey.problem == nil)
    }

    @Test func recordedLeftOnlyComboAcceptsEitherSide() throws {
        let hotkey = try #require(Hotkey(rawFlags: Flags.leftControl | Flags.leftOption))
        #expect(hotkey == .default)
    }

    @Test func comboWithARightKeyKeepsEverySide() throws {
        let hotkey = try #require(Hotkey(rawFlags: Flags.rightOption | Flags.rightCommand))
        #expect(hotkey.rightOnly == [.option, .command])
        #expect(hotkey.isHeld(in: Flags.rightOption | Flags.rightCommand))
        #expect(!hotkey.isHeld(in: Flags.leftOption | Flags.rightCommand))
        #expect(hotkey.symbols == "Right ⌥⌘")

        let mixed = try #require(Hotkey(rawFlags: Flags.leftControl | Flags.rightCommand))
        #expect(mixed.side(of: .control) == .left)
        #expect(mixed.side(of: .command) == .right)
        #expect(mixed.symbols == "Left ⌃ Right ⌘")
    }

    @Test func functionKeyHasNoSide() throws {
        let hotkey = try #require(Hotkey(rawFlags: Flags.function))
        #expect(hotkey.modifiers == .function)
        #expect(hotkey.side(of: .function) == nil)
        #expect(hotkey.isHeld(in: Flags.function))
        #expect(hotkey.symbols == "fn")
        #expect(hotkey.spokenName == "fn (🌐)")
        #expect(hotkey.problem == nil)
    }

    @Test func noModifiersIsNotAHotkey() {
        #expect(Hotkey(rawFlags: 0) == nil)
    }

    @Test func refusesShiftAloneAndLeftHandSingleKeys() throws {
        #expect(Hotkey(modifiers: .shift).problem != nil)
        #expect(try #require(Hotkey(rawFlags: Flags.leftShift)).problem != nil)
        #expect(try #require(Hotkey(rawFlags: Flags.leftCommand)).problem != nil)
        #expect(try #require(Hotkey(rawFlags: Flags.leftOption)).problem != nil)
        #expect(try #require(Hotkey(rawFlags: Flags.rightOption)).problem == nil)
        #expect(Hotkey(modifiers: [.shift, .command]).problem == nil)
    }

    @Test func keycapsReflectSides() throws {
        let hotkey = try #require(Hotkey(rawFlags: Flags.rightCommand))
        let cap = try #require(hotkey.keycaps.first)
        #expect(cap.name == "right command")
        #expect(cap.isPressed(in: Flags.rightCommand))
        #expect(!cap.isPressed(in: Flags.leftCommand))
    }

    @Test func roundTripsThroughCodable() throws {
        let hotkey = try #require(Hotkey(rawFlags: Flags.rightOption | Flags.rightCommand))
        let data = try JSONEncoder().encode(hotkey)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == hotkey)
    }
}
