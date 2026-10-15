import Foundation
import Testing
@testable import Orra

/// Made up audio for the segmenter: tones stand in for speech, zeros for pauses.
enum CaptionAudio {
    static let rate = Double(RecordingLimits.sampleRate)

    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    /// A 220 Hz tone. An amplitude of 0.1 has an RMS of about 0.07, like speech in a call.
    static func tone(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(2 * .pi * 220 * Float($0) / Float(rate)) }
    }
}

struct CaptionSegmenterTests {
    private func segments(_ audio: [Float], settings: CaptionSegmenter.Settings = .init(), chunk: Int = 1_600) -> [CaptionSegment] {
        var segmenter = CaptionSegmenter(settings: settings)
        var found: [CaptionSegment] = []
        var index = 0
        while index < audio.count {
            let end = min(audio.count, index + chunk)
            found += segmenter.append(Array(audio[index..<end]))
            index = end
        }
        if let last = segmenter.finish() {
            found.append(last)
        }
        return found
    }

    @Test func oneSentenceComesWithItsPrerollAndTail() throws {
        let found = segments(CaptionAudio.silence(1) + CaptionAudio.tone(2) + CaptionAudio.silence(1))
        try #require(found.count == 1)
        // 0.2 s of preroll before the start at 1 s, and 0.15 s of the pause after 3 s.
        #expect(abs(found[0].start - 0.8) < 0.03)
        #expect(abs(found[0].end - 3.15) < 0.03)
        #expect(found[0].samples.count == Int((found[0].end - found[0].start) * CaptionAudio.rate))
    }

    @Test func aShortPauseKeepsTheSentenceAndALongOneEndsIt() {
        let short = CaptionAudio.tone(1) + CaptionAudio.silence(0.4) + CaptionAudio.tone(1) + CaptionAudio.silence(1)
        #expect(segments(short).count == 1)
        let long = CaptionAudio.tone(1) + CaptionAudio.silence(0.8) + CaptionAudio.tone(1) + CaptionAudio.silence(1)
        let found = segments(long)
        #expect(found.count == 2)
        #expect(found.map(\.start) == found.map(\.start).sorted())
    }

    @Test func aClickIsNoSentence() {
        let audio = CaptionAudio.silence(0.5) + CaptionAudio.tone(0.2) + CaptionAudio.silence(1) + CaptionAudio.tone(0.04) + CaptionAudio.silence(1)
        #expect(segments(audio).isEmpty)
    }

    @Test func aSoftSoundKeepsSpeechGoingButDoesNotStartIt() {
        // An RMS of about 0.0025, between the continue level and the start level.
        let soft = CaptionAudio.tone(0.8, amplitude: 0.0036)
        #expect(segments(CaptionAudio.silence(0.5) + soft + CaptionAudio.silence(1)).isEmpty)
        let found = segments(CaptionAudio.tone(1) + soft + CaptionAudio.tone(1) + CaptionAudio.silence(1))
        #expect(found.count == 1)
        #expect(found.first.map { $0.duration > 2.7 } == true)
    }

    @Test func aLongStretchIsCutAtItsQuietestPoint() throws {
        // 1.5 s of tone, then a softer dip of 0.1 s, again and again for 30 s. The dip
        // from 11.1 s to 11.2 s is quieter than the others.
        var audio: [Float] = []
        while Double(audio.count) / CaptionAudio.rate < 30 {
            let atQuietDip = abs(Double(audio.count) / CaptionAudio.rate - 9.6) < 0.01
            audio += CaptionAudio.tone(1.5) + CaptionAudio.tone(0.1, amplitude: atQuietDip ? 0.001 : 0.02)
        }
        let found = segments(audio + CaptionAudio.silence(1))
        try #require(found.count >= 3)
        for segment in found {
            #expect(segment.duration <= 12.01)
        }
        // The cut came at the quietest dip, within the last 3 s before 12 s.
        #expect(found[0].end > 11.1 && found[0].end <= 11.21)
        // Nothing is lost or doubled at the cut.
        #expect(abs(found[1].start - found[0].end) < 0.001)
    }

    @Test func theChunkSizeDoesNotMatter() {
        let audio = CaptionAudio.silence(0.3) + CaptionAudio.tone(1.2) + CaptionAudio.silence(0.9) + CaptionAudio.tone(0.7) + CaptionAudio.silence(0.2)
        let whole = segments(audio, chunk: audio.count)
        #expect(whole.count == 2)
        for chunk in [1, 37, 160, 1_000, 4_801] {
            #expect(segments(audio, chunk: chunk) == whole)
        }
    }

    @Test func theEndOfTheStreamEndsTheSentence() throws {
        var segmenter = CaptionSegmenter()
        let heard = segmenter.append(CaptionAudio.tone(1))
        #expect(heard.isEmpty)
        #expect(segmenter.isInSpeech)
        let finished = segmenter.finish()
        let last = try #require(finished)
        #expect(abs(last.duration - 1) < 0.03)
        #expect(!segmenter.isInSpeech)
        let again = segmenter.finish()
        #expect(again == nil)
    }

    @Test func steadyNoiseRaisesTheThresholds() {
        // Soft noise between sentences lifts the floor, so a sound just above the start
        // level but not above the noise by enough does not start a sentence.
        var segmenter = CaptionSegmenter()
        _ = segmenter.append(CaptionAudio.tone(5, amplitude: 0.0036))
        #expect(!segmenter.isInSpeech)
        #expect(segmenter.noiseFloor > 0.002)
        let found = segmenter.append(CaptionAudio.tone(0.5, amplitude: 0.01) + CaptionAudio.silence(1))
        #expect(found.isEmpty)
    }
}
