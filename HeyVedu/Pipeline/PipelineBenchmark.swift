#if DEBUG
@preconcurrency import AVFoundation
import Darwin
import Foundation

/// Debug harness: `HeyVedu.app/Contents/MacOS/HeyVedu --pipeline-benchmark <audio files…>`
/// loads the speech model and Vedu Scribe, runs each clip through transcription and cleanup
/// the way a dictation would, prints timings and memory, and exits. Feeds the homepage numbers.
/// Make clips with `say -r 150 -o clip.wav --data-format=LEF32@16000 "…"`.
enum PipelineBenchmark {
    static let flag = "--pipeline-benchmark"

    /// What the homepage compares against: typical typing and speaking rates. The speed-up
    /// adds the measured processing time per word to a person speaking at `speakingWPM`.
    private static let typingWPM = 40.0
    private static let speakingWPM = 150.0

    static func run() async {
        let files = CommandLine.arguments
            .drop { $0 != flag }.dropFirst()
            .map { URL(filePath: $0) }
        guard !files.isEmpty else { return print("usage: \(flag) <audio files…>") }
        let baseline = footprint()

        let speech = SpeechModel()
        let cleaner = TextCleaner()
        let savedEngine = cleaner.engine
        defer { cleaner.engine = savedEngine }  // don't change the user's persisted choice
        cleaner.engine = .defaultEngine
        speech.prepare()
        let loadStarted = ContinuousClock.now
        while !speech.isReady || cleaner.availability != .available {
            if case .failed(let reason) = speech.state { return print("speech model failed: \(reason)") }
            if case .failed(let reason) = cleaner.modelState { return print("cleanup failed: \(reason)") }
            try? await Task.sleep(for: .milliseconds(200))
        }
        print("Models ready after \(seconds(ContinuousClock.now - loadStarted))s (\(cleaner.engine.title))")
        let loaded = footprint()

        var totalWords = 0.0, totalAudio = 0.0, totalProcessing = 0.0
        for file in files {
            guard let recording = load(file) else { print("skipped \(file.lastPathComponent)"); continue }
            cleaner.prepare()
            let started = ContinuousClock.now
            let transcript = (try? await speech.transcribe(recording)) ?? ""
            let transcribed = ContinuousClock.now
            let result = await cleaner.clean(transcript)
            let finished = ContinuousClock.now

            let words = Double(result.text.split(whereSeparator: \.isWhitespace).count)
            let processing = seconds(finished - started)
            totalWords += words
            totalAudio += recording.duration
            totalProcessing += processing
            print(String(format: "%@: %.0f words, %.2fs audio, transcribe %.3fs, clean %.3fs%@",
                         file.lastPathComponent, words, recording.duration,
                         seconds(transcribed - started), seconds(finished - transcribed),
                         result.fallbackReason.map { " · fallback: \($0)" } ?? ""))
            print("  OUT: \(result.text)")
        }

        let peak = peakFootprint()
        let spokenWPM = totalWords / (totalAudio / 60)
        let processingPerWord = totalProcessing / totalWords
        let effectiveWPM = 60 / (60 / speakingWPM + processingPerWord)
        print(String(format: """

            Clips: %d · words: %.0f · audio: %.1fs · processing: %.2fs (avg %.3fs per clip)
            Clip speaking rate: %.0f wpm · processing: %.1f ms per word
            Speaking at %.0f wpm plus processing: %.0f wpm · vs typing at %.0f wpm: %.2f×
            Memory (phys footprint): before models %.0f MB · models loaded %.0f MB · peak %.0f MB
            Models added: %.0f MB loaded, %.0f MB at peak
            """,
            files.count, totalWords, totalAudio, totalProcessing, totalProcessing / Double(files.count),
            spokenWPM, processingPerWord * 1000, speakingWPM, effectiveWPM, typingWPM, effectiveWPM / typingWPM,
            mb(baseline), mb(loaded), mb(peak), mb(loaded - baseline), mb(peak - baseline)))
    }

    /// Reads any audio file and converts it to the 16 kHz mono Float32 a dictation records.
    private static func load(_ url: URL) -> Recording? {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Recording.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * Recording.sampleRate
                                         / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard let channel = output.floatChannelData?[0] else { return nil }
        return Recording(samples: Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }

    /// The figure Activity Monitor shows as Memory, including Metal buffers on Apple silicon.
    private static func footprint() -> UInt64 { usage().ri_phys_footprint }
    private static func peakFootprint() -> UInt64 { usage().ri_lifetime_max_phys_footprint }

    private static func usage() -> rusage_info_v4 {
        var info = rusage_info_v4()
        withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                _ = proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return info
    }

    private static func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_000_000 }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
#endif
