import AppKit
import Observation
import os
import Sparkle

/// Checks the appcast once a day (Info.plist `SUScheduledCheckInterval`), downloads new
/// releases silently, and installs them when the app quits. The main window's sidebar shows
/// the state and offers "Relaunch" once a download is ready; quitting normally installs it too.
@Observable
final class UpdateController: NSObject {
    enum State: Equatable {
        case idle
        case checking
        case downloading(version: String)
        case readyToInstall(version: String)
    }

    /// Outcome of the last check the user asked for, shown next to the button.
    enum CheckResult: Equatable {
        case upToDate
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheckResult: CheckResult?
    /// False when the updater could not start (Debug builds, or a build without a signing key).
    private(set) var isAvailable = false

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var installNow: (() -> Void)?
    /// Results of a check the user asked for are reported; scheduled checks stay silent.
    @ObservationIgnored private var userInitiated = false
    @ObservationIgnored private var clearResult: Task<Void, Never>?

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
        setResult(nil)
        state = .checking
        updater.checkForUpdatesInBackground()
    }

    func installAndRelaunch() {
        installNow?()
    }

    /// "Up to date" fades after a few seconds; an error stays until the next check.
    private func setResult(_ result: CheckResult?) {
        clearResult?.cancel()
        lastCheckResult = result
        guard result == .upToDate else { return }
        clearResult = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.lastCheckResult = nil
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        state = .downloading(version: item.displayVersionString)
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
        // The sidebar offers "Relaunch"; Sparkle still installs on quit.
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let reported = userInitiated
        userInitiated = false
        if case .readyToInstall = state { return }
        state = .idle
        guard let error = error as NSError? else { return }
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
            if reported { setResult(.upToDate) }
            return
        }
        logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        if reported { setResult(.failed(error.localizedDescription)) }
    }
}
