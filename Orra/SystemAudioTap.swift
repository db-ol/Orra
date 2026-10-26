import AVFoundation
import CoreAudio
import os
import Synchronization

/// Why the sound the Mac plays cannot be captured.
nonisolated enum SystemAudioProblem: Error, Equatable, Sendable {
    /// The app has no NSAudioCaptureUsageDescription, so macOS would refuse or end it.
    case notConfigured
    /// A Core Audio call failed. The step names it for the log.
    case failed(step: String, status: OSStatus)
}

/// What meeting captions need from the capture of the sound the Mac plays. Closures, so
/// tests pass a fake. MeetingCaptions calls both off the main actor, one after the other,
/// since starting can wait for the permission prompt.
nonisolated struct SystemAudioSource: Sendable {
    /// Starts the capture. `deliver` gets 16 kHz mono samples on a background queue, in
    /// order, about every 100 ms.
    var start: @Sendable (_ deliver: @escaping @Sendable ([Float]) -> Void) throws -> Void
    var stop: @Sendable () -> Void

    static func live() -> SystemAudioSource {
        let tap = SystemAudioTap()
        return SystemAudioSource(start: { try tap.start(deliver: $0) }, stop: { tap.stop() })
    }
}

/// Captures what the Mac plays with a Core Audio process tap: a global stereo mixdown of
/// every process but Orra itself, so its own sounds never get into the captions. The
/// microphone is never touched.
///
/// A process tap rather than ScreenCaptureKit: a tap needs only the system audio recording
/// permission, which macOS asks for the first time captions start, while ScreenCaptureKit
/// needs Screen Recording, which also lets an app see the screen. A tap also takes no
/// video work and works on macOS 14.2 and later, below Orra's minimum of 15.6.
///
/// The tap feeds a private aggregate device, whose input Orra reads like a microphone.
/// macOS asks for the permission when that device starts. There is no public way to read
/// the permission, and when it is refused the tap delivers silence, which MeetingCaptions
/// watches for.
///
/// The IO block runs on Core Audio's real time thread and only copies the tap's frames
/// into an AudioFrameRing. A timer on `queue` takes them out, converts them to 16 kHz
/// mono and hands on the chunks.
nonisolated final class SystemAudioTap: @unchecked Sendable {
    /// The key macOS needs in Info.plist before an app may capture system audio.
    static let usageDescriptionKey = "NSAudioCaptureUsageDescription"

    /// Whether this build carries the usage description. Without it macOS does not let
    /// the app capture, so Orra does not try.
    static var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: usageDescriptionKey) != nil
    }

    /// How often the frames are taken out of the ring and converted.
    static let drainInterval = DispatchTimeInterval.milliseconds(20)
    /// Seconds of the tap's frames the ring holds, far more than one drain needs.
    static let ringSeconds = 2.0

    private let lock = OSAllocatedUnfairLock()
    /// Converts and hands on the chunks. Serial, so they stay in order.
    private let queue = DispatchQueue(label: "io.github.db-ol.Orra.system-audio", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private var writer: TapWriter?

    deinit {
        stop()
    }

    func start(deliver: @escaping @Sendable ([Float]) -> Void) throws {
        stop()
        guard Self.isConfigured else { throw SystemAudioProblem.notConfigured }
        let own = Self.ownProcess()
        if own == nil {
            // Then Orra's own sounds, such as the start and stop sounds, can be captioned.
            Logger.captions.notice("System audio capture could not find Orra's own process to leave it out")
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Orra Meeting Captions"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "create the tap")
        let createdTap = tap
        lock.withLock { tapID = createdTap }
        do {
            var format = try Self.read(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            guard let tapFormat = AVAudioFormat(streamDescription: &format),
                  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(RecordingLimits.sampleRate), channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: tapFormat, to: target),
                  format.mBytesPerFrame > 0 else {
                throw SystemAudioProblem.failed(step: "read the tap format", status: 0)
            }
            // The average of the channels, which is what was played, not the left one.
            converter.downmix = true
            let output = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Orra Meeting Captions",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the aggregate device")
            let createdDevice = device
            lock.withLock { aggregateID = createdDevice }
            let tapBuffers = tapFormat.isInterleaved ? 1 : Int(tapFormat.channelCount)
            let ring = AudioFrameRing(
                planes: tapBuffers,
                bytesPerFrame: Int(format.mBytesPerFrame),
                capacity: Int(tapFormat.sampleRate * Self.ringSeconds)
            )
            let writer = TapWriter(ring: ring)
            let chunker = Chunker(writer: writer, converter: converter, input: tapFormat, output: target, deliver: deliver)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval, leeway: .milliseconds(5))
            timer.setEventHandler { chunker.drain() }
            lock.withLock {
                self.timer = timer
                self.writer = writer
            }
            timer.resume()
            var proc: AudioDeviceIOProcID?
            // No queue: the block runs on the real time IO thread itself, and the buffers
            // are valid only until it returns. It only copies them into the ring.
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
                writer.write(input)
            }, "create the IO block")
            let createdProc = proc
            lock.withLock { procID = createdProc }
            // The start can wait for the permission prompt, and with tap auto start until
            // an app plays something, so the tap's format is in the log before it too.
            Logger.captions.notice("System audio capture is starting its device, the tap at \(tapFormat.sampleRate, privacy: .public) Hz with \(tapFormat.channelCount, privacy: .public) channels")
            try Self.check(AudioDeviceStart(device, proc), "start the device")
            Logger.captions.notice("System audio capture started at \(tapFormat.sampleRate, privacy: .public) Hz with \(tapFormat.channelCount, privacy: .public) channels")
        } catch {
            stop()
            throw error
        }
    }

    /// Stops the capture and removes the device and the tap. Safe to call when nothing
    /// runs.
    func stop() {
        let (tap, device, proc, timer, writer) = lock.withLock {
            let ids = (tapID, aggregateID, procID, self.timer, self.writer)
            tapID = AudioObjectID(kAudioObjectUnknown)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            procID = nil
            self.timer = nil
            self.writer = nil
            return ids
        }
        if device != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(device, proc)
                // Waits for a block under way on the IO thread.
                AudioDeviceDestroyIOProcID(device, proc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        timer?.cancel()
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            if let dropped = writer?.ring.dropped, dropped > 0 {
                Logger.captions.notice("System audio capture dropped \(dropped, privacy: .public) frames while converting fell behind")
            }
            Logger.captions.notice("System audio capture stopped")
        }
        // Waits for a conversion under way, so no samples come after stop returns.
        queue.sync {}
    }

    /// Orra's own process as a Core Audio object, to leave out of the tap.
    private static func ownProcess() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() throws -> String {
        let device = try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(kAudioObjectUnknown))
        // Core Audio hands out a retained string.
        let uid = try read(device, kAudioDevicePropertyDeviceUID, Unmanaged<CFString>?.none)
        guard let uid else { throw SystemAudioProblem.failed(step: "read the output device", status: 0) }
        return uid.takeRetainedValue() as String
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }, "read property \(selector)")
        return value
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            Logger.captions.error("System audio capture could not \(step, privacy: .public): \(status, privacy: .public)")
            throw SystemAudioProblem.failed(step: step, status: status)
        }
    }
}

/// The IO block's side: copies the tap's buffers into the ring. Runs on Core Audio's real
/// time thread, so it allocates nothing, takes no lock and does not log. Internal for
/// tests.
nonisolated final class TapWriter: Sendable {
    let ring: AudioFrameRing
    /// How many input buffers the device last gave, for Chunker to log once.
    let seenBuffers = Atomic<Int>(0)

    init(ring: AudioFrameRing) {
        self.ring = ring
    }

    /// The aggregate device lists the output device too, and when that device has inputs
    /// of its own, such as the microphone of a headset, their streams come first and the
    /// tap's stream last. Only the last `ring.planes` buffers are read.
    func write(_ list: UnsafePointer<AudioBufferList>) {
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let count = all.count
        seenBuffers.store(count, ordering: .relaxed)
        let planes = ring.planes
        guard count >= planes else { return }
        let first = count - planes
        var frames = Int.max
        for index in first..<count {
            frames = min(frames, Int(all[index].mDataByteSize) / ring.bytesPerFrame)
        }
        ring.write(frames: frames) { plane in
            UnsafeRawPointer(all[first + plane].mData)
        }
    }
}

/// Takes the tap's frames out of the ring, converts them to 16 kHz mono and hands them
/// on in chunks of about 100 ms. Used on the capture queue only. Internal for tests.
nonisolated final class Chunker: @unchecked Sendable {
    private let writer: TapWriter
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let deliver: @Sendable ([Float]) -> Void
    private var collected: [Float] = []
    private let chunk = RecordingLimits.sampleRate / 10
    /// The frames taken from the ring for one conversion, reused.
    private let taken: AVAudioPCMBuffer?
    /// The converted samples of one conversion, reused.
    private let converted: AVAudioPCMBuffer?
    private var reportedLayout = false
    private static let framesPerConversion: AVAudioFrameCount = 4_096

    init(writer: TapWriter, converter: AVAudioConverter, input: AVAudioFormat, output: AVAudioFormat, deliver: @escaping @Sendable ([Float]) -> Void) {
        self.writer = writer
        self.converter = converter
        self.output = output
        self.deliver = deliver
        taken = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: Self.framesPerConversion)
        let capacity = AVAudioFrameCount((Double(Self.framesPerConversion) * output.sampleRate / input.sampleRate).rounded(.up)) + 64
        converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
        collected.reserveCapacity(chunk * 2)
    }

    /// Converts every frame waiting in the ring.
    func drain() {
        reportLayout()
        guard let taken else { return }
        let planes = UnsafeMutableAudioBufferListPointer(taken.mutableAudioBufferList)
        while true {
            let frames = writer.ring.read(maxFrames: Int(taken.frameCapacity)) { plane in
                // AVAudioPCMBuffer allocates every plane up front.
                planes[plane].mData!
            }
            guard frames > 0 else { return }
            taken.frameLength = AVAudioFrameCount(frames)
            convert(taken)
        }
    }

    private func reportLayout() {
        guard !reportedLayout else { return }
        let seen = writer.seenBuffers.load(ordering: .relaxed)
        guard seen > 0 else { return }
        reportedLayout = true
        if seen != writer.ring.planes {
            Logger.captions.notice("System audio capture gets \(seen, privacy: .public) input buffers and reads the last \(self.writer.ring.planes, privacy: .public)")
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converted else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                // More comes with the next frames, so the converter keeps its state.
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = converted.floatChannelData?[0] else { return }
        collected.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        if collected.count >= chunk {
            deliver(collected)
            collected = []
            collected.reserveCapacity(chunk * 2)
        }
    }
}
