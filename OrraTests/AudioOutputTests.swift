import Foundation
import Testing
@testable import Orra

/// Where the spoken translation goes, and its saved settings.
struct AudioOutputTests {
    static let speakers = AudioOutput(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    static let orraVoice = AudioOutput(id: 2, uid: "OrraVoice_UID", name: "Orra Voice")
    static let loopback = AudioOutput(id: 3, uid: "loopback-uid", name: "Loopback Audio")

    @Test func orraVoiceIsFoundByNameOrUID() {
        #expect(Self.orraVoice.isOrraVoice)
        #expect(AudioOutput(id: 4, uid: "io.github.db-ol.OrraVoice.device", name: "Something").isOrraVoice)
        #expect(!Self.speakers.isOrraVoice)
        #expect(!Self.loopback.isOrraVoice)
    }

    /// Without a choice the voice goes to Orra Voice, and without Orra Voice nowhere: never
    /// to the speakers by surprise.
    @Test func withoutAChoiceOnlyOrraVoiceIsUsed() {
        #expect(SpeechOutputChoice.resolve(nil, outputs: [Self.speakers, Self.orraVoice, Self.loopback]) == Self.orraVoice)
        #expect(SpeechOutputChoice.resolve(nil, outputs: [Self.speakers, Self.loopback]) == nil)
        #expect(SpeechOutputChoice.resolve(nil, outputs: []) == nil)
    }

    /// A chosen device is used while it is connected, by UID, and nothing stands in for it
    /// while it is gone.
    @Test func aChosenDeviceIsUsedOnlyWhileConnected() {
        let loopback = SpeechOutputChoice(uid: "loopback-uid", name: "Loopback Audio")
        let moved = AudioOutput(id: 9, uid: "loopback-uid", name: "Loopback Audio")
        #expect(SpeechOutputChoice.resolve(loopback, outputs: [Self.speakers, Self.orraVoice, moved]) == moved)
        #expect(SpeechOutputChoice.resolve(loopback, outputs: [Self.speakers, Self.orraVoice]) == nil)
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
