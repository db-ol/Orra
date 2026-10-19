import Foundation
import Testing
@testable import Orra

/// The queue that runs Projects prompts on the cleanup model in slices and bursts, with a
/// stand in for the engine's job calls and a clock the test moves. No model runs and no
/// time decides a result.
@MainActor
struct ProjectsModelQueueTests {
    /// A stand in for RewriteEngine's job calls that counts tokens the way the engine does,
    /// can hold a slice or a burst until the test lets it go, and records every call.
    @MainActor
    final class FakeJobs {
        /// The prompt tokens of a prompt.
        var promptTokens: (String) -> Int = { $0.count }
        /// The answer tokens every job writes before the model ends it.
        var answerTokens = 70
        var answer = "好的。"
        /// How long each slice ran inside the engine, by the order of the slices. Later
        /// slices take the last value.
        var ran: [Duration] = [.milliseconds(150)]
        /// Waits this long before a slice returns, as a slice that waited behind other work
        /// at the engine.
        var waitsBeforeEachSlice: Duration?
        var holdsSlices = false
        var holdsBursts = false
        /// The slices, counted from 1 over every job, that throw RewriteError.jobDropped
        /// as after an unload.
        var dropsSlices: Set<Int> = []
        var loaded = true
        var holdsTheLoad = false

        var isDictating = false
        var captionsOn = false
        var memory: ProjectsMemoryPressure.Level = .normal
        var voiceLoaded = false
        var physicalMemory: UInt64 = 32 << 30

        /// A gate the job calls run at, to look at it from inside a call.
        var gate: ModelGate?
        /// The gate as each slice and burst saw it from inside.
        private(set) var gateInside: [ModelGate.Snapshot] = []

        /// "start <prompt>", "slice <job> <tokens>", "burst <job> <tokens>", "end <job>"
        /// and "voice", in the order they ran.
        private(set) var events: [String] = []
        private(set) var slicesBegun = 0
        private(set) var loadWaits = 0
        private var jobs: [Int: (prompt: Int, read: Int, written: Int)] = [:]
        private var lastJob = 0
        private var held: [CheckedContinuation<Void, Never>] = []

        var isHolding: Bool {
            !held.isEmpty
        }

        func letGo() {
            let continuations = held
            held = []
            for continuation in continuations {
                continuation.resume()
            }
        }

        func note(_ event: String) {
            events.append(event)
        }

        var slices: [String] {
            events.filter { $0.hasPrefix("slice") }
        }

        var bursts: [String] {
            events.filter { $0.hasPrefix("burst") }
        }

        var ends: [String] {
            events.filter { $0.hasPrefix("end") }
        }

        var starts: [String] {
            events.filter { $0.hasPrefix("start") }
        }

        /// The tokens each slice was asked for, in order.
        var sliceSizes: [Int] {
            slices.compactMap { $0.split(separator: " ").last.flatMap { Int($0) } }
        }

        func start(_ prompt: String, _ maximumTokens: Int) throws -> RewriteEngine.JobStart {
            let tokens = promptTokens(prompt)
            guard tokens <= RewriteEngine.maximumJobPromptTokens else { throw RewriteError.promptTooLong }
            lastJob += 1
            jobs[lastJob] = (tokens, 0, 0)
            events.append("start \(prompt)")
            return RewriteEngine.JobStart(id: lastJob, promptTokens: tokens)
        }

        func slice(_ id: Int, _ tokens: Int) async throws -> RewriteEngine.SliceRun {
            slicesBegun += 1
            let number = slicesBegun
            if let gate {
                gateInside.append(gate.snapshot)
            }
            events.append("slice \(id) \(tokens)")
            if holdsSlices {
                await withCheckedContinuation { held.append($0) }
            }
            if let waitsBeforeEachSlice {
                try await Task.sleep(for: waitsBeforeEachSlice)
            }
            if dropsSlices.contains(number) {
                jobs[id] = nil
            }
            guard var job = jobs[id] else { throw RewriteError.jobDropped }
            let last = max(job.prompt - 1, 0)
            let end = min(job.read + tokens, last)
            let read = end - job.read
            job.read = end
            jobs[id] = job
            return RewriteEngine.SliceRun(read: read, remaining: last - end, ran: ran[min(number - 1, ran.count - 1)])
        }

        func burst(_ id: Int, _ tokens: Int) async throws -> RewriteEngine.BurstRun {
            if let gate {
                gateInside.append(gate.snapshot)
            }
            events.append("burst \(id) \(tokens)")
            if holdsBursts {
                await withCheckedContinuation { held.append($0) }
            }
            guard var job = jobs[id] else { throw RewriteError.jobDropped }
            let written = min(tokens, answerTokens - job.written)
            job.written += written
            job.read = job.prompt
            jobs[id] = job
            return RewriteEngine.BurstRun(written: written, finished: job.written >= answerTokens, ran: .milliseconds(300))
        }

        func end(_ id: Int) throws -> String {
            events.append("end \(id)")
            guard jobs.removeValue(forKey: id) != nil else { throw RewriteError.jobDropped }
            return answer
        }

        func waitUntilLoaded() async -> Bool {
            loadWaits += 1
            if holdsTheLoad {
                await withCheckedContinuation { held.append($0) }
            }
            return loaded
        }

        /// The job calls, as CleanupEngine passes them on.
        var engine: CleanupEngine {
            CleanupEngine(
                load: { _ in },
                unload: {},
                complete: { _ in "" },
                startJob: { [self] in try await start($0, $1) },
                readSlice: { [self] in try await slice($0, $1) },
                writeBurst: { [self] in try await burst($0, $1) },
                endJob: { [self] in try await end($0) }
            )
        }

        func environment(_ engine: CleanupEngine, clock: TestClock) -> ProjectsModelEnvironment {
            ProjectsModelEnvironment(
                startJob: engine.startJob,
                readSlice: engine.readSlice,
                writeBurst: engine.writeBurst,
                endJob: engine.endJob,
                isDictating: { [self] in isDictating },
                captionsOn: { [self] in captionsOn },
                memoryPressure: { [self] in memory },
                voiceLoaded: { [self] in voiceLoaded },
                physicalMemory: physicalMemory,
                waitUntilLoaded: { [self] in await waitUntilLoaded() },
                sleep: { [clock] in try await clock.sleep(for: $0) }
            )
        }
    }

    let fake = FakeJobs()
    let clock = TestClock()

    private func makeQueue(gate: ModelGate? = nil) -> ProjectsModelQueue {
        let engine = gate.map { fake.engine.gated($0) } ?? fake.engine
        fake.gate = gate
        return ProjectsModelQueue(environment: fake.environment(engine, clock: clock))
    }

    private static func request(_ prompt: String = String(repeating: "x", count: 1_000), _ priority: ProjectsModelRequest.Priority = .user) -> ProjectsModelRequest {
        ProjectsModelRequest(prompt: prompt, maximumTokens: 100, priority: priority)
    }

    /// Lets the tasks the clock or the stand in woke run, for a moment.
    private func settle() async throws {
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Moves the clock by one look of a waiting job, once it waits on the clock.
    private func poll() async throws {
        try await eventually { clock.sleeping > 0 }
        clock.advance(by: ProjectsModelQueue.pollInterval)
        try await settle()
    }

    // MARK: Slices and bursts

    @Test func aJobReadsThePromptInSlicesAndWritesTheAnswerInBursts() async throws {
        let queue = makeQueue()
        let answer = try await queue.run(Self.request())
        #expect(answer == "好的。")
        // 999 tokens in slices, the last one for the first burst.
        #expect(fake.slices == ["slice 1 256", "slice 1 256", "slice 1 256", "slice 1 256"])
        #expect(fake.bursts == ["burst 1 32", "burst 1 32", "burst 1 32"])
        #expect(fake.ends == ["end 1"])
        #expect(fake.events.first == "start " + Self.request().prompt)
        #expect(queue.pause == nil)
    }

    @Test func eachSliceAndBurstIsItsOwnSharedGateEntry() async throws {
        let gate = ModelGate()
        let queue = makeQueue(gate: gate)
        fake.holdsSlices = true
        let job = Task { try await queue.run(Self.request()) }
        try await eventually { fake.isHolding }
        // A voice request that asks during the first slice goes in right after it, before
        // the second.
        let voice = Task {
            try await gate.run(.exclusive) { fake.note("voice") }
        }
        try await eventually { gate.snapshot.waiting == [.exclusive] }
        fake.holdsSlices = false
        fake.letGo()
        _ = try await job.value
        try await voice.value
        #expect(Array(fake.events.prefix(4)) == ["start " + Self.request().prompt, "slice 1 256", "voice", "slice 1 256"])
        // Inside every slice and burst the gate held that one shared call and nothing else.
        #expect(fake.gateInside.count == 7)
        #expect(fake.gateInside.allSatisfy { $0 == ModelGate.Snapshot(shared: 1) })
        #expect(gate.snapshot == ModelGate.Snapshot())
    }

    // MARK: Turns

    @Test func noSliceStartsWhileDictatingAndTheSliceUnderWayFinishes() async throws {
        let queue = makeQueue()
        fake.holdsSlices = true
        let job = Task { try await queue.run(Self.request()) }
        try await eventually { fake.isHolding }
        // The talk key goes down during the first slice, which runs to its end.
        fake.isDictating = true
        fake.holdsSlices = false
        fake.letGo()
        try await eventually { queue.pause == .dictation }
        for _ in 0..<10 {
            try await poll()
        }
        #expect(fake.slices.count == 1)
        #expect(queue.pause == .dictation)
        // The paste: the job goes on where it was and loses nothing.
        fake.isDictating = false
        try await poll()
        let answer = try await job.value
        #expect(answer == "好的。")
        #expect(fake.slices.count == 4)
        #expect(fake.starts.count == 1)
        #expect(queue.pause == nil)
    }

    @Test func noBurstStartsWhileDictating() async throws {
        let queue = makeQueue()
        fake.holdsBursts = true
        let job = Task { try await queue.run(Self.request()) }
        try await eventually { fake.isHolding }
        fake.isDictating = true
        fake.holdsBursts = false
        fake.letGo()
        try await eventually { queue.pause == .dictation }
        try await poll()
        try await poll()
        #expect(fake.bursts.count == 1)
        fake.isDictating = false
        try await poll()
        _ = try await job.value
        #expect(fake.bursts.count == 3)
    }

    @Test func captionsPauseTheJob() async throws {
        let queue = makeQueue()
        fake.captionsOn = true
        let job = Task { try await queue.run(Self.request()) }
        try await eventually { queue.pause == .captions }
        try await poll()
        #expect(fake.events.isEmpty)
        fake.captionsOn = false
        try await poll()
        _ = try await job.value
        #expect(fake.slices.count == 4)
    }

    @Test func memoryPressurePausesTheJobUntilItIsNormal() async throws {
        let memory = ProjectsMemoryPressure()
        let queue = makeQueue()
        fake.holdsSlices = true
        let job = Task { try await queue.run(Self.request()) }
        try await eventually { fake.isHolding }
        // The level as the dispatch source reports it.
        memory.update(try #require(ProjectsMemoryPressure.level(of: .warning)))
        fake.memory = memory.level
        fake.holdsSlices = false
        fake.letGo()
        try await eventually { queue.pause == .memory }
        memory.update(try #require(ProjectsMemoryPressure.level(of: [.warning, .critical])))
        fake.memory = memory.level
        #expect(memory.level == .critical)
        try await poll()
        #expect(queue.pause == .memory)
        #expect(fake.slices.count == 1)
        memory.update(try #require(ProjectsMemoryPressure.level(of: .normal)))
        fake.memory = memory.level
        try await poll()
        _ = try await job.value
        #expect(fake.slices.count == 4)
        #expect(queue.pause == nil)
    }

    @Test func stoppingTheMemoryWatchEndsAPause() {
        let memory = ProjectsMemoryPressure()
        memory.update(.warning)
        memory.stop()
        #expect(memory.level == .normal)
        #expect(ProjectsMemoryPressure.level(of: []) == nil)
    }

    @Test func theVoiceModelPausesJobsOnlyBelow24GiB() async throws {
        fake.voiceLoaded = true
        fake.physicalMemory = 16 << 30
        let small = makeQueue()
        let job = Task { try await small.run(Self.request()) }
        try await eventually { small.pause == .voice }
        try await poll()
        #expect(fake.events.isEmpty)
        fake.voiceLoaded = false
        try await poll()
        _ = try await job.value
        // A Mac with 18 GB is under the bar too, one with 24 GB is not.
        #expect(UInt64(18) << 30 < ProjectsModelQueue.voiceRuleMemory)
        fake.voiceLoaded = true
        fake.physicalMemory = 24 << 30
        let large = makeQueue()
        _ = try await large.run(Self.request())
        #expect(fake.starts.count == 2)
    }

    // MARK: Slice size

    @Test func theSliceSizeFollowsHowLongTheLastSliceRan() async throws {
        let queue = makeQueue()
        fake.ran = [.milliseconds(250), .milliseconds(250), .milliseconds(250), .milliseconds(50), .milliseconds(50), .milliseconds(50), .milliseconds(50), .milliseconds(150)]
        _ = try await queue.run(Self.request(String(repeating: "x", count: 3_000)))
        // Halved twice down to 64 and held there, doubled up to 512 and held there.
        #expect(Array(fake.sliceSizes.prefix(9)) == [256, 128, 64, 64, 128, 256, 512, 512, 512])
        // The size is kept for the next job.
        #expect(queue.sizer.tokens == 512)
    }

    @Test func onlyAWholeQuickSliceDoublesTheNext() {
        var sizer = ProjectsModelQueue.SliceSizer()
        sizer.record(RewriteEngine.SliceRun(read: 40, remaining: 0, ran: .milliseconds(20)), asked: 256)
        #expect(sizer.tokens == 256)
        sizer.record(RewriteEngine.SliceRun(read: 256, remaining: 10, ran: .milliseconds(100)), asked: 256)
        #expect(sizer.tokens == 256)
        sizer.record(RewriteEngine.SliceRun(read: 256, remaining: 10, ran: .milliseconds(200)), asked: 256)
        #expect(sizer.tokens == 256)
        sizer.record(RewriteEngine.SliceRun(read: 30, remaining: 0, ran: .milliseconds(201)), asked: 256)
        #expect(sizer.tokens == 128)
    }

    @Test func aWaitOutsideTheEngineDoesNotMakeSlicesSmaller() async throws {
        let queue = makeQueue()
        // Each slice waits for other work first, far longer than 0.2 s with the wait, but
        // runs 0.15 s itself.
        fake.waitsBeforeEachSlice = .milliseconds(250)
        _ = try await queue.run(Self.request(String(repeating: "x", count: 600)))
        #expect(fake.sliceSizes == [256, 256, 256])
    }

    // MARK: Limits and failures

    @Test func aPromptOverTheBudgetIsRefused() async throws {
        let queue = makeQueue()
        await #expect(throws: RewriteError.promptTooLong) {
            try await queue.run(Self.request(String(repeating: "x", count: RewriteEngine.maximumJobPromptTokens + 1)))
        }
        #expect(fake.slices.isEmpty)
        #expect(fake.ends.isEmpty)
        // At the budget it runs.
        _ = try await queue.run(Self.request(String(repeating: "x", count: RewriteEngine.maximumJobPromptTokens)))
        #expect(fake.slices.count == 32)
    }

    @Test func aMissingModelFailsTheRequestAndALoadIsWaitedFor() async throws {
        let queue = makeQueue()
        fake.loaded = false
        await #expect(throws: RewriteError.notLoaded) {
            try await queue.run(Self.request())
        }
        #expect(fake.events.isEmpty)
        fake.loaded = true
        fake.holdsTheLoad = true
        let job = Task { try await queue.run(Self.request()) }
        try await eventually { fake.isHolding }
        #expect(queue.pause == .loading)
        fake.holdsTheLoad = false
        fake.letGo()
        _ = try await job.value
        #expect(queue.pause == nil)
    }

    @Test func cancellingTheCallerEndsTheJob() async throws {
        let queue = makeQueue()
        fake.holdsSlices = true
        let job = Task { try await queue.run(Self.request()) }
        try await eventually { fake.isHolding }
        job.cancel()
        try await settle()
        // The slice under way still runs to its end.
        #expect(fake.ends.isEmpty)
        fake.holdsSlices = false
        fake.letGo()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(fake.slices.count == 1)
        #expect(fake.ends == ["end 1"])
    }

    @Test func cancellingTheCallerDuringAPauseEndsTheJob() async throws {
        let queue = makeQueue()
        fake.holdsSlices = true
        let job = Task { try await queue.run(Self.request()) }
        try await eventually { fake.isHolding }
        fake.isDictating = true
        fake.holdsSlices = false
        fake.letGo()
        try await eventually { queue.pause == .dictation }
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(fake.ends == ["end 1"])
        #expect(queue.pause == nil)
        // The next request runs.
        fake.isDictating = false
        _ = try await queue.run(Self.request())
        #expect(fake.ends == ["end 1", "end 2"])
    }

    @Test func aDroppedJobStartsAgainOnce() async throws {
        let queue = makeQueue()
        fake.dropsSlices = [2]
        let answer = try await queue.run(Self.request())
        #expect(answer == "好的。")
        #expect(fake.starts.count == 2)
        #expect(fake.loadWaits == 2)
        // The dropped job is gone already, and the second one ends as usual.
        #expect(fake.ends == ["end 1", "end 2"])
    }

    @Test func aSecondDropFailsTheRequest() async throws {
        let queue = makeQueue()
        fake.dropsSlices = [2, 4]
        await #expect(throws: RewriteError.jobDropped) {
            try await queue.run(Self.request())
        }
        #expect(fake.starts.count == 2)
    }

    // MARK: Order

    @Test func userRequestsGoBeforeBackgroundOnes() async throws {
        let queue = makeQueue()
        fake.holdsSlices = true
        let first = Task { try await queue.run(Self.request("first", .background)) }
        try await eventually { fake.isHolding }
        let background = Task { try await queue.run(Self.request("background", .background)) }
        try await settle()
        let user = Task { try await queue.run(Self.request("user", .user)) }
        try await settle()
        // One job at a time.
        #expect(fake.starts == ["start first"])
        fake.holdsSlices = false
        fake.letGo()
        _ = try await first.value
        _ = try await user.value
        _ = try await background.value
        #expect(fake.starts == ["start first", "start user", "start background"])
    }

    @Test func cancelBackgroundDropsTheBackgroundRequestsOnly() async throws {
        let queue = makeQueue()
        fake.holdsSlices = true
        let running = Task { try await queue.run(Self.request("running", .background)) }
        try await eventually { fake.isHolding }
        let waiting = Task { try await queue.run(Self.request("waiting", .background)) }
        let user = Task { try await queue.run(Self.request("user", .user)) }
        try await settle()
        queue.cancelBackground()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        fake.holdsSlices = false
        fake.letGo()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try await user.value == "好的。")
        #expect(fake.starts == ["start running", "start user"])
        #expect(fake.ends == ["end 1", "end 2"])
    }

    @Test func aRequestCancelledWhileItWaitsLeavesTheLine() async throws {
        let queue = makeQueue()
        fake.holdsSlices = true
        let running = Task { try await queue.run(Self.request("running")) }
        try await eventually { fake.isHolding }
        let waiting = Task { try await queue.run(Self.request("waiting")) }
        try await settle()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        fake.holdsSlices = false
        fake.letGo()
        _ = try await running.value
        _ = try await queue.run(Self.request("next"))
        #expect(fake.starts == ["start running", "start next"])
    }

    // MARK: The app's engine

    /// The live job calls wait for the model gate like every other cleanup model call, and
    /// the end of a job waits for its turn even when its task is cancelled.
    @Test func theAppsJobCallsShareTheGate() async throws {
        let gate = ModelGate()
        let engine = CleanupEngine.live(RewriteEngine(), gate: gate)
        let voice = HeldWork()
        let speaking = Task { try await gate.run(.exclusive) { await voice.run() } }
        try await eventually { voice.began == 1 }
        let starting = Task { try await engine.startJob("<|im_start|>user\nHello<|im_end|>\n", 8) }
        try await eventually { gate.snapshot.waiting.count == 1 }
        let reading = Task { try await engine.readSlice(1, 256) }
        try await eventually { gate.snapshot.waiting.count == 2 }
        let writing = Task { try await engine.writeBurst(1, 32) }
        try await eventually { gate.snapshot.waiting.count == 3 }
        let ending = Task { try await engine.endJob(1) }
        try await eventually { gate.snapshot.waiting.count == 4 }
        ending.cancel()
        try await settle()
        #expect(gate.snapshot.waiting == [.shared, .shared, .shared, .shared])
        voice.release()
        try await speaking.value
        await #expect(throws: RewriteError.notLoaded) { try await starting.value }
        await #expect(throws: RewriteError.jobDropped) { try await reading.value }
        await #expect(throws: RewriteError.jobDropped) { try await writing.value }
        await #expect(throws: RewriteError.jobDropped) { try await ending.value }
        #expect(gate.snapshot == ModelGate.Snapshot())
    }
}
