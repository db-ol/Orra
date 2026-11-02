import AudioToolbox
import AVFoundation
import CoreAudio
import os
import Synchronization

/// Why Live Captions cannot listen to the microphone.
nonisolated enum MicrophoneCaptionProblem: Error, Equatable, Sendable {
    /// Microphone access is not given: not decided yet, turned off, or the build cannot
    /// ask for it.
    case access(MicrophoneAccess)
    /// No input that Orra offers is connected.
    case noInput
    /// A Core Audio call failed. The step names it for the log.
    case failed(step: String, status: OSStatus)
}

/// What meeting captions need from the microphone. Closures, so tests pass a fake and never
/// open a device or ask for access. MeetingCaptions calls `start` and `stop` off the main
/// actor, one after the other on a queue of its own, since starting a Bluetooth
/// microphone can take seconds. It calls the others on the main actor.
nonisolated struct MicrophoneCaptionSource: Sendable {
    /// Microphone access as it is now. Reading it never shows the prompt.
    var access: @Sendable () -> MicrophoneAccess
    /// Starts listening to the microphone with the UID `preferredInput` while it is
    /// connected, or else to the system default input, and returns the input it listens
    /// to. `deliver` gets 16 kHz mono samples on a background queue, in order, about every
    /// 100 ms. `moved` is called once, on a background queue, when that input goes away,
    /// changes its rate or loses its inputs, or when the input to listen to is now
    /// another one. Throws a MicrophoneCaptionProblem, and never shows the prompt.
    var start: @Sendable (
        _ preferredInput: String?,
        _ deliver: @escaping @Sendable ([Float]) -> Void,
        _ moved: @escaping @Sendable () -> Void
    ) throws -> AudioInput
    /// Stops listening and lets go of the device. Returns once no samples come anymore.
    /// Safe to call when nothing runs.
    var stop: @Sendable () -> Void
    /// Whether the lid of a MacBook is closed, which turns its built in microphone off.
    var lidClosed: @Sendable () -> Bool
    /// Calls its argument on the main actor whenever Core Audio's list of devices changes,
    /// until the object it returns is released, so a microphone plugged in later is used.
    var watchInputs: @Sendable (_ onChange: @escaping @MainActor () -> Void) -> AnyObject?

    static func live() -> MicrophoneCaptionSource {
        let microphone = CaptionMicrophone()
        return MicrophoneCaptionSource(
            access: { MicrophoneAccess.current() },
            start: { try microphone.start(preferredInput: $0, deliver: $1, moved: $2) },
            stop: { microphone.stop() },
            lidClosed: { Lid.isClosed() },
            watchInputs: { DeviceListWatch(onChange: $0) }
        )
    }

    /// No microphone, for captions that only listen to what the Mac plays, as in tests and
    /// previews: no access, and a start throws.
    static let unavailable = MicrophoneCaptionSource(
        access: { .notConfigured },
        start: { _, _, _ in throw MicrophoneCaptionProblem.access(.notConfigured) },
        stop: {},
        lidClosed: { false },
        watchInputs: { _ in nil }
    )
}

/// Listens to a microphone for Live Captions, through an input only audio unit (AUHAL) of
/// its own, bound to the device a dictation would record from now. Never through
/// AudioRecorder, so dictation keeps its own unit or engine, and Core Audio serves the
/// device to both.
///
/// The unit is set up the way InputUnit sets up dictation's, see Apple's TN2091: input on,
/// output off, bound to the device, 32 bit float mono at the device's own rate, from its
/// first channel. The input callback runs on Core Audio's real time thread and only
/// renders into scratch memory and copies it into an AudioFrameRing, as the capture of
/// what the Mac plays does. A timer on `queue` takes the frames out, converts them to
/// 16 kHz mono and hands on the chunks, and looks whether the device moved.
///
/// Each start makes a new unit, and the stop stops, uninitializes and disposes of it, so
/// nothing stays set up while captions do not listen. docs/microphone-choice.md says why.
nonisolated final class CaptionMicrophone: @unchecked Sendable {
    /// How often the frames are taken out of the ring and converted.
    static let drainInterval = DispatchTimeInterval.milliseconds(20)
    /// Seconds of frames the ring holds, far more than one drain needs.
    static let ringSeconds = 2.0

    /// What one start made, until the stop takes it apart. Handed over under `lock` only,
    /// and taken apart on the queue that started it.
    private struct Running: @unchecked Sendable {
        let unit: AudioUnit
        let context: CaptionInputContext
        let timer: DispatchSourceTimer
        /// Released with this, which removes their listeners.
        let watch: DeviceWatch
        let inputs: InputListWatch
        let started: ContinuousClock.Instant
    }

    private let lock = OSAllocatedUnfairLock()
    /// Converts and hands on the chunks. Serial, so they stay in order.
    private let queue = DispatchQueue(label: "io.github.db-ol.Orra.caption-microphone", qos: .userInteractive)
    private var running: Running?

    deinit {
        stop()
    }

    /// The input captions listen to: the microphone chosen in Orra while it is connected,
    /// otherwise the system default input, as a dictation records. Nil without either.
    static func resolve(preferredInput: String?, connected: (String) -> AudioInput?, systemDefault: () -> AudioInput?) -> AudioInput? {
        preferredInput.flatMap(connected) ?? systemDefault()
    }

    /// Whether captions start the microphone again: the input they listen to went away,
    /// changed its rate or lost its inputs, or the input to listen to is now another one,
    /// or none, such as after the chosen microphone was plugged in or the default input
    /// changed. A change of the list that leaves the same input, such as the private
    /// aggregate device that dictation's engine makes, is no move.
    static func hasMoved(interrupted: Bool, listensTo bound: String, resolved: String?) -> Bool {
        interrupted || resolved != bound
    }

    /// Starts listening, see MicrophoneCaptionSource.start. Never shows the prompt: without
    /// microphone access it throws before it touches a device.
    func start(preferredInput: String?, deliver: @escaping @Sendable ([Float]) -> Void, moved: @escaping @Sendable () -> Void) throws -> AudioInput {
        stop()
        let began = ContinuousClock.now
        // Checked again here, so the capture itself never asks.
        let access = MicrophoneAccess.current()
        guard access == .authorized else { throw MicrophoneCaptionProblem.access(access) }
        guard let device = Self.resolve(preferredInput: preferredInput, connected: AudioInput.device(uid:), systemDefault: AudioInput.systemDefault) else {
            throw MicrophoneCaptionProblem.noInput
        }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Self.failure("find the input unit", kAudioUnitErr_FailedInitialization)
        }
        var instance: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &instance), "create the input unit")
        guard let unit = instance else { throw Self.failure("create the input unit", kAudioUnitErr_FailedInitialization) }
        var initialized = false
        let rate: Double
        do {
            let format: AudioStreamBasicDescription
            do {
                format = try InputUnit.configure(unit, device: device)
            } catch AudioRecorderError.inputUnitFailed(let step, let status) {
                throw Self.failure(step, status)
            }
            rate = format.mSampleRate
            guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.mSampleRate, channels: 1, interleaved: false),
                  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(RecordingLimits.sampleRate), channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: input, to: target) else {
                throw Self.failure("make the converter", 0)
            }
            let writer = TapWriter(ring: AudioFrameRing(
                planes: 1,
                bytesPerFrame: MemoryLayout<Float>.size,
                capacity: Int(format.mSampleRate * Self.ringSeconds)
            ))
            let context = CaptionInputContext(unit: unit, writer: writer, maximumFrames: InputUnit.maximumFrames(of: unit))
            var callback = AURenderCallbackStruct(
                inputProc: { refCon, flags, timestamp, bus, frames, _ in
                    Unmanaged<CaptionInputContext>.fromOpaque(refCon).takeUnretainedValue().render(flags, timestamp, bus, frames)
                },
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            try Self.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "set the input callback"
            )
            try Self.check(AudioUnitInitialize(unit), "initialize the input unit")
            initialized = true
            let check = MicrophoneMoveCheck(listensTo: device, preferredInput: preferredInput, moved: moved)
            let chunker = Chunker(writer: writer, converter: converter, input: input, output: target, deliver: deliver)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval, leeway: .milliseconds(5))
            timer.setEventHandler {
                chunker.drain()
                check.look()
            }
            let running = Running(
                unit: unit,
                context: context,
                timer: timer,
                watch: DeviceWatch(device: device.id, sampleRate: format.mSampleRate, flag: check.interrupted),
                inputs: InputListWatch(queue: queue, changed: check),
                started: .now
            )
            lock.withLock { self.running = running }
            timer.resume()
        } catch {
            if initialized {
                AudioUnitUninitialize(unit)
            }
            AudioComponentInstanceDispose(unit)
            throw error
        }
        do {
            try Self.check(AudioOutputUnitStart(unit), "start the input unit")
        } catch {
            stop()
            throw error
        }
        // How long the start took tells a Bluetooth microphone that switched to its call
        // profile. Never the device's name.
        Logger.captions.notice("Caption microphone started over \(AudioInput.fourCC(device.transport), privacy: .public) at \(Int(rate), privacy: .public) Hz in \(began.duration(to: .now), privacy: .public)")
        return device
    }

    /// Stops listening: the unit stops, is uninitialized and disposed of, and the watches
    /// go. Returns once no samples come anymore. Safe to call when nothing runs.
    func stop() {
        let running = lock.withLock {
            let current = self.running
            self.running = nil
            return current
        }
        if let running {
            // Returns once the device's IO has stopped, so no callback writes anymore.
            AudioOutputUnitStop(running.unit)
            AudioUnitUninitialize(running.unit)
            AudioComponentInstanceDispose(running.unit)
            running.timer.cancel()
            let lost = running.context.lostCallbacks.load(ordering: .relaxed)
            let dropped = running.context.writer.ring.dropped
            Logger.captions.notice("Caption microphone stopped after \(running.started.duration(to: .now), privacy: .public), \(lost, privacy: .public) callbacks lost, \(dropped, privacy: .public) frames dropped")
        }
        // Waits for a conversion under way, so no samples come after stop returns.
        queue.sync {}
    }

    private static func failure(_ step: String, _ status: OSStatus) -> MicrophoneCaptionProblem {
        Logger.captions.error("Caption microphone could not \(step, privacy: .public): \(status, privacy: .public)")
        return .failed(step: step, status: status)
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status != noErr else { return }
        throw failure(step, status)
    }
}

/// What the input callback of the caption microphone touches on Core Audio's real time
/// thread: it renders into scratch memory set aside in advance and copies it into the
/// ring. Nothing there allocates, takes a lock or logs.
nonisolated final class CaptionInputContext: @unchecked Sendable {
    let unit: AudioUnit
    let writer: TapWriter
    /// Callbacks whose audio was lost: more frames than the scratch memory holds, or a
    /// failed render.
    let lostCallbacks = Atomic<Int>(0)
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames: Int
    private let list: UnsafeMutableAudioBufferListPointer

    init(unit: AudioUnit, writer: TapWriter, maximumFrames: Int) {
        self.unit = unit
        self.writer = writer
        scratchFrames = maximumFrames
        scratch = .allocate(capacity: maximumFrames)
        scratch.initialize(repeating: 0, count: maximumFrames)
        list = AudioBufferList.allocate(maximumBuffers: 1)
    }

    deinit {
        scratch.deallocate()
        free(list.unsafeMutablePointer)
    }

    /// Runs on Core Audio's real time thread each time input arrives. One buffer of one
    /// channel, so TapWriter reads it whole.
    func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        guard Int(frames) <= scratchFrames else {
            lostCallbacks.wrappingAdd(1, ordering: .relaxed)
            return noErr
        }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * UInt32(MemoryLayout<Float>.size), mData: UnsafeMutableRawPointer(scratch))
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, list.unsafeMutablePointer)
        guard status == noErr else {
            lostCallbacks.wrappingAdd(1, ordering: .relaxed)
            return status
        }
        writer.write(UnsafePointer(list.unsafeMutablePointer))
        return noErr
    }
}

/// Whether the caption microphone moved, for its drain timer, see
/// `CaptionMicrophone.hasMoved`. The watches only set flags, and `look` reads the devices
/// on the capture's queue, never on the main thread, and calls `moved` once.
nonisolated final class MicrophoneMoveCheck: @unchecked Sendable {
    /// Set by DeviceWatch when the bound device goes away, changes its rate or loses its
    /// inputs.
    let interrupted = InterruptionFlag()
    /// Set by InputListWatch when the default input or the list of devices changes.
    let devicesChanged = Atomic<Bool>(false)
    private let bound: AudioInput
    private let preferredInput: String?
    private let moved: @Sendable () -> Void
    /// Used on the capture's queue only.
    private var reported = false

    init(listensTo bound: AudioInput, preferredInput: String?, moved: @escaping @Sendable () -> Void) {
        self.bound = bound
        self.preferredInput = preferredInput
        self.moved = moved
    }

    func look() {
        guard !reported else { return }
        var resolved: String? = bound.uid
        if devicesChanged.exchange(false, ordering: .acquiringAndReleasing) {
            resolved = CaptionMicrophone.resolve(preferredInput: preferredInput, connected: AudioInput.device(uid:), systemDefault: AudioInput.systemDefault)?.uid
        }
        guard CaptionMicrophone.hasMoved(interrupted: interrupted.isSet, listensTo: bound.uid, resolved: resolved) else { return }
        reported = true
        moved()
    }
}

/// Listens to the system's default input and its list of devices for as long as it lives,
/// and sets a flag at each change. Registered and removed through DeviceWatch's C function
/// references, so the removal matches the block that was added.
nonisolated final class InputListWatch {
    private let queue: DispatchQueue
    private let listener: DeviceWatch.Listener
    private var addresses: [AudioObjectPropertyAddress] = []

    init(queue: DispatchQueue, changed: MicrophoneMoveCheck) {
        self.queue = queue
        listener = { _, _ in
            changed.devicesChanged.store(true, ordering: .releasing)
        }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioInput.address(selector)
            if DeviceWatch.addListener(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
                addresses.append(address)
            }
        }
    }

    deinit {
        for var address in addresses {
            _ = DeviceWatch.removeListener(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }
}
