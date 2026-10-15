import AVFoundation
import CoreAudio
import os

/// Where TranslationSpeech plays the voice. The app's is SpeechPlayer. Tests pass a fake,
/// so they never touch an audio device.
protocol SpeechPlayback: AnyObject {
    /// Opens `device` for one spoken translation.
    func start(on device: AudioOutput) throws
    /// Queues a piece behind the ones queued before it, and returns at once.
    func play(_ audio: SpokenAudio)
    /// Returns once everything queued has played, or at once after `stop`.
    func finish() async
    /// Stops at once and lets go of the device.
    func stop()
}

nonisolated enum SpeechPlayerError: Error, Equatable {
    case deviceRefused(OSStatus)
    case engineFailed
}

/// Plays synthesized speech into one output device with AVAudioEngine: a player node into
/// the main mixer, which converts the voice model's 24 kHz mono to the device's format.
/// The engine only plays. It never touches its input node, so it never starts the
/// microphone or asks for it. Nothing it plays is kept after it played.
final class SpeechPlayer: SpeechPlayback {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    /// Pieces queued and not played yet.
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Counts the starts, so a late callback of a stopped engine changes nothing.
    private var generation = 0
    private let logger = Logger(subsystem: "io.github.db-ol.Orra", category: "speech")
    /// Qwen3-TTS speaks at 24 kHz.
    private static let voiceSampleRate = 24_000.0

    func start(on device: AudioOutput) throws {
        stop()
        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { throw SpeechPlayerError.engineFailed }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw SpeechPlayerError.deviceRefused(status) }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        // The voice model's own format, so the usual piece needs no new connection.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.voiceSampleRate, channels: 1, interleaved: false)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw SpeechPlayerError.engineFailed
        }
        player.play()
        self.engine = engine
        self.player = player
        self.format = format
        generation += 1
        logger.notice("Speaking into an output device with \(AudioOutput.outputChannelCount(device.id), privacy: .public) channels")
    }

    func play(_ audio: SpokenAudio) {
        guard let engine, let player, !audio.samples.isEmpty,
              let buffer = buffer(for: audio, engine: engine, player: player) else { return }
        pending += 1
        let generation = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.played(generation: generation)
                }
            }
        }
    }

    func finish() async {
        guard pending > 0 else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        pending = 0
        generation += 1
        resumeWaiters()
    }

    private func played(generation: Int) {
        guard generation == self.generation else { return }
        pending -= 1
        if pending == 0 {
            resumeWaiters()
        }
    }

    private func resumeWaiters() {
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }

    /// A mono Float32 buffer at the piece's rate. The player node is connected again for
    /// another rate, which Qwen3-TTS never uses.
    private func buffer(for audio: SpokenAudio, engine: AVAudioEngine, player: AVAudioPlayerNode) -> AVAudioPCMBuffer? {
        if format?.sampleRate != Double(audio.sampleRate) {
            guard let new = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(audio.sampleRate), channels: 1, interleaved: false) else { return nil }
            engine.connect(player, to: engine.mainMixerNode, format: new)
            format = new
            if !player.isPlaying {
                player.play()
            }
        }
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = buffer.frameCapacity
        audio.samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: source.count)
            }
        }
        return buffer
    }
}
