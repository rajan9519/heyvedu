import AppKit
import SwiftUI

/// First-run guide: what HeyVedu does, the two permissions, the model downloads, and a
/// practice dictation. Shown automatically once; reopened from the main window's Home page.
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

    /// Called after the guide closes and onboarding is marked complete.
    var onClose: (() -> Void)?

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
        // Closing early counts too: the main window's Home page keeps the Allow
        // buttons and the guide.
        Onboarding.isCompleted = true
        // Dictation needs the speech model, so whatever wasn't started here starts now.
        controller.downloadModels()
        window = nil
        onClose?()
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
                case .welcome: WelcomeStep(hotkey: controller.hotkey)
                case .permissions: PermissionsStep(permissions: controller.permissions, hotkey: controller.hotkey)
                case .model: ModelStep(model: controller.speechModel, cleaner: controller.cleaner)
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
        case .permissions where !controller.permissions.allGranted,
             .model where controller.speechModel.state == .idle:
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
    let hotkey: Hotkey

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
                HotkeyKeycaps(hotkey: hotkey, heldFlags: 0)
                Text("speak, then let go.")
            }
            .font(.title3)
            .padding(.top, 8)

            Label("HeyVedu also runs from the menu bar, at the top right of your screen.", systemImage: "menubar.arrow.up.rectangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }
}

private struct PermissionsStep: View {
    let permissions: PermissionsManager
    let hotkey: Hotkey

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
                detail: "To notice \(hotkey.symbols) in any app and paste the text where your cursor is. In System Settings, switch HeyVedu on, then come back here.",
                granted: permissions.accessibilityGranted,
                grant: permissions.requestAccessibility
            )
            Spacer()
        }
    }
}

/// A permission with an Allow… button. Used by onboarding and the main window's Home page.
struct PermissionRow: View {
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
    let cleaner: TextCleaner

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(
                title: "Models",
                subtitle: "HeyVedu runs these models on your Mac. Each downloads once and works offline after that."
            )
            ModelRow(
                icon: "waveform",
                title: "Speech model",
                detail: "Turns your voice into text. Required for dictation.",
                status: speechStatus,
                download: model.prepare
            )
            ModelRow(
                icon: "text.badge.checkmark",
                title: "Cleanup model",
                detail: "\(cleaner.engine.name) removes filler words, applies your corrections and fixes punctuation. Optional.",
                status: cleanupStatus,
                download: downloadCleanup
            )
            Text("You can continue while they download. Turn off Clean Up Transcripts in the menu to skip the cleanup model.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var speechStatus: ModelRow.Status { .speech(model) }

    private var cleanupStatus: ModelRow.Status { .cleanup(cleaner) }

    private func downloadCleanup() { cleaner.download() }
}

/// A model's download state with a Download / Try Again button. Used by onboarding and
/// the main window's Models section.
struct ModelRow: View {
    enum Status {
        case notDownloaded(size: Int64?)
        /// Downloaded but cleanup is turned off.
        case off
        /// The engine needs no download (Apple Intelligence).
        case builtIn
        case downloading(Double, size: Int64?)
        case loading
        case ready
        case failed(String)

        static func speech(_ model: SpeechModel) -> Status {
            switch model.state {
            case .idle: return .notDownloaded(size: SpeechModel.downloadSize)
            case .downloading: return .downloading(model.downloadProgress ?? 0, size: SpeechModel.downloadSize)
            case .loading: return .loading
            case .ready: return .ready
            case .failed(let reason): return .failed(reason)
            }
        }

        static func cleanup(_ cleaner: TextCleaner) -> Status {
            guard cleaner.isEnabled else {
                return cleaner.needsDownload ? .notDownloaded(size: cleaner.downloadSize) : .off
            }
            switch cleaner.modelState {
            case nil: return .builtIn
            case .idle: return .notDownloaded(size: cleaner.downloadSize)
            case .downloading(let fraction): return .downloading(fraction, size: cleaner.downloadSize)
            case .loading: return .loading
            case .ready: return .ready
            case .failed(let reason): return .failed(reason)
            }
        }
    }

    let icon: String
    let title: String
    let detail: String
    let status: Status
    let download: () -> Void

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
                progress
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var progress: some View {
        switch status {
        case .downloading(let fraction, let size):
            ProgressView(value: fraction)
                .padding(.top, 6)
            if let size {
                Text("\(Self.format(Int64(Double(size) * fraction))) of \(Self.format(size))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .notDownloaded(let size):
            VStack(alignment: .trailing, spacing: 4) {
                Button("Download", action: download)
                if let size {
                    Text(Self.format(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .off:
            Button("Turn On", action: download)
        case .builtIn:
            Label("Built in", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading(let fraction, _):
            Text("\(Int(fraction * 100))%")
                .font(.headline)
                .monospacedDigit()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Setting up…")
            }
            .foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Button("Try Again", action: download)
        }
    }

    private static func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

private struct PracticeStep: View {
    let controller: DictationController

    @State private var text = ""
    @State private var heldFlags: UInt64 = 0
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
                    : "Click in the box, hold \(controller.hotkey.symbols), say “Hello, this is my first dictation”, then let go."
            )

            HStack(spacing: 10) {
                HotkeyKeycaps(hotkey: controller.hotkey, heldFlags: heldFlags)
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
                if controller.handsFreeEnabled {
                    tip("lock", "Double-tap \(controller.hotkey.symbols) to dictate hands-free, then press it again to finish.")
                }
                tip("command", "Pressing another key with \(controller.hotkey.symbols) still works as a normal shortcut.")
            }
        }
        .onAppear {
            startingCount = controller.completedDictations
            editorFocused = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                heldFlags = UInt64(event.modifierFlags.rawValue)
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
        } else if controller.speechModel.state == .idle {
            warning("Download the speech model first")
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

/// The hotkey's keys as keycaps joined by "+", lit while held.
struct HotkeyKeycaps: View {
    let hotkey: Hotkey
    let heldFlags: UInt64

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(hotkey.keycaps.enumerated()), id: \.offset) { index, key in
                if index > 0 { Text("+").font(.title2).foregroundStyle(.secondary) }
                Keycap(symbol: key.symbol, name: key.name, pressed: key.isPressed(in: heldFlags))
            }
        }
    }
}

struct Keycap: View {
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
