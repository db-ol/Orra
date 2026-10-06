import AVFoundation
import Testing
@testable import Orra

struct AudioRecorderTests {
    /// A buffer of a 440 Hz sine wave in the given format.
    private func sine(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount, interleaved: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let value = 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            for channel in 0..<Int(channels) {
                if interleaved {
                    data[0][frame * Int(channels) + channel] = value
                } else {
                    data[channel][frame] = value
                }
            }
        }
        return buffer
    }

    private func sineSamples(sampleRate: Double, seconds: Double) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { 0.5 * Float(sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
    }

    private func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }

    @Test func takesTheFirstChannelOnly() {
        // A microphone on input 1 of a multichannel interface, with something else, such
        // as a loopback of what the Mac plays, on input 2. Only input 1 is kept, at full level.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        for frame in 0..<4 {
            buffer.floatChannelData![0][frame] = 0.8
            buffer.floatChannelData![1][frame] = -0.6
        }
        #expect(MicrophoneChannel.samples(from: buffer) == [0.8, 0.8, 0.8, 0.8])
    }

    @Test func takesTheFirstChannelOfAnInterleavedBuffer() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        let data = buffer.floatChannelData![0]
        for frame in 0..<3 {
            data[frame * 2] = Float(frame)
            data[frame * 2 + 1] = 9
        }
        #expect(MicrophoneChannel.samples(from: buffer) == [0, 1, 2])
    }

    @Test func monoBufferPassesThrough() {
        let buffer = sine(sampleRate: 48_000, channels: 1, frames: 480)
        #expect(MicrophoneChannel.samples(from: buffer).count == 480)
        #expect(MicrophoneChannel.samples(from: sine(sampleRate: 48_000, channels: 1, frames: 0)).isEmpty)
    }

    @Test(arguments: [48_000.0, 44_100.0, 24_000.0])
    func resamplesAWholeRecordingWithoutLosingTheEnd(sampleRate: Double) {
        let recording = AudioRecording(samples: sineSamples(sampleRate: sampleRate, seconds: 1), sampleRate: sampleRate)
        let output = AudioResampler.monoAt16kHz(recording)
        // One second in gives one second out, including the tail the converter would hold back.
        #expect(abs(output.count - 16_000) <= 2)
        // The sine keeps its level. An amplitude of 0.5 has an RMS of about 0.354.
        #expect(abs(rms(Array(output.dropFirst(100))) - 0.354) < 0.02)
    }

    @Test func recordingAt16kHzIsNotResampled() {
        let samples = sineSamples(sampleRate: 16_000, seconds: 0.5)
        #expect(AudioResampler.monoAt16kHz(AudioRecording(samples: samples, sampleRate: 16_000)) == samples)
    }

    @Test func emptyRecordingGivesNoSamples() {
        #expect(AudioResampler.monoAt16kHz(AudioRecording(samples: [], sampleRate: 48_000)).isEmpty)
    }

    @Test func storeCollectsAndEmpties() {
        let store = SampleStore()
        store.begin(limit: 100)
        store.append([1, 2, 3])
        store.append([4])
        #expect(store.take() == [1, 2, 3, 4])
        #expect(store.take().isEmpty)
    }

    @Test func storeStopsAtItsLimit() {
        let store = SampleStore()
        store.begin(limit: 10)
        store.append(Array(repeating: 0.1, count: 8))
        store.append(Array(repeating: 0.2, count: 5))
        let taken = store.take()
        #expect(taken.count == 10)
        #expect(taken.last == 0.2)
    }

    @Test func beginDropsLeftoversFromThePreviousRecording() {
        let store = SampleStore()
        store.begin(limit: 10)
        store.append([1, 2])
        store.begin(limit: 10)
        #expect(store.take().isEmpty)
    }

    @Test func lengthRules() {
        #expect(RecordingLimits.minimumHold == .milliseconds(300))
        #expect(RecordingLimits.maximumDuration == .seconds(RecordingLimits.maximumSeconds))
        #expect(RecordingLimits.releaseTail == .milliseconds(150))
        #expect(AudioRecording(samples: Array(repeating: 0, count: 24_000), sampleRate: 48_000).duration == 0.5)
        #expect(AudioRecording(samples: [], sampleRate: 0).duration == 0)
        #expect(AudioRecording(samples: [], sampleRate: 16_000).wasCut == false)
    }
}
