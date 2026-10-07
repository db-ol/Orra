import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import os
import Synchronization

/// Microphone permission, as Orra needs it.
nonisolated enum MicrophoneAccess: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    /// The build has no microphone usage description. macOS ends any app that asks for
    /// the microphone without one, so Orra must not ask.
    case notConfigured

    /// The current state. Reading it never shows a prompt.
    static func current() -> MicrophoneAccess {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            return .notConfigured
        }
        return switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Shows the system prompt if the user has not decided yet, then returns the state.
    static func request() async -> MicrophoneAccess {
        guard current() == .notDetermined else { return current() }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return current()
    }
}

/// Length rules for one recording.
nonisolated enum RecordingLimits {
    /// Orra transcribes 16 kHz mono audio.
    static let sampleRate = 16_000
    /// Holds of the talk key shorter than this are taps, not speech, and are discarded.
    /// Measured from press to release, not from the audio that arrived.
    static let minimumHold: Duration = .milliseconds(300)
    /// A recording stops and is processed after this long.
    static let maximumSeconds = 60.0
    static let maximumDuration: Duration = .seconds(60)
    /// After the talk key is released, recording goes on this long, because the last
    /// buffer and the input latency still hold the end of the speech.
    static let releaseTail: Duration = .milliseconds(150)
}

/// One recording as it came from the microphone: mono, at the device's sample rate.
nonisolated struct AudioRecording: Equatable, Sendable {
    var samples: [Float]
    var sampleRate: Double
    /// True when the input device changed or went away during the hold, so the recording
    /// ends early.
    var wasCut = false
    /// The device that recorded, as read at the start of the hold. Nil when it could not
    /// be read.
    var input: AudioInput?

    var duration: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

/// Takes the first channel of a Float32 buffer.
///
/// Averaging all channels would make a single microphone on a multichannel interface
/// quieter, and would mix in loopback channels that carry whatever the Mac is playing.
/// Channel 0 is what most apps record.
nonisolated enum MicrophoneChannel {
    static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return [] }
        if buffer.format.isInterleaved {
            // An interleaved buffer keeps every channel behind the first pointer.
            let interleaved = data[0]
            return (0..<frames).map { interleaved[$0 * channels] }
        }
        return Array(UnsafeBufferPointer(start: data[0], count: frames))
    }
}

/// Resamples a whole recording to 16 kHz in one pass.
///
/// The converter is told when the input ends, so it also returns the last few
/// milliseconds it would otherwise hold back. Pure work on values, so it can run on
/// any thread.
nonisolated enum AudioResampler {
    static func monoAt16kHz(_ recording: AudioRecording) -> [Float] {
        let target = Double(RecordingLimits.sampleRate)
        if recording.sampleRate == target {
            return recording.samples
        }
        guard !recording.samples.isEmpty, recording.sampleRate > 0,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: recording.sampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(recording.samples.count)),
              let inputChannel = input.floatChannelData?[0] else {
            return []
        }
        input.frameLength = input.frameCapacity
        recording.samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                inputChannel.update(from: base, count: source.count)
            }
        }
        let expected = (Double(recording.samples.count) * target / recording.sampleRate).rounded(.up)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(expected) + 1_024) else {
            return []
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Collects mono samples from the audio thread, up to a limit set per recording.
nonisolated final class SampleStore: Sendable {
    private struct State {
        var samples: [Float] = []
        var limit = 0
    }

    private let state = Mutex(State())

    /// Empties the store and sets the most samples the next recording may hold.
    func begin(limit: Int) {
        state.withLock { current in
            current = State(samples: [], limit: limit)
        }
    }

    func append(_ newSamples: [Float]) {
        state.withLock { current in
            let room = current.limit - current.samples.count
            guard room > 0 else { return }
            current.samples.append(contentsOf: newSamples.prefix(room))
        }
    }

    /// Returns everything collected so far and empties the store.
    func take() -> [Float] {
        state.withLock { current in
            let taken = current.samples
            current.samples = []
            return taken
        }
    }
}

/// How loud the latest audio from the microphone was, for the recording indicator. The
/// audio thread stores the peak of each buffer in one atomic, so it neither locks nor
/// allocates, and the main actor reads it.
nonisolated final class LevelMeter: Sendable {
    private let peakBits = Atomic<UInt32>(0)

    /// The peak of the latest buffer, from 0 to 1.
    var peak: Float {
        let value = Float(bitPattern: peakBits.load(ordering: .relaxed))
        return value.isFinite ? min(max(value, 0), 1) : 0
    }

    /// Stores the largest magnitude among the samples. Safe on Core Audio's real time
    /// thread.
    func record(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        peakBits.store(peak.bitPattern, ordering: .relaxed)
    }

    func reset() {
        peakBits.store(0, ordering: .relaxed)
    }
}

nonisolated enum AudioRecorderError: Error, Equatable {
    /// The default input reports a format that cannot be recorded.
    case unsupportedInput
    /// The input unit for the chosen microphone failed at this step, with Core Audio's
    /// status.
    case inputUnitFailed(step: String, status: OSStatus)
}

/// Records the microphone into memory while the talk key is held. Nothing is written to disk.
///
/// An actor, so the audio hardware starts and stops away from the main thread. The
/// keyboard tap runs there, every key press on the Mac waits for it, and starting a
/// Bluetooth microphone can take seconds.
///
/// Two ways to record:
/// - A microphone chosen in Orra's menu records through an InputUnit made for the hold and
///   bound to that device. InputUnit says why.
/// - The system default input records through AVAudioEngine, as it did before the choice
///   existed. It also records while the chosen microphone is not connected.
///
/// AVAudioEngine calls the tap on an audio thread. The tap block is built in a nonisolated
/// function, so it is not tied to any actor. It only copies the first channel into the
/// lock protected store. Resampling happens once, after the recording ends, in
/// AudioResampler.
actor AudioRecorder {
    private enum Source {
        /// AVAudioEngine records the default input, read at the start of the hold.
        case engine(AudioInput?)
        case unit(InputUnit)
    }

    private var engine: AVAudioEngine?
    /// The default input when `engine` was made.
    private var engineInput: AudioDeviceID?
    private let store = SampleStore()
    /// How loud the recording in progress is, for the recording indicator.
    nonisolated let meter = LevelMeter()
    private var sampleRate = 0.0
    /// What records the current hold. Nil between holds.
    private var source: Source?
    private let logger = Logger(subsystem: "io.github.db-ol.Orra", category: "audio")

    /// Starts recording. Call only when microphone access is authorized, because starting
    /// without it would show the system prompt.
    /// - Parameter preferredInput: The UID of the microphone chosen in Orra, or nil for
    ///   the system default. While that microphone is not connected, the default records.
    func start(preferredInput: String?) throws {
        guard source == nil else { return }
        meter.reset()
        if let preferredInput {
            if let device = AudioInput.device(uid: preferredInput) {
                try startUnit(on: device)
                return
            }
            logger.notice("The chosen microphone is not connected, so the system default input records")
        }
        try startEngine()
    }

    /// Stops recording and returns what was recorded.
    func stop() -> AudioRecording {
        guard let source else { return AudioRecording(samples: [], sampleRate: sampleRate) }
        self.source = nil
        meter.reset()
        switch source {
        case .unit(let unit):
            let result = unit.stop()
            if result.interrupted || result.lostCallbacks > 0 {
                logger.notice("The chosen microphone changed or went away: \(result.interrupted, privacy: .public), callbacks lost: \(result.lostCallbacks, privacy: .public)")
            }
            return AudioRecording(samples: result.samples, sampleRate: unit.sampleRate, wasCut: result.interrupted, input: unit.device)
        case .engine(let input):
            // The engine stops itself when the input device changes. The recording is then
            // cut, and the next hold gets a fresh engine.
            let wasCut = engine?.isRunning != true
            endEngine()
            if wasCut {
                discardEngine()
            }
            return AudioRecording(samples: store.take(), sampleRate: sampleRate, wasCut: wasCut, input: input)
        }
    }

    /// Stops recording and throws the samples away.
    func cancel() {
        guard let source else { return }
        self.source = nil
        meter.reset()
        switch source {
        case .unit(let unit):
            _ = unit.stop()
        case .engine:
            endEngine()
            _ = store.take()
        }
    }

    private func startUnit(on device: AudioInput) throws {
        let began = ContinuousClock.now
        let unit = try InputUnit(device: device, maximumSeconds: RecordingLimits.maximumSeconds, meter: meter)
        try unit.start()
        source = .unit(unit)
        logger.notice("Recording from the chosen microphone over \(AudioInput.fourCC(device.transport), privacy: .public) at \(Int(unit.sampleRate), privacy: .public) Hz, started in \(began.duration(to: .now), privacy: .public)")
    }

    private func startEngine() throws {
        // An engine records from the default input as it was when the engine was made.
        // Whether it follows a later change is not documented, and reports disagree, so a
        // changed default input gets a fresh engine. Reading the device back from the
        // engine's input unit does not tell, because the unit is bound to a private
        // aggregate device that the engine builds from the default input and output.
        let defaultID = AudioInput.defaultDeviceID()
        let engine: AVAudioEngine
        if let current = self.engine, engineInput == defaultID {
            engine = current
        } else {
            engine = AVAudioEngine()
            self.engine = engine
            engineInput = defaultID
        }
        let input = engine.inputNode
        // The tap must match the hardware format. After the input device changes, the
        // output bus can still report the old one, and a tap in that format raises an
        // exception, so read the hardware side and build the tap format from it.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount) else {
            discardEngine()
            throw AudioRecorderError.unsupportedInput
        }
        sampleRate = hardware.sampleRate
        store.begin(limit: Int(hardware.sampleRate * RecordingLimits.maximumSeconds))
        // About 100 ms per buffer, so little speech waits in a half filled buffer.
        let bufferSize = AVAudioFrameCount(hardware.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: Self.tapBlock(store: store, meter: meter))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            // A fresh engine reads the device again on the next hold.
            discardEngine()
            throw error
        }
        source = .engine(defaultID.flatMap { AudioInput.device(id: $0) })
        logger.notice("Recording from the system default input")
    }

    private func endEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func discardEngine() {
        engine = nil
        engineInput = nil
    }

    nonisolated private static func tapBlock(store: SampleStore, meter: LevelMeter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let samples = MicrophoneChannel.samples(from: buffer)
            samples.withUnsafeBufferPointer { pointer in
                if let base = pointer.baseAddress {
                    meter.record(base, count: pointer.count)
                }
            }
            store.append(samples)
        }
    }
}

/// What PushToTalkController needs from the microphone. Closures, so tests can pass fakes
/// and never touch the real microphone or its permission prompt.
struct AudioCapture {
    var access: () -> MicrophoneAccess
    var requestAccess: () async -> MicrophoneAccess
    /// Starts recording from the microphone with this UID, or the system default for nil.
    var start: (String?) async throws -> Void
    var stop: () async -> AudioRecording
    var cancel: () async -> Void
    /// The peak of the latest audio while recording, from 0 to 1, for the recording
    /// indicator. Fakes may leave it at zero.
    var level: () -> Float = { 0 }

    static func live() -> AudioCapture {
        let recorder = AudioRecorder()
        return AudioCapture(
            access: { MicrophoneAccess.current() },
            requestAccess: { await MicrophoneAccess.request() },
            start: { preferredInput in try await recorder.start(preferredInput: preferredInput) },
            stop: { await recorder.stop() },
            cancel: { await recorder.cancel() },
            level: { recorder.meter.peak }
        )
    }
}
