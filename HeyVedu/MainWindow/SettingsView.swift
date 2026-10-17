import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcut, models, assist, privacy, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcut: return "Shortcut"
        case .models: return "Models"
        case .assist: return "AI Assist"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .shortcut: return "keyboard"
        case .models: return "cpu"
        case .assist: return "sparkles"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

/// The main window's Settings page: a row of tabs across the top, like a Mac app's
/// Settings window, with every customization below.
struct SettingsView: View {
    let controller: DictationController
    let navigation: MainNavigation
    let showWelcomeGuide: () -> Void

    var body: some View {
        @Bindable var navigation = navigation

        VStack(spacing: 0) {
            SettingsTabBar(selection: $navigation.settingsTab)
            Divider()
            Group {
                switch navigation.settingsTab {
                case .general:
                    GeneralSettings(controller: controller)
                case .shortcut:
                    ShortcutSettings(controller: controller)
                case .models:
                    ModelSettings(speechModel: controller.speechModel, cleaner: controller.cleaner)
                case .assist:
                    AssistSettingsView(assist: controller.assist, learner: controller.learner)
                case .privacy:
                    PrivacySettings(controller: controller)
                case .about:
                    AboutSettings(showWelcomeGuide: showWelcomeGuide)
                }
            }
            .frame(maxWidth: 640, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabButton(tab: tab, selected: tab == selection) { selection = tab }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 17))
                    .frame(height: 20)
                Text(tab.title)
                    .font(.caption)
            }
            .frame(minWidth: 64)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.brandText : .secondary)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(selected ? 0.08 : hovering ? 0.04 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let controller: DictationController

    var body: some View {
        @Bindable var controller = controller
        @Bindable var cleaner = controller.cleaner
        @Bindable var devices = controller.devices
        @Bindable var sounds = controller.sounds

        Form {
            Section {
                LaunchAtLoginToggle(launchAtLogin: controller.launchAtLogin)
            }

            Section {
                Toggle(isOn: $cleaner.isEnabled) {
                    Text("Clean up transcripts")
                    Text("Removes filler words, applies your self-corrections and fixes punctuation.")
                }
                Picker("Cleanup engine", selection: engineBinding) {
                    ForEach(TextCleaner.Engine.supported) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .disabled(!cleaner.isEnabled)
                if cleaner.isEnabled, case .unavailable(let reason) = cleaner.availability {
                    Label("\(reason). Pasting raw transcripts until it's ready.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                if cleaner.isEnabled, cleaner.engine.sendsTranscripts {
                    CloudCleanupNotice(assist: controller.assist)
                }
            }
            .confirmationDialog("Clean up dictations with Claude Code or Codex?",
                                isPresented: $confirmingCloudCleanup, titleVisibility: .visible) {
                Button("Use Claude Code or Codex") { controller.cleaner.engine = .assist }
                Button("Keep \(controller.cleaner.engine.name)", role: .cancel) {}
            } message: {
                Text(Self.cloudCleanupWarning)
            }

            Section {
                Picker("Microphone", selection: $devices.selectedDeviceUID) {
                    Text(systemDefaultLabel).tag(String?.none)
                    ForEach(devices.inputDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
            }

            Section {
                Picker("Appearance", selection: $controller.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                Picker(selection: $controller.hudPosition) {
                    ForEach(HUDPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                } label: {
                    Text("Recording indicator")
                    Text("Notch uses the top of the screen on displays without one.")
                }
                Toggle(isOn: $sounds.isEnabled) {
                    Text("Play sounds")
                    Text("A short sound when recording starts, finishes or is cancelled.")
                }
            }
        }
        .formStyle(.grouped)
    }

    @State private var confirmingCloudCleanup = false

    static let cloudCleanupWarning = """
        Vedu Scribe is the fastest option and runs entirely on this Mac.

        Claude Code or Codex is slower (usually 1–3 seconds more per dictation). It sends \
        every transcript, along with your dictionary words and snippets, to Anthropic or \
        OpenAI through your own sign-in, whichever is set up, and counts against your plan's \
        limits.

        The model does the whole job, cleanup, dictionary and snippets, and its answer is \
        pasted exactly as it wrote it, without HeyVedu's own checks. If it's slow or \
        unavailable, the raw transcript is pasted instead.
        """

    /// Choosing the cloud engine asks first; the others switch right away.
    private var engineBinding: Binding<TextCleaner.Engine> {
        let cleaner = controller.cleaner
        return Binding {
            cleaner.engine
        } set: { engine in
            if engine.sendsTranscripts, !cleaner.engine.sendsTranscripts {
                confirmingCloudCleanup = true
            } else {
                cleaner.engine = engine
            }
        }
    }

    private var systemDefaultLabel: String {
        if let name = controller.devices.defaultInputDevice?.name {
            return "System Default (\(name))"
        }
        return "System Default"
    }
}

/// Under the cleanup picker while Claude Code or Codex cleans dictations: what that costs,
/// and which model is answering.
private struct CloudCleanupNotice: View {
    let assist: AssistService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Slower than Vedu Scribe. Each transcript, with your dictionary and snippets, is sent to Anthropic or OpenAI through your own sign-in, and the model's answer is pasted as is.",
                  systemImage: "icloud.and.arrow.up")
                .foregroundStyle(.orange)
            Text(modelLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelLine: String {
        if !assist.hasUsableCLI { return "Sign in to Claude Code or Codex first. Until then the raw transcript is pasted." }
        if assist.isMeasuring { return "Finding the fastest model your account offers…" }
        guard let route = assist.cleanupRoute else { return "No model available yet." }
        return "Using \(assist.name(of: route)). Change it in Settings → AI Assist."
    }
}

private struct LaunchAtLoginToggle: View {
    let launchAtLogin: LaunchAtLogin

    var body: some View {
        Toggle(isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })) {
            Text("Open at login")
            Text("Start HeyVedu when you log in, so the shortcut is always ready.")
        }
        // The user can change login items in System Settings while HeyVedu runs.
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
        .alert(
            "Couldn't change Open at login",
            isPresented: Binding(get: { launchAtLogin.error != nil }, set: { if !$0 { launchAtLogin.error = nil } })
        ) {
            Button("OK", role: .cancel) {}
            Button("Open Login Items…") { launchAtLogin.openLoginItemsSettings() }
        } message: {
            Text(launchAtLogin.error ?? "")
        }
        if launchAtLogin.needsApproval {
            HStack {
                Label("Turned off in System Settings. Allow HeyVedu in Login Items.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items…") { launchAtLogin.openLoginItemsSettings() }
            }
        }
    }
}

// MARK: - Shortcut

private struct ShortcutSettings: View {
    let controller: DictationController
    @State private var recording = false

    var body: some View {
        @Bindable var controller = controller

        Form {
            Section {
                if recording {
                    HotkeyRecorderView(current: controller.hotkey) { hotkey in
                        if let hotkey { controller.hotkey = hotkey }
                        setRecording(false)
                    }
                } else {
                    LabeledContent("Dictation shortcut") {
                        HStack(spacing: 12) {
                            Text(controller.hotkey.symbols)
                                .font(.title3.weight(.medium))
                            Button("Change…") { setRecording(true) }
                        }
                    }
                    if controller.hotkey.modifiers == .function, Hotkey.systemUsesFunctionKey {
                        FunctionKeyWarning()
                    }
                }
            } footer: {
                Text("Hold the shortcut to dictate, and let go to paste. Esc cancels.")
            }

            Section {
                Toggle(isOn: $controller.handsFreeEnabled) {
                    Text("Double-tap for hands-free")
                    Text("Double-tap the shortcut to keep recording without holding it. Press it again to finish.")
                }
                Picker(selection: $controller.handsFreeSilenceStop) {
                    ForEach(DictationController.handsFreeSilenceStopChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Never" : "After \(seconds) seconds").tag(seconds)
                    }
                } label: {
                    Text("Stop when you go quiet")
                    Text("Finish a hands-free dictation by itself once you've stopped talking.")
                }
                .disabled(!controller.handsFreeEnabled)
            }
        }
        .formStyle(.grouped)
        // Leaving the tab or closing the window mid-recording must not leave the hotkey off.
        .onDisappear { setRecording(false) }
    }

    /// Pressing the current hotkey while recording must not start a dictation.
    private func setRecording(_ on: Bool) {
        recording = on
        controller.hotkeySuspended = on
    }
}

private struct FunctionKeyWarning: View {
    var body: some View {
        HStack {
            Label("macOS also acts on the 🌐 key. Set “Press 🌐 key to” to Do Nothing.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Keyboard Settings…") { Hotkey.openKeyboardSettings() }
        }
    }
}

// MARK: - Models

private struct ModelSettings: View {
    let speechModel: SpeechModel
    let cleaner: TextCleaner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("HeyVedu runs these models on your Mac. Each downloads once and works offline after that.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ModelRow(
                    icon: "waveform",
                    title: "Speech model",
                    detail: "Parakeet TDT v3 turns your voice into text. Required for dictation.",
                    status: .speech(speechModel),
                    download: speechModel.prepare
                )
                ModelRow(
                    icon: "text.badge.checkmark",
                    title: "Cleanup model",
                    detail: cleaner.engine.sendsTranscripts
                        ? "\(cleaner.engine.name) removes filler words, applies your corrections and fixes punctuation. It runs in the cloud through your own sign-in, not on this Mac. Choose the engine in General."
                        : "\(cleaner.engine.name) removes filler words, applies your corrections and fixes punctuation. Choose the engine in General.",
                    status: .cleanup(cleaner),
                    download: cleaner.download
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - AI Assist

private struct AssistSettingsView: View {
    @Bindable var assist: AssistService
    let learner: DictionaryLearner

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $assist.isEnabled) {
                    Text("Use AI Assist")
                    Text("A language model double-checks the words HeyVedu suggests from your corrections, so fewer wrong ones come up. Without it, a simple sounds-alike check is used.")
                }
                if assist.isEnabled, !learner.isEnabled {
                    Label("Turn on “Suggest words from your corrections” in Dictionary to use it.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if assist.cleansDictations, !(assist.isEnabled && assist.engine == .cli) {
                cleanupOnlySections
            }

            if assist.isEnabled {
                Section {
                    Picker("Engine", selection: $assist.engine) {
                        ForEach(AssistSettings.Engine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    switch assist.engine {
                    case .apple:
                        ProviderStatusRow(provider: .apple, status: assist.statuses[.apple])
                    case .cli:
                        ProviderStatusRow(provider: .claude, status: assist.statuses[.claude])
                        ProviderStatusRow(provider: .codex, status: assist.statuses[.codex])
                    }
                } header: {
                    Text("Where requests go")
                } footer: {
                    Text(assist.engine == .apple
                         ? "Runs on this Mac. Nothing is sent anywhere."
                         : "Sends the sentence you edited, before and after, to Anthropic or OpenAI through your own Claude Code or Codex sign-in. It counts against your plan’s limits. HeyVedu never sees or stores your sign-in.")
                }

                if assist.engine == .cli {
                    modelSection
                }

                Section {
                    Stepper(value: $assist.dailyCap, in: 10...500, step: 10) {
                        Text("Daily limit: \(assist.dailyCap) requests")
                    }
                    LabeledContent("Today") {
                        Text(activity).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Usage")
                }
            }
        }
        .formStyle(.grouped)
        .task { await assist.refreshStatus() }
    }

    /// Cleanup uses the CLIs even with AI Assist off; show their status and model here too.
    private var cleanupOnlySections: some View {
        Group {
            Section {
                ProviderStatusRow(provider: .claude, status: assist.statuses[.claude])
                ProviderStatusRow(provider: .codex, status: assist.statuses[.codex])
            } header: {
                Text("Cleanup")
            } footer: {
                Text("Your cleanup engine is Claude Code or Codex (Settings → General), so each transcript, with your dictionary and snippets, is sent to Anthropic or OpenAI through your own sign-in. The model's answer is pasted as is.")
            }
            modelSection
        }
    }

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $assist.pinnedRoute) {
                Text(fastestLabel).tag(AssistRoute?.none)
                ForEach(measuredRoutes, id: \.self) { route in
                    Text(assist.name(of: route)).tag(Optional(route))
                }
            }
            if assist.cleansDictations, let route = assist.cleanupRoute {
                LabeledContent("Cleanup uses") {
                    Text(assist.name(of: route)).foregroundStyle(.secondary)
                }
            }
            LabeledContent {
                if assist.isMeasuring {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Re-check Models", action: assist.recheckModels)
                }
            } label: {
                Text("Last checked")
                Text(lastChecked)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("HeyVedu asks each CLI which models your account offers and uses the cheapest one, in its newest version, that gets a few test sentences right (for example Claude Code’s Haiku or Codex’s Luna). It checks again when a CLI updates, once a week, or here. Pick another model here to use it for both word suggestions and cleanup.")
        }
    }

    private var fastestLabel: String {
        guard let first = (assist.pick ?? assist.cleanupPick)?.chain.first else { return "Cheapest (not checked yet)" }
        return "Cheapest (\(assist.name(of: first)))"
    }

    /// Every model that passed a measurement, for either task.
    private var measuredRoutes: [AssistRoute] {
        var seen = Set<AssistRoute>()
        return ((assist.pick?.chain ?? []) + (assist.cleanupPick?.chain ?? [])).filter { seen.insert($0).inserted }
    }

    private var lastChecked: String {
        if assist.isMeasuring { return "Measuring models…" }
        guard let date = [assist.pick, assist.cleanupPick].compactMap({ $0?.measuredAt }).max() else { return "Not yet" }
        return date.formatted(.relative(presentation: .named))
    }

    private var activity: String {
        let count = "\(assist.requestsToday) request\(assist.requestsToday == 1 ? "" : "s")"
        guard let route = assist.lastRoute else { return count }
        return "\(count) · last on \(assist.name(of: route))"
    }
}

private struct ProviderStatusRow: View {
    let provider: AssistProviderID
    let status: AssistAvailability?

    var body: some View {
        LabeledContent(provider.title) {
            switch status {
            case nil:
                ProgressView().controlSize(.small)
            case .available(let version):
                Label(version.map { "Ready · \($0)" } ?? "Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .outdated(_, let message):
                Label(message, systemImage: "arrow.up.circle").foregroundStyle(.orange)
            case .notInstalled:
                Text("Not installed").foregroundStyle(.secondary)
            case .signedOut(let message), .failed(let message):
                Text(message).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    let controller: DictationController

    @State private var confirmingHistoryOff = false
    @State private var confirmingStatsReset = false

    var body: some View {
        let permissions = controller.permissions
        let history = controller.history

        Form {
            Section {
                PermissionStatus(title: "Microphone", granted: permissions.microphoneGranted, grant: permissions.requestMicrophone)
                PermissionStatus(title: "Accessibility", granted: permissions.accessibilityGranted, grant: permissions.requestAccessibility)
            } header: {
                Text("Permissions")
            } footer: {
                Text("The microphone hears you only while you dictate. Accessibility lets HeyVedu notice \(controller.hotkey.symbols) in any app and paste where your cursor is.")
            }

            Section {
                Toggle(isOn: historyBinding) {
                    Text("Keep dictation history")
                    Text("Saved on this Mac only, so you can find and copy past dictations. Turning this off deletes the history.")
                }
                LabeledContent {
                    Button("Reset…") { confirmingStatsReset = true }
                        .disabled(controller.stats.totalDictations == 0)
                } label: {
                    Text("Activity stats")
                    Text("Daily word and time counts behind Home. Never the text itself.")
                }
            } header: {
                Text("Your data")
            } footer: {
                Text(controller.cleaner.engine.sendsTranscripts
                     ? "Your voice is transcribed on this Mac. Transcripts, with your dictionary and snippets, are then cleaned up by Claude Code or Codex, which sends them to Anthropic or OpenAI. Switch to Vedu Scribe in General to keep everything local."
                     : "Your voice is transcribed on this Mac, and nothing leaves it unless you turn on AI Assist with Claude Code or Codex.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Turn off history?", isPresented: $confirmingHistoryOff) {
            Button("Turn Off and Delete", role: .destructive) { history.isEnabled = false }
        } message: {
            Text("All \(history.entries.count) saved dictations will be deleted.")
        }
        .confirmationDialog("Reset activity stats?", isPresented: $confirmingStatsReset) {
            Button("Reset", role: .destructive) { controller.stats.reset() }
        } message: {
            Text("Your word counts, streaks and activity calendar start over.")
        }
    }

    /// Asks before turning off, since that deletes what's saved.
    private var historyBinding: Binding<Bool> {
        let history = controller.history
        return Binding {
            history.isEnabled
        } set: { on in
            if on || history.entries.isEmpty {
                history.isEnabled = on
            } else {
                confirmingHistoryOff = true
            }
        }
    }
}

private struct PermissionStatus: View {
    let title: String
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: grant)
            }
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    let showWelcomeGuide: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("BrandMark")
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HeyVedu").font(.title3.weight(.semibold))
                        Text("Version \(UpdateController.currentVersion)")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Welcome guide") {
                    Button("Show…", action: showWelcomeGuide)
                }
            }
        }
        .formStyle(.grouped)
    }
}
