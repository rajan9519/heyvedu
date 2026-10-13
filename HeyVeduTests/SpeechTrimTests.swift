import Testing
@testable import HeyVedu

struct SpeechTrimTests {
    private let chunk = VoiceActivity.chunkSize
    private let lead = Int(SpeechTrim.leadingPadding * Recording.sampleRate)
    private let trail = Int(SpeechTrim.trailingPadding * Recording.sampleRate)

    @Test func noSpeechKeepsEverything() {
        #expect(SpeechTrim.range(probabilities: [0.1, 0.2, 0.4], sampleCount: chunk * 3) == nil)
        #expect(SpeechTrim.range(probabilities: [], sampleCount: 100) == nil)
    }

    @Test func trimsSilenceAroundSpeechWithPadding() {
        let probabilities: [Float] = [0, 0, 0, 0.9, 0.8, 0, 0, 0]
        let range = SpeechTrim.range(probabilities: probabilities, sampleCount: chunk * 8)
        #expect(range == (3 * chunk - lead)..<(5 * chunk + trail))
    }

    @Test func paddingIsClampedToTheRecording() {
        let range = SpeechTrim.range(probabilities: [0.9, 0.1], sampleCount: chunk * 2 + 10)
        #expect(range?.lowerBound == 0)
        #expect(range?.upperBound == min(chunk * 2 + 10, chunk + trail))
    }

    @Test func speechInTheLastChunkKeepsTheUnscoredTail() {
        let sampleCount = chunk * 3 + 500
        let range = SpeechTrim.range(probabilities: [0, 0, 0.7], sampleCount: sampleCount)
        #expect(range?.upperBound == sampleCount)
    }

    @Test func trailingSilenceCountsQuietChunksAtTheEnd() {
        #expect(SpeechTrim.trailingSilence([]) == 0)
        #expect(SpeechTrim.trailingSilence([0.9, 0.1, 0.2]) == 2 * SpeechTrim.chunkDuration)
        // Between the thresholds is neither speech nor silence, so it ends the count.
        #expect(SpeechTrim.trailingSilence([0.1, 0.4, 0.1]) == SpeechTrim.chunkDuration)
        #expect(SpeechTrim.trailingSilence([0.2, 0.2]) == 2 * SpeechTrim.chunkDuration)
    }
}
