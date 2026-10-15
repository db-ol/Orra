// Plays an audio file to one output device, found by name, without changing the default device.
// say lists only devices that can be the default output, and the output side of Orra
// Microphone never can, so a quick test plays to it with this instead.
// Usage: swift Tests/play_to_device.swift "Orra Microphone" hello.aiff
import AVFoundation
import CoreAudio

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: play_to_device.swift <device name> <audio file>"); exit(2) }

func devices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    return ids
}

func name(of device: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
    return value.takeRetainedValue() as String
}

guard var device = devices().first(where: { name(of: $0) == args[1] }) else { print("no device named \(args[1])"); exit(1) }
let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
let engine = AVAudioEngine()
// Pick the device before anything is connected, so the engine builds its graph for it.
let status = AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
guard status == noErr else { print("could not pick the device: \(status)"); exit(1) }
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
engine.prepare()
let done = DispatchSemaphore(value: 0)
// The default callback fires once the player has read the file, which is before the end
// is heard. Wait until it has been played back, then a little longer for the device.
player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in done.signal() }
try engine.start()
// The device needs a moment to run its first IO cycle, and play() throws before that.
Thread.sleep(forTimeInterval: 0.2)
player.play()
done.wait()
Thread.sleep(forTimeInterval: 1.0)
print("played \(file.duration) s to \(args[1])")
extension AVAudioFile { var duration: Double { Double(length) / fileFormat.sampleRate } }
