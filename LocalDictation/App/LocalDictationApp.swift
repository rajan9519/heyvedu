import SwiftUI

@main
struct LocalDictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            Image(systemName: appDelegate.controller.menuBarSymbol)
        }
    }
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
}
