import AppKit
import SwiftUI

/// The app's main window: status and permissions on Home, plus every setting. Opens on
/// launch and from the Dock once onboarding is done; closing it leaves HeyVedu running
/// in the menu bar.
final class MainWindowController: NSObject, NSWindowDelegate {
    private let controller: DictationController
    private let showWelcomeGuide: () -> Void
    private var window: NSWindow?

    init(controller: DictationController, showWelcomeGuide: @escaping () -> Void) {
        self.controller = controller
        self.showWelcomeGuide = showWelcomeGuide
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Activation can be refused (e.g. launched in the background), so order the
        // window front regardless.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let view = MainView(controller: controller, showWelcomeGuide: showWelcomeGuide)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "HeyVedu"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 820, height: 620))
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }
}

private enum SidebarItem: String, CaseIterable, Identifiable {
    case home, general, shortcut, dictionary, models

    var id: Self { self }

    var title: String {
        switch self {
        case .home: return "Home"
        case .general: return "General"
        case .shortcut: return "Shortcut"
        case .dictionary: return "Dictionary"
        case .models: return "Models"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .general: return "gearshape"
        case .shortcut: return "keyboard"
        case .dictionary: return "character.book.closed"
        case .models: return "cpu"
        }
    }
}

private struct MainView: View {
    let controller: DictationController
    let showWelcomeGuide: () -> Void

    @State private var section: SidebarItem = .home

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .navigationTitle(section.title)
        }
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .home:
            HomeView(controller: controller, showWelcomeGuide: showWelcomeGuide)
        case .general:
            GeneralSettings(controller: controller)
        case .shortcut:
            ShortcutSettings(controller: controller)
        case .dictionary:
            DictionaryView(dictionary: controller.dictionary)
        case .models:
            ModelSettings(speechModel: controller.speechModel, cleaner: controller.cleaner)
        }
    }
}

// MARK: - Home

private struct HomeView: View {
    let controller: DictationController
    let showWelcomeGuide: () -> Void

    private var ready: Bool { controller.canDictate }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image("BrandMark")
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HeyVedu").font(.largeTitle.bold())
                        Label(controller.statusText, systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(ready ? .green : .orange)
                    }
                }

                HStack(spacing: 10) {
                    Text("Hold")
                    HotkeyKeycaps(hotkey: controller.hotkey, heldFlags: 0)
                    Text("in any app, speak, then let go.")
                }
                .font(.title3)

                Text("Double-tap the shortcut for hands-free dictation. Your voice is transcribed on this Mac, and nothing leaves it. Close this window and HeyVedu keeps running in the menu bar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Permissions").font(.headline)
                    PermissionRow(
                        icon: "mic.fill",
                        title: "Microphone",
                        detail: "To hear you while you hold the shortcut. Nothing is recorded otherwise.",
                        granted: controller.permissions.microphoneGranted,
                        grant: controller.permissions.requestMicrophone
                    )
                    PermissionRow(
                        icon: "accessibility",
                        title: "Accessibility",
                        detail: "To notice \(controller.hotkey.symbols) in any app and paste the text where your cursor is.",
                        granted: controller.permissions.accessibilityGranted,
                        grant: controller.permissions.requestAccessibility
                    )
                }

                if !controller.speechModel.isReady {
                    ModelRow(
                        icon: "waveform",
                        title: "Speech model",
                        detail: "Turns your voice into text. Required for dictation.",
                        status: .speech(controller.speechModel),
                        download: controller.speechModel.prepare
                    )
                }

                if controller.hotkey.modifiers == .function, Hotkey.systemUsesFunctionKey {
                    FunctionKeyWarning()
                }

                Button("Show Welcome Guide…", action: showWelcomeGuide)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FunctionKeyWarning: View {
    var body: some View {
        HStack {
            Label("macOS also acts on the 🌐 key. Set “Press 🌐 key to” to Do Nothing.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Keyboard Settings…") { Hotkey.openKeyboardSettings() }
        }
    }
}

// MARK: - Settings sections

private struct GeneralSettings: View {
    let controller: DictationController

    var body: some View {
        @Bindable var cleaner = controller.cleaner
        @Bindable var devices = controller.devices

        Form {
            Section {
                Toggle(isOn: $cleaner.isEnabled) {
                    Text("Clean up transcripts")
                    Text("Removes filler words, applies your self-corrections and fixes punctuation.")
                }
                Picker("Cleanup engine", selection: $cleaner.engine) {
                    ForEach(TextCleaner.Engine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .disabled(!cleaner.isEnabled)
                if cleaner.isEnabled, case .unavailable(let reason) = cleaner.availability {
                    Label("\(reason). Pasting raw transcripts until it's ready.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Microphone", selection: $devices.selectedDeviceUID) {
                    Text(systemDefaultLabel).tag(String?.none)
                    ForEach(devices.inputDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var systemDefaultLabel: String {
        if let name = controller.devices.defaultInputDevice?.name {
            return "System Default (\(name))"
        }
        return "System Default"
    }
}

private struct ShortcutSettings: View {
    let controller: DictationController
    @State private var recording = false

    var body: some View {
        @Bindable var controller = controller

        Form {
            Section {
                if recording {
                    HotkeyRecorderView(current: controller.hotkey) { hotkey in
                        if let hotkey { controller.hotkey = hotkey }
                        setRecording(false)
                    }
                } else {
                    LabeledContent("Dictation shortcut") {
                        HStack(spacing: 12) {
                            Text(controller.hotkey.symbols)
                                .font(.title3.weight(.medium))
                            Button("Change…") { setRecording(true) }
                        }
                    }
                    if controller.hotkey.modifiers == .function, Hotkey.systemUsesFunctionKey {
                        FunctionKeyWarning()
                    }
                }
            } footer: {
                Text("Hold the shortcut to dictate, and let go to paste. Esc cancels.")
            }

            Section {
                Toggle(isOn: $controller.handsFreeEnabled) {
                    Text("Double-tap for hands-free")
                    Text("Double-tap the shortcut to keep recording without holding it. Press it again to finish.")
                }
            }
        }
        .formStyle(.grouped)
        // Leaving the section or closing the window mid-recording must not leave the hotkey off.
        .onDisappear { setRecording(false) }
    }

    /// Pressing the current hotkey while recording must not start a dictation.
    private func setRecording(_ on: Bool) {
        recording = on
        controller.hotkeySuspended = on
    }
}

private struct ModelSettings: View {
    let speechModel: SpeechModel
    let cleaner: TextCleaner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("HeyVedu runs these models on your Mac. Each downloads once and works offline after that.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ModelRow(
                    icon: "waveform",
                    title: "Speech model",
                    detail: "Parakeet TDT v3 turns your voice into text. Required for dictation.",
                    status: .speech(speechModel),
                    download: speechModel.prepare
                )
                ModelRow(
                    icon: "text.badge.checkmark",
                    title: "Cleanup model",
                    detail: "\(cleaner.engine.name) removes filler words, applies your corrections and fixes punctuation. Choose the engine in General.",
                    status: .cleanup(cleaner),
                    download: cleaner.download
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
