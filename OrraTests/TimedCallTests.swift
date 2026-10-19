import Foundation
import Synchronization
import Testing
@testable import Orra

/// Waits until `condition` holds, with no bound of its own. A hang ends at the test's
/// time limit.
@MainActor
private func waitWithoutBound(until condition: () -> Bool) async throws {
    while !condition() {
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// What happened, in order.
private final class Events: Sendable {
    private let events = Mutex<[String]>([])

    var all: [String] {
        events.withLock { $0 }
    }

    func note(_ event: String) {
        events.withLock { $0.append(event) }
    }
}

/// The time limit of the cleanup and translation calls. The stand in calls ignore
/// cancellation and run until the test lets them end, see HeldWork, so each test shows
/// what waits for what by the order of events, never by how long they took. No bound on
/// the time taken, since a busy runner can be seconds late.
@MainActor
struct TimedCallTests {
    /// At the limit the caller gets the time out at once, while the call still runs. The
    /// call is cancelled, and its answer is dropped when it comes.
    @Test(.timeLimit(.minutes(1)))
    func theLimitReturnsWhileTheCallStillRuns() async throws {
        let call = HeldWork()
        // Whether the call's task was cancelled when it ended, nil while it runs.
        let ended = Mutex<Bool?>(nil)
        let (result, timedOut) = await TimedCall.run(within: .milliseconds(20)) {
            await call.run()
            ended.withLock { $0 = Task.isCancelled }
            return "late"
        }
        #expect(timedOut)
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ended.withLock { $0 } == nil)
        call.release()
        try await waitWithoutBound { ended.withLock { $0 } != nil }
        #expect(ended.withLock { $0 } == true)
    }

    /// A call that ends before the limit gives its answer or its error, as before, and the
    /// caller waits for it.
    @Test(.timeLimit(.minutes(1)))
    func aCallThatEndsInTimeGivesItsResult() async throws {
        let call = HeldWork()
        let waiting = Task {
            await TimedCall.run(within: .seconds(3600)) {
                await call.run()
                return "in time"
            }
        }
        try await waitWithoutBound { call.began == 1 }
        call.release()
        let answered = await waiting.value
        #expect(try answered.result.get() == "in time")
        #expect(!answered.timedOut)

        let failed = await TimedCall.run(within: .seconds(3600)) { () throws -> String in
            throw RewriteError.notLoaded
        }
        #expect(throws: RewriteError.notLoaded) { try failed.result.get() }
        #expect(!failed.timedOut)
    }

    /// A caller whose task is cancelled stops waiting at once, without a time out, and the
    /// call is cancelled and left to end on its own. A caller cancelled before it asks gets
    /// the same.
    @Test(.timeLimit(.minutes(1)))
    func cancellingTheCallerReturnsAtOnce() async throws {
        let call = HeldWork()
        let ended = Mutex<Bool?>(nil)
        let caller = Task {
            await TimedCall.run(within: .seconds(3600)) {
                await call.run()
                ended.withLock { $0 = Task.isCancelled }
                return "late"
            }
        }
        try await waitWithoutBound { call.began == 1 }
        caller.cancel()
        let (result, timedOut) = await caller.value
        #expect(!timedOut)
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ended.withLock { $0 } == nil)
        call.release()
        try await waitWithoutBound { ended.withLock { $0 } != nil }
        #expect(ended.withLock { $0 } == true)

        // HeldWork ignores cancellation, so this caller asks with its task cancelled.
        let asking = HeldWork()
        let started = Mutex(false)
        let cancelledCaller = Task {
            await asking.run()
            return await TimedCall.run(within: .seconds(3600)) {
                started.withLock { $0 = true }
                return "never used"
            }
        }
        cancelledCaller.cancel()
        asking.release()
        let early = await cancelledCaller.value
        #expect(!early.timedOut)
        #expect(throws: CancellationError.self) { try early.result.get() }
        // A call that was started runs at once, so a short wait shows that none was.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!started.withLock { $0 })
    }
}

/// A call that TimedCall gave up on keeps the model busy until it really ends: it holds its
/// access to the model gate, so the voice model, which must never run next to it, waits
/// for it, also after the dictation that started it was pasted and its reservation ended.
@MainActor
struct AbandonedCallTests {
    let mic = FakeMicrophone()
    let inserter = FakeInserter()

    /// The cleanup model at `gate`, whose answer waits for `call` and notes when it ends.
    private func cleanupModel(at gate: ModelGate, waitingFor call: HeldWork, notingIn events: Events) -> CleanupEngine {
        CleanupEngine(load: { _ in }, unload: {}, complete: { _ in
            await call.run()
            events.note("cleanup ended")
            return #"{"cleaned": "我们下午3点开会。"}"#
        }).gated(gate)
    }

    @Test(.timeLimit(.minutes(1)))
    func theVoiceWaitsForACleanupThatRanOutOfTime() async throws {
        let gate = ModelGate()
        let call = HeldWork()
        let events = Events()
        let engine = cleanupModel(at: gate, waitingFor: call, notingIn: events)
        let dictation = gate.reserve()
        let step = await CleanupStep.run("呃，我们下午两点，哦不对，下午三点开会。", timeout: .milliseconds(20), complete: engine.complete)
        #expect(step.outcome == .timedOut)
        // The reserved gate lets the call in, also when the limit passed before it began.
        try await waitWithoutBound { call.began == 1 }
        // Pasted: the dictation ends its reservation.
        dictation.end()
        #expect(gate.snapshot == ModelGate.Snapshot(shared: 1))
        let voice = Task { try await gate.run(.exclusive) { events.note("voice") } }
        try await waitWithoutBound { gate.snapshot.waiting == [.exclusive] }
        #expect(events.all.isEmpty)
        call.release()
        try await voice.value
        #expect(events.all == ["cleanup ended", "voice"])
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// An engine call whose task is cancelled throws CancellationError before it looks for
    /// the model. The engine here has no model, so a call that went on would throw
    /// notLoaded instead, as one that was not cancelled does. Only the order of the two
    /// checks shows here. A call that waits for its turn behind another one needs the real
    /// model.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledCallThrowsBeforeTheModelIsChecked() async throws {
        let engine = RewriteEngine()
        // HeldWork ignores cancellation, so both calls reach the engine cancelled.
        let turn = HeldWork()
        let cleaning = Task {
            await turn.run()
            return try await engine.cleanUp("Hello.")
        }
        let translating = Task {
            await turn.run()
            return try await engine.translate("Hello.", into: TranslationRoute.chinese(.english))
        }
        cleaning.cancel()
        translating.cancel()
        turn.release()
        await #expect(throws: CancellationError.self) { try await cleaning.value }
        await #expect(throws: CancellationError.self) { try await translating.value }
        await #expect(throws: RewriteError.notLoaded) { try await engine.cleanUp("Hello.") }
        await #expect(throws: RewriteError.notLoaded) { try await engine.translate("Hello.", into: TranslationRoute.chinese(.english)) }
    }

    /// The whole dictation: the text is pasted without the cleanup at the limit, while the
    /// cleanup call still runs, and a voice request after the paste waits for that call.
    /// The limit is CleanupStep's own, about 2 s for this text.
    @Test(.timeLimit(.minutes(1)))
    func aDictationPastesWhileItsCleanupStillHoldsTheGate() async throws {
        let gate = ModelGate()
        let call = HeldWork()
        let events = Events()
        let engine = cleanupModel(at: gate, waitingFor: call, notingIn: events)
        let transcription = Transcription(
            load: {},
            transcribe: { _, _, _ in "呃，我们下午两点，哦不对，下午三点开会。" }
        ).gated(gate)
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: transcription,
            cleanup: CleanupModel(waitUntilLoaded: { true }, complete: engine.complete),
            insert: inserter.insert,
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero
        )
        await controller.loadModel()
        controller.handle(.pressed(isRepeat: false), key: .key(.rightControl))
        try await waitWithoutBound { mic.calls.contains("start") }
        controller.handle(.released, key: .key(.rightControl))
        try await waitWithoutBound { controller.state == .idle }
        #expect(inserter.inserted.count == 1)
        #expect(inserter.inserted.first != "我们下午3点开会。")
        #expect(events.all.isEmpty)
        try await waitWithoutBound { call.began == 1 }
        #expect(gate.snapshot == ModelGate.Snapshot(shared: 1))
        let voice = Task { try await gate.run(.exclusive) { events.note("voice") } }
        try await waitWithoutBound { gate.snapshot.waiting == [.exclusive] }
        call.release()
        try await voice.value
        #expect(events.all == ["cleanup ended", "voice"])
        #expect(gate.snapshot == ModelGate.Snapshot())
    }
}
