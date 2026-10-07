import AppKit
import CoreGraphics

/// A modifier-only push-to-talk shortcut, such as ⌃⌥, fn, or the right ⌘ key on its own.
///
/// Keys can be tied to one side. A shortcut recorded with any right-hand key keeps the
/// exact side of every key, so Right ⌥ + Right ⌘ ignores the left-hand ones. One recorded
/// with left-hand keys only accepts either side, since that's what people usually mean.
/// A single modifier always has a side, and the left-hand ⌘/⌥/⌃ keys are refused on their
/// own because they start too many ordinary shortcuts to double as a dictation key.
nonisolated struct Hotkey: Codable, Hashable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
        static let function = Modifiers(rawValue: 1 << 4)

        /// In the order macOS lists modifiers in menus.
        static let ordered: [Modifiers] = [.function, .control, .option, .shift, .command]
    }

    enum Side: String, Codable, Sendable {
        case left
        case right
    }

    var modifiers: Modifiers
    /// Keys that must be pressed on the left; the others in `modifiers` accept either side
    /// unless they're in `rightOnly`.
    var leftOnly: Modifiers = []
    var rightOnly: Modifiers = []

    static let `default` = Hotkey(modifiers: [.control, .option])

    init(modifiers: Modifiers, leftOnly: Modifiers = [], rightOnly: Modifiers = []) {
        self.modifiers = modifiers
        self.leftOnly = leftOnly
        self.rightOnly = rightOnly
    }

    /// The hotkey formed by the modifiers currently held, as the shortcut recorder sees it.
    init?(rawFlags: UInt64) {
        let modifiers = Modifiers(rawFlags: rawFlags)
        guard !modifiers.isEmpty else { return nil }
        self.modifiers = modifiers
        let sided = Self.Modifiers.ordered.filter { modifiers.contains($0) && Self.sideMasks[$0] != nil }
        let anyRight = sided.contains { rawFlags & Self.sideMasks[$0]!.right != 0 }
        // Only a lone key, or a combination using a right-hand key, keeps its sides.
        guard modifiers.count == 1 || anyRight else { return }
        for modifier in sided {
            if rawFlags & Self.sideMasks[modifier]!.right != 0 {
                rightOnly.insert(modifier)
            } else {
                leftOnly.insert(modifier)
            }
        }
    }

    func side(of modifier: Modifiers) -> Side? {
        if leftOnly.contains(modifier) { return .left }
        if rightOnly.contains(modifier) { return .right }
        return nil
    }

    // MARK: - Matching event flags

    /// Whether exactly this hotkey is held, given an event's raw modifier flags (the
    /// `rawValue` of `CGEventFlags` or `NSEvent.ModifierFlags`; both carry the
    /// device-dependent left/right bits).
    func isHeld(in rawFlags: UInt64) -> Bool {
        guard Modifiers(rawFlags: rawFlags) == modifiers else { return false }
        return Self.Modifiers.ordered.allSatisfy { modifier in
            guard let side = side(of: modifier), let masks = Self.sideMasks[modifier] else { return true }
            let left = rawFlags & masks.left != 0
            let right = rawFlags & masks.right != 0
            return side == .left ? left && !right : right && !left
        }
    }

    /// Whether the held modifiers include this hotkey's and more (or the other side's key),
    /// meaning the user is pressing a different shortcut.
    func isPartOfOtherShortcut(in rawFlags: UInt64) -> Bool {
        Modifiers(rawFlags: rawFlags).isSuperset(of: modifiers) && !isHeld(in: rawFlags)
    }

    /// Why this hotkey can't be used, or nil if it can.
    var problem: String? {
        if modifiers == .shift {
            return "Shift on its own is used for typing capitals. Add another key."
        }
        if modifiers.count == 1, side(of: modifiers) == .left {
            return "The left-hand \(Self.symbol(for: modifiers)) key starts too many shortcuts on its own. Use the right-hand one, fn, or a combination."
        }
        return nil
    }

    // MARK: - Display

    private var orderedKeys: [Modifiers] { Self.Modifiers.ordered.filter(modifiers.contains) }

    /// Compact form for menus and status text: "⌃⌥", "fn", "Right ⌘", "Right ⌥⌘".
    var symbols: String {
        let sides = Set(orderedKeys.map(side(of:)))
        if sides == [nil] {
            return orderedKeys.map(Self.symbol(for:)).joined()
        }
        if sides.count == 1, let side = sides.first ?? nil {
            return "\(side.rawValue.capitalized) \(orderedKeys.map(Self.symbol(for:)).joined())"
        }
        return orderedKeys.map { key in
            side(of: key).map { "\($0.rawValue.capitalized) \(Self.symbol(for: key))" } ?? Self.symbol(for: key)
        }.joined(separator: " ")
    }

    /// Spelled out for hints: "⌃ Control + ⌥ Option", "the right ⌘ Command key".
    var spokenName: String {
        if modifiers == .function { return "fn (🌐)" }
        let keys = orderedKeys.map { key in
            let name = "\(Self.symbol(for: key)) \(Self.name(for: key).capitalized)"
            return side(of: key).map { "\($0.rawValue) \(name)" } ?? name
        }
        if keys.count == 1, side(of: modifiers) != nil { return "the \(keys[0]) key" }
        return keys.joined(separator: " + ")
    }

    /// One entry per key to draw as a keycap.
    var keycaps: [Keycap] {
        orderedKeys.map { modifier in
            let name = modifier == .function ? "fn / globe" : Self.name(for: modifier)
            let side = side(of: modifier)
            return Keycap(
                symbol: modifier == .function ? "fn" : Self.symbol(for: modifier),
                name: side.map { "\($0.rawValue) \(name)" } ?? name,
                modifier: modifier,
                side: side
            )
        }
    }

    struct Keycap: Hashable {
        let symbol: String
        let name: String
        let modifier: Modifiers
        let side: Side?

        func isPressed(in rawFlags: UInt64) -> Bool {
            guard let side, let masks = Hotkey.sideMasks[modifier] else {
                return Modifiers(rawFlags: rawFlags).contains(modifier)
            }
            return rawFlags & (side == .left ? masks.left : masks.right) != 0
        }
    }

    private static func symbol(for modifier: Modifiers) -> String {
        switch modifier {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        default: "fn"
        }
    }

    private static func name(for modifier: Modifiers) -> String {
        switch modifier {
        case .control: "control"
        case .option: "option"
        case .shift: "shift"
        case .command: "command"
        default: "fn"
        }
    }

    // MARK: - Flag bits

    /// Device-dependent bits from IOKit's IOLLEvent.h (NX_DEVICE*KEYMASK).
    fileprivate static let sideMasks: [Modifiers: (left: UInt64, right: UInt64)] = [
        .control: (0x0000_0001, 0x0000_2000),
        .shift: (0x0000_0002, 0x0000_0004),
        .command: (0x0000_0008, 0x0000_0010),
        .option: (0x0000_0020, 0x0000_0040),
    ]

    // MARK: - Persistence

    private static let defaultsKey = "dictationHotkey"

    static var saved: Hotkey {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data),
              hotkey.problem == nil, !hotkey.modifiers.isEmpty
        else { return .default }
        return hotkey
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - fn key

    /// macOS acts on a lone fn/🌐 press itself (emoji picker, input source, Apple
    /// Dictation) unless "Press 🌐 key to" is set to "Do Nothing" in Keyboard settings.
    static var systemUsesFunctionKey: Bool {
        // 0 is "Do Nothing"; a missing value means the system default, which acts.
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return value != 0
    }

    @MainActor static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

nonisolated extension Hotkey.Modifiers {
    var count: Int { rawValue.nonzeroBitCount }

    init(rawFlags: UInt64) {
        let flags = CGEventFlags(rawValue: rawFlags)
        var modifiers: Hotkey.Modifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        self = modifiers
    }
}
