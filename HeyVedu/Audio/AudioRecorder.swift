import AVFoundation
import AudioToolbox
import CoreAudio
import os

/// 16 kHz mono Float32 audio captured for one dictation. Kept in memory only.
nonisolated struct Recording: Sendable {
    static let sampleRate: Double = 16_000

    let samples: [Float]

    var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
}

enum AudioRecorderError: LocalizedError {
    case noAudioUnit
    case deviceSelectionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noAudioUnit: return "Input node has no audio unit"
        case .deviceSelectionFailed(let status): return "Could not select input device (OSStatus \(status))"
        }
    }
}

/// Main-actor façade over `CaptureSession`. Engine work (which can take hundreds of
/// milliseconds) runs on a background queue so the hotkey event tap is never blocked.
final class AudioRecorder {
    /// Normalised 0…1 input level for the waveform.
    var onLevel: ((Float) -> Void)?
    /// First non-empty buffer arrived — the mic is actually live.
    var onFirstAudio: (() -> Void)?
    /// The input device went away mid-recording.
    var onInterrupted: (() -> Void)?

    private let session = CaptureSession()

    init() {
        session.sink = { [weak self] event in
            Task { @MainActor in self?.deliver(event) }
        }
    }

    /// `deviceID == nil` records from the system default input.
    func start(deviceID: AudioDeviceID?) async throws {
        try await session.run { try $0.start(deviceID: deviceID) }
    }

    /// Stops capture and returns everything recorded so far.
    func stop() async -> Recording {
        await session.run { Recording(samples: $0.stop()) }
    }

    func cancel() async {
        await session.run { _ = $0.stop() }
    }

    private func deliver(_ event: CaptureSession.Event) {
        switch event {
        case .level(let level): onLevel?(level)
        case .firstAudio: onFirstAudio?()
        case .interrupted: onInterrupted?()
        }
    }
}

/// Owns the AVAudioEngine. All mutable state is confined to `queue`.
private nonisolated final class CaptureSession: @unchecked Sendable {
    enum Event: Sendable {
        case level(Float)
        case firstAudio
        case interrupted
    }

    /// Set once at init, before any capture starts.
    var sink: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "com.heyvedu.app.audio", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.heyvedu.app", category: "Audio")
    private var engine: AVAudioEngine?
    private var processor: CaptureProcessor?
    private var configObserver: NSObjectProtocol?
    private var deviceID: AudioDeviceID?
    private var restartCount = 0
    /// Bumped per engine so late notifications from a torn-down engine are ignored.
    private var generation = 0

    private static let startAttempts = 2
    private static let maxRestartsPerRecording = 3

    func run<T: Sendable>(_ work: @escaping @Sendable (CaptureSession) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work(self) }) }
        }
    }

    func run<T: Sendable>(_ work: @escaping @Sendable (CaptureSession) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work(self)) }
        }
    }

    // MARK: - Queue-confined operations

    func start(deviceID: AudioDeviceID?) throws {
        teardownEngine()
        self.deviceID = deviceID
        restartCount = 0
        processor = CaptureProcessor(sink: sink)
        try startEngineWithRetry()
    }

    func stop() -> [Float] {
        teardownEngine()
        let samples = processor?.drain() ?? []
        processor = nil
        return samples
    }

    private func startEngineWithRetry() throws {
        var lastError: Error?
        for attempt in 1...Self.startAttempts {
            do {
                try startEngine()
                return
            } catch {
                lastError = error
                DebugTrace.write("audio: engine start attempt \(attempt) failed: \(error.localizedDescription)")
                teardownEngine()
                if attempt < Self.startAttempts { Thread.sleep(forTimeInterval: 0.15) }
            }
        }
        throw lastError ?? AudioRecorderError.noAudioUnit
    }

    private func startEngine() throws {
        guard let processor else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Only switch devices when the user picked a specific mic; the engine already
        // follows the system default, and switching forces a reconfiguration.
        if let deviceID { try Self.select(deviceID: deviceID, on: input) }

        // format: nil → the tap uses whatever format the bus actually delivers. The
        // processor builds its converter from the first real buffer, so a stale
        // reported format can't break capture.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            processor.process(buffer)
        }

        engine.prepare()
        try engine.start()

        generation += 1
        let currentGeneration = generation
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleConfigurationChange(generation: currentGeneration) }
        }
        self.engine = engine

        let format = input.outputFormat(forBus: 0)
        DebugTrace.write("audio: engine started device=\(deviceID.map(String.init) ?? "default") reported=\(format.sampleRate)Hz/\(format.channelCount)ch")
    }

    /// Format changes (e.g. AirPods switching to the headset profile when the mic opens)
    /// restart the engine on the same device, keeping captured audio. If the device is
    /// gone, or it keeps changing, end the recording with what we have.
    private func handleConfigurationChange(generation changedGeneration: Int) {
        guard engine != nil, changedGeneration == generation else { return }
        DebugTrace.write("audio: configuration change (restart #\(restartCount + 1))")
        teardownEngine()

        let deviceAvailable = deviceID.map(CoreAudioDevice.isAlive) ?? (CoreAudioDevice.defaultInputID() != nil)
        guard restartCount < Self.maxRestartsPerRecording, deviceAvailable else {
            sink?(.interrupted)
            return
        }
        restartCount += 1
        do {
            try startEngineWithRetry()
            logger.notice("Audio engine restarted after configuration change")
        } catch {
            logger.error("Audio engine restart failed: \(error.localizedDescription, privacy: .public)")
            sink?(.interrupted)
        }
    }

    private func teardownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private static func select(deviceID: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw AudioRecorderError.noAudioUnit }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw AudioRecorderError.deviceSelectionFailed(status) }
    }
}

/// Resamples tap buffers to 16 kHz mono and accumulates them for one recording (across
/// engine restarts). Called on the audio thread; drained on the session queue.
private nonisolated final class CaptureProcessor: @unchecked Sendable {
    private let sink: (@Sendable (CaptureSession.Event) -> Void)?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Recording.sampleRate,
        channels: 1,
        interleaved: false
    )!
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var receivedAudio = false

    init(sink: (@Sendable (CaptureSession.Event) -> Void)?) {
        self.sink = sink
        samples.reserveCapacity(Int(Recording.sampleRate) * 30)
    }

    func process(_ input: AVAudioPCMBuffer) {
        guard input.frameLength > 0 else { return }

        lock.lock()
        let converted = convert(input)
        let isFirst = converted != nil && !receivedAudio
        if let converted {
            samples.append(contentsOf: converted)
            receivedAudio = true
        }
        lock.unlock()

        guard let converted else { return }
        if isFirst { sink?(.firstAudio) }
        sink?(.level(Self.normalisedLevel(converted)))
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }

    /// Must be called with `lock` held.
    private func convert(_ input: AVAudioPCMBuffer) -> [Float]? {
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            converter?.downmix = true
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let feed = InputFeed(buffer: input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            feed.next(outStatus)
        }
        guard status != .error, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private static func normalisedLevel(_ chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let rms = (sum / Float(chunk.count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(max((decibels + 50) / 50, 0), 1)
    }
}

private nonisolated enum CoreAudioDevice {
    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }
}

/// Hands a single tap buffer to AVAudioConverter exactly once per convert call.
private nonisolated final class InputFeed: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if consumed {
            status.pointee = .noDataNow
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
}
