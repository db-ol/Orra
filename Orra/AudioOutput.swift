import CoreAudio
import Foundation
import Observation

/// An output device, read through Core Audio, that the spoken translation can play into.
/// Reading needs no permission.
nonisolated struct AudioOutput: Equatable, Sendable {
    /// Valid while the device stays connected, see AudioInput.id.
    var id: AudioDeviceID
    /// Core Audio's persistent identifier of the device.
    var uid: String
    var name: String

    /// The UID of Orra's own microphone device, an Audio Server plug in with an output
    /// side Orra plays into and an input side a meeting app records from. Built and
    /// installed separately, see Drivers/OrraMicrophone. Must stay the same as
    /// kOrraDeviceUID in OrraMicrophone.c.
    static let orraMicrophoneUID = "io.github.db-ol.Orra.Microphone"
    /// The name the driver gives that device, kOrraDeviceName in OrraMicrophone.c.
    static let orraMicrophoneName = "Orra Microphone"

    /// Orra's own microphone device among `outputs`: the one with its UID, else the one
    /// with its name, nil when it is not installed.
    static func orraMicrophone(in outputs: [AudioOutput]) -> AudioOutput? {
        outputs.first { $0.uid == orraMicrophoneUID } ?? outputs.first { $0.name == orraMicrophoneName }
    }

    /// Every output Orra offers, in the order Core Audio lists them.
    static func all() -> [AudioOutput] {
        AudioInput.deviceIDs().compactMap { device(id: $0) }
    }

    /// The output with this ID, or nil for a device without output channels, one that is
    /// gone or hidden, and the private aggregate devices AVAudioEngine makes inside Orra.
    static func device(id: AudioDeviceID) -> AudioOutput? {
        guard outputChannelCount(id) > 0,
              AudioInput.readUInt32(id, kAudioDevicePropertyDeviceIsAlive) != 0,
              AudioInput.readUInt32(id, kAudioDevicePropertyIsHidden) != 1,
              let uid = AudioInput.readString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let transport = AudioInput.readUInt32(id, kAudioDevicePropertyTransportType) ?? 0
        guard !AudioInput.isPrivateAggregate(uid: uid, transport: transport, composition: nil) else { return nil }
        return AudioOutput(id: id, uid: uid, name: AudioInput.readString(id, kAudioObjectPropertyName) ?? uid)
    }

    /// The connected output with this UID, looked up each time Orra speaks, since IDs
    /// change when devices reconnect.
    static func device(uid: String) -> AudioOutput? {
        all().first { $0.uid == uid }
    }

    /// The output channels of all the device's output streams together.
    static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioInput.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let byteCount = max(Int(size), MemoryLayout<AudioBufferList>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// The output devices for the Speak into list in Settings. Read when Settings shows the
/// list, and again each time Core Audio adds or removes a device while it does, so a
/// device plugged in later shows up without reopening Settings. The reading and the
/// watching are closures, so tests never depend on this Mac's devices.
@Observable
final class AudioOutputList {
    private(set) var outputs: [AudioOutput] = []

    @ObservationIgnored private let read: () -> [AudioOutput]
    @ObservationIgnored private let watch: (@escaping @MainActor () -> Void) -> AnyObject?
    /// Keeps the watch alive while the list is shown. Releasing it stops the watch.
    @ObservationIgnored private var watching: AnyObject?

    /// - Parameters:
    ///   - read: The outputs connected now.
    ///   - watch: Starts calling its argument on the main actor whenever the devices
    ///     change, until the object it returns is released.
    init(read: @escaping () -> [AudioOutput], watch: @escaping (@escaping @MainActor () -> Void) -> AnyObject?) {
        self.read = read
        self.watch = watch
    }

    static func live() -> AudioOutputList {
        AudioOutputList(read: { AudioOutput.all() }, watch: { DeviceListWatch(onChange: $0) })
    }

    /// Whether the devices are being watched. Internal for tests.
    var isWatching: Bool {
        watching != nil
    }

    /// Reads the outputs and keeps them current until `stop`.
    func start() {
        refresh()
        guard watching == nil else { return }
        watching = watch { [weak self] in
            self?.refresh()
        }
    }

    func stop() {
        watching = nil
    }

    func refresh() {
        let now = read()
        if now != outputs {
            outputs = now
        }
    }
}

/// Calls back on the main queue whenever Core Audio's list of devices changes, until it is
/// released. Registered and removed through the same C function references as DeviceWatch,
/// so the removal matches the block that was added.
nonisolated final class DeviceListWatch {
    typealias Listener = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    private typealias Registration = @convention(c) (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, DispatchQueue?, @escaping Listener) -> OSStatus
    private static let addListener: Registration = AudioObjectAddPropertyListenerBlock
    private static let removeListener: Registration = AudioObjectRemovePropertyListenerBlock

    private let listener: Listener

    /// Nil when Core Audio refuses the listener.
    init?(onChange: @escaping @MainActor () -> Void) {
        listener = { _, _ in
            MainActor.assumeIsolated {
                onChange()
            }
        }
        var address = AudioInput.address(kAudioHardwarePropertyDevices)
        guard Self.addListener(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else {
            return nil
        }
    }

    deinit {
        var address = AudioInput.address(kAudioHardwarePropertyDevices)
        _ = Self.removeListener(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
}

/// The output the user picked for the spoken translation, remembered by UID like the
/// microphone, with the name kept for the menu while the device is gone.
nonisolated struct SpeechOutputChoice: Equatable, Sendable {
    var uid: String
    var name: String

    /// Where the spoken translation goes now, or nil for nowhere. A chosen device that is
    /// connected. Without a choice, Orra's own microphone device when it is installed.
    /// Never the speakers on its own: the voice is meant for the other side of a call, and
    /// a translation played out loud by surprise is worse than none.
    static func resolve(_ choice: SpeechOutputChoice?, outputs: [AudioOutput]) -> AudioOutput? {
        if let choice {
            return outputs.first { $0.uid == choice.uid }
        }
        return AudioOutput.orraMicrophone(in: outputs)
    }
}

/// Keeps the speak translation settings in UserDefaults. Never the voice sample.
nonisolated enum SpeechPreference {
    static let isOnKey = "speakTranslation"
    static let alsoPastesKey = "speakTranslationAlsoPastes"
    static let outputUIDKey = "speakTranslationOutputUID"
    static let outputNameKey = "speakTranslationOutputName"

    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: isOnKey)
    }

    static func saveIsOn(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: isOnKey)
    }

    /// True unless the user turned it off: the text is pasted as well as spoken.
    static func alsoPastes(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: alsoPastesKey) == nil ? true : defaults.bool(forKey: alsoPastesKey)
    }

    static func saveAlsoPastes(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: alsoPastesKey)
    }

    static func output(in defaults: UserDefaults = .standard) -> SpeechOutputChoice? {
        guard let uid = defaults.string(forKey: outputUIDKey), !uid.isEmpty else { return nil }
        return SpeechOutputChoice(uid: uid, name: defaults.string(forKey: outputNameKey) ?? uid)
    }

    static func saveOutput(_ choice: SpeechOutputChoice?, to defaults: UserDefaults = .standard) {
        if let choice {
            defaults.set(choice.uid, forKey: outputUIDKey)
            defaults.set(choice.name, forKey: outputNameKey)
        } else {
            defaults.removeObject(forKey: outputUIDKey)
            defaults.removeObject(forKey: outputNameKey)
        }
    }
}
