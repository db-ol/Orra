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

    // MARK: When the first audio arrived

    @Test func theFirstBufferAndTheFirstSoundAreKeptUntilTheNextRecording() {
        let arrival = AudioArrival()
        #expect(arrival.firstBufferHostTime == 0)
        // An empty buffer is no buffer.
        arrival.record(peak: 0.5, count: 0, at: 50)
        #expect(arrival.firstBufferHostTime == 0)
        // Zeros from a microphone that is starting: a buffer, but no sound.
        arrival.record(peak: 0, count: 512, at: 100)
        arrival.record(peak: 0.000_005, count: 512, at: 200)
        #expect(arrival.firstBufferHostTime == 100)
        #expect(arrival.firstSoundHostTime == 0)
        // The noise of a working microphone counts as sound.
        arrival.record(peak: AudioArrival.soundFloor, count: 512, at: 300)
        arrival.record(peak: 0.5, count: 512, at: 400)
        #expect(arrival.firstBufferHostTime == 100)
        #expect(arrival.firstSoundHostTime == 300)
        arrival.reset()
        #expect(arrival.firstBufferHostTime == 0)
        #expect(arrival.firstSoundHostTime == 0)
    }

    @Test func soundCountsFromTheFloorOfTheSilenceCheck() {
        #expect(AudioArrival.soundFloor == Silence.threshold)
        #expect(AudioArrival.soundFloor == 0.000_01)
    }

    @Test func waitingForSoundEndsWithTheSoundOrAtTheDeadline() async {
        let arrival = AudioArrival()
        let started = ContinuousClock.now
        await arrival.waitForSound(until: started + .milliseconds(100))
        #expect(started.duration(to: .now) >= .milliseconds(100))
        arrival.record(peak: 0.1, count: 512, at: 1)
        let again = ContinuousClock.now
        await arrival.waitForSound(until: again + .seconds(10))
        #expect(again.duration(to: .now) < .seconds(1))
    }

    @Test func hostTimesBecomeInstantsOfTheContinuousClock() throws {
        // Apple silicon's timebase: 125 / 3 nanoseconds a tick, 24 million ticks a second.
        let timebase = mach_timebase_info_data_t(numer: 125, denom: 3)
        let now = ContinuousClock.now
        let instant = try #require(HostTime.instant(76_000_000, now: now, hostNow: 100_000_000, timebase: timebase))
        #expect(instant.duration(to: now) == .seconds(1))
        // A stamp of zero is a buffer that never came.
        #expect(HostTime.instant(0, now: now, hostNow: 100_000_000, timebase: timebase) == nil)
        // A stamp after the reading counts as now.
        #expect(HostTime.instant(100_000_010, now: now, hostNow: 100_000_000, timebase: timebase) == now)
        // With this Mac's own clocks, a stamp taken now is now, within a millisecond.
        let live = try #require(HostTime.instant(mach_absolute_time()))
        #expect(abs(DictationTimings.milliseconds(live.duration(to: .now))) <= 1)
    }

    // MARK: Keeping a chosen microphone's unit

    /// A unit records the next hold only after a hold whose stop worked, whose device stayed
    /// and that lost no audio.
    @Test func aKeptUnitRecordsTheNextHoldOnlyAfterAGoodOne() {
        let good = InputUnit.StopResult(samples: [0.1], interrupted: false, lostCallbacks: 0, ran: .seconds(2), status: noErr)
        #expect(AudioRecorder.keepsUnit(after: good, gotFirstBuffer: true))
        // A failed stop closed the unit, so its IO ended, and the next hold needs a new one.
        var failedStop = good
        failedStop.status = -10_863
        #expect(!AudioRecorder.keepsUnit(after: failedStop, gotFirstBuffer: true))
        var cut = good
        cut.interrupted = true
        #expect(!AudioRecorder.keepsUnit(after: cut, gotFirstBuffer: true))
        var lost = good
        lost.lostCallbacks = 1
        #expect(!AudioRecorder.keepsUnit(after: lost, gotFirstBuffer: true))
    }

    /// A unit whose IO ran for a second in a hold without a single buffer is made again,
    /// rather than kept for every hold to come. A shorter hold without a buffer, such as a
    /// shortcut during the wait of the translation key, keeps it.
    @Test func aUnitWithoutAnyBufferIsMadeAgainOnceItsIORanASecond() {
        #expect(AudioRecorder.firstBufferLimit == .seconds(1))
        let silent = InputUnit.StopResult(samples: [], interrupted: false, lostCallbacks: 0, ran: .seconds(1), status: noErr)
        #expect(!AudioRecorder.keepsUnit(after: silent, gotFirstBuffer: false))
        var longer = silent
        longer.ran = .seconds(30)
        #expect(!AudioRecorder.keepsUnit(after: longer, gotFirstBuffer: false))
        var shortcut = silent
        shortcut.ran = .milliseconds(80)
        #expect(AudioRecorder.keepsUnit(after: shortcut, gotFirstBuffer: false))
        var neverStarted = silent
        neverStarted.ran = .zero
        #expect(AudioRecorder.keepsUnit(after: neverStarted, gotFirstBuffer: false))
        // A buffer of zeros is still a buffer: a muted microphone keeps its unit.
        #expect(AudioRecorder.keepsUnit(after: longer, gotFirstBuffer: true))
    }

    @Test func lengthRules() {
        #expect(RecordingLimits.minimumHold == .milliseconds(300))
        #expect(RecordingLimits.maximumDuration == .seconds(RecordingLimits.maximumSeconds))
        // The recording limit notice and both user guides say 1 minute. Change them with it.
        #expect(RecordingLimits.maximumDuration == .seconds(60))
        #expect(RecordingLimits.releaseTail == .milliseconds(150))
        #expect(AudioRecording(samples: Array(repeating: 0, count: 24_000), sampleRate: 48_000).duration == 0.5)
        #expect(AudioRecording(samples: [], sampleRate: 0).duration == 0)
        #expect(AudioRecording(samples: [], sampleRate: 16_000).wasCut == false)
    }
}
