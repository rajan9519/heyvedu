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
    let vocabulary = VocabularyStore()

    private(set) var status: Status = .idle
    private(set) var hotkeyAvailable = false

    @ObservationIgnored private let hotkey = HotkeyMonitor()
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

    private static let minimumDuration: TimeInterval = 0.2
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
            case .idle, .loading: return "Loading speech model…"
            case .downloading: return "Downloading speech model (~600 MB)…"
            case .failed: return "Speech model failed to load"
            case .ready: break
            }
            if devices.inputDevices.isEmpty { return "No microphone connected" }
            return "Hold ⌃⌥ to dictate"
        }
    }

    // MARK: - Lifecycle

    func start() {
        devices.start()

        hotkey.onEvent = { [weak self] event in self?.handle(event) }
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

        speechModel.prepare()
        cleaner.vocabulary = vocabulary.terms
        cleaner.warmUp()

        permissions.onChange = { [weak self] in self?.permissionsChanged() }
        permissions.startMonitoring()

        if !permissions.microphoneGranted { permissions.requestMicrophone() }
        if !permissions.accessibilityGranted { permissions.requestAccessibility() }
        permissionsChanged()
    }

    private func permissionsChanged() {
        if permissions.accessibilityGranted {
            hotkeyAvailable = hotkey.start()
            if !hotkeyAvailable { logger.error("Event tap creation failed despite Accessibility trust") }
        } else {
            DebugTrace.write("controller: accessibility lost")
            logger.notice("Accessibility trust lost; stopping hotkey")
            hotkey.stop()
            hotkeyAvailable = false
        }
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
        case .released:
            finishRecording()
        case .cancelled:
            cancelRecording()
        }
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
        case .idle, .downloading, .loading:
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
            self.cleaner.vocabulary = self.vocabulary.terms
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
        if status == .recording {
            status = .idle
            cleaner.discardPrepared()
            Task { await recorder.cancel() }
        }
        hud.hide()
    }

    private func finishRecording() {
        guard status == .recording else { return }
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
                if cleaner.isEnabled {
                    hud.showProcessing("Cleaning…")
                    let started = ContinuousClock.now
                    cleaner.vocabulary = vocabulary.terms
                    let result = await cleaner.clean(trimmed)
                    output = result.text
                    fallbackReason = result.fallbackReason
                    // Timing and fallback reason only — never the text itself.
                    DebugTrace.write("cleanup[\(cleaner.engine.rawValue)]: \(ContinuousClock.now - started)\(fallbackReason.map { ", fallback: \($0)" } ?? "")")
                }
                hud.hide()
                guard !output.isEmpty else {
                    // S1-mini drops filler-only speech ("um") entirely.
                    hud.flash("Nothing to paste")
                    return
                }
                inserter.insert(output)
                if let fallbackReason {
                    // Tell the user the pasted text is the uncleaned transcript, and why.
                    hud.flash("Pasted raw text — \(fallbackReason)", for: .seconds(3))
                }
            } catch {
                // Never log transcript content; error descriptions only.
                logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                hud.flash("Transcription failed")
            }
        }
    }
}
