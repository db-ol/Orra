import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import Orra

struct InputUnitTests {
    @Test func theClientFormatIsFloatMonoAtTheDeviceRate() throws {
        let format = try #require(InputUnit.clientFormat(sampleRate: 48_000))
        #expect(format.mSampleRate == 48_000)
        #expect(format.mFormatID == kAudioFormatLinearPCM)
        #expect(format.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        #expect(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
        #expect(format.mChannelsPerFrame == 1)
        #expect(format.mBitsPerChannel == 32)
        #expect(format.mBytesPerFrame == 4)
        #expect(format.mBytesPerPacket == 4)
        #expect(format.mFramesPerPacket == 1)
    }

    @Test func ratesThatCannotBeRecordedAreRefused() {
        for rate in [0, -48_000, .nan, .infinity, 1_000, 1_000_000] as [Double] {
            #expect(InputUnit.clientFormat(sampleRate: rate) == nil, "\(rate)")
        }
        #expect(InputUnit.clientFormat(sampleRate: 16_000) != nil)
        #expect(InputUnit.clientFormat(sampleRate: 44_100) != nil)
    }

    @Test func theCaptureBufferKeepsWhatFitsInOrder() {
        let buffer = CaptureBuffer(capacity: 5)
        #expect(buffer.samples().isEmpty)
        let first: [Float] = [1, 2, 3]
        let second: [Float] = [4, 5, 6, 7]
        first.withUnsafeBufferPointer { buffer.append($0.baseAddress!, count: $0.count) }
        second.withUnsafeBufferPointer { buffer.append($0.baseAddress!, count: $0.count) }
        #expect(buffer.samples() == [1, 2, 3, 4, 5])
        // Full, so more is dropped.
        first.withUnsafeBufferPointer { buffer.append($0.baseAddress!, count: $0.count) }
        #expect(buffer.samples() == [1, 2, 3, 4, 5])
    }

    @Test func anEmptyCaptureBufferDropsEverything() {
        let buffer = CaptureBuffer(capacity: 0)
        let samples: [Float] = [1, 2]
        samples.withUnsafeBufferPointer { buffer.append($0.baseAddress!, count: $0.count) }
        #expect(buffer.samples().isEmpty)
    }

    @Test func theInterruptionFlagStaysSet() {
        let flag = InterruptionFlag()
        #expect(!flag.isSet)
        flag.set()
        flag.set()
        #expect(flag.isSet)
    }

    /// Builds and initializes a unit for each wired input of this Mac, the built in
    /// microphone and USB devices, and stops it without ever starting it. Nothing is
    /// recorded and the microphone indicator stays off. Wireless inputs such as an iPhone
    /// or AirPods are left alone, so the test never wakes them.
    @Test func aUnitCanBeSetUpForEveryWiredInputWithoutRecording() throws {
        let wired = AudioInput.all().filter {
            $0.transport == kAudioDeviceTransportTypeBuiltIn || $0.transport == kAudioDeviceTransportTypeUSB
        }
        var setUp: [String] = []
        for input in wired {
            let unit = try InputUnit(device: input, maximumSeconds: 1)
            #expect(unit.sampleRate >= 8_000, "\(AudioInput.fourCC(input.transport))")
            #expect(unit.device == input)
            let result = unit.stop()
            #expect(result.samples.isEmpty)
            #expect(!result.interrupted)
            #expect(result.lostCallbacks == 0)
            // Stopping twice is harmless.
            #expect(unit.stop().samples.isEmpty)
            setUp.append("\(AudioInput.fourCC(input.transport)) \(AudioInput.inputChannelCount(input.id)) ch \(Int(unit.sampleRate)) Hz")
        }
        // Which kinds of device were set up, without names, so a run shows what it covered.
        Attachment.record(setUp.joined(separator: "\n"), named: "wired-inputs.txt")
    }

    /// A released watch removes its listeners, so Core Audio lets go of the block and what
    /// it holds. Adds and removes listeners only, records nothing.
    @Test func aReleasedDeviceWatchRemovesItsListeners() throws {
        guard let input = AudioInput.systemDefault() ?? AudioInput.all().first else { return }
        weak var releasedFlag: InterruptionFlag?
        do {
            let flag = InterruptionFlag()
            releasedFlag = flag
            let watch = DeviceWatch(device: input.id, sampleRate: 48_000, flag: flag)
            withExtendedLifetime(watch) {}
        }
        #expect(releasedFlag == nil)
    }

    @Test func aDeviceThatIsGoneCannotBeBound() {
        let gone = AudioInput(id: 0x7FFF_FFF0, uid: "io.github.db-ol.OrraTests.gone", name: "Gone", isInternalMicrophone: false)
        #expect(throws: AudioRecorderError.self) {
            _ = try InputUnit(device: gone, maximumSeconds: 1)
        }
    }
}
