import SwiftUI

@main
struct HeyVeduApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                controller: appDelegate.controller,
                openMainWindow: { appDelegate.mainWindow.show() },
                openSettings: { appDelegate.mainWindow.showSettings() }
            )
        } label: {
            if appDelegate.controller.menuBarSymbol == "mic" {
                Image(nsImage: Self.menuBarMark)
                    .accessibilityLabel("HeyVedu")
            } else {
                Image(systemName: appDelegate.controller.menuBarSymbol)
                    .accessibilityLabel("HeyVedu: \(appDelegate.controller.statusText)")
            }
        }
    }

    /// MenuBarExtra labels ignore `.resizable()`/`.frame()` and draw an image at its point
    /// size, so the 128 px brand mark is sized to a menu bar glyph here (the extra pixels
    /// keep it sharp on Retina). Template so it follows the menu bar's light/dark tint.
    private static let menuBarMark: NSImage = {
        let image = (NSImage(named: "BrandMark")?.copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    let updates = UpdateController()
    lazy var onboarding: OnboardingWindowController = {
        let onboarding = OnboardingWindowController(controller: controller)
        onboarding.onClose = { [unowned self] in mainWindow.show() }
        return onboarding
    }()
    lazy var mainWindow = MainWindowController(controller: controller, updates: updates) { [unowned self] in
        onboarding.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.theme.apply()
        #if DEBUG
        if CommandLine.arguments.contains(CleanupSelfTest.flag) {
            Task {
                await CleanupSelfTest.run()
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains(AssistSelfTest.flag) {
            Task {
                await AssistSelfTest.run()
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains(PipelineBenchmark.flag) {
            Task {
                await PipelineBenchmark.run()
                exit(0)
            }
            return
        }
        #endif
        // Unit tests load into this app; don't ask for permissions or download models.
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("XCTest") }) { return }
        let firstRun = !Onboarding.isCompleted
        controller.start(requestPermissions: !firstRun, downloadModels: !firstRun)
        updates.start()
        // First run shows only the welcome guide; the main window follows when it closes.
        if firstRun { onboarding.show() } else { mainWindow.show() }
    }

    /// Clicking the Dock icon with no window open brings up the main window (or the
    /// welcome guide until it has been completed).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if Onboarding.isCompleted { mainWindow.show() } else { onboarding.show() }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.cleaner.shutdown()
    }
}
