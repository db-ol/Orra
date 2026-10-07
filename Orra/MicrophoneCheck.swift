import CoreAudio
import Foundation
import IOKit

/// An input device, read through Core Audio. Reading needs no permission and records
/// nothing.
nonisolated struct AudioInput: Equatable, Sendable {
    /// Valid while the device stays connected. A device that comes back gets a new ID, and
    /// an old ID can later name another device, so Orra remembers `uid` instead.
    var id: AudioDeviceID
    /// Core Audio's persistent identifier of the device.
    var uid: String
    var name: String
    /// True for the microphone inside the Mac, which a MacBook turns off while its lid is
    /// closed. A headset in the Mac's audio jack is built in hardware too, but not this.
    var isInternalMicrophone: Bool
    /// How the device is connected, such as 'usb ' or 'bltn'. Logged, never shown.
    var transport: UInt32 = 0

    /// The data source of a Mac's internal microphone, 'imic'.
    static let internalMicrophoneSource: UInt32 = 0x696D_6963

    /// The system's default input device.
    static func systemDefault() -> AudioInput? {
        defaultDeviceID().flatMap { device(id: $0) }
    }

    static func defaultDeviceID() -> AudioDeviceID? {
        guard let id = readUInt32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Every input Orra offers, in the order Core Audio lists them. `device(id:)` says
    /// which devices are left out.
    static func all() -> [AudioInput] {
        deviceIDs().compactMap { device(id: $0) }
    }

    /// The connected input with this UID, or nil when it is not connected or is a device
    /// Orra does not offer. Looked up at each hold, because IDs change when devices
    /// reconnect.
    static func device(uid: String) -> AudioInput? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        // For a UID that no device has, Core Audio answers kAudioObjectUnknown without an
        // error.
        let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return device(id: id)
    }

    /// The input with this ID, or nil for a device Orra does not offer: one without input
    /// channels, one that is gone or hidden, one that cannot be the default input, such as
    /// a loopback device for screen sharing, and the private aggregate devices that
    /// AVAudioEngine makes inside Orra for its own use.
    static func device(id: AudioDeviceID) -> AudioInput? {
        guard inputChannelCount(id) > 0,
              readUInt32(id, kAudioDevicePropertyDeviceIsAlive) != 0,
              readUInt32(id, kAudioDevicePropertyIsHidden) != 1,
              readUInt32(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeInput) != 0,
              let uid = readString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let transport = readUInt32(id, kAudioDevicePropertyTransportType) ?? 0
        let isAggregate = transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate
        let composition = isAggregate ? readDictionary(id, kAudioAggregateDevicePropertyComposition) as? [String: Any] : nil
        guard !isPrivateAggregate(uid: uid, transport: transport, composition: composition) else { return nil }
        let dataSource = transport == kAudioDeviceTransportTypeBuiltIn
            ? readUInt32(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeInput)
            : nil
        return AudioInput(
            id: id,
            uid: uid,
            name: readString(id, kAudioObjectPropertyName) ?? uid,
            isInternalMicrophone: isInternalMicrophone(transport: transport, dataSource: dataSource, uid: uid),
            transport: transport
        )
    }

    /// False once the device is gone.
    static func isAlive(_ id: AudioDeviceID) -> Bool {
        readUInt32(id, kAudioDevicePropertyDeviceIsAlive) == 1
    }

    /// The rate the device runs at, or nil when it cannot be read.
    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    /// The input channels of all the device's input streams together.
    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        // The list has one AudioBuffer per stream, so its size varies.
        let byteCount = max(Int(size), MemoryLayout<AudioBufferList>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// A four character code as text, such as "usb ", or as a number when it is not
    /// printable.
    static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        guard bytes.allSatisfy({ (0x20..<0x7F).contains($0) }) else { return String(code) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The internal microphone reports the 'imic' input data source, and a headset in the
    /// audio jack 'emic' (IOAudioTypes.h). Without a data source, the UID tells them apart.
    static func isInternalMicrophone(transport: UInt32, dataSource: UInt32?, uid: String) -> Bool {
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        if let dataSource {
            return dataSource == internalMicrophoneSource
        }
        return uid == "BuiltInMicrophoneDevice"
    }

    /// An aggregate device that only its own process sees. AVAudioEngine makes one named
    /// CADefaultDeviceAggregate, and voice processing one named VPAUAggregateAudioDevice.
    /// Other aggregates say so in their composition. Aggregates built in Audio MIDI Setup
    /// are public and stay in the list.
    static func isPrivateAggregate(uid: String, transport: UInt32, composition: [String: Any]?) -> Bool {
        if uid.contains("CADefaultDeviceAggregate") || uid.contains("VPAUAggregateAudioDevice") {
            return true
        }
        guard transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate else {
            return false
        }
        return (composition?[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size)) : []
    }

    private static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Core Audio hands over a retained CFString, which this releases.
    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var string: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &string) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let string else { return nil }
        return string.takeRetainedValue() as String
    }

    /// Core Audio hands over a retained CFDictionary, which this releases.
    private static func readDictionary(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> NSDictionary? {
        var address = address(selector)
        var dictionary: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        let status = withUnsafeMutablePointer(to: &dictionary) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let dictionary else { return nil }
        return dictionary.takeRetainedValue() as NSDictionary
    }
}

/// The lid of a MacBook. A MacBook disconnects its built in microphone while the lid is
/// closed, so with an external display and keyboard the default input can be a microphone
/// that delivers only zeros while the microphone indicator still shows.
nonisolated enum Lid {
    /// True when the lid is closed. False on a Mac without a lid, or when the state cannot
    /// be read. Read from AppleClamshellState of IOPMrootDomain in the IOKit registry,
    /// which `ioreg` showed on this Mac on 2026-10-05. Not a documented interface.
    static func isClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }
}

/// What the menu needs to explain a recording without any sound.
nonisolated struct MicrophoneSituation: Equatable, Sendable {
    var lidClosed: Bool
    /// The input that recorded, as AudioRecorder saw it at the start of the hold.
    var input: AudioInput?
}

/// Tells a recording in which the microphone delivered no sound at all from one that is
/// merely quiet. Such a recording is explained in the menu and never pasted.
nonisolated enum Silence {
    /// About -100 dBFS. A working microphone never stays below this for a whole hold. A
    /// disconnected one, such as a MacBook's with the lid closed, delivers zeros.
    static let threshold: Float = 0.000_01

    /// True when no sample reaches the threshold. Stops at the first sample that does.
    static func isSilent(_ samples: [Float]) -> Bool {
        !samples.contains { abs($0) >= threshold }
    }

    /// One short line for the menu. A closed lid explains silence only from the internal
    /// microphone, or from an input that could not be read.
    static func advice(for situation: MicrophoneSituation) -> String {
        if situation.lidClosed, situation.input?.isInternalMicrophone ?? true {
            return String(localized: "The lid is closed, so the built in microphone is off")
        }
        if let input = situation.input {
            return String(localized: "No sound came from \(input.name)")
        }
        return String(localized: "No sound came from the microphone")
    }
}
