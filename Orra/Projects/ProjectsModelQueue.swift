import Foundation
import Observation
import os

extension Logger {
    /// Projects work on the cleanup model. Counts of slices, bursts, tokens and pauses, and
    /// times only, never text.
    nonisolated static let projectsModel = Logger(subsystem: ProblemReport.subsystem, category: "projects-model")
}

/// One prompt for the model, from Projects.
nonisolated struct ProjectsModelRequest: Equatable, Sendable {
    nonisolated enum Priority: String, Sendable {
        /// The user asked for it and waits for it, such as an explanation.
        case user
        /// Work the user did not ask for just now, such as sorting new mail.
        case background
    }

    /// The whole prompt, which ends with the caller's own prefill. The answer comes back
    /// without it.
    let prompt: String
    /// The most tokens the answer may have.
    let maximumTokens: Int
    let priority: Priority
}

/// What ProjectsModelQueue needs. Closures, so tests pass fakes. The app's come from
/// TextCleanup.projectsEnvironment.
struct ProjectsModelEnvironment {
    /// Begins a job on a prompt with a maximum number of answer tokens, see
    /// RewriteEngine.startJob.
    var startJob: @Sendable (String, Int) async throws -> RewriteEngine.JobStart
    /// Reads a number of a job's prompt tokens, see RewriteEngine.readSlice.
    var readSlice: @Sendable (Int, Int) async throws -> RewriteEngine.SliceRun
    /// Writes a number of a job's answer tokens, see RewriteEngine.writeBurst.
    var writeBurst: @Sendable (Int, Int) async throws -> RewriteEngine.BurstRun
    /// Ends a job with its answer, see RewriteEngine.endJob.
    var endJob: @Sendable (Int) async throws -> String
    /// True from the press of the talk key or the translation key until the dictation is
    /// pasted or cancelled, see EngineTurns.isDictating.
    var isDictating: () -> Bool
    /// True while Live Captions run.
    var captionsOn: () -> Bool
    /// The memory pressure of the Mac, see ProjectsMemoryPressure.
    var memoryPressure: () -> ProjectsMemoryPressure.Level
    /// True while the voice model of Speak Translations is loaded.
    var voiceLoaded: () -> Bool
    /// The Mac's memory in bytes, for the voice rule, see ProjectsModelQueue.
    var physicalMemory: UInt64
    /// Whether the model can run a job now, after waiting for a load under way, see
    /// TextCleanup.waitUntilLoadedForProjects.
    var waitUntilLoaded: () async -> Bool
    /// Takes a holder on the model for a request of the user, see
    /// TextCleanup.projectsStarted.
    var holdModel: () -> Void
    /// Gives back a holder that `holdModel` took, see TextCleanup.projectsStopped.
    var releaseModel: () -> Void
    /// Waits for a time. Tests pass a clock they move.
    var sleep: @Sendable (Duration) async throws -> Void
}

/// Runs Projects prompts on the cleanup model so that dictation stays as fast as without
/// them.
///
/// - One job runs at a time. Requests of the user go before background ones, and
///   `cancelBackground()` drops the background ones when the Projects window closes. Each
///   request of the user holds the model from when it comes until it ends, see
///   `holdModel`, so closing the window does not unload the model under it.
/// - The model reads a prompt in slices and writes the answer in bursts, each its own call
///   and its own entry at the model gate, see RewriteEngine.startJob. A cleanup or a
///   translation never waits for more than the slice or burst under way.
/// - Before every slice and burst the job waits while a dictation is under way, from the
///   press of either key until the paste or cancel, while Live Captions run, while the
///   memory pressure is not normal, and on a Mac with less than 24 GiB while the voice
///   model is loaded. `pause` says why it waits. A key press pauses a job and never drops
///   it.
/// - The press of a key cancels the call under way at once, before the dictation reserves
///   the model gate, which would let a call that waits there in, see `dictationStarted()`.
///   For the other pauses, while a call waits at the model gate or at the engine, the queue
///   looks every `pollInterval` whether a pause began, and then cancels the call. A call
///   cancelled before it began leaves without running and runs again after the pause, so a
///   call that waited behind the voice model never starts during a dictation. A burst
///   under way stops after its next token. A slice under way runs to its end.
/// - Slices start at 256 tokens. A slice that ran longer than 0.2 s halves the next one,
///   down to 64 tokens, and one that ran under 0.1 s doubles it, up to 512, so every Mac
///   keeps a slice near 0.1 to 0.2 s. The time is the one the model ran, measured inside
///   the engine, so a wait behind a dictation's cleanup never makes slices smaller. Other
///   sizes can give another greedy answer to the same prompt, see RewriteEngine.readSlice,
///   so a run that must repeat its answers needs slices of one size.
/// - Cancelling the caller's task ends the job and gives its memory back. The end of a job
///   waits while a dictation is under way, also for a cancelled job. A job that an unload
///   dropped starts again once the model is loaded, and fails on a second drop.
///
/// Why both: on an M5 Pro a prompt of 8,192 tokens read in one call made cleanups miss
/// their time limit, and slices that did not pause for a dictation made every dictation
/// paste about 1.5 s later, since the speech model shares the GPU with them.
@Observable
final class ProjectsModelQueue {
    /// Why the job under way waits before its next slice or burst.
    nonisolated enum Pause: String, Sendable {
        case dictation
        case captions
        case memory
        case voice
        /// The model is loading.
        case loading
    }

    /// How many prompt tokens the next slice reads, by how long the last one ran.
    nonisolated struct SliceSizer: Equatable, Sendable {
        static let first = 256
        static let smallest = 64
        static let largest = 512
        /// A slice that ran longer halves the next one.
        static let slow: Duration = .milliseconds(200)
        /// A whole slice that ran shorter doubles the next one.
        static let fast: Duration = .milliseconds(100)

        private(set) var tokens = first

        /// Sizes the next slice after one that was asked for `asked` tokens. The last slice
        /// of a prompt reads fewer and runs short, so only a slice that read all it was
        /// asked for makes the next one larger.
        mutating func record(_ slice: RewriteEngine.SliceRun, asked: Int) {
            if slice.ran > Self.slow {
                tokens = max(tokens / 2, Self.smallest)
            } else if slice.ran < Self.fast, slice.read >= asked {
                tokens = min(tokens * 2, Self.largest)
            }
        }
    }

    /// How many answer tokens one burst writes.
    nonisolated static let burstTokens = 32
    /// How often a job that waits looks again whether it may go on.
    nonisolated static let pollInterval: Duration = .milliseconds(50)
    /// Below this much memory no job runs while the voice model is loaded. Covers Macs
    /// with 16 and 18 GB.
    nonisolated static let voiceRuleMemory: UInt64 = 24 << 30

    /// Why the job under way waits now, nil while it runs or when no job runs.
    private(set) var pause: Pause?

    @ObservationIgnored private let environment: ProjectsModelEnvironment
    /// Kept from job to job, so the size fits this Mac. Internal for tests.
    @ObservationIgnored private(set) var sizer = SliceSizer()
    /// True while a job runs or is about to.
    @ObservationIgnored private var isBusy = false
    /// The requests waiting for the job under way, in the order they came.
    @ObservationIgnored private var line: [Waiter] = []
    @ObservationIgnored private var lastTicket = 0
    /// The job under way.
    @ObservationIgnored private var running: (priority: ProjectsModelRequest.Priority, task: Task<String, any Error>)?
    /// Counts the calls of `cancelBackground()`, so a background request that was let in
    /// before one and had not begun yet leaves too.
    @ObservationIgnored private var backgroundGeneration = 0
    /// Cancels the call under way, see `dictationStarted()`.
    @ObservationIgnored private var cancelCall: (() -> Void)?

    private struct Waiter {
        let ticket: Int
        let priority: ProjectsModelRequest.Priority
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// What one job did, for the log.
    private struct JobLog {
        var promptTokens = 0
        var slices: [Duration] = []
        var bursts: [Duration] = []
        var written = 0
        var pauses = 0
        var paused: Duration = .zero
        /// Calls cancelled for a pause before they began, which ran again after it.
        var gaveWay = 0
        var restarts = 0
    }

    init(environment: ProjectsModelEnvironment) {
        self.environment = environment
    }

    /// Runs a prompt once the jobs before it are done, and returns what the model wrote,
    /// without the prompt's prefill. Throws RewriteError.notLoaded when the model is not
    /// there, RewriteError.promptTooLong for a prompt over the budget, and
    /// CancellationError when the caller's task is cancelled or `cancelBackground()` drops
    /// a background request.
    func run(_ request: ProjectsModelRequest) async throws -> String {
        try Task.checkCancellation()
        let isUsers = request.priority == .user
        if isUsers {
            environment.holdModel()
        }
        defer {
            if isUsers {
                environment.releaseModel()
            }
        }
        let generation = backgroundGeneration
        try await waitInLine(request.priority)
        // Let in, but `cancelBackground()` ran before this request got here.
        if !isUsers, generation != backgroundGeneration {
            passTheTurn()
            throw CancellationError()
        }
        defer { passTheTurn() }
        let job = Task { try await self.execute(request) }
        running = (request.priority, job)
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Drops the background requests waiting, also one let in that has not begun, and ends
    /// the background job under way, such as when the Projects window closes.
    func cancelBackground() {
        backgroundGeneration += 1
        let dropped = line.filter { $0.priority == .background }
        line.removeAll { $0.priority == .background }
        for waiter in dropped {
            waiter.continuation.resume(throwing: CancellationError())
        }
        if let running, running.priority == .background {
            running.task.cancel()
        }
    }

    /// The talk key or the translation key went down, before the dictation reserves the
    /// model gate. Cancels the call under way at once, so one that waits at the gate leaves
    /// it before the reservation lets it in. The job waits until the dictation is over, as
    /// for any pause.
    func dictationStarted() {
        cancelCall?()
    }

    /// How many requests wait for the job under way. Internal for tests.
    var waitingCount: Int {
        line.count
    }

    // MARK: The line

    private func waitInLine(_ priority: ProjectsModelRequest.Priority) async throws {
        try Task.checkCancellation()
        guard isBusy else {
            isBusy = true
            return
        }
        lastTicket += 1
        let ticket = lastTicket
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    line.append(Waiter(ticket: ticket, priority: priority, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.leaveLine(ticket)
            }
        }
    }

    private func leaveLine(_ ticket: Int) {
        guard let index = line.firstIndex(where: { $0.ticket == ticket }) else { return }
        line.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Lets the next request run: the first of the user's, otherwise the first one.
    private func passTheTurn() {
        running = nil
        guard let next = line.firstIndex(where: { $0.priority == .user }) ?? line.indices.first else {
            isBusy = false
            return
        }
        line.remove(at: next).continuation.resume()
    }

    // MARK: The job

    private func execute(_ request: ProjectsModelRequest) async throws -> String {
        let started = ContinuousClock.now
        var log = JobLog()
        do {
            let answer: String
            do {
                answer = try await attempt(request, &log)
            } catch RewriteError.jobDropped {
                log.restarts += 1
                Logger.projectsModel.notice("A Projects job was dropped when the model was unloaded, starting it again once the model is loaded")
                answer = try await attempt(request, &log)
            }
            Logger.projectsModel.notice("Projects job (\(request.priority.rawValue, privacy: .public)) done in \(started.duration(to: .now), privacy: .public): \(Self.summary(log), privacy: .public)")
            return answer
        } catch {
            Logger.projectsModel.notice("Projects job (\(request.priority.rawValue, privacy: .public)) ended by \(Self.logName(error), privacy: .public) after \(started.duration(to: .now), privacy: .public): \(Self.summary(log), privacy: .public)")
            throw error
        }
    }

    private func attempt(_ request: ProjectsModelRequest, _ log: inout JobLog) async throws -> String {
        try await waitForTurn(&log)
        guard await modelIsLoaded() else {
            try Task.checkCancellation()
            throw RewriteError.notLoaded
        }
        let (startJob, readSlice, writeBurst) = (environment.startJob, environment.readSlice, environment.writeBurst)
        let (prompt, maximumTokens) = (request.prompt, request.maximumTokens)
        let job = try await call(&log) { try await startJob(prompt, maximumTokens) }
        log.promptTokens = job.promptTokens
        do {
            var remaining = 0
            repeat {
                let asked = sizer.tokens
                let slice = try await call(&log) { try await readSlice(job.id, asked) }
                sizer.record(slice, asked: asked)
                log.slices.append(slice.ran)
                // A slice that read nothing leaves the rest to the first burst.
                remaining = slice.read > 0 ? slice.remaining : 0
            } while remaining > 0
            var finished = false
            repeat {
                let burst = try await call(&log) { try await writeBurst(job.id, Self.burstTokens) }
                log.bursts.append(burst.ran)
                log.written += burst.written
                finished = burst.finished || burst.written == 0
            } while !finished
            // A caller cancelled during the last burst gets no answer, and the job ends.
            try Task.checkCancellation()
        } catch {
            // Gives the job's memory back, whatever ended it. After an unload the job is
            // gone already.
            _ = try? await end(job.id)
            throw error
        }
        return try await end(job.id)
    }

    /// Runs one call of the job once it may go on, see `waitForTurn`, in a task of its own
    /// that a pause cancels, see ProjectsModelQueue. A call cancelled before it began
    /// throws CancellationError at the gate or at the engine and changes nothing, so it
    /// runs again after the pause. A burst cancelled while it writes returns what it wrote.
    /// What a call returns is kept also when the caller was cancelled meanwhile, so a job
    /// that started then is ended, see `attempt`.
    private func call<T: Sendable>(_ log: inout JobLog, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        while true {
            try await waitForTurn(&log)
            let task = Task { try await work() }
            cancelCall = { task.cancel() }
            let watch = Task { [weak self, sleep = environment.sleep] in
                while (try? await sleep(Self.pollInterval)) != nil {
                    if self?.pauseReason() != nil {
                        task.cancel()
                        return
                    }
                }
            }
            let result = await withTaskCancellationHandler {
                await task.result
            } onCancel: {
                task.cancel()
            }
            cancelCall = nil
            watch.cancel()
            if case .success(let value) = result {
                return value
            }
            try Task.checkCancellation()
            do {
                return try result.get()
            } catch is CancellationError {
                log.gaveWay += 1
            }
        }
    }

    /// Ends a job once no dictation is under way, also when the job's task was cancelled,
    /// so a dictation never meets the end of a job and the job's memory always goes back.
    private func end(_ id: Int) async throws -> String {
        let endJob = environment.endJob
        // A task of its own, which the caller's cancellation does not reach.
        return try await Task {
            while environment.isDictating() {
                try? await environment.sleep(Self.pollInterval)
            }
            return try await endJob(id)
        }.value
    }

    /// Returns once the job may run its next call, and throws when its task is cancelled.
    private func waitForTurn(_ log: inout JobLog) async throws {
        try Task.checkCancellation()
        guard pauseReason() != nil else { return }
        let started = ContinuousClock.now
        log.pauses += 1
        defer {
            pause = nil
            log.paused += started.duration(to: .now)
        }
        while let reason = pauseReason() {
            pause = reason
            try await environment.sleep(Self.pollInterval)
        }
        try Task.checkCancellation()
    }

    private func pauseReason() -> Pause? {
        if environment.isDictating() {
            return .dictation
        }
        if environment.captionsOn() {
            return .captions
        }
        if environment.memoryPressure() != .normal {
            return .memory
        }
        if environment.physicalMemory < Self.voiceRuleMemory, environment.voiceLoaded() {
            return .voice
        }
        return nil
    }

    private func modelIsLoaded() async -> Bool {
        pause = .loading
        defer { pause = nil }
        return await environment.waitUntilLoaded()
    }

    /// Counts and times only.
    private static func summary(_ log: JobLog) -> String {
        let longest = log.slices.max() ?? .zero
        let reading = log.slices.reduce(Duration.zero, +)
        let longestBurst = log.bursts.max() ?? .zero
        return "\(log.promptTokens) prompt tokens in \(log.slices.count) slices that ran \(seconds(reading)) in all and \(seconds(longest)) at most, \(log.bursts.count) bursts wrote \(log.written) tokens and ran \(seconds(longestBurst)) at most, paused \(log.pauses) times for \(seconds(log.paused)), gave way \(log.gaveWay) times, started again \(log.restarts) times"
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.3f s", duration / .seconds(1))
    }

    /// The kind of error, never its description, which could hold text.
    private static func logName(_ error: any Error) -> String {
        if let error = error as? RewriteError {
            return "RewriteError.\(error)"
        }
        if error is CancellationError {
            return "cancellation"
        }
        return String(reflecting: type(of: error))
    }
}
