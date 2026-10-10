import SwiftUI

struct MenuContent: View {
    let controller: DictationController
    let updates: UpdateController
    let openMainWindow: () -> Void

    var body: some View {
        Text(controller.statusText)

        if !controller.permissions.microphoneGranted {
            Button("Grant Microphone Access…") { controller.permissions.requestMicrophone() }
        }
        if !controller.permissions.accessibilityGranted {
            Button("Grant Accessibility Access…") { controller.permissions.requestAccessibility() }
        }
        switch controller.speechModel.state {
        case .idle:
            Button("Download Speech Model") { controller.speechModel.prepare() }
        case .failed:
            Button("Retry Loading Speech Model") { controller.speechModel.prepare() }
        case .downloading, .loading, .ready:
            EmptyView()
        }

        Divider()

        Toggle("Clean Up Transcripts", isOn: cleanupEnabled)
        if controller.cleaner.isEnabled {
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

        Toggle("Double-Tap for Hands-Free", isOn: handsFreeEnabled)

        Divider()

        Picker("Microphone", selection: microphoneSelection) {
            Text(systemDefaultLabel).tag(String?.none)
            ForEach(controller.devices.inputDevices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        }

        Divider()

        Button("Open HeyVedu…", action: openMainWindow)
            .keyboardShortcut(",")
        if updates.isAvailable {
            switch updates.state {
            case .idle:
                Button(updates.menuTitle) { updates.checkForUpdates() }
            case .readyToInstall:
                Button(updates.menuTitle) { updates.installAndRelaunch() }
            case .checking, .downloading:
                Text(updates.menuTitle)
            }
        }
        Button("Quit HeyVedu") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var cleanupEnabled: Binding<Bool> {
        Binding(
            get: { controller.cleaner.isEnabled },
            set: { controller.cleaner.isEnabled = $0 }
        )
    }

    private var handsFreeEnabled: Binding<Bool> {
        Binding(
            get: { controller.handsFreeEnabled },
            set: { controller.handsFreeEnabled = $0 }
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
