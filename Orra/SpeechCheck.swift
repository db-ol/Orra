import Foundation

/// Checks a sentence the voice model made before it plays, against the length its text
/// predicts. Voice models sometimes go wrong on a sentence: they stop early, make near
/// silence, or run on in a loop. A scratch benchmark on 2026-10-14 saw this for about 2%
/// of CosyVoice3's sentences, for example 7.1 s of audio for "好的，我们开始吧。". The
/// check reads only the audio and the text, so it holds for every voice model.
///
/// The numbers come from that benchmark (1,312 clips of seven engines, their lengths and
/// what Qwen3-ASR heard in them) and from a run on 2026-10-15 of both of Orra's voice
/// models on 232 clips each (four public voices, 20 meeting sentences and 6 short ones,
/// in English and Chinese), measured as here.
nonisolated enum SpeechCheck {
    nonisolated enum Verdict: String, Equatable, Sendable {
        case good
        /// Longer than the text could take, such as a loop or a long silence after it.
        case tooLong
        /// Hardly any sound at all.
        case silent
        /// Sound over a much shorter stretch than the text needs, such as a sentence cut
        /// off and followed by silence.
        case tooShort
    }

    /// Seconds a Chinese character takes, the median of the benchmark's good clips.
    static let secondsPerCharacter = 0.23
    /// Seconds an English word takes, the median of the benchmark's good clips.
    static let secondsPerWord = 0.34

    /// A piece may run twice its expected length plus 2 s. No good clip of the benchmark
    /// ran longer, the longest reached 0.95 of it, and no streamed clip passed 0.63 of it.
    static let longestFactor = 2.0
    static let extraSeconds = 2.0
    /// Less sound than this in a whole piece is silence, or less than `leastSpeechShare`
    /// of the expected length when that is shorter. A quiet cloned voice can say "好。" or
    /// "OK." with only one to four frames above `soundLevel`, while every silent clip of
    /// the probes had none.
    static let leastSpeechSeconds = 0.1
    static let leastSpeechShare = 0.05
    /// The stretch from the first to the last frame with sound must reach this share of
    /// the expected length, less `shortSlackSeconds`, which leaves short texts such as
    /// "Thank you." alone. Good clips of the bench sentences reached at least 0.49 of it.
    static let shortestFactor = 0.45
    static let shortSlackSeconds = 0.3

    /// The length of a frame the level is measured over.
    static let frameSeconds = 0.02
    /// A frame at least this loud has sound in it, about -46 dBFS. Some cloned voices are
    /// quiet: half the frames of good clips of one public voice were under -40 dBFS.
    static let soundLevel: Float = 0.005

    /// The seconds a voice model takes to say `text` at a usual pace: Chinese, Japanese
    /// and Korean characters one by one, other text by its words. Zero for text with
    /// neither, such as punctuation only.
    static func expectedSeconds(for text: String) -> Double {
        var characters = 0
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCharacterScript(scalar) {
                characters += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord {
                    words += 1
                }
                inWord = true
            } else if scalar == "'" || scalar == "’", inWord {
                // It's, don't: one word.
            } else {
                inWord = false
            }
        }
        return Double(characters) * secondsPerCharacter + Double(words) * secondsPerWord
    }

    /// The longest a piece of `text` may run. A voice that streams is cut there. A number
    /// counts as one word in the expected length, but it may be read digit by digit, such
    /// as a phone number, or take many words, such as "1234567". So here each digit after
    /// a number's first counts as a word too.
    static func longestSeconds(for text: String) -> Double {
        var digits = 0
        var inNumber = false
        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                if inNumber {
                    digits += 1
                }
                inNumber = true
            } else {
                inNumber = false
            }
        }
        return (expectedSeconds(for: text) + Double(digits) * secondsPerWord) * longestFactor + extraSeconds
    }

    /// How much of a piece has sound in it.
    struct Measurement: Equatable, Sendable {
        /// The whole piece.
        var seconds: Double
        /// The frames with sound, added up.
        var soundSeconds: Double
        /// From the start of the first frame with sound to the end of the last.
        var soundSpanSeconds: Double
    }

    static func measure(_ audio: SpokenAudio) -> Measurement {
        let rate = max(audio.sampleRate, 1)
        let frame = max(1, Int(Double(rate) * frameSeconds))
        var loudFrames = 0
        var first: Int?
        var last = 0
        audio.samples.withUnsafeBufferPointer { samples in
            var start = 0
            var index = 0
            while start < samples.count {
                let end = min(samples.count, start + frame)
                var energy: Float = 0
                for sample in samples[start..<end] {
                    energy += sample * sample
                }
                if (energy / Float(end - start)).squareRoot() >= soundLevel {
                    loudFrames += 1
                    first = first ?? index
                    last = index
                }
                start = end
                index += 1
            }
        }
        let frameLength = Double(frame) / Double(rate)
        return Measurement(
            seconds: Double(audio.samples.count) / Double(rate),
            soundSeconds: Double(loudFrames) * frameLength,
            soundSpanSeconds: first.map { Double(last - $0 + 1) * frameLength } ?? 0
        )
    }

    /// Whether `audio` is a plausible reading of `text`.
    static func verdict(for audio: SpokenAudio, text: String) -> Verdict {
        verdict(for: measure(audio), text: text)
    }

    static func verdict(for measurement: Measurement, text: String) -> Verdict {
        let expected = expectedSeconds(for: text)
        // Nothing to judge the length by.
        guard expected > 0 else { return .good }
        if measurement.seconds > longestSeconds(for: text) {
            return .tooLong
        }
        if measurement.soundSeconds < min(leastSpeechSeconds, expected * leastSpeechShare) {
            return .silent
        }
        if measurement.soundSpanSeconds < expected * shortestFactor - shortSlackSeconds {
            return .tooShort
        }
        return .good
    }

    private static func isCharacterScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF, // Hangul syllables
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0x20000...0x2FA1F: // CJK Extensions B and on
            true
        default:
            false
        }
    }
}
