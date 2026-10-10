import SwiftUI

/// Records a new dictation hotkey: the user holds modifier keys and lets go. Shown in
/// the main window's Shortcut section; the caller suspends the global hotkey meanwhile.
struct HotkeyRecorderView: View {
    let current: Hotkey
    /// Called with the chosen hotkey, or nil when cancelled.
    let finish: (Hotkey?) -> Void

    @State private var heldFlags: UInt64 = 0
    /// The most keys held at once during the current press.
    @State private var peak: Hotkey?
    @State private var captured: Hotkey?
    @State private var message: String?
    @State private var monitor: Any?

    private var shown: Hotkey? { Hotkey(rawFlags: heldFlags) ?? captured }
    private var problem: String? { message ?? captured?.problem }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hold the keys you want to use, then let go.")
                .font(.headline)
            Text("Use modifier keys only: ⌃ ⌥ ⇧ ⌘ or fn. Currently \(current.symbols).")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if let shown {
                    HotkeyKeycaps(hotkey: shown, heldFlags: heldFlags)
                } else {
                    Text("Waiting for keys…")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 56)

            Group {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if captured?.modifiers == .function, Hotkey.systemUsesFunctionKey {
                    Label("macOS also acts on the 🌐 key. Set Keyboard → “Press 🌐 key to” → Do Nothing.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text(" ")
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset to \(Hotkey.default.symbols)") { finish(.default) }
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Use Shortcut") { finish(captured) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(captured == nil || problem != nil || heldFlags != 0)
            }
        }
        .onAppear(perform: startMonitoring)
        .onDisappear(perform: stopMonitoring)
    }

    private func startMonitoring() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            switch event.type {
            case .flagsChanged:
                record(UInt64(event.modifierFlags.rawValue))
                return event
            case .keyDown:
                // Let Esc and Return reach the Cancel/Use buttons when no keys are held.
                if heldFlags == 0, event.keyCode == 53 || event.keyCode == 36 { return event }
                message = "Only modifier keys can be used. Try holding just ⌃ ⌥ ⇧ ⌘ or fn."
                captured = nil
                return nil
            default:
                return event
            }
        }
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func record(_ rawFlags: UInt64) {
        heldFlags = Hotkey.Modifiers(rawFlags: rawFlags).isEmpty ? 0 : rawFlags
        if let held = Hotkey(rawFlags: rawFlags) {
            if peak == nil { message = nil }
            if held.keycaps.count >= (peak?.keycaps.count ?? 0) { peak = held }
        } else if let peak {
            // All keys released: the largest combination held is the choice.
            captured = peak
            self.peak = nil
        }
    }
}
