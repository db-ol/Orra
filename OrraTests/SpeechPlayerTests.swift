import Foundation
import Synchronization
import Testing
@testable import Orra

/// A stand in for the audio device side of SpeechPlayer. It records each call and whether
/// it ran on the main thread, and holds a start until the test lets it go when asked to.
final class FakeSpeechOutput: SpeechOutput {
    struct State {
        var calls: [String] = []
        var callsOnMainThread = 0
        var running = false
        var changed: (@Sendable () -> Void)?
        var played: [@Sendable () -> Void] = []
    }

    let state = Mutex(State())
    /// When set, each start waits until the test signals it, or five seconds.
    let startGate: DispatchSemaphore?

    init(startGate: DispatchSemaphore? = nil) {
        self.startGate = startGate
    }

    var calls: [String] {
        state.withLock { $0.calls }
    }

    var callsOnMainThread: Int {
        state.withLock { $0.callsOnMainThread }
    }

    func start(on device: AudioOutput, changed: @escaping @Sendable () -> Void) throws {
        record("start \(device.name)")
        _ = startGate?.wait(timeout: .now() + 5)
        state.withLock { state in
            state.running = true
            state.changed = changed
            state.calls.append("started")
        }
    }

    func schedule(_ audio: SpokenAudio, played: @escaping @Sendable () -> Void) -> Bool {
        record("schedule \(audio.samples.count)")
        state.withLock { $0.played.append(played) }
        return true
    }

    var isRunning: Bool {
        state.withLock { $0.running }
    }

    func stop() {
        record("stop")
        state.withLock { $0.running = false }
    }

    /// Reports every piece queued so far as played.
    func playAll() {
        let played = state.withLock { state in
            defer { state.played = [] }
            return state.played
        }
        for done in played {
            done()
        }
    }

    /// The engine stops on its own, as when its device goes away.
    func deviceGoesAway() {
        let changed = state.withLock { state in
            state.running = false
            return state.changed
        }
        changed?()
    }

    private func record(_ call: String) {
        let onMain = Thread.isMainThread
        state.withLock { state in
            state.calls.append(call)
            if onMain {
                state.callsOnMainThread += 1
            }
        }
    }
}

@MainActor
struct SpeechPlayerTests {
    static let speakers = AudioOutput(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    static let piece = SpokenAudio(samples: [Float](repeating: 0, count: 2_400), sampleRate: 24_000)

    /// A device that is slow to open leaves the main actor free, where the keyboard tap runs.
    /// No call to the device runs on the main thread.
    @Test func aSlowDeviceStartLeavesTheMainActorFree() async throws {
        let gate = DispatchSemaphore(value: 0)
        let output = FakeSpeechOutput(startGate: gate)
        let player = SpeechPlayer(output: output)
        let starting = Task { try await player.start(on: Self.speakers) }
        // The main actor runs this while the device still opens. A start on the main
        // thread would hold it until the gate gives up, and the start would be over.
        try await waitUntil { output.calls == ["start MacBook Pro Speakers"] }
        #expect(output.calls == ["start MacBook Pro Speakers"])
        try await Task.sleep(for: .milliseconds(20))
        #expect(output.calls == ["start MacBook Pro Speakers"])
        gate.signal()
        try await starting.value
        player.play(Self.piece)
        player.stop()
        try await waitUntil { output.calls.last == "stop" }
        #expect(output.calls == ["start MacBook Pro Speakers", "started", "schedule 2400", "stop"])
        #expect(output.callsOnMainThread == 0)
    }

    /// A stop while the device opens wins: the device is let go after the start, and
    /// nothing plays.
    @Test func aStopDuringASlowStartWins() async throws {
        let gate = DispatchSemaphore(value: 0)
        let output = FakeSpeechOutput(startGate: gate)
        let player = SpeechPlayer(output: output)
        let starting = Task { try await player.start(on: Self.speakers) }
        try await waitUntil { output.calls == ["start MacBook Pro Speakers"] }
        player.stop()
        gate.signal()
        try await starting.value
        player.play(Self.piece)
        // Nothing queued, so finish returns at once.
        await player.finish()
        try await waitUntil { output.calls.last == "stop" }
        try await Task.sleep(for: .milliseconds(20))
        #expect(output.calls == ["start MacBook Pro Speakers", "started", "stop"])
        #expect(!output.isRunning)
    }

    /// Finish returns once every queued piece played.
    @Test func finishWaitsForThePiecesToPlay() async throws {
        let output = FakeSpeechOutput()
        let player = SpeechPlayer(output: output)
        try await player.start(on: Self.speakers)
        player.play(Self.piece)
        player.play(Self.piece)
        try await waitUntil { output.calls.filter { $0.hasPrefix("schedule") }.count == 2 }
        let finished = Mutex(false)
        let finishing = Task {
            await player.finish()
            finished.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!finished.withLock { $0 })
        output.playAll()
        await finishing.value
        #expect(finished.withLock { $0 })
    }

    /// A player let go of without a stop lets go of its device side too, so the device is
    /// not held for good. The fake keeps the change callback, as NotificationCenter does
    /// for the real engine until it stops.
    @Test func aPlayerLetGoWithoutAStopLetsGoOfTheDevice() async throws {
        weak var released: FakeSpeechOutput?
        do {
            let output = FakeSpeechOutput()
            released = output
            let player = SpeechPlayer(output: output)
            try await player.start(on: Self.speakers)
            #expect(output.isRunning)
        }
        try await waitUntil { released == nil }
        #expect(released == nil)
    }

    /// A device that goes away while it plays stops the speech, so finish does not wait for
    /// pieces that never report.
    @Test func aDeviceThatGoesAwayStopsTheSpeech() async throws {
        let output = FakeSpeechOutput()
        let player = SpeechPlayer(output: output)
        try await player.start(on: Self.speakers)
        player.play(Self.piece)
        try await waitUntil { output.calls.last == "schedule 2400" }
        let began = ContinuousClock.now
        let finishing = Task { await player.finish() }
        try await Task.sleep(for: .milliseconds(20))
        output.deviceGoesAway()
        await finishing.value
        // Well before the watchdog of finish, which waits the queued seconds plus three.
        #expect(began.duration(to: .now) < .seconds(2))
        try await waitUntil { output.calls.last == "stop" }
        #expect(output.calls == ["start MacBook Pro Speakers", "started", "schedule 2400", "stop"])
    }
}
