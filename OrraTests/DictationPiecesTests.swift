import AVFoundation
import Foundation
import Testing
@testable import Orra

/// The pieces the text shown while the user speaks cuts a recording into, and its
/// conversion to 16 kHz while the recording goes on.
struct DictationPiecesTests {
    private static let rate = RecordingLimits.sampleRate

    /// Feeds `audio` in chunks of 100 ms, as the reads of a hold come, and returns the pieces
    /// and what the segmenter knows at the end.
    private func pieces(_ audio: [Float], chunk: Int = 1_600) -> (pieces: [DictationPieces.Piece], state: DictationPieces) {
        var cutter = DictationPieces()
        var found: [DictationPieces.Piece] = []
        var index = 0
        while index < audio.count {
            let end = min(audio.count, index + chunk)
            found += cutter.append(Array(audio[index..<end]))
            index = end
        }
        return (found, cutter)
    }

    @Test func thePiecesCoverTheStreamWithoutAGap() throws {
        let audio = CaptionAudio.silence(0.5) + CaptionAudio.tone(1.5) + CaptionAudio.silence(1)
            + CaptionAudio.tone(2) + CaptionAudio.silence(1) + CaptionAudio.tone(1) + CaptionAudio.silence(1)
        let (found, state) = pieces(audio)
        try #require(found.count == 3)
        #expect(found[0].range.lowerBound == 0)
        for (before, after) in zip(found, found.dropFirst()) {
            #expect(before.range.upperBound == after.range.lowerBound)
        }
        #expect(state.lastCut == found[2].range.upperBound)
        // Each piece ends where its sentence does, with the tail of the pause.
        for piece in found {
            #expect(piece.range.upperBound == piece.sentence.upperBound)
            #expect(piece.range.lowerBound <= piece.sentence.lowerBound)
        }
        // The second sentence starts at 3 s, less the 0.2 s preroll.
        #expect(abs(Double(found[1].sentence.lowerBound) / Double(Self.rate) - 2.8) < 0.03)
    }

    /// A word with too little speech gives no piece of its own. It stays in the piece that
    /// follows, so nothing of the recording is lost.
    @Test func aWordWithTooLittleSpeechGoesWithTheNextPiece() throws {
        let audio = CaptionAudio.silence(0.5) + CaptionAudio.tone(0.2) + CaptionAudio.silence(1)
            + CaptionAudio.tone(1.5) + CaptionAudio.silence(1)
        let (found, _) = pieces(audio)
        try #require(found.count == 1)
        #expect(found[0].range.lowerBound == 0)
        // The short tone at 0.5 s lies before the sentence, inside the piece.
        #expect(found[0].sentence.lowerBound > Int(0.7 * Double(Self.rate)))
    }

    @Test func aLongStretchWithoutAPauseIsCutAtTheLimit() throws {
        let (found, state) = pieces(CaptionAudio.tone(14))
        try #require(found.count == 1)
        #expect(found[0].range.lowerBound == 0)
        #expect(found[0].range.count <= 12 * Self.rate)
        #expect(found[0].range.count >= 9 * Self.rate)
        // The rest goes on as the sentence being heard.
        let open = try #require(state.openSentence)
        #expect(open.lowerBound == found[0].range.upperBound)
        #expect(state.isInSpeech)
    }

    @Test func theSentenceBeingHeardFollowsTheSegmenter() throws {
        let short = pieces(CaptionAudio.silence(0.5) + CaptionAudio.tone(0.3)).state
        // Less speech than a sentence needs.
        #expect(short.openSentence == nil)
        #expect(short.isInSpeech)
        let long = pieces(CaptionAudio.silence(0.5) + CaptionAudio.tone(1.2)).state
        let open = try #require(long.openSentence)
        #expect(abs(Double(open.lowerBound) / Double(Self.rate) - 0.3) < 0.03)
        #expect(open.upperBound <= long.count)
        #expect(long.openSeconds > 1.2)
        #expect(long.openSilenceSeconds == 0)
    }

    /// A pass for the text on screen reads a sentence with at most a second before it,
    /// never from before the cut ahead of it, and at most 12.2 s.
    @Test func theShownAudioIsTheSentenceWithALeadIn() {
        let cutter = DictationPieces()
        let second = Self.rate
        // After a long pause, a second before the sentence.
        #expect(cutter.shownRange(for: (30 * second)..<(33 * second), after: 10 * second, leadIn: 1) == (29 * second)..<(33 * second))
        // Never from before the cut.
        #expect(cutter.shownRange(for: (30 * second)..<(33 * second), after: 29 * second + 8_000, leadIn: 1) == (29 * second + 8_000)..<(33 * second))
        // A long sentence is read from 12.2 s before its end.
        #expect(cutter.shownRange(for: (30 * second)..<(42 * second), after: 0, leadIn: 1) == (42 * second - Int(12.2 * Double(second)))..<(42 * second))
    }

    /// Converted in chunks of 100 ms, the recording is what one conversion of the whole
    /// gives, except at its very start and the end the converter holds back, so a cut lies
    /// at the same place in both.
    @Test(arguments: [48_000.0, 44_100.0])
    func theConversionWhileRecordingMatchesTheOneAfter(_ rate: Double) throws {
        let seconds = 3.0
        let count = Int(rate * seconds)
        let source = (0..<count).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
        let whole = AudioResampler.monoAt16kHz(AudioRecording(samples: source, sampleRate: rate))
        let resampler = try #require(LiveResampler(sampleRate: rate))
        var live: [Float] = []
        let chunk = Int(rate / 10)
        var index = 0
        while index < count {
            let end = min(count, index + chunk)
            live += resampler.convert(Array(source[index..<end]))
            index = end
        }
        // The converter holds back the end until more comes, less than one read of 100 ms.
        // It held back 754 samples at 48 kHz on macOS 27.2.
        #expect(live.count <= whole.count)
        #expect(whole.count - live.count < 1_600)
        // Inside, every sample is close, so the two are aligned.
        var largest: Float = 0
        for index in 160..<(live.count - 160) {
            largest = max(largest, abs(live[index] - whole[index]))
        }
        #expect(largest < 0.01)
    }

    @Test func sixteenKilohertzGoesThroughAsItIs() throws {
        let resampler = try #require(LiveResampler(sampleRate: 16_000))
        let samples = CaptionAudio.tone(0.1)
        #expect(resampler.convert(samples) == samples)
        #expect(LiveResampler(sampleRate: 0) == nil)
    }
}
