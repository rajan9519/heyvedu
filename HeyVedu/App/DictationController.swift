import AppKit
import CoreAudio
import Observation
import os

/// Orchestrates hotkey → recording → transcription → insertion.
@Observable
final class DictationController {
    enum Status {
        case idle
        case recording
        case processing
    }

    let permissions = PermissionsManager()
    let devices = AudioDeviceManager()
    let speechModel = SpeechModel()
    let cleaner = TextCleaner()
    let dictionary = PersonalDictionary()
    let style = WritingStyle()
    let snippets = SnippetLibrary()
    let history = DictationHistory()
    let stats = DictationStats()
    let voiceActivity = VoiceActivity()
    let sounds = SoundCues()
    let launchAtLogin = LaunchAtLogin()

    var hudPosition: HUDPosition = .saved {
        didSet {
            hudPosition.save()
            hud.position = hudPosition
        }
    }

    var theme: AppTheme = .saved {
        didSet {
            theme.save()
            theme.apply()
        }
    }

    private(set) var status: Status = .idle
    private(set) var hotkeyAvailable = false
    /// The current recording continues without holding the hotkey.
    private(set) var isHandsFree = false

    var hotkey: Hotkey = .saved {
        didSet {
            hotkey.save()
            hotkeyMonitor.hotkey = hotkey
        }
    }

    /// Double-tap the hotkey to keep recording without holding it.
    var handsFreeEnabled = UserDefaults.standard.object(forKey: DictationController.handsFreeKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(handsFreeEnabled, forKey: Self.handsFreeKey)
            hotkeyMonitor.handsFreeEnabled = handsFreeEnabled
        }
    }

    /// Seconds of silence after which a hands-free recording finishes by itself; 0 is off.
    var handsFreeSilenceStop = UserDefaults.standard.object(forKey: DictationController.handsFreeSilenceStopKey) as? Int ?? 10 {
        didSet { UserDefaults.standard.set(handsFreeSilenceStop, forKey: Self.handsFreeSilenceStopKey) }
    }
    static let handsFreeSilenceStopChoices = [0, 5, 10, 20, 30]

    /// Stops listening for the hotkey, e.g. while the user records a new one.
    var hotkeySuspended: Bool {
        get { hotkeyMonitor.isSuspended }
        set { hotkeyMonitor.isSuspended = newValue }
    }
    /// The person chose to paste raw transcripts until the cleanup model finishes
    /// downloading. Cleared once it's ready, so a later download asks again.
    private(set) var pastesRawWhileDownloading = false

    /// Dictations pasted this session; the onboarding practice step watches it.
    private(set) var completedDictations = 0
    /// The most recent dictation's text, kept in memory only so it can be pasted again.
    /// Cleared `lastResultLifetime` after it was dictated.
    private(set) var lastResult: String?

    @ObservationIgnored private let hotkeyMonitor = HotkeyMonitor()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let hud = RecordingHUD()
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private let editWatcher = EditWatcher()
    @ObservationIgnored private lazy var downloadCard = DownloadCard { [weak self] in self?.modelDownload }
    /// The current press didn't record because dictation waits for a model download.
    @ObservationIgnored private var pressWaitsForDownload = false
    /// Why the current press could not start recording, shown once the press commits.
    @ObservationIgnored private var pressFailure: String?
    /// Set when the chosen mic was missing and the system default is used instead.
    @ObservationIgnored private var pressNotice: String?
    /// Audio has actually arrived for the current recording (often before the press commits).
    @ObservationIgnored private var audioLive = false
    /// The current press passed the hold threshold (the HUD is visible).
    @ObservationIgnored private var pressActivated = false
    /// The hands-free HUD is counting down to the silence auto-stop.
    @ObservationIgnored private var stoppingSoonShown = false
    /// The cleanup model finished downloading mid-dictation; announce it once that's done.
    @ObservationIgnored private var cleanupReadyNoticePending = false
    /// Ends a hands-free recording that runs past `handsFreeLimit`.
    @ObservationIgnored private var handsFreeLimitTask: Task<Void, Never>?
    /// Scores the current recording for speech; nil when VAD isn't loaded.
    @ObservationIgnored private var speechTracker: SpeechTracker?
    /// Forgets `lastResult` once it expires.
    @ObservationIgnored private var lastResultExpiryTask: Task<Void, Never>?
    /// Where the current recording's text is going, looked up when the hotkey was pressed.
    @ObservationIgnored private var targetLookup: Task<DictationTarget?, Never>?

    private static let minimumDuration: TimeInterval = 0.2
    private static let handsFreeLimit: Duration = .seconds(10 * 60)
    private static let handsFreeKey = "handsFreeEnabled"
    private static let handsFreeSilenceStopKey = "handsFreeSilenceStop"
    private static let lastResultLifetime: Duration = .seconds(5 * 60)
    /// Lets the menu close and focus return to the previous app before ⌘V is sent.
    private static let menuDismissDelay: Duration = .milliseconds(250)
    private let logger = Logger(subsystem: "com.heyvedu.app", category: "Dictation")

    // MARK: - Menu bar presentation

    var menuBarSymbol: String {
        switch status {
        case .recording: return "mic.fill"
        case .processing: return "waveform"
        case .idle:
            if !permissions.allGranted || !hotkeyAvailable { return "exclamationmark.triangle" }
            switch speechModel.state {
            case .idle, .downloading, .loading: return "arrow.down.circle"
            case .failed: return "exclamationmark.triangle"
            case .ready: break
            }
            if devices.defaultInputDevice == nil && devices.inputDevices.isEmpty { return "mic.slash" }
            return "mic"
        }
    }

    /// A model download dictation waits for: the speech model's, or the cleanup model's
    /// while cleanup is on. Nil when nothing is downloading or failed to download.
    var modelDownload: ModelDownload? {
        if speechModel.isDownloadPending {
            switch speechModel.state {
            case .downloading:
                return ModelDownload(model: .speech, progress: speechModel.downloadProgress ?? 0, size: SpeechModel.downloadSize, failure: nil)
            case .idle, .loading:
                return ModelDownload(model: .speech, progress: nil, size: SpeechModel.downloadSize, failure: nil)
            case .failed(let reason):
                return ModelDownload(model: .speech, progress: nil, size: SpeechModel.downloadSize, failure: reason)
            case .ready:
                break
            }
        }
        guard cleaner.isEnabled, let state = cleaner.modelState else { return nil }
        let model = ModelDownload.Model.cleanup(cleaner.engine.name)
        switch state {
        case .downloading(let fraction):
            return ModelDownload(model: model, progress: fraction, size: cleaner.downloadSize, failure: nil)
        case .loading where cleaner.isAwaitingDownload:
            return ModelDownload(model: model, progress: nil, size: cleaner.downloadSize, failure: nil)
        case .failed(let reason) where cleaner.needsDownload:
            return ModelDownload(model: model, progress: nil, size: cleaner.downloadSize, failure: reason)
        default:
            return nil
        }
    }

    /// Everything dictation needs is in place.
    var canDictate: Bool {
        permissions.allGranted && hotkeyAvailable && speechModel.isReady && !devices.inputDevices.isEmpty
    }

    var statusText: String {
        switch status {
        case .recording: return "Recording…"
        case .processing: return "Processing…"
        case .idle:
            if !permissions.allGranted { return "Permissions needed" }
            if !hotkeyAvailable { return "Hotkey unavailable — re-grant Accessibility" }
            switch speechModel.state {
            case .idle: return "Speech model not downloaded"
            case .loading: return "Loading speech model…"
            case .downloading: return "Downloading speech model (~600 MB)…"
            case .failed: return "Speech model failed to load"
            case .ready: break
            }
            if devices.inputDevices.isEmpty { return "No microphone connected" }
            return "Hold \(hotkey.symbols) to dictate"
        }
    }

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - requestPermissions: Prompt for missing grants right away. Off while the
    ///     onboarding window is up, which asks for them with an explanation instead.
    ///   - downloadModels: Start model downloads right away. Off on first run, where the
    ///     onboarding window offers them; models already on disk load either way.
    func start(requestPermissions: Bool = true, downloadModels: Bool = true) {
        devices.start()
        stats.importOnce(history.entries)

        hotkeyMonitor.hotkey = hotkey
        hotkeyMonitor.handsFreeEnabled = handsFreeEnabled
        hotkeyMonitor.onEvent = { [weak self] event in self?.handle(event) }
        recorder.onLevel = { [weak self] level in self?.hud.push(level: level) }
        recorder.onFirstAudio = { [weak self] in
            self?.audioLive = true
            self?.hud.setListening()
        }
        recorder.onInterrupted = { [weak self] in
            DebugTrace.write("controller: recorder interrupted")
            self?.logger.notice("Input device changed mid-recording; finishing with captured audio")
            self?.finishRecording()
        }

        downloadCard.onUseRawTranscripts = { [weak self] in self?.pastesRawWhileDownloading = true }
        downloadCard.onRetry = { [weak self] in self?.retryDownload() }
        speechModel.onDownloadStarted = { [weak self] in self?.downloadStarted() }
        cleaner.onDownloadStarted = { [weak self] in self?.downloadStarted() }
        speechModel.onReady = { [weak self] downloaded in
            if downloaded { self?.speechModelDownloaded() } else { self?.showLaunchHintIfNeeded() }
            // A small extra download, made once the user has agreed to the speech model's.
            self?.voiceActivity.prepare()
        }
        if downloadModels || speechModel.isDownloaded { speechModel.prepare() }
        cleaner.onDownloadedModelReady = { [weak self] in self?.cleanupModelReady() }
        if downloadModels || !cleaner.needsDownload { cleaner.warmUp() }

        permissions.onChange = { [weak self] in self?.permissionsChanged() }
        permissions.startMonitoring()

        if requestPermissions {
            if !permissions.microphoneGranted { permissions.requestMicrophone() }
            if !permissions.accessibilityGranted { permissions.requestAccessibility() }
        }
        permissionsChanged()
    }

    /// Starts any model download not started yet, e.g. the onboarding window closed first.
    func downloadModels() {
        speechModel.prepare()
        cleaner.warmUp()
    }

    /// For the first few launches after onboarding, remind the user of the hotkey once
    /// everything is ready to dictate.
    private func showLaunchHintIfNeeded() {
        let defaults = UserDefaults.standard
        guard Onboarding.isCompleted else { return }
        let shown = defaults.integer(forKey: Self.launchHintsShownKey)
        guard shown < Self.launchHintCount, status == .idle, permissions.allGranted, hotkeyAvailable else { return }
        defaults.set(shown + 1, forKey: Self.launchHintsShownKey)
        hud.flash("Hold \(hotkey.spokenName) anywhere to dictate", for: .seconds(3))
    }

    private static let launchHintsShownKey = "launchHintsShown"
    private static let launchHintCount = 3

    private func permissionsChanged() {
        if permissions.accessibilityGranted {
            hotkeyAvailable = hotkeyMonitor.start()
            if !hotkeyAvailable { logger.error("Event tap creation failed despite Accessibility trust") }
        } else {
            DebugTrace.write("controller: accessibility lost")
            logger.notice("Accessibility trust lost; stopping hotkey")
            hotkeyMonitor.stop()
            hotkeyAvailable = false
        }
    }

    /// Shows the download card once as a download starts. Not during onboarding, whose
    /// window shows the downloads, nor over a dictation in progress.
    private func downloadStarted() {
        guard Onboarding.isCompleted, status == .idle else { return }
        downloadCard.show(.started)
    }

    private func retryDownload() {
        if case .failed = speechModel.state {
            speechModel.prepare()
        } else {
            cleaner.download()
        }
    }

    /// The speech model downloaded this session is ready, so dictation works now.
    private func speechModelDownloaded() {
        // Dictation may still wait for the cleanup model; an open card now shows that one.
        guard modelDownload == nil else { return }
        downloadCard.hide()
        guard status == .idle, permissions.allGranted, hotkeyAvailable else { return }
        hud.flashSuccess("HeyVedu is ready — hold \(hotkey.spokenName) to dictate", for: .seconds(3))
    }

    /// A cleanup model downloaded this session is now in use. Tell the user, without
    /// covering the HUD of a dictation in progress.
    private func cleanupModelReady() {
        pastesRawWhileDownloading = false
        downloadCard.hide()
        if status == .idle {
            showCleanupReadyNotice()
        } else {
            cleanupReadyNoticePending = true
        }
    }

    private func showCleanupReadyNotice() {
        cleanupReadyNoticePending = false
        hud.flashSuccess("\(cleaner.engine.name) is ready — transcripts will be cleaned up", for: .seconds(3))
    }

    // MARK: - Hotkey handling

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .pressed:
            beginRecording()
        case .activated:
            pressActivated = true
            if status == .recording {
                sounds.play(.start)
                hud.showRecording(notice: pressNotice, listening: audioLive, tag: rawTag)
            } else if pressWaitsForDownload {
                downloadCard.show(.hotkeyPressed)
            } else if let pressFailure {
                hud.flash(pressFailure)
            }
        case .locked:
            // A double-tap never passes the hold threshold, so this is the first cue.
            let alreadyActive = pressActivated
            pressActivated = true
            if status == .recording {
                if !alreadyActive { sounds.play(.start) }
                isHandsFree = true
                hud.showRecording(notice: pressNotice ?? handsFreeHint, listening: audioLive, handsFree: true, tag: rawTag)
                handsFreeLimitTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.handsFreeLimit)
                    guard !Task.isCancelled else { return }
                    DebugTrace.write("controller: hands-free limit reached")
                    self?.finishRecording()
                }
            } else {
                // Busy or unable to record: don't let the next press count as "finish".
                hotkeyMonitor.reset()
                if pressWaitsForDownload {
                    downloadCard.show(.hotkeyPressed)
                } else {
                    hud.flash(pressFailure ?? "Still processing the last dictation")
                }
            }
        case .released:
            finishRecording()
        case .cancelled:
            cancelRecording()
        }
    }

    /// Marks a recording whose transcript will be pasted raw because the cleanup model
    /// is still downloading.
    private var rawTag: String? {
        guard pastesRawWhileDownloading, let download = modelDownload, download.allowsRawTranscripts else { return nil }
        guard download.failure == nil, let progress = download.progress else { return "Raw" }
        return "Raw · \(Int(progress * 100))%"
    }

    private var handsFreeHint: String {
        "Hands-free — press \(hotkey.symbols) to finish, Esc to cancel"
    }

    /// Clears hands-free state when a recording ends for any reason.
    private func endHandsFree() {
        handsFreeLimitTask?.cancel()
        handsFreeLimitTask = nil
        if isHandsFree { hotkeyMonitor.reset() }
        isHandsFree = false
        stoppingSoonShown = false
    }

    /// Returns immediately; the engine starts on the recorder's background queue so the
    /// keyboard event tap is never blocked.
    private func beginRecording() {
        pressFailure = nil
        pressWaitsForDownload = false
        pressNotice = nil
        audioLive = false
        pressActivated = false
        guard status == .idle else { return }
        // The next paste may land in the same field; keep what the last one became.
        editWatcher.finish()

        guard permissions.microphoneGranted else {
            pressFailure = "Microphone access needed"
            return
        }
        if let download = modelDownload, !(download.allowsRawTranscripts && pastesRawWhileDownloading) {
            pressWaitsForDownload = true
            return
        }
        switch speechModel.state {
        case .ready: break
        case .failed:
            pressFailure = "Speech model unavailable"
            return
        case .idle:
            pressFailure = "Speech model not downloaded"
            return
        case .downloading, .loading:
            pressFailure = "Speech model still loading…"
            return
        }
        let (resolution, fellBack) = devices.resolveInputDevice()
        let deviceID: AudioDeviceID?
        switch resolution {
        case .unavailable:
            pressFailure = "No microphone"
            return
        case .systemDefault:
            deviceID = nil
        case .device(let id):
            deviceID = id
        }
        if fellBack { pressNotice = "Selected mic unavailable — using default" }

        status = .recording
        // Start cleanup preparation on the initial press so model/session setup overlaps
        // the 250 ms commit delay as well as the time the user spends speaking. Defer it
        // off the event-tap callback so launching a CLI cannot make the tap time out.
        Task { [weak self] in
            guard let self, self.status == .recording else { return }
            self.cleaner.prepare()
        }
        // The cursor is in the target now; a browser's page host can take a moment to read.
        targetLookup = Task { await DictationTarget.current(askConsent: true) }
        Task {
            do {
                let chunks = try await recorder.start(deviceID: deviceID, chunkSize: VoiceActivity.chunkSize)
                // The press may have been released or cancelled while the engine started;
                // the stream is already finished then, so the tracker ends on its own.
                guard status == .recording else { return }
                speechTracker = voiceActivity.track(chunks)
                speechTracker?.onSilence = { [weak self] silence in self?.silenceUpdated(silence) }
            } catch {
                DebugTrace.write("controller: start failed: \(error.localizedDescription)")
                logger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
                // The press may already have been released or cancelled meanwhile.
                guard status == .recording else { return }
                status = .idle
                pressFailure = "Microphone unavailable"
                if pressActivated { hud.flash("Microphone unavailable") }
            }
        }
    }

    private func cancelRecording() {
        DebugTrace.write("controller: cancel")
        endHandsFree()
        if status == .recording {
            if pressActivated { sounds.play(.cancel) }
            status = .idle
            cleaner.discardPrepared()
            Task { await recorder.cancel() }
        }
        targetLookup?.cancel()
        targetLookup = nil
        speechTracker = nil
        hud.hide()
    }

    /// Finishes a hands-free recording once the user has been quiet long enough, after a
    /// short countdown in the HUD that speaking again cancels.
    private func silenceUpdated(_ silence: TimeInterval) {
        guard isHandsFree, status == .recording, handsFreeSilenceStop > 0 else { return }
        let remaining = TimeInterval(handsFreeSilenceStop) - silence
        if remaining <= 0 {
            DebugTrace.write("controller: hands-free stopped after \(Int(silence))s of silence")
            finishRecording()
        } else if remaining <= Self.stoppingSoonWarning {
            stoppingSoonShown = true
            hud.setNotice("Finishing in \(Int(remaining.rounded(.up)))s — keep talking to continue")
        } else if stoppingSoonShown {
            stoppingSoonShown = false
            hud.setNotice(pressNotice ?? handsFreeHint)
        }
    }

    private static let stoppingSoonWarning: TimeInterval = 3

    /// Drops leading and trailing silence, so the model doesn't invent words for it.
    /// Returns the recording unchanged when VAD isn't available or heard no speech.
    private func trimSilence(_ recording: Recording, tracker: SpeechTracker?) async -> Recording {
        guard let probabilities = await tracker?.finish(),
              let range = SpeechTrim.range(probabilities: probabilities, sampleCount: recording.samples.count),
              range.count < recording.samples.count else { return recording }
        let trimmed = Recording(samples: Array(recording.samples[range]))
        DebugTrace.write("vad: trimmed \(String(format: "%.2f", recording.duration))s to \(String(format: "%.2f", trimmed.duration))s")
        return trimmed
    }

    private func finishRecording() {
        guard status == .recording else { return }
        if pressActivated { sounds.play(.stop) }
        endHandsFree()
        status = .processing
        let target = PasteTarget.current()
        hud.showProcessing("Transcribing…")

        let tracker = speechTracker
        speechTracker = nil
        let lookup = targetLookup
        targetLookup = nil

        Task {
            defer { status = .idle }
            let captured = await recorder.stop()
            let recording = await trimSilence(captured, tracker: tracker)
            DebugTrace.write("controller: finish, captured \(String(format: "%.2f", captured.duration))s")
            logger.notice("Recording finished: \(captured.duration, format: .fixed(precision: 2), privacy: .public)s captured")

            guard recording.duration >= Self.minimumDuration else {
                cleaner.discardPrepared()
                if recording.samples.isEmpty {
                    hud.flash("No audio from microphone")
                } else if cleanupReadyNoticePending {
                    showCleanupReadyNotice()
                } else {
                    hud.hide()
                }
                return
            }

            do {
                let text = try await speechModel.transcribe(recording)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    cleaner.discardPrepared()
                    hud.flash("No speech detected")
                    return
                }

                var output = trimmed
                var fallbackReason: String?
                var awaitingDownload = false
                var cleanup: TextCleaner.Result?
                if cleaner.isEnabled {
                    hud.showProcessing("Cleaning…")
                    let context = await cleanupContext(for: target, lookup: lookup)
                    let started = ContinuousClock.now
                    let result = await cleaner.clean(
                        trimmed, context: context,
                        vocabulary: dictionary.vocabulary)
                    cleanup = result
                    output = result.text
                    fallbackReason = result.fallbackReason
                    awaitingDownload = result.awaitingDownload
                    // Timing and fallback reason only — never the text itself.
                    DebugTrace.write("cleanup[\(cleaner.engine.rawValue)]: \(ContinuousClock.now - started)\(fallbackReason.map { ", fallback: \($0)" } ?? "")")
                }
                // After cleanup, so the model can't undo the user's spellings or touch a
                // snippet's text.
                output = snippets.expander.expand(output, dictionary: dictionary.matcher)
                hud.hide()
                guard !output.isEmpty else {
                    // Vedu Scribe drops filler-only speech ("um") entirely.
                    hud.flash("Nothing to paste")
                    return
                }
                remember(output)
                let entry = DictationHistory.Entry(
                    date: .now,
                    duration: recording.duration,
                    transcript: trimmed,
                    modelOutput: cleanup?.text,
                    cleanupEngine: cleanup.map { _ in cleaner.engine.rawValue },
                    fallbackReason: fallbackReason,
                    finalText: output
                )
                history.record(entry)
                stats.record(output, duration: recording.duration)
                let outcome = await inserter.insert(output, into: target)
                if outcome == .pasted, history.isEnabled {
                    editWatcher.watch(inserted: output) { [weak self] edited in
                        self?.history.recordEdit(edited, for: entry.id)
                    }
                }
                completedDictations += 1
                if let message = Self.copiedMessage(for: outcome) {
                    // Ahead of the cleanup notices: the user has to act to get their text.
                    hud.flashInfo(message, for: .seconds(4))
                } else if awaitingDownload || pastesRawWhileDownloading {
                    // The person chose raw transcripts; the recording HUD's tag said so.
                } else if let fallbackReason {
                    // Tell the user the pasted text is the uncleaned transcript, and why.
                    hud.flash("Pasted raw text — \(fallbackReason)", for: .seconds(3))
                } else if cleanupReadyNoticePending {
                    showCleanupReadyNotice()
                }
            } catch {
                // Never log transcript content; error descriptions only.
                logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                hud.flash("Transcription failed")
            }
        }
    }

    /// How to write the text for `app`, the app it's pasted into, in the user's tone for it.
    /// Uses the lookup made when the hotkey was pressed, unless the user switched apps while
    /// speaking.
    private func cleanupContext(for app: NSRunningApplication?, lookup: Task<DictationTarget?, Never>?) async -> CleanupContext {
        guard let app else { return style.context(for: .other) }
        var detected = await lookup?.value
        if detected?.processID != app.processIdentifier {
            detected = await DictationTarget.detect(bundleID: app.bundleIdentifier, processID: app.processIdentifier)
        }
        let context = style.context(for: detected?.destination ?? .other)
        // The app and page host only, never the text.
        DebugTrace.write("target: \(detected?.summary ?? "none"), header \(context.header ?? "none")")
        return context
    }

    // MARK: - Last result

    private static func copiedMessage(for outcome: TextInserter.Outcome) -> String? {
        switch outcome {
        case .pasted:
            return nil
        case .noTextField:
            return "No text field — copied, press ⌘V to paste"
        case .targetUnavailable(let appName):
            return "Couldn't return to \(appName ?? "the app") — copied, press ⌘V to paste"
        }
    }

    private func remember(_ text: String) {
        lastResult = text
        lastResultExpiryTask?.cancel()
        lastResultExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lastResultLifetime)
            guard !Task.isCancelled else { return }
            self?.lastResult = nil
        }
    }

    /// Pastes the last dictation into whatever has focus, e.g. after a paste went missing.
    /// Called from the menu, so it waits for the menu to close first.
    func pasteLastResult() {
        guard status == .idle, lastResult != nil else { return }
        // The menu doesn't take focus, so this is the app the user was just in.
        let target = PasteTarget.current()
        Task {
            try? await Task.sleep(for: Self.menuDismissDelay)
            // It may have expired, or a dictation started, while the menu closed.
            guard status == .idle, let text = lastResult else { return }
            if let message = Self.copiedMessage(for: await inserter.insert(text, into: target)) {
                hud.flashInfo(message, for: .seconds(4))
            }
        }
    }

    func copyLastResult() {
        guard let lastResult else { return }
        inserter.copy(lastResult)
    }

    /// Puts `text` on the clipboard, e.g. a dictation from history.
    func copy(_ text: String) {
        inserter.copy(text)
    }
}
