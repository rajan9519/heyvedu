import SwiftUI

@main
struct HeyVeduApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                controller: appDelegate.controller,
                updates: appDelegate.updates,
                showWelcomeGuide: { appDelegate.onboarding.show() },
                recordShortcut: { appDelegate.hotkeyRecorder.show() },
                editDictionary: { appDelegate.dictionaryWindow.show() }
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
    lazy var onboarding = OnboardingWindowController(controller: controller)
    lazy var hotkeyRecorder = HotkeyRecorderWindowController(controller: controller)
    lazy var dictionaryWindow = DictionaryWindowController(dictionary: controller.dictionary)

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains(CleanupSelfTest.flag) {
            Task {
                await CleanupSelfTest.run()
                exit(0)
            }
            return
        }
        #endif
        let firstRun = !Onboarding.isCompleted
        controller.start(requestPermissions: !firstRun, downloadModels: !firstRun)
        updates.start()
        if firstRun { onboarding.show() }
    }

    /// Clicking the Dock icon with no window open brings up the welcome guide.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { onboarding.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.cleaner.shutdown()
    }
}
