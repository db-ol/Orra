import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Records the holds from a microphone chosen in Orra, through an input only audio unit
/// (AUHAL) bound to that device.
///
/// AVAudioEngine has no documented way to record from a device other than the default
/// input on macOS. Pointing its input node at another device is reported to deliver no
/// audio for some devices, and the engine opens the default input and output first anyway.
/// An AUHAL bound to the device is the way Apple's TN2091 documents for device input. The
/// system default input still records through AVAudioEngine in AudioRecorder.
///
/// The steps follow Apple's Technical Note TN2091: enable input and disable output, bind
/// the device, read its format, ask for 32 bit float mono at the device's own rate (AUHAL
/// does not resample input), take the device's first channel, set the input callback,
/// initialize, and start. docs/microphone-choice.md has the sources and what is not
/// verified yet.
///
/// The unit stays initialized between holds, so a hold only starts and stops its IO, and
/// no IO runs between holds. AudioRecorder makes a new one when the device changes, after
/// the device went away or changed, and after a failure.
///
/// Not Sendable. AudioRecorder makes, starts and stops it on its own actor.
nonisolated final class InputUnit {
    /// What a stop returns.
    nonisolated struct StopResult {
        var samples: [Float]
        /// The device went away, changed its rate or lost its input channels.
        var interrupted: Bool
        /// Callbacks of this recording whose audio was lost.
        var lostCallbacks: Int
        /// How long the IO ran, from the start returning to the stop. Zero when it did not
        /// start.
        var ran: Duration
        /// What AudioOutputUnitStop returned, noErr also when the unit was not running.
        /// When it is not noErr, the unit was closed.
        var status: OSStatus
    }

    let device: AudioInput
    /// The rate of the samples, which is the device's own.
    let sampleRate: Double
    private let unit: AudioUnit
    private let context: InputRenderContext
    private var watch: DeviceWatch?
    private var isRunning = false
    /// When the IO of the current recording started.
    private var startedAt: ContinuousClock.Instant?
    /// True once the unit was uninitialized and disposed. It records nothing more, and
    /// AudioRecorder makes a new one.
    private(set) var isClosed = false

    /// Builds and initializes the unit without starting it, so nothing is recorded yet, and
    /// watches the device for as long as the unit lives, so a device that went away or
    /// changed its rate is noticed also between holds.
    /// - Parameters:
    ///   - maximumSeconds: Room for this much audio is set aside before the first recording
    ///     starts. Audio past it is dropped.
    ///   - meter: Gets the peak of every buffer, for the recording indicator.
    ///   - arrival: Gets the time of the first buffer and the first buffer with sound.
    init(device: AudioInput, maximumSeconds: Double, meter: LevelMeter = LevelMeter(), arrival: AudioArrival = AudioArrival()) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioRecorderError.inputUnitFailed(step: "find the input unit", status: kAudioUnitErr_FailedInitialization)
        }
        var instance: AudioUnit?
        try InputUnit.check(AudioComponentInstanceNew(component, &instance), "create the input unit")
        guard let unit = instance else {
            throw AudioRecorderError.inputUnitFailed(step: "create the input unit", status: kAudioUnitErr_FailedInitialization)
        }
        do {
            let format = try InputUnit.configure(unit, device: device)
            let context = InputRenderContext(
                unit: unit,
                capacity: Int(format.mSampleRate * maximumSeconds),
                maximumFrames: InputUnit.maximumFrames(of: unit),
                meter: meter,
                arrival: arrival
            )
            var callback = AURenderCallbackStruct(
                inputProc: { refCon, flags, timestamp, bus, frames, _ in
                    Unmanaged<InputRenderContext>.fromOpaque(refCon).takeUnretainedValue().render(flags, timestamp, bus, frames)
                },
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            try InputUnit.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "set the input callback"
            )
            try InputUnit.check(AudioUnitInitialize(unit), "initialize the input unit")
            self.device = device
            self.sampleRate = format.mSampleRate
            self.unit = unit
            self.context = context
            watch = DeviceWatch(device: device.id, sampleRate: format.mSampleRate, flag: context.interrupted)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    deinit {
        close()
    }

    /// 32 bit float mono at `sampleRate`, or nil for a rate Orra cannot record.
    static func clientFormat(sampleRate: Double) -> AudioStreamBasicDescription? {
        guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate) else { return nil }
        let bytes = UInt32(MemoryLayout<Float32>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytes,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytes,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// True once the device went away, changed its rate or lost its input channels since
    /// the unit was made. Such a unit is made again.
    var isInterrupted: Bool {
        context.interrupted.isSet
    }

    /// Starts a recording with an empty capture buffer. A device that goes away or changes
    /// its rate during the hold marks the recording as cut.
    func start() throws {
        guard !isRunning, !isClosed else { return }
        // No IO runs, so no callback writes.
        context.buffer.clear()
        context.lostCallbacks.store(0, ordering: .relaxed)
        try InputUnit.check(AudioOutputUnitStart(unit), "start the input unit")
        isRunning = true
        startedAt = .now
    }

    /// Stops the device's IO and returns what was recorded, and clears the capture buffer,
    /// so the audio does not stay in memory until the next hold. The unit stays
    /// initialized for the next start. Also right for a unit that never started.
    ///
    /// When AudioOutputUnitStop fails, the IO may still run, so the unit is closed:
    /// uninitialized and disposed, which ends its IO and removes the callback. The result
    /// holds the status, and AudioRecorder makes a new unit for the next hold.
    func stop() -> StopResult {
        var status = noErr
        let ran = startedAt.map { $0.duration(to: .now) } ?? .zero
        startedAt = nil
        if isRunning {
            status = AudioOutputUnitStop(unit)
            if status == noErr {
                isRunning = false
            } else {
                close()
            }
        }
        // Stopping, or closing after a failed stop, returns once the device's IO has
        // stopped, so no callback writes anymore.
        let samples = context.buffer.samples()
        context.buffer.clear()
        return StopResult(
            samples: samples,
            interrupted: context.interrupted.isSet,
            lostCallbacks: context.lostCallbacks.load(ordering: .relaxed),
            ran: ran,
            status: status
        )
    }

    /// Stopping returns once the device's IO has stopped, and disposing the unit removes
    /// the callback. The memory the callback writes to belongs to `context`, which lives as
    /// long as this object, so it outlasts both.
    private func close() {
        guard !isClosed else { return }
        isClosed = true
        if isRunning {
            AudioOutputUnitStop(unit)
            isRunning = false
        }
        watch = nil
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// Makes the unit an input only unit on `device`, delivering 32 bit float mono at the
    /// device's rate from its first channel. Returns that format.
    private static func configure(_ unit: AudioUnit, device: AudioInput) throws -> AudioStreamBasicDescription {
        var on: UInt32 = 1
        var off: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        // Element 1 is the input side of the unit, element 0 the output side.
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flagSize), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize), "disable output")
        // TN2091: the device can be set only after IO is enabled. Always bound, also for
        // the device that is the default input, because an unbound unit is reported to
        // start without an error and deliver nothing.
        var id = device.id
        try check(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "bind the device"
        )
        // The input scope of element 1 is the device's side.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "read the device format")
        guard hardware.mChannelsPerFrame > 0, var client = clientFormat(sampleRate: hardware.mSampleRate) else {
            throw AudioRecorderError.inputUnitFailed(step: "read the device format", status: kAudioUnitErr_FormatNotSupported)
        }
        // The output scope of element 1 is Orra's side.
        try check(
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "set the sample format"
        )
        // The device's first channel goes into Orra's one channel, as with the engine. See
        // MicrophoneChannel for why the first channel.
        var channelMap: [Int32] = [0]
        let mapStatus = channelMap.withUnsafeMutableBytes { bytes in
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, bytes.baseAddress, UInt32(bytes.count))
        }
        try check(mapStatus, "take the first channel")
        return client
    }

    /// The most frames one callback may bring: the unit's own limit, and at least 8192.
    private static func maximumFrames(of unit: AudioUnit) -> Int {
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, &size)
        return max(Int(frames), 8_192)
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status != noErr else { return }
        throw AudioRecorderError.inputUnitFailed(step: step, status: status)
    }
}

/// What the input callback touches on Core Audio's real time thread. Nothing there
/// allocates, takes a lock or logs: the callback renders into scratch memory set aside in
/// advance and copies into the capture buffer.
nonisolated final class InputRenderContext: @unchecked Sendable {
    let unit: AudioUnit
    let buffer: CaptureBuffer
    /// Set when the device goes away or changes during the recording.
    let interrupted = InterruptionFlag()
    /// Callbacks whose audio was lost: more frames than the scratch memory holds, or a
    /// failed render.
    let lostCallbacks = Atomic<Int>(0)
    private let meter: LevelMeter
    private let arrival: AudioArrival
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames: Int
    private let list: UnsafeMutableAudioBufferListPointer

    init(unit: AudioUnit, capacity: Int, maximumFrames: Int, meter: LevelMeter, arrival: AudioArrival) {
        self.unit = unit
        self.meter = meter
        self.arrival = arrival
        buffer = CaptureBuffer(capacity: capacity)
        scratchFrames = maximumFrames
        scratch = .allocate(capacity: maximumFrames)
        scratch.initialize(repeating: 0, count: maximumFrames)
        list = AudioBufferList.allocate(maximumBuffers: 1)
    }

    deinit {
        scratch.deallocate()
        free(list.unsafeMutablePointer)
    }

    /// Runs on Core Audio's real time thread each time input arrives.
    func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        let count = Int(frames)
        guard count <= scratchFrames else {
            lostCallbacks.wrappingAdd(1, ordering: .relaxed)
            return noErr
        }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * UInt32(MemoryLayout<Float>.size), mData: UnsafeMutableRawPointer(scratch))
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, list.unsafeMutablePointer)
        guard status == noErr else {
            lostCallbacks.wrappingAdd(1, ordering: .relaxed)
            return status
        }
        buffer.append(scratch, count: count)
        let peak = meter.record(scratch, count: count)
        arrival.record(peak: peak, count: count)
        return noErr
    }
}

/// Room for a whole recording. Allocated and touched before the first recording starts, so
/// the real time thread only copies. One thread appends, and the count it publishes with an
/// atomic store covers only samples already written. Reading and clearing are for while the
/// unit is stopped.
nonisolated final class CaptureBuffer: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let count = Atomic<Int>(0)

    init(capacity: Int) {
        let capacity = max(capacity, 0)
        self.capacity = capacity
        storage = .allocate(capacity: max(capacity, 1))
        // Touching every page now keeps page faults off the real time thread.
        storage.initialize(repeating: 0, count: max(capacity, 1))
    }

    deinit {
        storage.deallocate()
    }

    /// Keeps what fits and drops the rest.
    func append(_ samples: UnsafePointer<Float>, count newSamples: Int) {
        let filled = count.load(ordering: .relaxed)
        let taken = min(newSamples, capacity - filled)
        guard taken > 0 else { return }
        (storage + filled).update(from: samples, count: taken)
        count.store(filled + taken, ordering: .releasing)
    }

    func samples() -> [Float] {
        Array(UnsafeBufferPointer(start: storage, count: count.load(ordering: .acquiring)))
    }

    /// Zeroes what was recorded and starts over at the beginning.
    func clear() {
        let filled = count.load(ordering: .acquiring)
        storage.update(repeating: 0, count: filled)
        count.store(0, ordering: .releasing)
    }
}

/// Set once the device a unit records from goes away, changes its rate, or loses its input
/// channels.
nonisolated final class InterruptionFlag: Sendable {
    private let value = Atomic<Bool>(false)

    var isSet: Bool {
        value.load(ordering: .acquiring)
    }

    func set() {
        value.store(true, ordering: .releasing)
    }
}

/// Listens to one device for as long as its unit lives and sets the flag when the device
/// goes away, runs at another rate, or has no input channels left. AudioRecording holds one
/// rate, so such a recording is cut, as the engine cuts one when its device changes, and
/// the unit is made again. The listeners are removed when this is released.
///
/// Core Audio matches a removal to its registration by the block. Swift imports the
/// listener type as a Swift closure and wraps it in a new block at every call, so calling
/// AudioObjectRemovePropertyListenerBlock directly never matches. It still returns no
/// error, and the listeners, their queue and what they capture stay behind (checked on
/// macOS 26.6.2). Both functions are therefore called through C function references that
/// take a block, which hand Core Audio the one block stored here.
nonisolated final class DeviceWatch {
    typealias Listener = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    typealias Registration = @convention(c) (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, DispatchQueue?, @escaping Listener) -> OSStatus
    /// Internal, because DeviceListWatch registers through them too.
    static let addListener: Registration = AudioObjectAddPropertyListenerBlock
    static let removeListener: Registration = AudioObjectRemovePropertyListenerBlock

    private let device: AudioDeviceID
    private let queue = DispatchQueue(label: "io.github.db-ol.Orra.input-device")
    private let listener: Listener
    private var addresses: [AudioObjectPropertyAddress] = []

    init(device: AudioDeviceID, sampleRate: Double, flag: InterruptionFlag) {
        self.device = device
        listener = { _, _ in
            let rate = AudioInput.nominalSampleRate(device)
            let changed = rate.map { abs($0 - sampleRate) > 1 } ?? true
            if changed || !AudioInput.isAlive(device) || AudioInput.inputChannelCount(device) == 0 {
                flag.set()
            }
        }
        let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ]
        for (selector, scope) in watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            if Self.addListener(device, &address, queue, listener) == noErr {
                addresses.append(address)
            }
        }
    }

    deinit {
        for var address in addresses {
            _ = Self.removeListener(device, &address, queue, listener)
        }
    }
}
