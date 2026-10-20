import Darwin
import Foundation
import MLX
import Synchronization
import Testing
@testable import Orra

/// Dictation next to Projects work on the real ProjectsModelQueue, and the memory it takes,
/// with the real speech model and the real cleanup model. Only when asked for, with
/// TEST_RUNNER_ORRA_PROJECTS_LATENCY=1, never in CI, and in a Release build:
///
///     TEST_RUNNER_ORRA_PROJECTS_LATENCY=1 TEST_RUNNER_ORRA_PROJECTS_LATENCY_CLIPS=<folder of say clips> TEST_RUNNER_ORRA_PROJECTS_LATENCY_OUT=<folder> xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/ProjectsLatencyMeasurementTests
///
/// The clips folder holds dictations made with macOS say, named zh… and en… .wav, each with
/// a filler or a self correction so that the cleanup model always runs. Optional, with the
/// same prefix: PARTS (latency, memory, default both), ROUNDS (default 2) and ANSWER, the
/// most answer tokens of a job (default 1,500, as an explanation with a draft may have).
///
/// `latency` drives PushToTalkController as LatencyMeasurementTests does: a stand in
/// microphone that returns a clip, held as long as the clip lasts, the real speech model,
/// the rules, then the cleanup step or the translation step with their own time limits, and
/// a paste that only notes the time. Every model call shares one ModelGate, and the
/// dictation tells an EngineTurns when it starts and ends, as in the app. Each round runs
/// every clip on both keys without Projects work, and again while a worker keeps the queue
/// busy with background jobs of 8,192 tokens that ask for a long reply, so every dictation
/// meets a job under way, reading its prompt or writing its answer.
/// The bar: no cleanup or translation misses its limit, and release to paste stays within
/// 0.1 s of the runs without Projects work at the median and at p90.
///
/// `memory` notes the footprint, the number Activity Monitor shows, at rest and at its
/// peak during a dictation, a job and a dictation during a job, and the swap used before
/// and after. It is meant for a Mac with 16 GB, with Mail and a browser open. No bar.
///
/// The prompt is a made up thread with invented people at .example addresses. The reports
/// hold durations, counts and bytes only, never text.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_PROJECTS_LATENCY"] != nil))
@MainActor
struct ProjectsLatencyMeasurementTests {
    enum Path: String, CaseIterable {
        case cleanup
        case translation
    }

    struct Clip {
        let name: String
        let recording: AudioRecording
    }

    /// One dictation and its model calls.
    struct Record {
        let condition: String
        let path: Path
        let timings: DictationTimings?
        let calls: [CallLog.Call]

        var total: Double? {
            timings.map { $0.total / .seconds(1) }
        }

        func step(_ step: DictationTimings.Step) -> Double {
            (timings?.durations[step] ?? .zero) / .seconds(1)
        }
    }

    /// The cleanup and translation calls of a dictation: how long each took against its
    /// limit, and whether TimedCall cancelled it at the limit.
    nonisolated final class CallLog: Sendable {
        struct Call: Sendable {
            let limit: Double
            let took: Double
            let missedLimit: Bool
            let failed: Bool
        }

        private struct State {
            var calls: [Call] = []
            var running = 0
        }

        private let state = Mutex(State())

        func reset() {
            state.withLock { $0.calls = [] }
        }

        var all: [Call] {
            state.withLock { $0.calls }
        }

        var running: Int {
            state.withLock { $0.running }
        }

        func run(limit: Duration, _ call: @Sendable () async throws -> String) async throws -> String {
            let started = ContinuousClock.now
            state.withLock { $0.running += 1 }
            func note(failed: Bool) {
                let entry = Call(limit: limit / .seconds(1), took: started.duration(to: .now) / .seconds(1), missedLimit: Task.isCancelled, failed: failed)
                state.withLock {
                    $0.calls.append(entry)
                    $0.running -= 1
                }
            }
            do {
                let answer = try await call()
                note(failed: false)
                return answer
            } catch {
                note(failed: true)
                throw error
            }
        }
    }

    /// How long the slices or the bursts the queue ran took inside the engine, and the
    /// tokens they read or wrote, for the report.
    nonisolated final class RunLog: Sendable {
        private let runs = Mutex<(times: [Double], tokens: Int)>(([], 0))

        func add(_ ran: Duration, tokens: Int) {
            runs.withLock {
                $0.times.append(ran / .seconds(1))
                $0.tokens += tokens
            }
        }

        func take() -> (times: [Double], tokens: Int) {
            runs.withLock {
                let taken = $0
                $0 = ([], 0)
                return taken
            }
        }
    }

    @Test func dictationsNextToProjectsWork() async throws {
        let speechFolder = try #require(RealModel.folder, "no speech model on this Mac")
        let cleanupFolder = try #require(RewriteTestModel.folder, "no cleanup model on this Mac")
        let clips = try Self.clips()
        try #require(!clips.isEmpty, "set TEST_RUNNER_ORRA_PROJECTS_LATENCY_CLIPS to a folder of say clips")
        let parts = Self.parts
        let sampler = FootprintSampler()
        sampler.start()
        defer { sampler.stop() }

        // The models as the app wires them: one gate, the speech and cleanup models shared
        // at it, and a dictation that tells EngineTurns when it starts and ends.
        let gate = ModelGate()
        let speech = Qwen3Engine(folder: { speechFolder })
        let transcription = Transcription(
            load: { try await speech.load() },
            transcribe: { samples, context, language in try await speech.transcribe(samples, context: context, language: language) }
        ).gated(gate)
        let rewrite = RewriteEngine()
        let engine = CleanupEngine.live(rewrite, gate: gate)
        let (cleanUp, translate, readSlice, writeBurst) = (engine.complete, engine.translate, engine.readSlice, engine.writeBurst)
        let turns = EngineTurns()
        let calls = CallLog()
        let cleanup = CleanupModel(
            isOn: { true },
            waitUntilLoaded: { true },
            complete: { text in try await calls.run(limit: CleanupStep.timeout(for: text)) { try await cleanUp(text) } }
        ).sharing(turns)
        let translation = TranslationModel(
            isReady: { true },
            direction: { .automatic },
            complete: { text, route in try await calls.run(limit: TranslationStep.timeout(for: text)) { try await translate(text, route) } }
        )
        let memory = ProjectsMemoryPressure()
        memory.start()
        defer { memory.stop() }
        let slices = RunLog()
        let bursts = RunLog()
        let queue = ProjectsModelQueue(environment: ProjectsModelEnvironment(
            startJob: engine.startJob,
            readSlice: { job, tokens in
                let slice = try await readSlice(job, tokens)
                slices.add(slice.ran, tokens: slice.read)
                return slice
            },
            writeBurst: { job, tokens in
                let burst = try await writeBurst(job, tokens)
                bursts.add(burst.ran, tokens: burst.written)
                return burst
            },
            endJob: engine.endJob,
            isDictating: { turns.isDictating },
            captionsOn: { false },
            memoryPressure: { memory.level },
            voiceLoaded: { false },
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            waitUntilLoaded: { true },
            holdModel: {},
            releaseModel: {},
            sleep: { try await Task.sleep(for: $0) }
        ))
        let mic = FakeMicrophone()
        let controller = PushToTalkController(
            capture: mic.capture,
            transcription: transcription,
            cleanup: cleanup,
            translation: translation,
            insert: { _ in .pasted },
            frontmostApp: { 100 },
            lidIsClosed: { false },
            isTrusted: { true },
            minimumHold: .zero
        )
        controller.setTranslationKeyOn(true)
        var latest: DictationTimings?
        controller.onTimings = { latest = $0 }

        var memoryReport = MemoryReport(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        memoryReport.swap("before any model")
        await memoryReport.idle("before any model")
        sampler.beginPhase()
        await controller.loadModel()
        try #require(controller.modelState == .ready)
        let reservation = gate.reserve()
        try await engine.load(cleanupFolder)
        for route in DictationLanguage.chinese.translationRoutes {
            try await engine.prepareTranslation(route)
        }
        reservation.end()
        memoryReport.peak("loading the speech and cleanup models", sampler)
        await memoryReport.idle("speech and cleanup models")

        let tokenizer = try await CleanupTokenizer(folder: cleanupFolder)
        let prompt = ProjectsModelJobTests.SyntheticThread.prompt(fitting: RewriteEngine.maximumJobPromptTokens, question: ProjectsModelJobTests.SyntheticThread.longReplyQuestion, tokenizer: tokenizer)
        let job = ProjectsModelRequest(prompt: prompt, maximumTokens: Self.answerTokens, priority: .background)

        /// One dictation, held as long as its clip lasts, and waited for until the paste
        /// and until its model calls returned. A gap before the press lands it at another
        /// point of the job under way.
        var random = SeededGaps()
        func dictate(_ clip: Clip, _ path: Path, condition: String, gap: Bool = true) async throws -> Record {
            if gap {
                try await Task.sleep(for: .milliseconds(random.next()))
            }
            mic.recording = clip.recording
            calls.reset()
            latest = nil
            let key: Hotkey? = path == .translation ? controller.translationKey : nil
            let starts = mic.calls.count
            controller.handle(.pressed(isRepeat: false), key: key)
            try await LatencyMeasurement.waitUntil { mic.calls.count > starts }
            try await Task.sleep(for: .seconds(clip.recording.duration))
            controller.handle(.released, key: key)
            try await LatencyMeasurement.waitUntil { controller.state == .idle }
            try await LatencyMeasurement.waitUntil { calls.running == 0 }
            return Record(condition: condition, path: path, timings: latest, calls: calls.all)
        }

        /// Keeps the queue busy with background jobs until stopped.
        func startWorker() -> Task<Int, Never> {
            Task {
                var done = 0
                while !Task.isCancelled {
                    do {
                        _ = try await queue.run(job)
                        done += 1
                    } catch {
                        break
                    }
                }
                return done
            }
        }

        func stop(_ worker: Task<Int, Never>) async -> Int {
            worker.cancel()
            queue.cancelBackground()
            return await worker.value
        }

        // Warm up both keys and the job, so no measured run pays for a first run.
        for path in Path.allCases {
            _ = try await dictate(clips[0], path, condition: "warm up", gap: false)
        }
        _ = try await queue.run(ProjectsModelRequest(prompt: prompt, maximumTokens: 32, priority: .user))
        _ = slices.take()
        _ = bursts.take()

        if parts.contains("latency") {
            var records: [Record] = []
            var jobs: [String: Int] = [:]
            var sliceTimes: [String: [Double]] = [:]
            var burstTimes: [String: [Double]] = [:]
            var tokens: [String: Int] = [:]
            var seconds: [String: Double] = [:]
            let conditions = ["no Projects work", "Projects queue"]
            for round in 0..<Self.rounds {
                for (index, condition) in (round % 2 == 0 ? conditions : conditions.reversed()).enumerated() {
                    print("Round \(round), \(condition), \(index)")
                    let started = ContinuousClock.now
                    let worker = condition == conditions[1] ? startWorker() : nil
                    if worker != nil {
                        try await Task.sleep(for: .milliseconds(1_500))
                    }
                    for (clipIndex, clip) in clips.enumerated() {
                        let paths: [Path] = (clipIndex + round) % 2 == 0 ? [.cleanup, .translation] : [.translation, .cleanup]
                        for path in paths {
                            records.append(try await dictate(clip, path, condition: condition))
                        }
                    }
                    if let worker {
                        jobs[condition, default: 0] += await stop(worker)
                    }
                    sliceTimes[condition, default: []] += slices.take().times
                    let written = bursts.take()
                    burstTimes[condition, default: []] += written.times
                    tokens[condition, default: 0] += written.tokens
                    seconds[condition, default: 0] += started.duration(to: .now) / .seconds(1)
                }
            }
            let report = Self.latencyReport(records, conditions: conditions, jobs: jobs, slices: sliceTimes, bursts: burstTimes, tokens: tokens, seconds: seconds, clips: clips)
            try Self.write(report, named: "latency.md")
            for path in Path.allCases {
                let none = records.filter { $0.condition == conditions[0] && $0.path == path }.compactMap(\.total)
                let busy = records.filter { $0.condition == conditions[1] && $0.path == path }.compactMap(\.total)
                #expect(records.filter { $0.path == path }.allSatisfy { $0.timings != nil }, "a \(path.rawValue) dictation pasted nothing")
                #expect(records.filter { $0.path == path }.flatMap(\.calls).allSatisfy { !$0.missedLimit }, "a \(path.rawValue) call missed its limit")
                #expect(LatencyMeasurement.percentile(busy, 0.5) - LatencyMeasurement.percentile(none, 0.5) <= 0.1, "\(path.rawValue) median")
                #expect(LatencyMeasurement.percentile(busy, 0.9) - LatencyMeasurement.percentile(none, 0.9) <= 0.1, "\(path.rawValue) p90")
            }
        }

        if parts.contains("memory") {
            Memory.clearCache()
            await memoryReport.idle("speech and cleanup models, after the warm up")
            sampler.beginPhase()
            _ = try await dictate(clips[0], .cleanup, condition: "memory", gap: false)
            _ = try await dictate(clips[min(1, clips.count - 1)], .translation, condition: "memory", gap: false)
            memoryReport.peak("a dictation with cleanup and one with translation", sampler)
            await memoryReport.idle("after the dictations")
            sampler.beginPhase()
            _ = try await queue.run(ProjectsModelRequest(prompt: prompt, maximumTokens: 32, priority: .user))
            memoryReport.peak("a Projects job of 8,192 tokens", sampler)
            await memoryReport.idle("after the job")
            sampler.beginPhase()
            let worker = startWorker()
            try await Task.sleep(for: .milliseconds(1_500))
            _ = try await dictate(clips[0], .cleanup, condition: "memory", gap: false)
            _ = try await dictate(clips[min(1, clips.count - 1)], .translation, condition: "memory", gap: false)
            _ = await stop(worker)
            memoryReport.peak("dictations during Projects jobs", sampler)
            await memoryReport.idle("after the jobs")
            memoryReport.swap("after")
            try Self.write(memoryReport.text, named: "memory.md")
        }

        await engine.unload()
    }

    // MARK: Settings

    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static var parts: Set<String> {
        Set((environment["ORRA_PROJECTS_LATENCY_PARTS"] ?? "latency,memory").split(separator: ",").map(String.init))
    }

    static var rounds: Int {
        Int(environment["ORRA_PROJECTS_LATENCY_ROUNDS"] ?? "") ?? 2
    }

    static var answerTokens: Int {
        Int(environment["ORRA_PROJECTS_LATENCY_ANSWER"] ?? "") ?? 1_500
    }

    /// The say clips, as a 48 kHz microphone would deliver them, Chinese and English in
    /// turn.
    static func clips() throws -> [Clip] {
        guard let path = environment["ORRA_PROJECTS_LATENCY_CLIPS"] else { return [] }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".wav") }.sorted()
        let zh = names.filter { $0.hasPrefix("zh") }
        let en = names.filter { $0.hasPrefix("en") }
        var ordered: [String] = []
        for index in 0..<max(zh.count, en.count) {
            if index < zh.count {
                ordered.append(zh[index])
            }
            if index < en.count {
                ordered.append(en[index])
            }
        }
        return try ordered.map { name in
            let recording = try SpeechCorpus.recording(folder.appendingPathComponent(name))
            return Clip(name: name.replacingOccurrences(of: ".wav", with: ""), recording: LatencyMeasurement.at48kHz(recording))
        }
    }

    static func write(_ text: String, named name: String) throws {
        print(text)
        Attachment.record(text, named: name)
        if let folder = environment["ORRA_PROJECTS_LATENCY_OUT"] {
            try text.write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
        }
    }

    /// Gaps of 0.2 to 1.5 s before each press, the same from run to run.
    struct SeededGaps {
        private var state: UInt64 = 20_261_019

        mutating func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 200 + Int((state >> 33) % 1_301)
        }
    }

    // MARK: Reports

    private typealias M = LatencyMeasurement

    private static func cell(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "" }
        return "\(M.f(M.percentile(values, 0.5), 3)) / \(M.f(M.percentile(values, 0.9), 3)) / \(M.f(values.max() ?? 0, 3))"
    }

    static func latencyReport(_ records: [Record], conditions: [String], jobs: [String: Int], slices: [String: [Double]], bursts: [String: [Double]], tokens: [String: Int], seconds: [String: Double], clips: [Clip]) -> String {
        var out = "# Dictation next to Projects work, chip \(SpeechCorpus.chip()), \(ProcessInfo.processInfo.physicalMemory) bytes of memory, \(clips.count) say clips, \(rounds) rounds, background jobs of 8,192 tokens with answers of up to \(answerTokens) tokens\n\n"
        out += "Cells are median / p90 / max in seconds. Release to paste is DictationTimings.total. A missed limit is a cleanup or translation that TimedCall cancelled at its limit.\n\n"
        for path in Path.allCases {
            let step: DictationTimings.Step = path == .cleanup ? .cleanup : .translation
            out += "## \(path.rawValue)\n\n| condition | n | release to paste | recognition | \(step.rawValue) step | model calls | missed limits | failed |\n|---|---|---|---|---|---|---|---|\n"
            for condition in conditions {
                let mine = records.filter { $0.condition == condition && $0.path == path }
                let modelCalls = mine.flatMap(\.calls)
                out += "| \(condition) | \(mine.count) | \(cell(mine.compactMap(\.total))) | \(cell(mine.map { $0.step(.recognition) })) | \(cell(mine.map { $0.step(step) })) | \(modelCalls.count) | \(modelCalls.filter(\.missedLimit).count) | \(modelCalls.filter(\.failed).count) |\n"
            }
            let none = records.filter { $0.condition == conditions[0] && $0.path == path }.compactMap(\.total)
            let busy = records.filter { $0.condition == conditions[1] && $0.path == path }.compactMap(\.total)
            out += "\nRelease to paste with Projects work against without: median \(M.f(M.percentile(busy, 0.5) - M.percentile(none, 0.5), 3)) s, p90 \(M.f(M.percentile(busy, 0.9) - M.percentile(none, 0.9), 3)) s. Bar: 0.1 s each.\n\n"
        }
        out += "## Projects jobs during the dictations\n\nSlices and bursts are the times they ran inside the engine. Reading and writing are their sums.\n\n| condition | seconds | jobs done | slices | slice median / p90 / max | reading s | bursts | tokens written | burst median / p90 / max | writing s |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for condition in conditions {
            let time = seconds[condition] ?? 0
            let done = jobs[condition] ?? 0
            let mine = slices[condition] ?? []
            let written = bursts[condition] ?? []
            out += "| \(condition) | \(M.f(time, 0)) | \(done) | \(mine.count) | \(cell(mine)) | \(M.f(mine.reduce(0, +), 1)) | \(written.count) | \(tokens[condition] ?? 0) | \(cell(written)) | \(M.f(written.reduce(0, +), 1)) |\n"
        }
        let limits = records.flatMap(\.calls).map(\.limit)
        out += "\nTime limits seen: \(M.f(limits.min() ?? 0, 2)) to \(M.f(limits.max() ?? 0, 2)) s. Dictations without timings: \(records.filter { $0.timings == nil }.count).\n"
        return out
    }

    /// The footprint at rest and at its peak, and the swap used.
    struct MemoryReport {
        let physicalMemory: UInt64
        private var rows: [String] = []
        private var notes: [String] = []

        init(physicalMemory: UInt64) {
            self.physicalMemory = physicalMemory
        }

        private static func gb(_ bytes: some BinaryInteger) -> String {
            String(format: "%.2f", Double(bytes) / 1e9)
        }

        mutating func peak(_ name: String, _ sampler: FootprintSampler) {
            rows.append("| \(name) | peak | \(Self.gb(sampler.peak)) | \(Self.gb(sampler.phaseStart)) | \(Self.gb(Memory.activeMemory)) | \(Self.gb(Memory.cacheMemory)) |")
        }

        mutating func idle(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(1_500))
            rows.append("| \(name) | at rest | \(Self.gb(FootprintSampler.footprint)) | | \(Self.gb(Memory.activeMemory)) | \(Self.gb(Memory.cacheMemory)) |")
        }

        mutating func swap(_ name: String) {
            var usage = xsw_usage()
            var size = MemoryLayout<xsw_usage>.size
            if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
                notes.append("Swap used \(name): \(Self.gb(usage.xsu_used)) GB of \(Self.gb(usage.xsu_total)) GB")
            }
        }

        var text: String {
            var out = "# Memory with Projects work, GB (1e9 bytes), chip \(SpeechCorpus.chip()), \(Self.gb(physicalMemory)) GB of memory\n\n"
            out += notes.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
            out += "| state | kind | footprint | footprint at the start | MLX active | MLX cache |\n|---|---|---|---|---|---|\n"
            out += rows.joined(separator: "\n") + "\n"
            return out
        }
    }

    /// Samples this process's footprint every 2 ms on a thread of its own and keeps the
    /// highest since the phase began.
    nonisolated final class FootprintSampler: Sendable {
        private let highest = Mutex<UInt64>(0)
        private let begun = Mutex<UInt64>(0)
        private let stopped = Atomic<Bool>(false)

        static var footprint: UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }

        func start() {
            let thread = Foundation.Thread { [self] in
                while !stopped.load(ordering: .relaxed) {
                    let now = Self.footprint
                    highest.withLock { $0 = max($0, now) }
                    usleep(2_000)
                }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func stop() {
            stopped.store(true, ordering: .relaxed)
        }

        func beginPhase() {
            let now = Self.footprint
            highest.withLock { $0 = now }
            begun.withLock { $0 = now }
        }

        var phaseStart: UInt64 {
            begun.withLock { $0 }
        }

        var peak: UInt64 {
            max(highest.withLock { $0 }, Self.footprint)
        }
    }
}
