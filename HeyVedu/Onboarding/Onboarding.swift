import AppKit
import SwiftUI

/// First-run guide: what HeyVedu does, the two permissions, the model download, and a
/// practice dictation. Shown automatically once; reopened from the menu.
enum Onboarding {
    private static let completedKey = "onboardingCompleted"

    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }
}

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let controller: DictationController
    private var window: NSWindow?

    init(controller: DictationController) {
        self.controller = controller
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // A menu bar app is never frontmost on its own.
        // Activation can be refused (cooperative activation, e.g. launched in the
        // background), so order the window front regardless.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing early counts too: the menu keeps the Grant buttons and the guide.
        Onboarding.isCompleted = true
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(controller: controller) { [weak self] in self?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to HeyVedu"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

private enum Step: Int, CaseIterable {
    case welcome, permissions, model, practice
}

private struct OnboardingView: View {
    let controller: DictationController
    let finish: () -> Void

    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep(permissions: controller.permissions)
                case .model: ModelStep(model: controller.speechModel)
                case .practice: PracticeStep(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)

            footer
        }
        .frame(width: 560, height: 480)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Circle()
                        .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button("Back") { move(by: -1) }
            }
            primaryButton
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .permissions where !controller.permissions.allGranted:
            Button("Skip for Now") { move(by: 1) }
        case .practice:
            Button("Done", action: finish)
        default:
            Button("Continue") { move(by: 1) }
        }
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Image("BrandMark")
                .resizable()
                .frame(width: 72, height: 72)
            Text("Welcome to HeyVedu")
                .font(.largeTitle.bold())
            Text("Dictate into any app. Your voice is transcribed on this Mac — nothing leaves it.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Text("Hold")
                Keycap(symbol: "⌃", name: "control", pressed: false)
                Text("+")
                Keycap(symbol: "⌥", name: "option", pressed: false)
                Text("speak, then let go.")
            }
            .font(.title3)
            .padding(.top, 8)

            Label("HeyVedu lives in the menu bar, at the top right of your screen.", systemImage: "menubar.arrow.up.rectangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }
}

private struct PermissionsStep: View {
    let permissions: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(
                title: "Two permissions",
                subtitle: "macOS asks you to allow these once. You can change them later in System Settings → Privacy & Security."
            )
            PermissionRow(
                icon: "mic.fill",
                title: "Microphone",
                detail: "To hear you while you hold the hotkey. Nothing is recorded otherwise.",
                granted: permissions.microphoneGranted,
                grant: permissions.requestMicrophone
            )
            PermissionRow(
                icon: "accessibility",
                title: "Accessibility",
                detail: "To notice ⌃⌥ in any app and paste the text where your cursor is. In System Settings, switch HeyVedu on, then come back here.",
                granted: permissions.accessibilityGranted,
                grant: permissions.requestAccessibility
            )
            Spacer()
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: grant)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ModelStep: View {
    let model: SpeechModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(
                title: "Speech model",
                subtitle: "HeyVedu transcribes with a speech model that runs on your Mac. It downloads once (about 600 MB) and works offline after that."
            )
            status
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Text("You can continue while it downloads.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading:
            if let progress = model.downloadProgress {
                ProgressView(value: progress) {
                    Text("Downloading…")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%").monospacedDigit()
                }
            } else {
                ProgressView { Text("Downloading…") }
            }
        case .idle, .loading:
            ProgressView { Text("Preparing the model…") }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Label("Download failed: \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Try Again", action: model.prepare)
            }
        }
    }
}

private struct PracticeStep: View {
    let controller: DictationController

    @State private var text = ""
    @State private var heldFlags: NSEvent.ModifierFlags = []
    @State private var startingCount = 0
    @State private var monitor: Any?
    @FocusState private var editorFocused: Bool

    private var succeeded: Bool { controller.completedDictations > startingCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                title: succeeded ? "You're all set 🎉" : "Try it",
                subtitle: succeeded
                    ? "That's all there is to it. Dictate into any app the same way."
                    : "Click in the box, hold both keys, say “Hello, this is my first dictation”, then let go."
            )

            HStack(spacing: 10) {
                Keycap(symbol: "⌃", name: "control", pressed: heldFlags.contains(.control))
                Text("+").font(.title2).foregroundStyle(.secondary)
                Keycap(symbol: "⌥", name: "option", pressed: heldFlags.contains(.option))
                Spacer()
                statusLine
            }

            TextEditor(text: $text)
                .font(.body)
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .frame(height: 110)

            VStack(alignment: .leading, spacing: 4) {
                tip("escape", "Press Esc while holding to cancel a dictation.")
                tip("command", "Pressing another key with ⌃⌥ still works as a normal shortcut.")
            }
        }
        .onAppear {
            startingCount = controller.completedDictations
            editorFocused = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                heldFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    @ViewBuilder private var statusLine: some View {
        if !controller.permissions.allGranted {
            warning("Allow both permissions first")
        } else if !controller.hotkeyAvailable {
            warning("Hotkey unavailable — quit and reopen HeyVedu")
        } else if !controller.speechModel.isReady {
            Label("Speech model still loading…", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        } else {
            switch controller.status {
            case .recording:
                Label("Listening…", systemImage: "mic.fill").foregroundStyle(.red)
            case .processing:
                Label("Transcribing…", systemImage: "waveform").foregroundStyle(.secondary)
            case .idle:
                if succeeded {
                    Label("It worked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Shared pieces

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Keycap: View {
    let symbol: String
    let name: String
    let pressed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(symbol).font(.system(size: 15, weight: .medium))
            Text(name).font(.system(size: 11))
        }
        .frame(width: 64, height: 44, alignment: .leading)
        .padding(.horizontal, 8)
        .foregroundStyle(pressed ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(pressed ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(pressed ? 0 : 0.25), radius: 0, y: pressed ? 0 : 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
        .offset(y: pressed ? 2 : 0)
        .animation(.easeOut(duration: 0.08), value: pressed)
    }
}
