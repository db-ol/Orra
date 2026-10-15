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
    /// Forgets anything the model derived from a voice sample.
    func forgetVoice() async
}
