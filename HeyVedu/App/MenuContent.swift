import SwiftUI

struct MenuContent: View {
    let controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.statusText)

        if !controller.permissions.microphoneGranted {
            Button("Grant Microphone Access…") { controller.permissions.requestMicrophone() }
        }
        if !controller.permissions.accessibilityGranted {
            Button("Grant Accessibility Access…") { controller.permissions.requestAccessibility() }
        }
        if case .failed = controller.speechModel.state {
            Button("Retry Loading Speech Model") { controller.speechModel.prepare() }
        }

        Divider()

        Toggle("Clean Up Transcripts", isOn: cleanupEnabled)
        if controller.cleaner.isEnabled {
            Picker("Cleanup Engine", selection: cleanupEngine) {
                ForEach(TextCleaner.Engine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            if controller.cleaner.engine == .s1Mini {
                Picker("Style", selection: styling) {
                    ForEach(S1MiniBackend.Styling.allCases) { styling in
                        Text(styling.title).tag(styling)
                    }
                }
            }
            if controller.cleaner.engine == .claudeCode {
                Picker("Claude Model", selection: claudeModel) {
                    ForEach(ClaudeCodeBackend.Model.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
            }
            if case .unavailable(let reason) = controller.cleaner.availability {
                Text("\(reason) — pasting raw transcripts")
            }
        }

        Button("Edit Vocabulary…") {
            openWindow(id: VocabularyWindow.id)
            // Menu-bar apps aren't active by default; bring the window to the front.
            NSApp.activate()
        }

        Divider()

        Picker("Microphone", selection: microphoneSelection) {
            Text(systemDefaultLabel).tag(String?.none)
            ForEach(controller.devices.inputDevices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        }

        Divider()

        Button("Quit HeyVedu") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var cleanupEnabled: Binding<Bool> {
        Binding(
            get: { controller.cleaner.isEnabled },
            set: { controller.cleaner.isEnabled = $0 }
        )
    }

    private var cleanupEngine: Binding<TextCleaner.Engine> {
        Binding(
            get: { controller.cleaner.engine },
            set: { controller.cleaner.engine = $0 }
        )
    }

    private var styling: Binding<S1MiniBackend.Styling> {
        Binding(
            get: { controller.cleaner.styling },
            set: { controller.cleaner.styling = $0 }
        )
    }

    private var claudeModel: Binding<ClaudeCodeBackend.Model> {
        Binding(
            get: { controller.cleaner.claudeModel },
            set: { controller.cleaner.claudeModel = $0 }
        )
    }

    private var microphoneSelection: Binding<String?> {
        Binding(
            get: { controller.devices.selectedDeviceUID },
            set: { controller.devices.selectedDeviceUID = $0 }
        )
    }

    private var systemDefaultLabel: String {
        if let name = controller.devices.defaultInputDevice?.name {
            return "System Default (\(name))"
        }
        return "System Default"
    }
}
