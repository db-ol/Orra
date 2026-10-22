import AVFoundation
import CoreAudio
import os

extension Logger {
    /// Playing the spoken translation. Devices and states only, never text or audio.
    nonisolated static let speech = Logger(subsystem: ProblemReport.subsystem, category: "speech")
}

/// Where TranslationSpeech plays the voice. The app's is SpeechPlayer. Tests pass a fake,
/// so they never touch an audio device.
protocol SpeechPlayback: AnyObject {
    /// Opens `device` for one spoken translation. A stop while this waits for the device
    /// wins: the device is let go, and nothing plays until the next start.
    func start(on device: AudioOutput) async throws
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

/// The audio device side of SpeechPlayer. SpeechPlayer makes every call to it on its own
/// serial queue, never on the main actor, since opening, starting and stopping a device
/// waits on the hardware. The app's is SpeechOutputEngine. Tests pass a fake, so they never
/// touch an audio device.
nonisolated protocol SpeechOutput: AnyObject, Sendable {
    /// Opens `device` and starts playing into it. `changed` runs, on any thread, when the
    /// engine's configuration changes, such as when the device goes away.
    func start(on device: AudioOutput, changed: @escaping @Sendable () -> Void) throws
    /// Queues a piece. `played` runs, on any thread, once it played. False when nothing
    /// was queued, and `played` then never runs.
    func schedule(_ audio: SpokenAudio, played: @escaping @Sendable () -> Void) -> Bool
    /// Whether the engine still runs.
    var isRunning: Bool { get }
    /// Stops and lets go of the device. Does nothing when nothing plays.
    func stop()
}

/// Plays synthesized speech into one output device. The device work runs in order on a
/// serial queue, as AudioRecorder does for the microphone, so a slow device never holds up
/// the main thread, where the keyboard tap runs. The counts of what is queued stay on the
/// main actor. Nothing it plays is kept after it played.
final class SpeechPlayer: SpeechPlayback {
    /// Runs every call to `output` in the order SpeechPlayer made it, so a stop always
    /// reaches the device after the start before it.
    private let queue = DispatchQueue(label: "io.github.db-ol.Orra.speech-output", qos: .userInitiated)
    private let output: any SpeechOutput
    /// A start went to the queue and no stop since, so a stop must reach the device.
    private var holdsDevice = false
    /// The start of this generation opened the device, so pieces may be queued.
    private var isOpen = false
    /// Pieces queued and not played yet.
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Counts the starts and stops, so a late callback of a stopped start changes nothing.
    private var generation = 0
    /// The seconds of audio queued since the start, which bounds the wait in `finish`.
    private var queuedSeconds = 0.0
    private let logger = Logger.speech

    /// - Parameter output: The audio device side. Tests pass a fake.
    init(output: any SpeechOutput = SpeechOutputEngine()) {
        self.output = output
    }

    func start(on device: AudioOutput) async throws {
        stop()
        let generation = generation
        let output = output
        let queue = queue
        holdsDevice = true
        // AVAudioEngine stops itself when its device goes away or changes its format. The
        // output keeps this callback until it stops, so the callback holds the output only
        // weakly. A player let go of without a stop then lets go of its device too.
        let changed: @Sendable () -> Void = { [weak self, weak output] in
            guard let output else { return }
            queue.async {
                guard !output.isRunning else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.engineStopped(generation: generation)
                    }
                }
            }
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    do {
                        try output.start(on: device, changed: changed)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            // After a stop the failure no longer matters.
            guard generation == self.generation else { return }
            holdsDevice = false
            throw error
        }
        // A stop while the device opened went to the queue behind the start, and lets the
        // device go there.
        guard generation == self.generation else { return }
        isOpen = true
    }

    func play(_ audio: SpokenAudio) {
        guard isOpen, !audio.samples.isEmpty else { return }
        pending += 1
        queuedSeconds += Double(audio.samples.count) / Double(max(audio.sampleRate, 1))
        let generation = generation
        let output = output
        let played: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.played(generation: generation)
                }
            }
        }
        queue.async {
            // A piece that could not be queued counts as played, so `finish` does not wait.
            if !output.schedule(audio, played: played) {
                played()
            }
        }
    }

    func finish() async {
        guard pending > 0 else { return }
        // A device that stops taking audio would leave the queue waiting for good. Nothing
        // queued takes longer to play than all of it from the start, plus a margin.
        let generation = generation
        let limit = Duration.seconds(queuedSeconds + 3)
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, generation == self.generation, self.pending > 0 else { return }
            self.logger.error("The output device did not finish playing in time")
            self.stop()
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        watchdog.cancel()
    }

    /// Returns at once. The device stops on the queue, after the start before it.
    func stop() {
        generation += 1
        isOpen = false
        pending = 0
        queuedSeconds = 0
        resumeWaiters()
        guard holdsDevice else { return }
        holdsDevice = false
        let output = output
        queue.async {
            output.stop()
        }
    }

    /// The engine stopped itself, and the queued pieces then never report that they
    /// played. Stops for good, so the spoken translation ends there and never moves to
    /// another device by surprise.
    private func engineStopped(generation: Int) {
        guard generation == self.generation else { return }
        logger.notice("The output device changed while speaking, so speaking stopped")
        stop()
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
}

/// SpeechPlayer's audio device side with AVAudioEngine: a player node into the main mixer,
/// which converts the voice model's 24 kHz mono to the device's format. The engine only
/// plays. It never touches its input node, so it never starts the microphone or asks for
/// it. Used only on SpeechPlayer's queue, which keeps its state to one thread at a time.
nonisolated final class SpeechOutputEngine: SpeechOutput, @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    /// Watches for the device going away, see SpeechPlayer.start.
    private var configurationObserver: (any NSObjectProtocol)?
    /// Qwen3-TTS speaks at 24 kHz.
    private static let voiceSampleRate = 24_000.0

    func start(on device: AudioOutput, changed: @escaping @Sendable () -> Void) throws {
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
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            changed()
        }
        Logger.speech.notice("Speaking into an output device with \(AudioOutput.outputChannelCount(device.id), privacy: .public) channels")
    }

    func schedule(_ audio: SpokenAudio, played: @escaping @Sendable () -> Void) -> Bool {
        guard let engine, let player, !audio.samples.isEmpty,
              let buffer = buffer(for: audio, engine: engine, player: player) else { return false }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            played()
        }
        return true
    }

    var isRunning: Bool {
        engine?.isRunning == true
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        format = nil
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
