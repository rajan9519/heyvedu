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
            if case .unavailable(let reason) = controller.cleaner.availability {
                if let progress = controller.cleaner.downloadProgress {
                    Text(reason)
                    Text("\(Self.progressBar(progress))  \(Int(progress * 100))%")
                        .monospacedDigit()
                    Text("Pasting raw transcripts until the download finishes")
                } else {
                    Text("\(reason) — pasting raw transcripts")
                }
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

    /// Menu-style menu bar extras only render text, so the bar is drawn with characters.
    private static func progressBar(_ progress: Double, width: Int = 20) -> String {
        let filled = min(width, max(0, Int((progress * Double(width)).rounded(.down))))
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: width - filled)
    }
}
