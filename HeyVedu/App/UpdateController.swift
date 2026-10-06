import AppKit
import Observation
import os
import Sparkle

/// Checks the appcast once a day (Info.plist `SUScheduledCheckInterval`), downloads new
/// releases silently, and installs them when the app quits. Once a download is ready the
/// menu offers "Restart to Update"; quitting normally installs it too.
@Observable
final class UpdateController: NSObject {
    enum State: Equatable {
        case idle
        case checking
        case downloading(version: String)
        case readyToInstall(version: String)
    }

    private(set) var state: State = .idle
    /// False when the updater could not start (Debug builds, or a build without a signing key).
    private(set) var isAvailable = false

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var installNow: (() -> Void)?
    /// Results of a check the user asked for are reported; scheduled checks stay silent.
    @ObservationIgnored private var userInitiated = false

    private let logger = Logger(subsystem: "com.heyvedu.app", category: "Updates")

    func start() {
        #if DEBUG
        logger.info("Automatic updates are disabled in Debug builds")
        #else
        let bundle = Bundle.main
        let updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil),
            delegate: self
        )
        do {
            try updater.start()
            self.updater = updater
            isAvailable = true
        } catch {
            logger.error("Updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Same as the daily check: a found update downloads in the background.
    func checkForUpdates() {
        guard let updater, state == .idle, !updater.sessionInProgress else { return }
        userInitiated = true
        state = .checking
        updater.checkForUpdatesInBackground()
    }

    func installAndRelaunch() {
        installNow?()
    }

    var menuTitle: String {
        switch state {
        case .idle: return "Check for Updates…"
        case .checking: return "Checking for Updates…"
        case .downloading(let version): return "Downloading HeyVedu \(version)…"
        case .readyToInstall(let version): return "Restart to Update to HeyVedu \(version)"
        }
    }

    /// Shown after the Sparkle callback returns, so the modal alert doesn't stall the updater.
    private func showAlert(_ message: String, info: String) {
        Task {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = info
            // Menu-bar apps aren't active by default; bring the alert to the front.
            NSApp.activate()
            alert.runModal()
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        state = .downloading(version: item.displayVersionString)
        if userInitiated {
            showAlert(
                "HeyVedu \(item.displayVersionString) is available.",
                info: "It's downloading in the background. When it's ready, choose Restart to Update from the HeyVedu menu, or it installs the next time you quit HeyVedu."
            )
        }
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        logger.info("HeyVedu \(item.displayVersionString, privacy: .public) is ready to install")
        installNow = immediateInstallHandler
        state = .readyToInstall(version: item.displayVersionString)
        userInitiated = false
        // We show "Restart to Update" in the menu; Sparkle still installs on quit.
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let reported = userInitiated
        userInitiated = false
        if case .readyToInstall = state { return }
        state = .idle
        guard let error = error as NSError? else { return }
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
            if reported {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                showAlert("You're up to date.", info: "HeyVedu \(version) is the latest version.")
            }
            return
        }
        logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        if reported {
            showAlert("Couldn't check for updates.", info: error.localizedDescription)
        }
    }
}
