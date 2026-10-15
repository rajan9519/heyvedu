import Observation
import ServiceManagement

/// Opens HeyVedu when the user logs in, as a login item in System Settings. Off by default.
///
/// macOS keeps the setting, not HeyVedu, so the user can also change it in System Settings
/// > General > Login Items; `refresh()` picks that up. Debug and Release builds have
/// different bundle IDs, so each registers as its own login item.
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    /// Why the last change failed, until it is shown and cleared.
    var error: String?

    /// On once registered, even while it waits for the user's approval in System Settings.
    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Registered, but turned off in System Settings, so it won't open at login until allowed.
    var needsApproval: Bool { status == .requiresApproval }

    func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status { status = current }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
