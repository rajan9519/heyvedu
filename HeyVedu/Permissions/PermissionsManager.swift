import AVFoundation
import AppKit
import ApplicationServices
import Observation

/// Tracks Microphone and Accessibility grants. Accessibility is required both for the
/// hotkey event tap and for posting the synthetic ⌘V.
@Observable
final class PermissionsManager {
    private(set) var microphoneGranted = false
    private(set) var accessibilityGranted = false

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var allGranted: Bool { microphoneGranted && accessibilityGranted }

    init() {
        refresh()
    }

    /// macOS has no notification for Accessibility changes, so poll while the app runs.
    func startMonitoring() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refresh()
            }
        }
    }

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        guard mic != microphoneGranted || ax != accessibilityGranted else { return }
        microphoneGranted = mic
        accessibilityGranted = ax
        onChange?()
    }

    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refresh()
            }
        default:
            openSettings(pane: "Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        // Literal value of kAXTrustedCheckOptionPrompt (the imported global isn't concurrency-safe).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings(pane: "Privacy_Accessibility")
        }
    }

    private func openSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
