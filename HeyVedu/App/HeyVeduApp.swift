import SwiftUI

@main
struct HeyVeduApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            Image(systemName: appDelegate.controller.menuBarSymbol)
        }

        Window("Vocabulary", id: VocabularyWindow.id) {
            VocabularyView(store: appDelegate.controller.vocabulary)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

enum VocabularyWindow {
    static let id = "vocabulary"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a `claude` child that already exited must surface as an error, not
        // kill the app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        #if DEBUG
        if CommandLine.arguments.contains(CleanupSelfTest.flag) {
            Task {
                await CleanupSelfTest.run()
                exit(0)
            }
            return
        }
        #endif
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.cleaner.shutdown()
    }
}
