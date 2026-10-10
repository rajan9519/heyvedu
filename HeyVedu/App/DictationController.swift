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

    /// Stops listening for the hotkey, e.g. while the user records a new one.
    var hotkeySuspended: Bool {
        get { hotkeyMonitor.isSuspended }
        set { hotkeyMonitor.isSuspended = newValue }
    }
    /// Dictations pasted this session; the onboarding practice step watches it.
    private(set) var completedDictations = 0

    @ObservationIgnored private let hotkeyMonitor = HotkeyMonitor()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let hud = RecordingHUD()
    @ObservationIgnored private let inserter = TextInserter()
    /// Why the current press could not start recording, shown once the press commits.
    @ObservationIgnored private var pressFailure: String?
    /// Set when the chosen mic was missing and the system default is used instead.
    @ObservationIgnored private var pressNotice: String?
    /// Audio has actually arrived for the current recording (often before the press commits).
    @ObservationIgnored private var audioLive = false
    /// The current press passed the hold threshold (the HUD is visible).
    @ObservationIgnored private var pressActivated = false
    /// The user was told once that dictations paste raw text while the cleanup model
    /// downloads; later dictations during the same download stay quiet.
    @ObservationIgnored private var downloadNoticeShown = false
    /// The cleanup model finished downloading mid-dictation; announce it once that's done.
    @ObservationIgnored private var cleanupReadyNoticePending = false
    /// Ends a hands-free recording that runs past `handsFreeLimit`.
    @ObservationIgnored private var handsFreeLimitTask: Task<Void, Never>?

    private static let minimumDuration: TimeInterval = 0.2
    private static let handsFreeLimit: Duration = .seconds(10 * 60)
    private static let handsFreeKey = "handsFreeEnabled"
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

        speechModel.onReady = { [weak self] in self?.showLaunchHintIfNeeded() }
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

    /// A cleanup model downloaded this session is now in use. Tell the user, without
    /// covering the HUD of a dictation in progress.
    private func cleanupModelReady() {
        downloadNoticeShown = false
        if status == .idle {
            showCleanupReadyNotice()
        } else {
            cleanupReadyNoticePending = true
        }
    }

    private func showCleanupReadyNotice() {
        cleanupReadyNoticePending = false
        hud.flash("\(cleaner.engine.name) is ready — transcripts will be cleaned up", for: .seconds(3))
    }

    // MARK: - Hotkey handling

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .pressed:
            beginRecording()
        case .activated:
            pressActivated = true
            if status == .recording {
                hud.showRecording(notice: pressNotice, listening: audioLive)
            } else if let pressFailure {
                hud.flash(pressFailure)
            }
        case .locked:
            pressActivated = true
            if status == .recording {
                isHandsFree = true
                hud.showRecording(notice: pressNotice ?? handsFreeHint, listening: audioLive, handsFree: true)
                handsFreeLimitTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.handsFreeLimit)
                    guard !Task.isCancelled else { return }
                    DebugTrace.write("controller: hands-free limit reached")
                    self?.finishRecording()
                }
            } else {
                // Busy or unable to record: don't let the next press count as "finish".
                hotkeyMonitor.reset()
                hud.flash(pressFailure ?? "Still processing the last dictation")
            }
        case .released:
            finishRecording()
        case .cancelled:
            cancelRecording()
        }
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
    }

    /// Returns immediately; the engine starts on the recorder's background queue so the
    /// keyboard event tap is never blocked.
    private func beginRecording() {
        pressFailure = nil
        pressNotice = nil
        audioLive = false
        pressActivated = false
        guard status == .idle else { return }

        guard permissions.microphoneGranted else {
            pressFailure = "Microphone access needed"
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
        Task {
            do {
                try await recorder.start(deviceID: deviceID)
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
            status = .idle
            cleaner.discardPrepared()
            Task { await recorder.cancel() }
        }
        hud.hide()
    }

    private func finishRecording() {
        guard status == .recording else { return }
        endHandsFree()
        status = .processing
        hud.showProcessing("Transcribing…")

        Task {
            defer { status = .idle }
            let recording = await recorder.stop()
            DebugTrace.write("controller: finish, captured \(String(format: "%.2f", recording.duration))s")
            logger.notice("Recording finished: \(recording.duration, format: .fixed(precision: 2), privacy: .public)s captured")

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
                if cleaner.isEnabled {
                    hud.showProcessing("Cleaning…")
                    let started = ContinuousClock.now
                    let result = await cleaner.clean(trimmed, dictionary: dictionary.matcher)
                    output = result.text
                    fallbackReason = result.fallbackReason
                    awaitingDownload = result.awaitingDownload
                    // Timing and fallback reason only — never the text itself.
                    DebugTrace.write("cleanup[\(cleaner.engine.rawValue)]: \(ContinuousClock.now - started)\(fallbackReason.map { ", fallback: \($0)" } ?? "")")
                }
                // After cleanup, so the model can't undo the user's spellings.
                output = dictionary.matcher.apply(to: output)
                hud.hide()
                guard !output.isEmpty else {
                    // Vedu Scribe drops filler-only speech ("um") entirely.
                    hud.flash("Nothing to paste")
                    return
                }
                inserter.insert(output)
                completedDictations += 1
                if awaitingDownload {
                    // Once per download; the menu shows its progress.
                    if !downloadNoticeShown {
                        downloadNoticeShown = true
                        hud.flash("Pasting raw text until \(cleaner.engine.name) finishes downloading", for: .seconds(4))
                    }
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
}
