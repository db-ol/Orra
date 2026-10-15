import Foundation
import Testing
@testable import Orra

/// The check of a piece the voice model made, on synthetic audio.
struct SpeechCheckTests {
    nonisolated static let rate = 24_000

    /// A 220 Hz tone at a level a voice model's speech has.
    nonisolated static func tone(seconds: Double, amplitude: Float = 0.2) -> SpokenAudio {
        let count = Int(seconds * Double(rate))
        let samples = (0..<count).map { amplitude * Float(sin(2 * Double.pi * 220 * Double($0) / Double(rate))) }
        return SpokenAudio(samples: samples, sampleRate: rate)
    }

    nonisolated static func silence(seconds: Double, level: Float = 0) -> SpokenAudio {
        SpokenAudio(samples: [Float](repeating: level, count: Int(seconds * Double(rate))), sampleRate: rate)
    }

    nonisolated static func joined(_ parts: SpokenAudio...) -> SpokenAudio {
        SpokenAudio(samples: parts.flatMap(\.samples), sampleRate: rate)
    }

    static let chinese = "感谢大家参加，我们开始每周的进度同步吧。"
    static let english = "Thanks everyone for joining, let's get started with the weekly update."

    @Test func theExpectedLengthCountsCharactersAndWords() {
        // 18 characters, 11 words.
        #expect(abs(SpeechCheck.expectedSeconds(for: Self.chinese) - 18 * SpeechCheck.secondsPerCharacter) < 1e-9)
        #expect(abs(SpeechCheck.expectedSeconds(for: Self.english) - 11 * SpeechCheck.secondsPerWord) < 1e-9)
        // Both in one text: 4 characters and 1 word.
        #expect(abs(SpeechCheck.expectedSeconds(for: "我们用 Slack 聊。") - (4 * SpeechCheck.secondsPerCharacter + SpeechCheck.secondsPerWord)) < 1e-9)
        #expect(SpeechCheck.expectedSeconds(for: "……！") == 0)
        #expect(SpeechCheck.expectedSeconds(for: "") == 0)
    }

    /// Clips about as long as the text, from slow to fast, pass, also with pauses at
    /// both ends.
    @Test func aPlausibleReadingPasses() {
        for text in [Self.chinese, Self.english, "好的，我们开始吧。", "Thank you."] {
            let expected = SpeechCheck.expectedSeconds(for: text)
            for pace in [0.65, 1.0, 1.6] {
                let audio = Self.joined(Self.silence(seconds: 0.2), Self.tone(seconds: expected * pace), Self.silence(seconds: 0.3))
                #expect(SpeechCheck.verdict(for: audio, text: text) == .good, "\(text) at \(pace)")
            }
        }
    }

    /// A loop runs past the longest the text may take, such as CosyVoice3's 7.1 s for
    /// "好的，我们开始吧。".
    @Test func aRunawayIsTooLong() {
        #expect(SpeechCheck.verdict(for: Self.tone(seconds: 7.1), text: "好的，我们开始吧。") == .tooLong)
        #expect(SpeechCheck.verdict(for: Self.tone(seconds: 40), text: "你能共享一下屏幕吗？我们一起看看这个仪表盘。") == .tooLong)
        let longest = SpeechCheck.longestSeconds(for: Self.english)
        #expect(SpeechCheck.verdict(for: Self.tone(seconds: longest + 0.1), text: Self.english) == .tooLong)
        #expect(SpeechCheck.verdict(for: Self.tone(seconds: longest - 0.1), text: Self.english) == .good)
    }

    /// A number may be read digit by digit, or as many words, so its digits give it room.
    /// "Call 5551234567." takes about 4 s read out, past twice two words plus 2 s.
    @Test func numbersMayRunLonger() {
        let phone = "Call 5551234567."
        #expect(abs(SpeechCheck.longestSeconds(for: phone) - ((2 + 9) * SpeechCheck.secondsPerWord * SpeechCheck.longestFactor + SpeechCheck.extraSeconds)) < 1e-9)
        #expect(SpeechCheck.verdict(for: Self.tone(seconds: 4.2), text: phone) == .good)
        #expect(SpeechCheck.verdict(for: Self.tone(seconds: 3.6), text: "电话是13812345678。") == .good)
        // The expected length, and with it the cut check, still counts a number as a word.
        #expect(SpeechCheck.expectedSeconds(for: phone) == 2 * SpeechCheck.secondsPerWord)
        #expect(SpeechCheck.longestSeconds(for: Self.english) == SpeechCheck.expectedSeconds(for: Self.english) * SpeechCheck.longestFactor + SpeechCheck.extraSeconds)
    }

    /// A sentence that stops after its first words, with or without silence after it, as
    /// CosyVoice3's "我们还在等。" for "我们还在等法务部门审核这份协议。" in 8 s of audio.
    @Test func aCutOffSentenceIsTooShort() {
        let text = "我们还在等法务部门审核这份协议。"
        let expected = SpeechCheck.expectedSeconds(for: text)
        let cut = (expected * SpeechCheck.shortestFactor - SpeechCheck.shortSlackSeconds) * 0.8
        #expect(SpeechCheck.verdict(for: Self.tone(seconds: cut), text: text) == .tooShort)
        #expect(SpeechCheck.verdict(for: Self.joined(Self.tone(seconds: cut), Self.silence(seconds: 4)), text: text) == .tooShort)
        // A pause in the middle is not a cut.
        let paused = Self.joined(Self.tone(seconds: expected * 0.3), Self.silence(seconds: 0.8), Self.tone(seconds: expected * 0.3))
        #expect(SpeechCheck.verdict(for: paused, text: text) == .good)
    }

    /// Near silence, also a long stretch of it, and nothing at all.
    @Test func nearSilenceIsSilent() {
        #expect(SpeechCheck.verdict(for: Self.silence(seconds: 3, level: 0.002), text: Self.english) == .silent)
        #expect(SpeechCheck.verdict(for: Self.tone(seconds: 3, amplitude: 0.005), text: Self.english) == .silent)
        #expect(SpeechCheck.verdict(for: Self.silence(seconds: 0), text: Self.english) == .silent)
        // A click in a clip of the right length.
        let audio = Self.joined(Self.tone(seconds: 0.06), Self.silence(seconds: 3.5))
        #expect(SpeechCheck.verdict(for: audio, text: Self.english) == .silent)
    }

    /// Some cloned voices are quiet. Speech at about -37 dBFS still counts.
    @Test func aQuietVoicePasses() {
        let expected = SpeechCheck.expectedSeconds(for: Self.english)
        #expect(SpeechCheck.verdict(for: Self.tone(seconds: expected, amplitude: 0.02), text: Self.english) == .good)
    }

    /// A text with nothing to say is not judged.
    @Test func punctuationOnlyIsNotJudged() {
        #expect(SpeechCheck.verdict(for: Self.silence(seconds: 1), text: "……") == .good)
    }

    @Test func soundIsMeasuredInFrames() {
        let measured = SpeechCheck.measure(Self.joined(Self.silence(seconds: 0.5), Self.tone(seconds: 1), Self.silence(seconds: 0.5), Self.tone(seconds: 0.5), Self.silence(seconds: 1)))
        #expect(measured.seconds == 3.5)
        #expect(abs(measured.soundSeconds - 1.5) < 0.041)
        #expect(abs(measured.soundSpanSeconds - 2) < 0.041)
        // Another sample rate.
        let slow = SpokenAudio(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)
        let flat = SpeechCheck.measure(slow)
        #expect(flat.seconds == 1)
        #expect(abs(flat.soundSeconds - 1) < 1e-9)
        #expect(abs(flat.soundSpanSeconds - 1) < 1e-9)
        #expect(SpeechCheck.measure(Self.silence(seconds: 1)) == SpeechCheck.Measurement(seconds: 1, soundSeconds: 0, soundSpanSeconds: 0))
    }
}
