import SwiftUI

@main
struct HeyVeduApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            if appDelegate.controller.menuBarSymbol == "mic" {
                Image("BrandMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 18)
                    .accessibilityLabel("HeyVedu")
            } else {
                Image(systemName: appDelegate.controller.menuBarSymbol)
                    .accessibilityLabel("HeyVedu: \(appDelegate.controller.statusText)")
            }
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
