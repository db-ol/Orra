import Accelerate
import AVFoundation
import Foundation

/// A stretch of synthesized speech, mono.
nonisolated struct SpokenAudio: Sendable, Equatable {
    var samples: [Float]
    var sampleRate: Int
}

/// A short recording of a voice for the voice model to imitate, with what is said in it.
/// Held in memory only, never written to disk or the log, and gone when Orra quits or the
/// user removes it.
nonisolated struct VoiceSample: Sendable, Equatable {
    /// Mono.
    let samples: [Float]
    let sampleRate: Int
    /// What is said in the recording, written down by Orra's speech model when the user
    /// picks the sample. Qwen3-TTS reads it along with the audio to imitate the voice.
    /// Empty until then.
    var transcript = ""

    /// The longest part of a file Orra keeps. Qwen3-TTS reads the whole sample again with
    /// every sentence it speaks, so a longer clip makes each sentence slower. In a scratch
    /// run on 2026-10-15 a sentence took a median 1.05 s with a 10 s sample and 1.52 s
    /// with a 21 s one of the same speaker. The benchmark's samples were about 10 s.
    static let maximumSeconds = 12.0
    /// A shorter clip gives the speaker encoder too little to go on.
    static let minimumSeconds = 2.0

    var seconds: Double {
        Double(samples.count) / Double(max(sampleRate, 1))
    }

    nonisolated enum ReadError: Error, Equatable {
        case unreadable
        case tooShort
    }

    /// Reads the first `maximumSeconds` of an audio file, its first channel as for a microphone. Off the main
    /// actor, since decoding takes a moment.
    @concurrent
    static func read(from url: URL) async throws -> VoiceSample {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ReadError.unreadable
        }
        let format = file.processingFormat
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(min(Double(file.length), rate * maximumSeconds))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw ReadError.unreadable
        }
        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            throw ReadError.unreadable
        }
        let sample = VoiceSample(samples: MicrophoneChannel.samples(from: buffer), sampleRate: Int(rate))
        guard sample.seconds >= minimumSeconds else { throw ReadError.tooShort }
        return sample
    }
}

/// Keeps a voice sample within Qwen3-TTS's limit when it comes from the microphone. In an
/// extension, so VoiceSample keeps its memberwise initializer.
nonisolated extension VoiceSample {
    /// A recording of the microphone, made in Settings. A recording longer than
    /// `maximumSeconds` is cut at the quietest moment of its last `cutWindow` seconds
    /// before that limit, so the cut seldom falls in the middle of a word. The speech model
    /// writes down what is said in the part that is kept.
    init(recorded samples: [Float], sampleRate: Int) {
        self.samples = Self.keptPart(of: samples, sampleRate: sampleRate)
        self.sampleRate = sampleRate
    }

    /// How far before the limit a long recording may be cut.
    static let cutWindow = 2.0

    static func keptPart(of samples: [Float], sampleRate: Int) -> [Float] {
        let limit = Int(maximumSeconds * Double(sampleRate))
        guard sampleRate > 0, samples.count > limit else { return samples }
        // Steps of 20 ms, each judged by its energy.
        let step = max(sampleRate / 50, 1)
        let earliest = max(limit - Int(cutWindow * Double(sampleRate)), 0)
        var cut = limit
        var quietest = Float.infinity
        var start = earliest
        while start + step <= limit {
            var energy: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                vDSP_svesq(buffer.baseAddress! + start, 1, &energy, vDSP_Length(step))
            }
            if energy < quietest {
                quietest = energy
                cut = start + step / 2
            }
            start += step
        }
        return Array(samples.prefix(cut))
    }
}

/// A voice model that turns text into speech. The app's is Qwen3-TTS from speech-swift,
/// see Qwen3VoiceEngine, built only when that product is linked. Tests pass a fake.
protocol SpeechSynthesizer: Sendable {
    /// Loads the model from the folders the voice model installers filled.
    func load(model: URL, codec: URL) async throws
    func unload() async
    /// Speaks `text` in `language`, in the voice of `voice` when there is one, as audio in
    /// order. The stream ends after the last piece, and stops early when the task that
    /// reads it is cancelled.
    func speak(_ text: String, in language: TranslationTarget, voice: VoiceSample?) -> AsyncThrowingStream<SpokenAudio, any Error>
    /// Whether `speak` streams a piece as it is made, in several parts, rather than whole
    /// at its end. TranslationSpeech checks a whole piece before it plays, and only caps
    /// the length of a streamed one, see SpeechCheck.
    func streams(voice: VoiceSample?) -> Bool
    /// Forgets anything the model derived from a voice sample.
    func forgetVoice() async
}
