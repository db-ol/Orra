import Foundation
import Testing
@testable import Orra

/// Where the spoken translation goes, and its saved settings.
struct AudioOutputTests {
    static let speakers = AudioOutput(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    static let orraMicrophone = AudioOutput(id: 2, uid: "io.github.db-ol.Orra.Microphone", name: "Orra Microphone")
    static let loopback = AudioOutput(id: 3, uid: "loopback-uid", name: "Loopback Audio")

    /// Orra Microphone is found by the UID and the name its driver publishes, the UID first.
    @Test func orraMicrophoneIsFoundByUIDThenName() {
        let renamed = AudioOutput(id: 4, uid: "io.github.db-ol.Orra.Microphone", name: "Renamed by the user")
        let sameName = AudioOutput(id: 5, uid: "other-uid", name: "Orra Microphone")
        #expect(AudioOutput.orraMicrophone(in: [Self.speakers, Self.orraMicrophone]) == Self.orraMicrophone)
        #expect(AudioOutput.orraMicrophone(in: [sameName, renamed]) == renamed)
        #expect(AudioOutput.orraMicrophone(in: [Self.speakers, sameName]) == sameName)
        #expect(AudioOutput.orraMicrophone(in: [Self.speakers, Self.loopback]) == nil)
        // The names of an earlier draft of the driver are not Orra's device.
        #expect(AudioOutput.orraMicrophone(in: [AudioOutput(id: 6, uid: "OrraVoice_UID", name: "Orra Voice")]) == nil)
    }

    /// The app looks for exactly what the driver publishes, see kOrraDeviceUID and
    /// kOrraDeviceName in Drivers/OrraMicrophone/OrraMicrophone.c.
    @Test func theNamesMatchTheDriver() {
        #expect(AudioOutput.orraMicrophoneUID == "io.github.db-ol.Orra.Microphone")
        #expect(AudioOutput.orraMicrophoneName == "Orra Microphone")
    }

    /// Without a choice the voice goes to Orra Microphone, and without it nowhere: never
    /// to the speakers by surprise.
    @Test func withoutAChoiceOnlyOrraMicrophoneIsUsed() {
        #expect(SpeechOutputChoice.resolve(nil, outputs: [Self.speakers, Self.orraMicrophone, Self.loopback]) == Self.orraMicrophone)
        #expect(SpeechOutputChoice.resolve(nil, outputs: [Self.speakers, Self.loopback]) == nil)
        #expect(SpeechOutputChoice.resolve(nil, outputs: []) == nil)
    }

    /// A chosen device is used while it is connected, by UID, and nothing stands in for it
    /// while it is gone.
    @Test func aChosenDeviceIsUsedOnlyWhileConnected() {
        let loopback = SpeechOutputChoice(uid: "loopback-uid", name: "Loopback Audio")
        let moved = AudioOutput(id: 9, uid: "loopback-uid", name: "Loopback Audio")
        #expect(SpeechOutputChoice.resolve(loopback, outputs: [Self.speakers, Self.orraMicrophone, moved]) == moved)
        #expect(SpeechOutputChoice.resolve(loopback, outputs: [Self.speakers, Self.orraMicrophone]) == nil)
    }

    /// The Speak into list follows the devices while it is shown: a device plugged in or
    /// unplugged then shows at once, and nothing is watched once Settings closes.
    @MainActor @Test func theListFollowsDeviceChangesWhileShown() {
        final class Token {}
        var connected = [Self.speakers]
        var onChange: (@MainActor () -> Void)?
        weak var token: Token?
        let list = AudioOutputList(read: { connected }, watch: { handler in
            onChange = handler
            let made = Token()
            token = made
            return made
        })
        #expect(list.outputs.isEmpty)
        #expect(!list.isWatching)

        list.start()
        #expect(list.outputs == [Self.speakers])
        #expect(list.isWatching)

        connected = [Self.speakers, Self.orraMicrophone]
        onChange?()
        #expect(list.outputs == [Self.speakers, Self.orraMicrophone])

        connected = [Self.orraMicrophone]
        onChange?()
        #expect(list.outputs == [Self.orraMicrophone])

        list.stop()
        #expect(!list.isWatching)
        #expect(token == nil)
    }

    /// Starting twice keeps one watch.
    @MainActor @Test func startingTwiceWatchesOnce() {
        var watches = 0
        let list = AudioOutputList(read: { [Self.speakers] }, watch: { _ in
            watches += 1
            return NSObject()
        })
        list.start()
        list.start()
        #expect(watches == 1)
        list.stop()
        list.start()
        #expect(watches == 2)
    }

    /// The live watch registers with Core Audio on this Mac and is removed when released.
    @MainActor @Test func theLiveWatchRegisters() {
        var watch = DeviceListWatch(onChange: {})
        #expect(watch != nil)
        watch = nil
        #expect(watch == nil)
    }

    /// Reading the devices of this Mac needs no permission and gives devices with output
    /// channels only.
    @Test func theMacsOutputsHaveOutputChannels() {
        for output in AudioOutput.all() {
            #expect(AudioOutput.outputChannelCount(output.id) > 0)
            #expect(!output.uid.isEmpty)
        }
    }
}
