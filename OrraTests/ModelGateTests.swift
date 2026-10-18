import Foundation
import Synchronization
import Testing
@testable import Orra

/// A body that runs until the test lets it end, and counts how often it began.
final class HeldWork: Sendable {
    private struct State {
        var began = 0
        var released = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var began: Int {
        state.withLock { $0.began }
    }

    /// Says it began, and returns once `release` was called.
    func run() async {
        await withCheckedContinuation { continuation in
            let released = state.withLock { state in
                state.began += 1
                if !state.released {
                    state.waiting.append(continuation)
                }
                return state.released
            }
            if released {
                continuation.resume()
            }
        }
    }

    func release() {
        let waiting = state.withLock { state in
            state.released = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting {
            continuation.resume()
        }
    }
}

/// The rules of the model gate, without models.
@MainActor
struct ModelGateTests {
    @Test func sharedCallsRunTogether() async throws {
        let gate = ModelGate()
        let work = HeldWork()
        let first = Task { try await gate.run(.shared) { await work.run() } }
        let second = Task { try await gate.run(.shared) { await work.run() } }
        try await eventually { work.began == 2 }
        #expect(gate.snapshot == ModelGate.Snapshot(shared: 2))
        work.release()
        try await first.value
        try await second.value
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// A voice request waits for the shared calls that run, and every shared call waits
    /// for the voice, also while the gate is reserved. Then the reserved gate lets the
    /// shared call in and keeps the next voice request out.
    @Test func theVoiceRunsAlone() async throws {
        let gate = ModelGate()
        let speech = HeldWork()
        let transcribing = Task { try await gate.run(.shared) { await speech.run() } }
        try await eventually { speech.began == 1 }
        let voice = HeldWork()
        let speaking = Task { try await gate.run(.exclusive) { await voice.run() } }
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        #expect(voice.began == 0)
        speech.release()
        try await transcribing.value
        try await eventually { voice.began == 1 }
        #expect(gate.snapshot == ModelGate.Snapshot(exclusive: true))

        let reservation = gate.reserve()
        let dictation = HeldWork()
        dictation.release()
        let dictating = Task { try await gate.run(.shared) { await dictation.run() } }
        let nextVoice = HeldWork()
        nextVoice.release()
        let nextPiece = Task { try await gate.run(.exclusive) { await nextVoice.run() } }
        try await eventually { gate.snapshot.waiting.count == 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(dictation.began == 0)
        #expect(nextVoice.began == 0)
        voice.release()
        try await speaking.value
        try await dictating.value
        #expect(dictation.began == 1)
        #expect(nextVoice.began == 0)
        #expect(gate.snapshot == ModelGate.Snapshot(reserved: 1, waiting: [.exclusive]))
        reservation.end()
        try await nextPiece.value
        #expect(nextVoice.began == 1)
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// A voice request that waits holds back the shared calls that came after it, such as
    /// captions, and enters once the shared calls before it ended.
    @Test func aWaitingVoiceHoldsBackLaterSharedCalls() async throws {
        let gate = ModelGate()
        let caption = HeldWork()
        let captioning = Task { try await gate.run(.shared) { await caption.run() } }
        try await eventually { caption.began == 1 }
        let voice = HeldWork()
        let speaking = Task { try await gate.run(.exclusive) { await voice.run() } }
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        let nextCaption = HeldWork()
        let background = Task { try await gate.run(.shared) { await nextCaption.run() } }
        try await eventually { gate.snapshot.waiting == [.exclusive, .shared] }
        #expect(gate.snapshot == ModelGate.Snapshot(shared: 1, waiting: [.exclusive, .shared]))

        caption.release()
        try await captioning.value
        try await eventually { voice.began == 1 }
        #expect(nextCaption.began == 0)
        #expect(gate.snapshot == ModelGate.Snapshot(exclusive: true, waiting: [.shared]))

        voice.release()
        try await speaking.value
        try await eventually { nextCaption.began == 1 }
        nextCaption.release()
        try await background.value
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// While a dictation reserves the gate, a voice request that waits does not come in
    /// between two of its calls, also when no shared call runs, and enters once the
    /// reservation ends.
    @Test func aReservationKeepsTheVoiceOutBetweenCalls() async throws {
        let gate = ModelGate()
        let reservation = gate.reserve()
        let transcription = HeldWork()
        let transcribing = Task { try await gate.run(.shared) { await transcription.run() } }
        try await eventually { transcription.began == 1 }
        let voice = HeldWork()
        let speaking = Task { try await gate.run(.exclusive) { await voice.run() } }
        try await eventually { gate.snapshot.waiting == [.exclusive] }

        transcription.release()
        try await transcribing.value
        try await Task.sleep(for: .milliseconds(20))
        #expect(voice.began == 0)
        #expect(gate.snapshot == ModelGate.Snapshot(reserved: 1, waiting: [.exclusive]))
        // The dictation's next call goes ahead of the voice. In a task of its own, so a
        // gate that let the voice in fails here instead of waiting for it for good.
        let cleaned = Mutex(false)
        let cleaning = Task { try await gate.run(.shared) { cleaned.withLock { $0 = true } } }
        try await eventually { cleaned.withLock { $0 } }
        #expect(voice.began == 0)

        reservation.end()
        try await eventually { voice.began == 1 }
        voice.release()
        try await speaking.value
        try await cleaning.value
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// A reservation lets in the shared calls that wait behind a voice request, such as an
    /// unload queued before a dictation's load, so whoever holds it never waits for the
    /// voice through them. The voice request stays out until the reservation ends.
    @Test func aReservationLetsInCallsQueuedBehindAVoice() async throws {
        let gate = ModelGate()
        let caption = HeldWork()
        let captioning = Task { try await gate.run(.shared) { await caption.run() } }
        try await eventually { caption.began == 1 }
        let voice = HeldWork()
        let speaking = Task { try await gate.run(.exclusive) { await voice.run() } }
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        let unloaded = Mutex(false)
        let unloading = Task { await gate.runEvenIfCancelled(.shared) { unloaded.withLock { $0 = true } } }
        try await eventually { gate.snapshot.waiting == [.exclusive, .shared] }

        let reservation = gate.reserve()
        try await eventually { unloaded.withLock { $0 } }
        caption.release()
        try await captioning.value
        try await Task.sleep(for: .milliseconds(20))
        #expect(voice.began == 0)
        #expect(gate.snapshot == ModelGate.Snapshot(reserved: 1, waiting: [.exclusive]))

        reservation.end()
        try await eventually { voice.began == 1 }
        voice.release()
        try await speaking.value
        await unloading.value
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// The voice waits until every reservation ended. Ending one twice counts once, and a
    /// reservation let go ends.
    @Test func everyReservationEndsOnce() async throws {
        let gate = ModelGate()
        let first = gate.reserve()
        var second: ModelGate.Reservation? = gate.reserve()
        #expect(gate.snapshot == ModelGate.Snapshot(reserved: 2))
        let spoken = Mutex(false)
        let speaking = Task { try await gate.run(.exclusive) { spoken.withLock { $0 = true } } }
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        first.end()
        first.end()
        #expect(gate.snapshot == ModelGate.Snapshot(reserved: 1, waiting: [.exclusive]))
        #expect(second != nil)
        second = nil
        try await speaking.value
        #expect(spoken.withLock { $0 })
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// Requests enter in the order they came: a shared call behind a voice request waits
    /// for it, and a later voice request waits for that call.
    @Test func requestsEnterInTheOrderTheyCame() async throws {
        let gate = ModelGate()
        let order = Mutex<[String]>([])
        let first = HeldWork()
        let running = Task { try await gate.run(.shared) { await first.run() } }
        try await eventually { first.began == 1 }
        var tasks: [Task<Void, any Error>] = []
        for (name, access) in [("voice 1", ModelGate.Access.exclusive), ("caption", .shared), ("voice 2", .exclusive)] {
            tasks.append(Task { try await gate.run(access) { order.withLock { $0.append(name) } } })
            // Each is queued behind the one before.
            try await eventually { gate.snapshot.waiting.count == tasks.count }
        }
        #expect(gate.snapshot.waiting == [.exclusive, .shared, .exclusive])
        first.release()
        try await running.value
        for task in tasks {
            try await task.value
        }
        #expect(order.withLock { $0 } == ["voice 1", "caption", "voice 2"])
    }

    /// A task cancelled while it waits leaves the queue with CancellationError, and those
    /// it held back move up.
    @Test func aCancelledWaiterLeavesTheQueue() async throws {
        let gate = ModelGate()
        let caption = HeldWork()
        let captioning = Task { try await gate.run(.shared) { await caption.run() } }
        try await eventually { caption.began == 1 }
        let voice = HeldWork()
        let speaking = Task { try await gate.run(.exclusive) { await voice.run() } }
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        let nextCaption = HeldWork()
        let background = Task { try await gate.run(.shared) { await nextCaption.run() } }
        try await eventually { gate.snapshot.waiting == [.exclusive, .shared] }

        speaking.cancel()
        await #expect(throws: CancellationError.self) { try await speaking.value }
        // The next caption no longer waits behind the voice, while the first still runs.
        try await eventually { nextCaption.began == 1 }
        #expect(voice.began == 0)
        #expect(gate.snapshot == ModelGate.Snapshot(shared: 2))

        // A task cancelled before it waits does not wait.
        let blocker = HeldWork()
        caption.release()
        nextCaption.release()
        try await captioning.value
        try await background.value
        let holding = Task { try await gate.run(.exclusive) { await blocker.run() } }
        try await eventually { blocker.began == 1 }
        let late = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.run(.shared) {}
        }
        await #expect(throws: CancellationError.self) { try await late.value }
        #expect(gate.snapshot == ModelGate.Snapshot(exclusive: true))
        blocker.release()
        try await holding.value
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// An unload waits for its turn even when its task is cancelled, and then runs: the
    /// cleanup model's behind the voice, and the voice model's, or a voice forgotten, behind
    /// a shared call.
    @Test func anUnloadWaitsThroughCancellation() async throws {
        let gate = ModelGate()
        let voice = HeldWork()
        let speaking = Task { try await gate.run(.exclusive) { await voice.run() } }
        try await eventually { voice.began == 1 }
        let unloaded = Mutex(false)
        let unloading = Task { await gate.runEvenIfCancelled(.shared) { unloaded.withLock { $0 = true } } }
        try await eventually { gate.snapshot.waiting == [.shared] }
        unloading.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.snapshot.waiting == [.shared])
        #expect(!unloaded.withLock { $0 })
        voice.release()
        try await speaking.value
        await unloading.value
        #expect(unloaded.withLock { $0 })
        #expect(gate.snapshot == ModelGate.Snapshot())

        let caption = HeldWork()
        let captioning = Task { try await gate.run(.shared) { await caption.run() } }
        try await eventually { caption.began == 1 }
        let voiceUnloaded = Mutex(false)
        let voiceUnloading = Task { await gate.runEvenIfCancelled(.exclusive) { voiceUnloaded.withLock { $0 = true } } }
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        voiceUnloading.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.snapshot == ModelGate.Snapshot(shared: 1, waiting: [.exclusive]))
        #expect(!voiceUnloaded.withLock { $0 })
        caption.release()
        try await captioning.value
        await voiceUnloading.value
        #expect(voiceUnloaded.withLock { $0 })
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// A body that throws releases the gate, and the voice that waited for it enters.
    @Test func aBodyThatThrowsReleasesTheGate() async throws {
        let gate = ModelGate()
        await #expect(throws: TestError.self) { try await gate.run(.exclusive) { throw TestError() } }
        #expect(gate.snapshot == ModelGate.Snapshot())

        let failing = HeldWork()
        let transcribing = Task {
            try await gate.run(.shared) {
                await failing.run()
                throw TestError()
            }
        }
        try await eventually { failing.began == 1 }
        let voice = HeldWork()
        voice.release()
        let speaking = Task { try await gate.run(.exclusive) { await voice.run() } }
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        failing.release()
        await #expect(throws: TestError.self) { try await transcribing.value }
        try await speaking.value
        #expect(voice.began == 1)
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// A call that can enter at once runs its body without giving up the actor, so the
    /// gate costs no suspension when nothing waits.
    @Test func aCallThatCanEnterDoesNotSuspend() async throws {
        let gate = ModelGate()
        let interleaved = Mutex(false)
        Task { interleaved.withLock { $0 = true } }
        try await gate.run(.shared) { #expect(!interleaved.withLock { $0 }) }
        try await gate.run(.exclusive) { #expect(!interleaved.withLock { $0 }) }
        await gate.runEvenIfCancelled(.shared) { #expect(!interleaved.withLock { $0 }) }
        let reservation = gate.reserve()
        try await gate.run(.shared) { #expect(!interleaved.withLock { $0 }) }
        reservation.end()
        try await eventually { interleaved.withLock { $0 } }
    }

    /// A body, and the tasks it starts, are marked as inside the gate, which debug builds
    /// read to stop a body that asks for the gate again.
    @Test func aBodyIsMarkedAsInside() async throws {
        let gate = ModelGate()
        #expect(!ModelGate.isInside)
        try await gate.run(.shared) {
            #expect(ModelGate.isInside)
            await Task { #expect(ModelGate.isInside) }.value
        }
        await gate.runEvenIfCancelled(.exclusive) {
            #expect(ModelGate.isInside)
        }
        #expect(!ModelGate.isInside)
    }
}

/// Counts the moments the fake models' work overlaps.
final class OverlapProbe: Sendable {
    nonisolated enum Model: Sendable {
        case speech
        case cleanup
        case voice
    }

    private struct State {
        var speech = 0
        var cleanup = 0
        var voice = 0
        /// Times the voice worked next to any other work, its own included.
        var voiceOverlaps = 0
        var speechWithCleanup = 0
        var begun: [Model: Int] = [:]
    }

    private let state = Mutex(State())

    /// How often work of `model` began.
    func begun(_ model: Model) -> Int {
        state.withLock { $0.begun[model, default: 0] }
    }

    var voiceOverlaps: Int {
        state.withLock { $0.voiceOverlaps }
    }

    var speechWithCleanup: Int {
        state.withLock { $0.speechWithCleanup }
    }

    func begin(_ model: Model) {
        state.withLock { state in
            switch model {
            case .speech: state.speech += 1
            case .cleanup: state.cleanup += 1
            case .voice: state.voice += 1
            }
            state.begun[model, default: 0] += 1
            if state.voice > 0, state.speech + state.cleanup > 0 || state.voice > 1 {
                state.voiceOverlaps += 1
            }
            if state.speech > 0, state.cleanup > 0 {
                state.speechWithCleanup += 1
            }
        }
    }

    func end(_ model: Model) {
        state.withLock { state in
            switch model {
            case .speech: state.speech -= 1
            case .cleanup: state.cleanup -= 1
            case .voice: state.voice -= 1
            }
        }
    }

    /// Work of `model` for `duration`, which a cancelled task does not cut short, like a
    /// transcription.
    func work(_ model: Model, for duration: Duration) async {
        begin(model)
        await Task { try? await Task.sleep(for: duration) }.value
        end(model)
    }
}

/// A voice model that works as Qwen3VoiceEngine does: a piece goes on after the reader
/// left, and its stream ends only once the piece is done. A streamed piece gives its first
/// part at once and works 300 ms more. A cloned piece comes whole after 300 ms.
final class ProbedVoice: SpeechSynthesizer {
    let probe: OverlapProbe

    init(probe: OverlapProbe) {
        self.probe = probe
    }

    func load(model: URL, codec: URL) async throws {
        await probe.work(.voice, for: .milliseconds(200))
    }

    func unload() async {
        await probe.work(.voice, for: .milliseconds(50))
    }

    func forgetVoice() async {
        await probe.work(.voice, for: .milliseconds(10))
    }

    func streams(voice: VoiceSample?) -> Bool {
        voice == nil
    }

    func speak(_ text: String, in language: TranslationTarget, voice: VoiceSample?) -> AsyncThrowingStream<SpokenAudio, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SpokenAudio, any Error>.makeStream()
        let part = SpokenAudio(samples: [Float](repeating: 0, count: 240), sampleRate: 24_000)
        // Not cancelled when the reader leaves, like speech-swift's own task.
        Task { [probe] in
            probe.begin(.voice)
            if voice == nil {
                continuation.yield(part)
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(100))
                    continuation.yield(part)
                }
            } else {
                try? await Task.sleep(for: .milliseconds(300))
                continuation.yield(part)
            }
            probe.end(.voice)
            continuation.finish()
        }
        return stream
    }
}

/// Fakes of the three models that tell `probe` when they work, through the app's wrappers
/// at `gate`, or without a gate as in Orra 0.4.0.
@MainActor
struct ProbedModels {
    let speech: Transcription
    let cleanup: CleanupEngine
    let voice: any SpeechSynthesizer

    init(probe: OverlapProbe, gate: ModelGate?) {
        let speech = Transcription(
            load: { await probe.work(.speech, for: .milliseconds(200)) },
            transcribe: { _, _, _ in
                await probe.work(.speech, for: .milliseconds(30))
                return "Hello."
            }
        )
        let cleanup = CleanupEngine(
            load: { _ in await probe.work(.cleanup, for: .milliseconds(200)) },
            unload: { await probe.work(.cleanup, for: .milliseconds(10)) },
            complete: { _ in
                await probe.work(.cleanup, for: .milliseconds(30))
                return ""
            },
            translate: { _, _ in
                await probe.work(.cleanup, for: .milliseconds(30))
                return ""
            },
            prepareTranslation: { _ in await probe.work(.cleanup, for: .milliseconds(30)) }
        )
        let voice = ProbedVoice(probe: probe)
        if let gate {
            self.speech = speech.gated(gate)
            self.cleanup = cleanup.gated(gate)
            self.voice = ExclusiveSynthesizer(voice, gate: gate)
        } else {
            self.speech = speech
            self.cleanup = cleanup
            self.voice = voice
        }
    }

    static let folder = URL(fileURLWithPath: "/tmp/model")
    static let sample = VoiceSample(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, transcript: "Hello.")

    /// Runs `body` while the gate is reserved, as a dictation and a load of the speech or
    /// cleanup model do. Without a gate it only runs `body`.
    func reserving<T>(_ body: () async throws -> T) async rethrows -> T {
        let reservation = speech.gate?.reserve()
        defer { reservation?.end() }
        return try await body()
    }

    /// The three loads at once, as at launch (AppDelegate), the speech and cleanup loads
    /// each with a reservation.
    func loadAtOnce() async throws {
        let speechLoad = Task { try await reserving { try await speech.load() } }
        let cleanupLoad = Task { try await reserving { try await cleanup.load(Self.folder) } }
        let voiceLoad = Task { try await voice.load(model: Self.folder, codec: Self.folder) }
        try await speechLoad.value
        try await cleanupLoad.value
        try await voiceLoad.value
    }
}

/// The wrappers never run voice work next to speech or cleanup work, while the speech
/// and cleanup models still run together. The fake voice keeps the engines' contract, see
/// ProbedVoice. ModelGateWiringTests checks that the app's models use these wrappers.
@MainActor
struct ModelGateOverlapTests {
    let probe = OverlapProbe()

    @Test func voiceWorkNeverOverlapsSpeechOrCleanup() async throws {
        let gate = ModelGate()
        let models = ProbedModels(probe: probe, gate: gate)
        let samples = [Float](repeating: 0, count: 16_000)

        // Launch: the three loads at once.
        try await models.loadAtOnce()

        // A streamed piece stopped after its first part, and a dictation right after:
        // its transcription and cleanup, and the cleanup model loaded again at the press of
        // the key.
        for try await _ in models.voice.speak("We met at noon.", in: .english, voice: nil) {
            break
        }
        try await models.reserving {
            let reload = Task { try await models.cleanup.load(ProbedModels.folder) }
            _ = try await models.speech.transcribe(samples, nil, nil)
            _ = try await models.cleanup.complete("Hello.")
            try await reload.value
        }

        // Captions during a cloned piece.
        let captions = Task {
            for _ in 0..<8 {
                _ = try await models.speech.transcribe(samples, nil, nil)
                _ = try await models.cleanup.translate("Hello.", .chinese(.chinese))
            }
        }
        for try await _ in models.voice.speak("We met at noon.", in: .english, voice: ProbedModels.sample) {}
        try await captions.value

        // The voice unloaded during a caption call, and the voice sample forgotten during
        // the read ahead of a translation prompt. Each asks once the other call is inside
        // the gate, see anUnloadWaitsThroughCancellation for the wait itself.
        let transcriptions = probe.begun(.speech)
        let caption = Task { _ = try await models.speech.transcribe(samples, nil, nil) }
        try await eventually { probe.begun(.speech) > transcriptions }
        await models.voice.unload()
        try await caption.value
        let readings = probe.begun(.cleanup)
        let reading = Task { try await models.cleanup.prepareTranslation(.chinese(.english)) }
        try await eventually { probe.begun(.cleanup) > readings }
        await models.voice.forgetVoice()
        try await reading.value
        #expect(gate.snapshot == ModelGate.Snapshot())

        #expect(probe.voiceOverlaps == 0)
        #expect(probe.speechWithCleanup > 0)
    }

    /// Without the gate, as in Orra 0.4.0, the probe sees the launch overlap at once.
    @Test func withoutTheGateTheLoadsOverlap() async throws {
        let models = ProbedModels(probe: probe, gate: nil)
        try await models.loadAtOnce()
        #expect(probe.voiceOverlaps > 0)
    }

    /// TranslationSpeech's queue through the wrapper: a dictation started while a streamed
    /// piece is stopped after its first part waits for the rest of the piece.
    @Test func aStopKeepsTheGateUntilThePieceIsDone() async throws {
        let gate = ModelGate()
        let models = ProbedModels(probe: probe, gate: gate)
        let playback = FakePlayback()
        let speech = TranslationSpeech(
            engines: VoiceEngines(available: [.qwen3]) { _ in models.voice },
            playback: playback,
            outputs: { [TranslationSpeechTests.orraMicrophone] },
            folders: { TranslationSpeechTests.folders },
            settings: TranslationSpeech.Settings(isOn: true),
            dictationPoll: .milliseconds(1)
        )
        speech.speak("We have a meeting next Tuesday.", in: .english)
        try await eventually { playback.calls.contains { $0.hasPrefix("play") } }
        speech.stop()
        try await models.reserving {
            _ = try await models.speech.transcribe([0], nil, nil)
        }
        await speech.waitUntilDone()
        #expect(probe.voiceOverlaps == 0)
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// TranslationSpeech with `voice` behind `gate`, as VoiceEngines.live puts the app's
    /// voice models.
    private func makeSpeech(_ voice: FakeSynthesizer, at gate: ModelGate, isOn: Bool = true) -> (TranslationSpeech, FakePlayback) {
        let playback = FakePlayback()
        let speech = TranslationSpeech(
            engines: .only(ExclusiveSynthesizer(voice, gate: gate)),
            playback: playback,
            outputs: { [TranslationSpeechTests.orraMicrophone] },
            folders: { TranslationSpeechTests.folders },
            settings: TranslationSpeech.Settings(isOn: isOn),
            dictationPoll: .milliseconds(1)
        )
        return (speech, playback)
    }

    /// A stop while a piece waits for the gate behind a caption call, as with live captions
    /// on: the piece leaves the gate's queue, so later caption calls are not held back and
    /// the voice model never makes it. A translation after the stop is spoken. Both for a
    /// streamed piece and for one that comes whole, as with a voice sample.
    @Test(arguments: [true, false])
    func aStopDropsAPieceThatWaitsForTheGate(streams: Bool) async throws {
        let gate = ModelGate()
        let voice = FakeSynthesizer()
        voice.streamsPieces.withLock { $0 = streams }
        voice.makes.withLock { $0 = { text, _ in [TranslationSpeechTests.reading(text)] } }
        let (speech, playback) = makeSpeech(voice, at: gate)
        speech.prepare()
        await speech.waitUntilDone()
        #expect(speech.isLoaded)

        let caption = HeldWork()
        let captioning = Task { try await gate.run(.shared) { await caption.run() } }
        try await eventually { caption.began == 1 }
        speech.speak("We have a meeting next Tuesday.", in: .english)
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        speech.stop()
        try await eventually { gate.snapshot.waiting.isEmpty }
        caption.release()
        try await captioning.value
        await speech.waitUntilDone()
        #expect(voice.spoken.withLock { $0 }.isEmpty)
        #expect(playback.calls == ["start Orra Microphone", "stop"])
        #expect(speech.state == .idle)
        #expect(speech.problem == nil)
        #expect(gate.snapshot == ModelGate.Snapshot())

        speech.speak("Thanks a lot, everyone.", in: .english)
        await speech.waitUntilDone()
        #expect(voice.spoken.withLock { $0 } == ["en Thanks a lot, everyone."])
        #expect(playback.calls.suffix(2) == ["finish", "stop"])
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// Speak translations turned off while its load waits for the gate behind a caption
    /// call: the load leaves the gate's queue and shows no problem, and the unload still
    /// runs once the caption call is done.
    @Test func turningSpeakTranslationsOffDropsALoadThatWaits() async throws {
        let gate = ModelGate()
        let voice = FakeSynthesizer()
        let (speech, _) = makeSpeech(voice, at: gate, isOn: false)
        let caption = HeldWork()
        let captioning = Task { try await gate.run(.shared) { await caption.run() } }
        try await eventually { caption.began == 1 }
        speech.setOn(true)
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        speech.setOn(false)
        caption.release()
        try await captioning.value
        await speech.waitUntilDone()
        #expect(voice.loads.withLock { $0 } == 0)
        #expect(voice.unloads.withLock { $0 } == 1)
        #expect(!speech.isLoaded)
        #expect(speech.problem == nil)
        #expect(speech.state == .idle)
        #expect(gate.snapshot == ModelGate.Snapshot())
    }
}

/// Notes each model call, and whether the gate was reserved during it.
final class ReservationLog: Sendable {
    private let gate: ModelGate
    private let entries = Mutex<[String]>([])

    init(_ gate: ModelGate) {
        self.gate = gate
    }

    var all: [String] {
        entries.withLock { $0 }
    }

    func note(_ name: String) {
        let reserved = gate.snapshot.reserved > 0
        entries.withLock { $0.append("\(name) \(reserved ? "reserved" : "free")") }
    }
}

/// A dictation reserves the gate from the press of its key until it is over, and so does a
/// load of the speech or cleanup model with the prompts read after it. Everything else,
/// such as the voice sample, the word check and the prompts read ahead later, does not.
@MainActor
struct ModelGateReservationTests {
    let mic = FakeMicrophone()
    let inserter = FakeInserter()

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func press(_ controller: PushToTalkController, _ key: TalkKey) async throws {
        let starts = mic.calls.filter { $0 == "start" }.count
        controller.handle(.pressed(isRepeat: false), key: .key(key))
        try await waitUntil { mic.calls.filter { $0 == "start" }.count > starts }
    }

    @Test func aDictationReservesTheGate() async throws {
        let gate = ModelGate()
        let log = ReservationLog(gate)
        let transcription = Transcription(
            load: { log.note("load") },
            transcribe: { _, _, _ in
                log.note("transcribe")
                return "呃，我们下午两点，哦不对，下午三点开会。"
            }
        ).gated(gate)
        let cleanup = CleanupModel(waitUntilLoaded: { true }, complete: { _ in
            log.note("cleanup")
            return #"{"cleaned": "我们下午3点开会。"}"#
        })
        let translation = TranslationModel(isReady: { true }, direction: { .automatic }, complete: { _, _ in
            log.note("translate")
            return #"{"cleaned": "我们下午3点开会。", "translation": "We meet at 3 pm."}"#
        })
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: transcription,
            cleanup: cleanup,
            translation: translation,
            insert: inserter.insert,
            frontmostApp: { 100 },
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero
        )
        controller.setTranslationKeyOn(true)
        await controller.loadModel()
        #expect(gate.snapshot == ModelGate.Snapshot())

        for key in [TalkKey.rightControl, .rightOption] {
            try await press(controller, key)
            // Also while the key is held, before any model call.
            #expect(gate.snapshot == ModelGate.Snapshot(reserved: 1))
            controller.handle(.released, key: .key(key))
            try await waitUntil { controller.state == .idle }
            #expect(gate.snapshot == ModelGate.Snapshot())
        }

        // A press that starts the microphone early, while it may still be a shortcut,
        // reserves the gate once it counts as a dictation.
        let starts = mic.calls.filter { $0 == "start" }.count
        controller.handle(.armed, key: .key(.rightControl))
        try await waitUntil { mic.calls.filter { $0 == "start" }.count > starts }
        #expect(gate.snapshot == ModelGate.Snapshot())
        controller.handle(.pressed(isRepeat: false), key: .key(.rightControl))
        #expect(gate.snapshot == ModelGate.Snapshot(reserved: 1))
        controller.handle(.released, key: .key(.rightControl))
        try await waitUntil { controller.state == .idle }
        #expect(gate.snapshot == ModelGate.Snapshot())

        // A hold that is cancelled ends its reservation too.
        try await press(controller, .rightControl)
        #expect(gate.snapshot == ModelGate.Snapshot(reserved: 1))
        controller.handle(.cancelled)
        #expect(gate.snapshot == ModelGate.Snapshot())

        let sample = VoiceSample(samples: FakeMicrophone.tone(count: 32_000), sampleRate: 16_000)
        _ = try await controller.transcribeVoiceSample(sample)
        _ = try await controller.transcribeSpeech(SpokenAudio(samples: FakeMicrophone.tone(count: 24_000), sampleRate: 24_000), in: .english)
        #expect(log.all == [
            "load reserved",
            "transcribe reserved", "cleanup reserved",
            "transcribe reserved", "translate reserved",
            "transcribe reserved", "cleanup reserved",
            "transcribe free", "transcribe free",
        ])
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// The cleanup model loads with a reservation, also for its prompts read with the load,
    /// and the prompts read ahead later go without one.
    @Test func aCleanupLoadReservesTheGate() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let gate = ModelGate()
        let log = ReservationLog(gate)
        let engine = CleanupEngine(
            load: { _ in log.note("load") },
            unload: {},
            complete: { _ in "" },
            prepareTranslation: { route in log.note("prepare \(route.target.rawValue)") }
        ).gated(gate)
        try temporary.writeAll(to: temporary.installed)
        let cleanup = TextCleanup(
            isOn: true,
            save: { _ in },
            translationIsOn: true,
            translationDirection: .english,
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in }, freeSpace: { _ in nil }, sleep: { _ in })
            ),
            engine: engine
        )
        await cleanup.start()
        await cleanup.waitForLoad()
        cleanup.setTranslationDirection(.chinese)
        await cleanup.waitForLoad()
        #expect(log.all == ["load reserved", "prepare en reserved", "prepare zh free"])
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// At launch the voice model may ask while the cleanup model loads. The prompts read
    /// after the load still go ahead of it, also once the load's own call ended and no
    /// other call runs.
    @Test func theCleanupLoadsPromptsGoAheadOfAWaitingVoice() async throws {
        let temporary = TemporaryModelFolders()
        defer { temporary.remove() }
        let gate = ModelGate()
        let loading = HeldWork()
        let order = Mutex<[String]>([])
        let engine = CleanupEngine(
            load: { _ in await loading.run() },
            unload: {},
            complete: { _ in "" },
            prepareTranslation: { route in order.withLock { $0.append("prepare \(route.target.rawValue)") } }
        ).gated(gate)
        try temporary.writeAll(to: temporary.installed)
        let cleanup = TextCleanup(
            isOn: true,
            save: { _ in },
            translationIsOn: true,
            translationDirection: .english,
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in }, freeSpace: { _ in nil }, sleep: { _ in })
            ),
            engine: engine
        )
        await cleanup.start()
        try await eventually { loading.began == 1 }
        let voice = Task { try await gate.run(.exclusive) { order.withLock { $0.append("voice") } } }
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        loading.release()
        await cleanup.waitForLoad()
        try await voice.value
        #expect(order.withLock { $0 } == ["prepare en", "voice"])
        #expect(gate.snapshot == ModelGate.Snapshot())
    }
}

/// The app's models go through the wrappers at the app's gate, so that dropping a wrapper
/// from a factory fails here. No model is needed: each call waits for the gate, and then
/// fails because nothing is loaded.
@MainActor
struct ModelGateWiringTests {
    /// Holds `gate` for a voice request until the returned work is released.
    private func holdForTheVoice(_ gate: ModelGate) async throws -> (HeldWork, Task<Void, any Error>) {
        let voice = HeldWork()
        let speaking = Task { try await gate.run(.exclusive) { await voice.run() } }
        try await eventually { voice.began == 1 }
        return (voice, speaking)
    }

    @Test func theSpeechModelSharesTheGate() async throws {
        let gate = ModelGate()
        let speech = Transcription.qwen3(Qwen3Engine(folder: { nil }), gate: gate)
        #expect(speech.gate === gate)
        let (voice, speaking) = try await holdForTheVoice(gate)
        let loading = Task { try await speech.load() }
        try await eventually { gate.snapshot.waiting == [.shared] }
        let transcribing = Task { try await speech.transcribe([0], nil, nil) }
        try await eventually { gate.snapshot.waiting == [.shared, .shared] }
        voice.release()
        try await speaking.value
        await #expect(throws: TranscriptionError.modelMissing) { try await loading.value }
        await #expect(throws: TranscriptionError.modelMissing) { try await transcribing.value }
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    @Test func theCleanupModelSharesTheGate() async throws {
        let gate = ModelGate()
        let cleanup = CleanupEngine.live(RewriteEngine(), gate: gate)
        #expect(cleanup.gate === gate)
        let (voice, speaking) = try await holdForTheVoice(gate)
        let cleaning = Task { try await cleanup.complete("Hello.") }
        try await eventually { gate.snapshot.waiting.count == 1 }
        let translating = Task { try await cleanup.translate("Hello.", .chinese(.chinese)) }
        try await eventually { gate.snapshot.waiting.count == 2 }
        let reading = Task { try await cleanup.prepareTranslation(.chinese(.english)) }
        try await eventually { gate.snapshot.waiting.count == 3 }
        let unloading = Task { await cleanup.unload() }
        try await eventually { gate.snapshot.waiting.count == 4 }
        #expect(gate.snapshot.waiting == [.shared, .shared, .shared, .shared])
        voice.release()
        try await speaking.value
        await #expect(throws: RewriteError.notLoaded) { try await cleaning.value }
        await #expect(throws: RewriteError.notLoaded) { try await translating.value }
        await #expect(throws: RewriteError.notLoaded) { try await reading.value }
        await unloading.value
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    /// The speech and cleanup models run at the app's gate unless told otherwise, and every
    /// voice model of the build runs alone at it.
    @Test func theAppsModelsUseTheAppsGate() {
        #expect(Transcription.qwen3(Qwen3Engine(folder: { nil })).gate === ModelGate.live)
        #expect(CleanupEngine.live(RewriteEngine()).gate === ModelGate.live)
        let engines = VoiceEngines.live
        for kind in engines.available {
            let voice = engines.make(kind) as? ExclusiveSynthesizer
            #expect(voice != nil, "\(kind) is not behind the model gate")
            #expect(voice?.gate === ModelGate.live)
        }
    }
}
