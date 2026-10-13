import AppKit
import Observation
import SwiftUI

/// The app's main window: dictation stats on Home, the History, Dictionary and Snippets
/// pages, and Settings. Opens on launch and from the Dock once onboarding is done; closing
/// it leaves HeyVedu running in the menu bar.
final class MainWindowController: NSObject, NSWindowDelegate {
    private let controller: DictationController
    private let updates: UpdateController
    private let showWelcomeGuide: () -> Void
    /// Outlives the window, so reopening it returns to the same page.
    private let navigation = MainNavigation()
    private var window: NSWindow?

    init(controller: DictationController, updates: UpdateController, showWelcomeGuide: @escaping () -> Void) {
        self.controller = controller
        self.updates = updates
        self.showWelcomeGuide = showWelcomeGuide
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Activation can be refused (e.g. launched in the background), so order the
        // window front regardless.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func showSettings() {
        navigation.section = .settings
        show()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let view = MainView(
            controller: controller,
            updates: updates,
            navigation: navigation,
            showWelcomeGuide: showWelcomeGuide
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "HeyVedu"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 900, height: 660))
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }
}

enum MainSection: Hashable {
    case home, history, dictionary, snippets, settings

    /// The pages listed at the top of the sidebar; Settings sits at its bottom.
    static let pages: [MainSection] = [.home, .history, .dictionary, .snippets]

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.bubble"
        case .settings: return "gearshape"
        }
    }
}

/// Which page and Settings tab the main window shows.
@Observable
final class MainNavigation {
    var section: MainSection = .home
    var settingsTab: SettingsTab = .general

    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        section = .settings
    }
}

private struct MainView: View {
    let controller: DictationController
    let updates: UpdateController
    let navigation: MainNavigation
    let showWelcomeGuide: () -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: pageSelection) {
                ForEach(MainSection.pages, id: \.self) { page in
                    Label(page.title, systemImage: page.icon)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    UpdateFooter(updates: updates)
                    Divider()
                        .padding(.horizontal, 10)
                    SettingsRow(selected: navigation.section == .settings) {
                        navigation.section = .settings
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.bottom, 10)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
                .navigationTitle(navigation.section.title)
        }
        .background {
            // ⌘, opens Settings, as in other Mac apps.
            Button("Settings") { navigation.section = .settings }
                .keyboardShortcut(",")
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// The sidebar list highlights nothing while Settings is open.
    private var pageSelection: Binding<MainSection?> {
        Binding {
            navigation.section == .settings ? nil : navigation.section
        } set: { page in
            if let page { navigation.section = page }
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.section {
        case .home:
            HomeView(controller: controller, navigation: navigation)
        case .history:
            HistoryView(history: controller.history, copy: controller.copy) {
                navigation.openSettings(.privacy)
            }
        case .dictionary:
            DictionaryView(dictionary: controller.dictionary)
        case .snippets:
            SnippetsView(library: controller.snippets, dictionary: controller.dictionary.matcher)
        case .settings:
            SettingsView(
                controller: controller,
                navigation: navigation,
                showWelcomeGuide: showWelcomeGuide
            )
        }
    }
}

/// The Settings entry at the bottom of the sidebar, styled like a sidebar row.
private struct SettingsRow: View {
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: MainSection.settings.icon)
                    .frame(width: 18)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(MainSection.settings.title)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
                Text("⌘,")
                    .font(.caption)
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(hovering ? 0.05 : 0)))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
