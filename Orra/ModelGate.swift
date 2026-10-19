import Foundation
import os
import Synchronization

/// Keeps the voice model's MLX work apart from the speech and cleanup models' work, so that
/// mlx-swift cannot deadlock.
///
/// In mlx-swift 0.31.6 a compiled function takes its own lock and then MLX's global
/// evaluation lock. The first call of a compiled function, and every call with a new
/// shape, traces its body while the evaluation lock is held. A body that calls another
/// compiled function then takes that function's lock after the evaluation lock, the other
/// way round. MLXNN's activations, such as silu and gelu, are one compiled function each
/// for the whole process. Qwen3-TTS and CosyVoice3 trace compiled functions that call
/// them, at load and while speaking. The speech model and the cleanup model call them
/// directly. So a voice model trace next to a speech or cleanup call can leave two threads
/// waiting for each other's lock, and every later MLX call in the process waits forever.
/// That could hang Orra 0.4.0 at launch with Speak translations on, when the three models
/// load at once, and it hung a test build of 0.4.1. The speech model and the cleanup model
/// trace no compiled function that calls another, so they may run next to each other.
/// docs/dependencies.md says what to check on every update of the packages.
///
/// So the voice model holds the gate alone (`exclusive`), and the speech model and the
/// cleanup model share it (`shared`). A dictation reserves the gate from the press of its
/// key until it is over, and so does a load of the speech model or the cleanup model, see
/// `reserve()`. These rules decide who enters, after every change:
///
/// - While the voice model holds the gate, nobody else enters.
/// - While the gate is reserved, no voice request enters, and every shared call does.
/// - Otherwise a voice request enters once no shared call runs. Shared calls that came
///   after it wait behind it, so a steady flow of captions cannot keep the voice waiting.
/// - Otherwise every shared call enters.
///
/// So a dictation waits at most for the voice work under way when its key went down, such
/// as the piece being made, and a voice request that waits never comes in between two of
/// its calls. Requests enter in the order they came, within these rules. Waiting never
/// blocks a thread. A call that can enter at once does not suspend, so without voice work
/// the gate costs one lock per call. A task cancelled while it waits leaves the queue, and
/// the others move up. A body that throws releases the gate too.
///
/// A body never asks for the gate again, and neither do the tasks it starts. A shared call
/// inside a shared call would wait behind a voice request that waits for the outer call,
/// which never ends. Debug builds check this. In the same way, whoever holds a reservation
/// never waits for a voice request, which waits for the reservation to end.
///
/// The wrappers below put each model behind the gate: `Transcription.gated`,
/// `CleanupEngine.gated` and `ExclusiveSynthesizer`.
nonisolated final class ModelGate: Sendable {
    nonisolated enum Access: String, Sendable {
        /// The speech model and the cleanup model, which may run next to each other.
        case shared
        /// The voice model, which runs alone.
        case exclusive
    }

    /// True inside a gated body and in the tasks it starts, for the check that a body never
    /// asks for the gate again. Internal for tests.
    @TaskLocal static var isInside = false

    /// The one gate of the app.
    static let live = ModelGate()

    /// A wait longer than this is logged, with its access, whether the gate was reserved
    /// and its length.
    static let longWait: Duration = .milliseconds(100)

    private struct Waiter {
        let id: Int
        let access: Access
        /// Resumed with true once the waiter entered, false when it left for cancellation.
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var exclusive = false
        var shared = 0
        /// The reservations that have not ended.
        var reserved = 0
        /// In the order they came.
        var waiters: [Waiter] = []
        var lastID = 0

        /// Whether a new request, at the end of the queue, enters at once.
        func canEnter(_ access: Access) -> Bool {
            switch access {
            case .shared:
                !exclusive && (reserved > 0 || !waiters.contains { $0.access == .exclusive })
            case .exclusive:
                !exclusive && shared == 0 && reserved == 0 && waiters.isEmpty
            }
        }

        mutating func take(_ access: Access) {
            switch access {
            case .shared: shared += 1
            case .exclusive: exclusive = true
            }
        }

        /// Lets in every waiter the rules allow, and returns them, to be resumed once the
        /// lock is let go.
        mutating func admit() -> [CheckedContinuation<Bool, Never>] {
            guard !exclusive else { return [] }
            var admitted: [CheckedContinuation<Bool, Never>] = []
            var voiceAhead = false
            var waiting: [Waiter] = []
            for waiter in waiters {
                if waiter.access == .shared, reserved > 0 || !voiceAhead {
                    shared += 1
                    admitted.append(waiter.continuation)
                } else {
                    voiceAhead = voiceAhead || waiter.access == .exclusive
                    waiting.append(waiter)
                }
            }
            waiters = waiting
            // Every shared call ahead of the first voice request entered, so that request
            // leads the queue now.
            if shared == 0, reserved == 0, let first = waiters.first {
                assert(first.access == .exclusive, "A shared call waits at the head of the model gate's queue")
                waiters.removeFirst()
                exclusive = true
                admitted.append(first.continuation)
            }
            return admitted
        }
    }

    private let state = Mutex(State())

    /// Who holds the gate and who waits, in order.
    nonisolated struct Snapshot: Equatable, Sendable {
        var exclusive = false
        var shared = 0
        var reserved = 0
        var waiting: [Access] = []
    }

    /// The gate now. Internal for tests.
    var snapshot: Snapshot {
        state.withLock {
            Snapshot(exclusive: $0.exclusive, shared: $0.shared, reserved: $0.reserved, waiting: $0.waiters.map(\.access))
        }
    }

    /// Runs `body` once the gate lets it in, and releases the gate when `body` returns or
    /// throws. Throws CancellationError, without running `body`, when the task is
    /// cancelled while it waits.
    func run<T>(_ access: Access, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async throws -> T {
        try await acquire(access)
        return try await holding(access, body)
    }

    /// Like `run`, but waits for its turn also when the task is cancelled, for work that
    /// must not be dropped, such as an unload.
    func runEvenIfCancelled<T>(_ access: Access, isolation: isolated (any Actor)? = #isolation, _ body: () async -> T) async -> T {
        let entered = await enter(access, leavesWhenCancelled: false)
        assert(entered, "A wait that ignores cancellation left the model gate")
        return await holding(access, body)
    }

    /// Waits until the gate lets this request in. Throws CancellationError when the task
    /// is cancelled while it waits. Every acquire needs one `release`, best through
    /// `holding`. For work that outlives the task that asked for it, such as a voice model's
    /// stream, see ExclusiveSynthesizer.
    func acquire(_ access: Access) async throws {
        guard await enter(access, leavesWhenCancelled: true) else { throw CancellationError() }
    }

    /// Runs `body` with an access taken through `acquire`, and releases it when `body`
    /// returns or throws.
    func holding<T>(_ access: Access, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        defer { release(access) }
        return try await Self.$isInside.withValue(true) {
            try await body()
        }
    }

    /// Gives back an access taken through `acquire`, and lets in whoever may enter now.
    func release(_ access: Access) {
        let admitted = state.withLock { state in
            switch access {
            case .shared:
                precondition(state.shared > 0, "The model gate was released for a shared call that did not hold it")
                state.shared -= 1
            case .exclusive:
                precondition(state.exclusive, "The model gate was released for a voice request that did not hold it")
                state.exclusive = false
            }
            return state.admit()
        }
        resume(admitted)
    }

    /// Keeps voice requests out of the gate until `end()`, see `reserve()`.
    nonisolated final class Reservation: Sendable {
        private let gate: ModelGate
        private let isOver = Mutex(false)

        fileprivate init(_ gate: ModelGate) {
            self.gate = gate
        }

        /// Lets voice requests in again once no other reservation holds the gate. Only the
        /// first call counts.
        func end() {
            let ends = isOver.withLock { isOver in
                guard !isOver else { return false }
                isOver = true
                return true
            }
            if ends {
                gate.endReservation()
            }
        }

        /// A reservation ends at the latest when it is let go.
        deinit {
            end()
        }
    }

    /// Reserves the gate for work of several calls, such as a dictation from the press of
    /// its key until it is pasted, or a load of the cleanup model with the prompts read
    /// after it. Until the reservation ends, no voice request enters, so none comes in
    /// between the calls, and every shared call enters, also one that came after a voice
    /// request that waits. The voice work under way when it began goes on to its end. Whoever
    /// holds it must never wait for a voice request, which waits for the reservation to end.
    func reserve() -> Reservation {
        let admitted = state.withLock { state in
            state.reserved += 1
            return state.admit()
        }
        resume(admitted)
        return Reservation(self)
    }

    private func endReservation() {
        let admitted = state.withLock { state in
            precondition(state.reserved > 0, "A reservation of the model gate ended that did not hold it")
            state.reserved -= 1
            return state.admit()
        }
        resume(admitted)
    }

    private func resume(_ admitted: [CheckedContinuation<Bool, Never>]) {
        for continuation in admitted {
            continuation.resume(returning: true)
        }
    }

    /// Returns true once the request entered, false when its task was cancelled while it
    /// waited and `leavesWhenCancelled` is set.
    private func enter(_ access: Access, leavesWhenCancelled: Bool) async -> Bool {
        assert(!Self.isInside, "A body that holds the model gate asked for it again, which can wait for itself for good")
        let (id, reserved): (Int?, Bool) = state.withLock { state in
            if state.canEnter(access) {
                state.take(access)
                return (nil, false)
            }
            state.lastID += 1
            return (state.lastID, state.reserved > 0)
        }
        guard let id else { return true }
        let started = ContinuousClock.now
        let entered: Bool
        if leavesWhenCancelled {
            entered = await withTaskCancellationHandler {
                await wait(id, access, leavesWhenCancelled: true)
            } onCancel: {
                leave(id)
            }
        } else {
            entered = await wait(id, access, leavesWhenCancelled: false)
        }
        let waited = started.duration(to: .now)
        if entered, waited > Self.longWait {
            // The access, whether the gate was reserved when it asked, and the time only.
            Logger.modelGate.notice("Waited \(waited, privacy: .public) for the model gate, \(access.rawValue, privacy: .public) access, reserved: \(reserved, privacy: .public)")
        }
        return entered
    }

    private func wait(_ id: Int, _ access: Access, leavesWhenCancelled: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            // The gate may have opened since the first look, and the task may have been
            // cancelled before its waiter was in the queue for `leave` to find.
            let now: Bool? = state.withLock { state in
                if leavesWhenCancelled, Task.isCancelled {
                    return false
                }
                if state.canEnter(access) {
                    state.take(access)
                    return true
                }
                state.waiters.append(Waiter(id: id, access: access, continuation: continuation))
                return nil
            }
            if let now {
                continuation.resume(returning: now)
            }
        }
    }

    /// Takes a cancelled waiter out of the queue, and lets in whoever it held back.
    private func leave(_ id: Int) {
        let (left, admitted) = state.withLock { state -> (CheckedContinuation<Bool, Never>?, [CheckedContinuation<Bool, Never>]) in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return (nil, []) }
            let waiter = state.waiters.remove(at: index)
            return (waiter.continuation, state.admit())
        }
        left?.resume(returning: false)
        resume(admitted)
    }
}

extension Logger {
    /// The model gate. Accesses, reservations and times only.
    nonisolated static let modelGate = Logger(subsystem: ProblemReport.subsystem, category: "model-gate")
}

extension Transcription {
    /// The same speech model with every call shared at `gate`, see ModelGate. A dictation
    /// reserves `gate`, see PushToTalkController.
    func gated(_ gate: ModelGate) -> Transcription {
        let load = load
        let transcribe = transcribe
        return Transcription(
            load: { try await gate.run(.shared) { try await load() } },
            transcribe: { samples, context, language in
                try await gate.run(.shared) { try await transcribe(samples, context, language) }
            },
            gate: gate
        )
    }
}

extension CleanupEngine {
    /// The same cleanup model with every call shared at `gate`, see ModelGate. An unload
    /// waits for its turn even when its task is cancelled, so the memory is always given
    /// back. A load reserves `gate`, see TextCleanup.
    ///
    /// Each slice and each burst of a Projects job is a call of its own, so a voice request
    /// that waits goes in after the one under way, never after a whole job. The end of a
    /// job waits for its turn even when its task is cancelled, like an unload, so the job's
    /// memory is always given back.
    func gated(_ gate: ModelGate) -> CleanupEngine {
        let load = load
        let unload = unload
        let complete = complete
        let translate = translate
        let prepareTranslation = prepareTranslation
        let keepTranslationPrefixes = keepTranslationPrefixes
        let startJob = startJob
        let readSlice = readSlice
        let writeBurst = writeBurst
        let endJob = endJob
        let clearCache = clearCache
        return CleanupEngine(
            load: { folder in try await gate.run(.shared) { try await load(folder) } },
            unload: { await gate.runEvenIfCancelled(.shared) { await unload() } },
            complete: { text in try await gate.run(.shared) { try await complete(text) } },
            translate: { text, route in try await gate.run(.shared) { try await translate(text, route) } },
            prepareTranslation: { route in try await gate.run(.shared) { try await prepareTranslation(route) } },
            keepTranslationPrefixes: { routes in await gate.runEvenIfCancelled(.shared) { await keepTranslationPrefixes(routes) } },
            startJob: { prompt, maximumTokens in try await gate.run(.shared) { try await startJob(prompt, maximumTokens) } },
            readSlice: { job, tokens in try await gate.run(.shared) { try await readSlice(job, tokens) } },
            writeBurst: { job, tokens in try await gate.run(.shared) { try await writeBurst(job, tokens) } },
            endJob: { job in
                let ended: Result<String, any Error> = await gate.runEvenIfCancelled(.shared) {
                    do {
                        return .success(try await endJob(job))
                    } catch {
                        return .failure(error)
                    }
                }
                return try ended.get()
            },
            clearCache: { await gate.runEvenIfCancelled(.shared) { await clearCache() } },
            gate: gate
        )
    }
}

/// A voice model that runs only while it holds the model gate alone, see ModelGate.
/// VoiceEngines.live puts every voice model of the build behind one.
///
/// Loading, unloading and forgetting a voice hold the gate for the call. Unloading and
/// forgetting a voice wait for their turn even when their task is cancelled, so the memory
/// and anything derived from a voice sample are always let go. Speaking holds the gate
/// until the model's stream ends, which SpeechSynthesizer says is when the model is done
/// with the piece, not only until the reader stops reading. A reader that leaves while
/// the piece waits for the gate ends it before the model starts.
nonisolated struct ExclusiveSynthesizer: SpeechSynthesizer {
    let inner: any SpeechSynthesizer
    let gate: ModelGate

    init(_ inner: any SpeechSynthesizer, gate: ModelGate = .live) {
        self.inner = inner
        self.gate = gate
    }

    func load(model: URL, codec: URL) async throws {
        try await gate.run(.exclusive) { try await inner.load(model: model, codec: codec) }
    }

    func unload() async {
        await gate.runEvenIfCancelled(.exclusive) { await inner.unload() }
    }

    func forgetVoice() async {
        await gate.runEvenIfCancelled(.exclusive) { await inner.forgetVoice() }
    }

    func streams(voice: VoiceSample?) -> Bool {
        inner.streams(voice: voice)
    }

    func speak(_ text: String, in language: TranslationTarget, voice: VoiceSample?) -> AsyncThrowingStream<SpokenAudio, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SpokenAudio, any Error>.makeStream()
        let waiting = Task { [inner, gate] in
            do {
                try await gate.acquire(.exclusive)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            guard !Task.isCancelled else {
                gate.release(.exclusive)
                continuation.finish(throwing: CancellationError())
                return
            }
            // A task of its own, which the reader leaving does not cancel, so the model's
            // stream is read to its end and the gate is held until then. Parts that come
            // after the reader left are dropped.
            Task {
                let failure: (any Error)? = await gate.holding(.exclusive) {
                    do {
                        for try await part in inner.speak(text, in: language, voice: voice) {
                            continuation.yield(part)
                        }
                        return nil
                    } catch {
                        return error
                    }
                }
                // After the release, so the reader can use the speech model at once.
                continuation.finish(throwing: failure)
            }
        }
        continuation.onTermination = { _ in waiting.cancel() }
        return stream
    }
}
