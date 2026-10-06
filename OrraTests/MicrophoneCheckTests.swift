import CoreAudio
import Foundation
import Testing
@testable import Orra

struct MicrophoneCheckTests {
    @Test func zerosAndNearZerosAreSilent() {
        #expect(Silence.isSilent([Float](repeating: 0, count: 16_000)))
        #expect(Silence.isSilent([Float](repeating: 0.000_001, count: 100)))
        #expect(!Silence.isSilent([0, 0, 0.000_1, 0]))
        #expect(!Silence.isSilent([0, -0.5, 0]))
    }

    /// The threshold must never take real speech for a dead microphone. The quietest set,
    /// fleurs_en, goes down to about -69.5 dBFS RMS.
    @Test(.enabled(if: EvaluationData.isAvailable))
    func noEvaluationClipIsSilent() throws {
        for set in ["fleurs_zh", "fleurs_en", "ascend_mixed"] {
            for clip in try EvaluationData.clips(in: set, count: 1_000) {
                let samples = try EvaluationData.samples(set: set, name: clip.name)
                #expect(!Silence.isSilent(samples), "\(set) \(clip.name) read as silent")
            }
        }
    }

    @Test func theAdviceNamesTheLidOnlyForTheBuiltInMicrophone() {
        let builtIn = AudioInput(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isInternalMicrophone: true)
        let webcam = AudioInput(id: 2, uid: "brio-uid", name: "Brio 500", isInternalMicrophone: false)
        let lid = "The lid is closed, so the built in microphone is off"
        #expect(Silence.advice(for: MicrophoneSituation(lidClosed: true, input: builtIn)) == lid)
        #expect(Silence.advice(for: MicrophoneSituation(lidClosed: true, input: nil)) == lid)
        #expect(Silence.advice(for: MicrophoneSituation(lidClosed: true, input: webcam)) == "No sound came from Brio 500")
        #expect(Silence.advice(for: MicrophoneSituation(lidClosed: false, input: builtIn)) == "No sound came from MacBook Pro Microphone")
        #expect(Silence.advice(for: MicrophoneSituation(lidClosed: false, input: nil)) == "No sound came from the microphone")
    }

    @Test func theDefaultInputAndTheLidCanBeRead() {
        // Reads Core Audio and the IOKit registry only. Records nothing and needs no
        // permission.
        _ = Lid.isClosed()
        guard let input = AudioInput.systemDefault() else { return }
        #expect(!input.name.isEmpty)
        #expect(!input.uid.isEmpty)
        #expect(AudioInput.defaultDeviceID() == input.id)
    }

    @Test func theInputListHoldsTheDefaultAndNoPrivateDevices() {
        // Reads this Mac's devices. Records nothing.
        let inputs = AudioInput.all()
        if let defaultInput = AudioInput.systemDefault() {
            #expect(inputs.contains(defaultInput))
        }
        #expect(Set(inputs.map(\.uid)).count == inputs.count)
        #expect(inputs.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
        #expect(inputs.allSatisfy { AudioInput.inputChannelCount($0.id) > 0 && AudioInput.isAlive($0.id) })
        #expect(!inputs.contains { $0.uid.contains("CADefaultDeviceAggregate") || $0.uid.contains("VPAUAggregateAudioDevice") })
        #expect(inputs.filter(\.isInternalMicrophone).count <= 1)
    }

    @Test func everyListedInputIsFoundAgainByItsUID() {
        for input in AudioInput.all() {
            #expect(AudioInput.device(uid: input.uid) == input)
        }
        #expect(AudioInput.device(uid: "io.github.db-ol.OrraTests.no-such-device") == nil)
        #expect(AudioInput.device(uid: "") == nil)
    }

    @Test func privateAggregatesAreLeftOut() {
        let aggregate = kAudioDeviceTransportTypeAggregate
        let on: [String: Any] = [kAudioAggregateDeviceIsPrivateKey: NSNumber(value: 1)]
        let onAsBoolean: [String: Any] = [kAudioAggregateDeviceIsPrivateKey: NSNumber(value: true)]
        let off: [String: Any] = [kAudioAggregateDeviceIsPrivateKey: NSNumber(value: 0)]
        // The ones AVAudioEngine and voice processing make, known by their UIDs.
        #expect(AudioInput.isPrivateAggregate(uid: "CADefaultDeviceAggregate-31286-0", transport: aggregate, composition: nil))
        #expect(AudioInput.isPrivateAggregate(uid: "VPAUAggregateAudioDevice-0x6000", transport: 0, composition: nil))
        // Others by their composition.
        #expect(AudioInput.isPrivateAggregate(uid: "aggregate-1", transport: aggregate, composition: on))
        #expect(AudioInput.isPrivateAggregate(uid: "aggregate-2", transport: kAudioDeviceTransportTypeAutoAggregate, composition: onAsBoolean))
        // Public ones, as Audio MIDI Setup makes them, stay.
        #expect(!AudioInput.isPrivateAggregate(uid: "aggregate-3", transport: aggregate, composition: off))
        #expect(!AudioInput.isPrivateAggregate(uid: "aggregate-4", transport: aggregate, composition: [:]))
        #expect(!AudioInput.isPrivateAggregate(uid: "aggregate-5", transport: aggregate, composition: nil))
        // A device that is not an aggregate stays, whatever its properties say.
        #expect(!AudioInput.isPrivateAggregate(uid: "AppleUSBAudioEngine:Brio 500", transport: kAudioDeviceTransportTypeUSB, composition: on))
    }

    @Test func theInternalMicrophoneIsToldApartFromAHeadset() {
        let builtIn = kAudioDeviceTransportTypeBuiltIn
        let internalSource = AudioInput.internalMicrophoneSource
        // 'emic', the data source of a microphone in the audio jack.
        let externalSource: UInt32 = 0x656D_6963
        #expect(AudioInput.isInternalMicrophone(transport: builtIn, dataSource: internalSource, uid: "BuiltInMicrophoneDevice"))
        #expect(!AudioInput.isInternalMicrophone(transport: builtIn, dataSource: externalSource, uid: "BuiltInHeadphoneInputDevice"))
        // The data source decides when there is one.
        #expect(!AudioInput.isInternalMicrophone(transport: builtIn, dataSource: externalSource, uid: "BuiltInMicrophoneDevice"))
        // Without one, the UID does.
        #expect(AudioInput.isInternalMicrophone(transport: builtIn, dataSource: nil, uid: "BuiltInMicrophoneDevice"))
        #expect(!AudioInput.isInternalMicrophone(transport: builtIn, dataSource: nil, uid: "BuiltInHeadphoneInputDevice"))
        #expect(!AudioInput.isInternalMicrophone(transport: kAudioDeviceTransportTypeUSB, dataSource: internalSource, uid: "BuiltInMicrophoneDevice"))
    }

    @Test func transportsReadAsText() {
        #expect(AudioInput.fourCC(kAudioDeviceTransportTypeUSB) == "usb ")
        #expect(AudioInput.fourCC(kAudioDeviceTransportTypeBuiltIn) == "bltn")
        #expect(AudioInput.fourCC(AudioInput.internalMicrophoneSource) == "imic")
        #expect(AudioInput.fourCC(0) == "0")
    }
}
