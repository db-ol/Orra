import AVFoundation
import CoreAudio
import os

/// Why the sound the Mac plays cannot be captured.
nonisolated enum SystemAudioProblem: Error, Equatable, Sendable {
    /// The app has no NSAudioCaptureUsageDescription, so macOS would refuse or end it.
    case notConfigured
    /// A Core Audio call failed. The step names it for the log.
    case failed(step: String, status: OSStatus)
}

/// What meeting captions need from the capture of the sound the Mac plays. Closures, so
/// tests pass a fake.
struct SystemAudioSource {
    /// Starts the capture. `deliver` gets 16 kHz mono samples on a background queue, in
    /// order, about every 100 ms.
    var start: (_ deliver: @escaping @Sendable ([Float]) -> Void) throws -> Void
    var stop: () -> Void

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
nonisolated final class SystemAudioTap: @unchecked Sendable {
    /// The key macOS needs in Info.plist before an app may capture system audio.
    static let usageDescriptionKey = "NSAudioCaptureUsageDescription"

    /// Whether this build carries the usage description. Without it macOS does not let
    /// the app capture, so Orra does not try.
    static var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: usageDescriptionKey) != nil
    }

    private let lock = OSAllocatedUnfairLock()
    private let queue = DispatchQueue(label: "io.github.db-ol.Orra.system-audio")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    deinit {
        stop()
    }

    func start(deliver: @escaping @Sendable ([Float]) -> Void) throws {
        stop()
        guard Self.isConfigured else { throw SystemAudioProblem.notConfigured }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcess().map { [$0] } ?? [])
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
                  let converter = AVAudioConverter(from: tapFormat, to: target) else {
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
            let chunker = Chunker(converter: converter, input: tapFormat, output: target, deliver: deliver)
            var proc: AudioDeviceIOProcID?
            // The block runs on `queue`, not the real time thread, so converting there is
            // safe. The buffers are valid until it returns.
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
                chunker.take(input)
            }, "create the IO block")
            let createdProc = proc
            lock.withLock { procID = createdProc }
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
        let (tap, device, proc) = lock.withLock {
            let ids = (tapID, aggregateID, procID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            procID = nil
            return ids
        }
        if device != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(device, proc)
                AudioDeviceDestroyIOProcID(device, proc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            Logger.captions.notice("System audio capture stopped")
        }
        // Waits for a block under way, so no samples come after stop returns.
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

/// Converts the tap's buffers to 16 kHz mono and hands them on in chunks of about 100 ms.
/// Used on the capture queue only.
nonisolated private final class Chunker: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let deliver: @Sendable ([Float]) -> Void
    private var collected: [Float] = []
    private let chunk = RecordingLimits.sampleRate / 10

    init(converter: AVAudioConverter, input: AVAudioFormat, output: AVAudioFormat, deliver: @escaping @Sendable ([Float]) -> Void) {
        self.converter = converter
        self.input = input
        self.output = output
        self.deliver = deliver
    }

    func take(_ list: UnsafePointer<AudioBufferList>) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input, bufferListNoCopy: list, deallocator: nil), buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * output.sampleRate / input.sampleRate).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                // More comes with the next block, so the converter keeps its state.
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
        }
    }
}
