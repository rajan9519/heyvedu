import SwiftUI

struct MenuContent: View {
    let controller: DictationController

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

        Picker("Microphone", selection: microphoneSelection) {
            Text(systemDefaultLabel).tag(String?.none)
            ForEach(controller.devices.inputDevices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        }

        Divider()

        Button("Quit LocalDictation") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
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
