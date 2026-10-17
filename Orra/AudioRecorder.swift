import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import os
import Synchronization

extension Logger {
    /// The microphone. Devices, formats and states only, never audio.
    nonisolated static let audio = Logger(subsystem: ProblemReport.subsystem, category: "audio")
}

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

    /// Stores the largest magnitude among the samples and returns it. Safe on Core Audio's
    /// real time thread.
    @discardableResult
    func record(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        peakBits.store(peak.bitPattern, ordering: .relaxed)
        return peak
    }

    func reset() {
        peakBits.store(0, ordering: .relaxed)
    }
}

/// When the first audio of a recording arrived, for the start cue and the timing log. The
/// audio thread stores the host time of the first buffer and of the first buffer with
/// sound in two atomics, so it neither locks nor allocates. The times are when Orra got
/// the buffer, so a buffer of the engine, about 100 ms long, arrives up to that much after
/// its first sample was recorded.
nonisolated final class AudioArrival: Sendable {
    /// A buffer whose peak reaches this has sound. It is the floor of the silence check,
    /// about -100 dBFS, so the two agree on what counts as sound. A microphone that is
    /// starting, muted or cut off, such as a MacBook's with the lid closed, or a Bluetooth
    /// one in its first moment as reported, delivers zeros, which stay below it. The noise
    /// of a working microphone is expected to reach it without any speech, so the start
    /// cue does not wait for the user to speak.
    static let soundFloor = Silence.threshold

    /// Mach host times, zero until the buffer arrived.
    private let firstBuffer = Atomic<UInt64>(0)
    private let firstSound = Atomic<UInt64>(0)

    /// Forgets the times of the previous recording. Called before the audio starts.
    func reset() {
        firstBuffer.store(0, ordering: .relaxed)
        firstSound.store(0, ordering: .releasing)
    }

    /// Notes a buffer of `count` samples whose largest magnitude is `peak`, arriving at the
    /// host time `now`. Safe on Core Audio's real time thread.
    func record(peak: Float, count: Int, at now: UInt64 = mach_absolute_time()) {
        guard count > 0 else { return }
        if firstBuffer.load(ordering: .relaxed) == 0 {
            firstBuffer.store(now, ordering: .relaxed)
        }
        if peak >= Self.soundFloor, firstSound.load(ordering: .relaxed) == 0 {
            firstSound.store(now, ordering: .releasing)
        }
    }

    /// The host time of the first buffer, and of the first buffer with sound, or zero.
    var firstBufferHostTime: UInt64 {
        firstBuffer.load(ordering: .acquiring)
    }

    var firstSoundHostTime: UInt64 {
        firstSound.load(ordering: .acquiring)
    }

    /// Returns once a buffer with sound has arrived, or at `deadline`, or when the task is
    /// cancelled. It looks every 5 ms, because the real time thread cannot wake a task
    /// without a lock or an allocation.
    @concurrent
    func waitForSound(until deadline: ContinuousClock.Instant) async {
        while firstSoundHostTime == 0, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Turns the mach host times of the audio thread into instants of the continuous clock,
/// which the key events and the controller use.
nonisolated enum HostTime {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// The instant of `hostTime`, or nil for zero. Both clocks advance together while the
    /// Mac is awake, so a stamp from the hold that just ended is placed by its distance to
    /// a pair of readings taken now.
    static func instant(
        _ hostTime: UInt64,
        now: ContinuousClock.Instant = .now,
        hostNow: UInt64 = mach_absolute_time(),
        timebase: mach_timebase_info_data_t = timebase
    ) -> ContinuousClock.Instant? {
        guard hostTime != 0, timebase.denom != 0 else { return nil }
        let ticks = hostNow >= hostTime ? hostNow - hostTime : 0
        let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return now - .nanoseconds(Int64(nanoseconds.rounded()))
    }
}

nonisolated enum AudioRecorderError: Error, Equatable {
    /// The default input reports a format that cannot be recorded.
    case unsupportedInput
    /// The input unit for the chosen microphone failed at this step, with Core Audio's
    /// status.
    case inputUnitFailed(step: String, status: OSStatus)
}

/// How the latest recording started, for the timing log: the way it recorded, how its
/// device is connected, and when its first buffer and its first buffer with sound arrived.
nonisolated struct CaptureOnset: Equatable, Sendable {
    nonisolated enum Path: String, Sendable {
        /// The chosen microphone's InputUnit.
        case unit
        /// AVAudioEngine on the system default input.
        case engine
    }

    var path: Path?
    /// The device's transport type, such as 'usb ', or 0 when it could not be read.
    var transport: UInt32 = 0
    var firstBuffer: ContinuousClock.Instant?
    var firstSound: ContinuousClock.Instant?
}

/// Records the microphone into memory while the talk key is held. Nothing is written to disk.
///
/// An actor, so the audio hardware starts and stops away from the main thread. The
/// keyboard tap runs there, every key press on the Mac waits for it, and starting a
/// Bluetooth microphone can take seconds.
///
/// Two ways to record:
/// - A microphone chosen in Orra's menu records through an InputUnit bound to that device.
///   InputUnit says why. The unit stays set up between holds, so a hold only starts and
///   stops its IO. It goes as soon as another microphone or System Default is chosen, and
///   when the system default records. It is made again after its device went away or
///   changed, and after any failure, see `keepsUnit(after:gotFirstBuffer:)`.
/// - The system default input records through AVAudioEngine, as it did before the choice
///   existed. It also records while the chosen microphone is not connected. After a hold
///   the engine is prepared again, which AVAudioEngine's documentation describes as
///   allocating what a start needs without starting the hardware. That happens once the
///   recording is handed over, so the release does not wait for it.
///
/// Between holds no IO runs. Whether macOS shows its microphone indicator for a unit or an
/// engine that is set up but stopped is not documented, see docs/microphone-choice.md.
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
    /// The chosen microphone's unit, kept between holds. Nil until a chosen microphone
    /// records, and again once the system default records.
    private var unit: InputUnit?
    private let store = SampleStore()
    /// How loud the recording in progress is, for the recording indicator.
    nonisolated let meter = LevelMeter()
    /// When the first audio of the latest recording arrived.
    nonisolated let arrival = AudioArrival()
    private var sampleRate = 0.0
    /// What records the current hold. Nil between holds.
    private var source: Source?
    /// How the latest recording started, for the timing log.
    private var latestPath: CaptureOnset.Path?
    private var latestTransport: UInt32 = 0
    private let logger = Logger.audio

    /// Starts recording. Call only when microphone access is authorized, because starting
    /// without it would show the system prompt.
    /// - Parameter preferredInput: The UID of the microphone chosen in Orra, or nil for
    ///   the system default. While that microphone is not connected, the default records.
    func start(preferredInput: String?) throws {
        guard source == nil else { return }
        meter.reset()
        arrival.reset()
        latestPath = nil
        latestTransport = 0
        if let preferredInput {
            if let device = AudioInput.device(uid: preferredInput) {
                // The engine stays prepared on the default input only while that records,
                // so a chosen microphone leaves the default input alone.
                discardEngine()
                try startUnit(on: device)
                return
            }
            // Info, because it comes at every press while the microphone is away, also for
            // a shortcut during the wait of a key. The controller logs a notice once for
            // each dictation the system default recorded instead.
            logger.info("The chosen microphone is not connected, so the system default input records")
        }
        // A unit kept for a chosen microphone is no longer needed.
        unit = nil
        try startEngine()
    }

    /// How the latest recording started and when its first audio arrived.
    func onset() -> CaptureOnset {
        CaptureOnset(
            path: latestPath,
            transport: latestTransport,
            firstBuffer: HostTime.instant(arrival.firstBufferHostTime),
            firstSound: HostTime.instant(arrival.firstSoundHostTime)
        )
    }

    /// Lets go of the kept unit unless it is bound to the microphone with the UID
    /// `preferredInput`, for when the choice changes, so the device is released then and not
    /// at the next press. A hold that records through it goes on, and the unit goes once
    /// that hold has stopped it.
    func microphoneChosen(_ preferredInput: String?) {
        guard let unit, unit.device.uid != preferredInput else { return }
        self.unit = nil
    }

    /// Stops recording and returns what was recorded.
    func stop() -> AudioRecording {
        guard let source else { return AudioRecording(samples: [], sampleRate: sampleRate) }
        self.source = nil
        // After the unit or the engine has stopped, so no late buffer leaves a peak behind.
        defer { meter.reset() }
        switch source {
        case .unit(let unit):
            let result = endUnit(unit)
            return AudioRecording(samples: result.samples, sampleRate: unit.sampleRate, wasCut: result.interrupted, input: unit.device)
        case .engine(let input):
            // The engine stops itself when the input device changes. The recording is then
            // cut, and the next hold gets a fresh engine.
            let wasCut = engine?.isRunning != true
            endEngine()
            if wasCut {
                discardEngine()
            } else {
                prepareEngineLater()
            }
            return AudioRecording(samples: store.take(), sampleRate: sampleRate, wasCut: wasCut, input: input)
        }
    }

    /// Stops recording and throws the samples away.
    func cancel() {
        guard let source else { return }
        self.source = nil
        defer { meter.reset() }
        switch source {
        case .unit(let unit):
            _ = endUnit(unit)
        case .engine:
            let kept = engine?.isRunning == true
            endEngine()
            if kept {
                prepareEngineLater()
            }
            _ = store.take()
        }
    }

    private func startUnit(on device: AudioInput) throws {
        let began = ContinuousClock.now
        let unit = try readyUnit(for: device)
        do {
            try unit.start()
        } catch {
            // A unit that failed is made again at the next hold.
            self.unit = nil
            throw error
        }
        source = .unit(unit)
        latestPath = .unit
        latestTransport = device.transport
        // Info, because a shortcut during the wait of a key starts the microphone too. The
        // timing line of each hold that counted holds the path and the transport.
        logger.info("Recording from the chosen microphone over \(AudioInput.fourCC(device.transport), privacy: .public) at \(Int(unit.sampleRate), privacy: .public) Hz, started in \(began.duration(to: .now), privacy: .public)")
    }

    /// Stops the unit of a hold, and lets the next hold make a new one when this one is not
    /// to be trusted again, see `keepsUnit(after:gotFirstBuffer:)`. Logs numbers only.
    private func endUnit(_ unit: InputUnit) -> InputUnit.StopResult {
        let result = unit.stop()
        let gotFirstBuffer = arrival.firstBufferHostTime != 0
        if result.status != noErr {
            logger.error("Stopping the chosen microphone failed with status \(result.status, privacy: .public), so its unit was closed")
        }
        if result.interrupted || result.lostCallbacks > 0 {
            logger.notice("The chosen microphone changed or went away: \(result.interrupted, privacy: .public), callbacks lost: \(result.lostCallbacks, privacy: .public)")
        }
        if !gotFirstBuffer, result.ran >= Self.firstBufferLimit {
            logger.notice("The chosen microphone delivered no audio in \(result.ran, privacy: .public), so the next hold makes its unit again")
        }
        if !Self.keepsUnit(after: result, gotFirstBuffer: gotFirstBuffer), self.unit === unit {
            self.unit = nil
        }
        return result
    }

    /// How long a unit's IO may run in a hold without delivering a single buffer before the
    /// next hold makes a new unit. A short press, such as a shortcut during the wait of a
    /// key, can end before the first buffer of a working unit, so it keeps the unit. One
    /// second is the limit of the wait for sound, by which a working microphone has
    /// delivered sound, see PushToTalkController.
    nonisolated static let firstBufferLimit: Duration = .seconds(1)

    /// Whether the unit that recorded a hold may record the next one. Not when its stop
    /// failed, which closed it, when its device changed or went away, when a callback lost
    /// its audio, or when its IO ran for `firstBufferLimit` and delivered no buffer at all.
    nonisolated static func keepsUnit(after result: InputUnit.StopResult, gotFirstBuffer: Bool) -> Bool {
        result.status == noErr && !result.interrupted && result.lostCallbacks == 0
            && (gotFirstBuffer || result.ran < firstBufferLimit)
    }

    /// The kept unit while it is still open and bound to `device` at the device's rate, or a
    /// new one. The unit's device watch notices a change between holds too, and the rate is
    /// read again in case its notice is still on the way.
    private func readyUnit(for device: AudioInput) throws -> InputUnit {
        if let unit, !unit.isClosed, unit.device == device, !unit.isInterrupted,
           let rate = AudioInput.nominalSampleRate(device.id), abs(rate - unit.sampleRate) <= 1 {
            return unit
        }
        // The old unit lets go of its device first.
        unit = nil
        let made = try InputUnit(device: device, maximumSeconds: RecordingLimits.maximumSeconds, meter: meter, arrival: arrival)
        unit = made
        return made
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
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: Self.tapBlock(store: store, meter: meter, arrival: arrival))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            // A fresh engine reads the device again on the next hold.
            discardEngine()
            throw error
        }
        let device = defaultID.flatMap { AudioInput.device(id: $0) }
        source = .engine(device)
        latestPath = .engine
        latestTransport = device?.transport ?? 0
        // Info, for the same reason as the line of a chosen microphone.
        logger.info("Recording from the system default input")
    }

    /// Stops the engine and the hardware.
    private func endEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Prepares the kept engine for the next hold after the caller got what it waited for.
    /// Apple's documentation of AVAudioEngine says that stop releases what prepare
    /// allocated, and that start calls prepare when it was not called after stop and only
    /// then starts the hardware, so preparing between holds moves that work out of the
    /// next press without starting anything. It runs as a job of its own on this actor,
    /// after stop or cancel returned, so the time from the release to the paste does not
    /// include it.
    private func prepareEngineLater() {
        Task { self.prepareIdleEngine() }
    }

    /// Prepares the engine only while no hold records and the next hold would use it: the
    /// default input is still the one it was made for, and that input still reports a
    /// format, which startEngine checks too, because a device that went away can raise an
    /// exception.
    private func prepareIdleEngine() {
        guard source == nil, let engine, !engine.isRunning, engineInput == AudioInput.defaultDeviceID() else { return }
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { return }
        engine.prepare()
    }

    private func discardEngine() {
        engine = nil
        engineInput = nil
    }

    nonisolated private static func tapBlock(store: SampleStore, meter: LevelMeter, arrival: AudioArrival) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let samples = MicrophoneChannel.samples(from: buffer)
            samples.withUnsafeBufferPointer { pointer in
                if let base = pointer.baseAddress {
                    let peak = meter.record(base, count: pointer.count)
                    arrival.record(peak: peak, count: pointer.count)
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
    /// Returns once the recording in progress has delivered a buffer with sound, or at the
    /// deadline. Fakes may return at once, as if sound came right after the start.
    var waitForSound: (ContinuousClock.Instant) async -> Void = { _ in }
    /// How the latest recording started, for the timing log. Fakes may leave it empty.
    var onset: () async -> CaptureOnset = { CaptureOnset() }
    /// Tells the microphone the UID of the newly chosen microphone, or nil for the system
    /// default, so what it kept for the choice before goes at once. Fakes may ignore it.
    var microphoneChosen: (String?) async -> Void = { _ in }

    static func live() -> AudioCapture {
        let recorder = AudioRecorder()
        return AudioCapture(
            access: { MicrophoneAccess.current() },
            requestAccess: { await MicrophoneAccess.request() },
            start: { preferredInput in try await recorder.start(preferredInput: preferredInput) },
            stop: { await recorder.stop() },
            cancel: { await recorder.cancel() },
            level: { recorder.meter.peak },
            waitForSound: { deadline in await recorder.arrival.waitForSound(until: deadline) },
            onset: { await recorder.onset() },
            microphoneChosen: { preferredInput in await recorder.microphoneChosen(preferredInput) }
        )
    }
}
