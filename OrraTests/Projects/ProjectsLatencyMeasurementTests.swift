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
/// same prefix: PARTS (latency, memory and terms, default latency and memory), ROUNDS
/// (default 2) and ANSWER, the most answer tokens of a job (default 1,500, as an
/// explanation with a draft may have).
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
/// `terms`, not among the parts by default, runs the search terms prompt of SearchTerms for
/// 10 made up mails, 5 in Chinese and 5 in English, 3 times each after a warm up, as
/// requests of the user, and reports the median, p90 and maximum of the job with its prompt
/// and answer tokens. It times whole explanations through ExplainService and the same
/// queue, with search terms and without, as Explain runs them. Then it runs the dictations
/// of the part latency while a worker keeps the queue busy with terms jobs back to back,
/// under the bar of the part latency. The bar of pull request E for the job alone is a
/// median of 2.0 s or less and a p90 of 3.5 s or less on the M5 Pro, with no job over the
/// time limit.
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
        func startWorker(_ work: ProjectsModelRequest = job) -> Task<Int, Never> {
            Task {
                var done = 0
                while !Task.isCancelled {
                    do {
                        _ = try await queue.run(work)
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

        if parts.contains("terms") {
            let counter = try await ProjectsTokenCounter.reading(cleanupFolder)
            let emails = Self.termMails.enumerated().map { index, mail in
                ExplainService.Email(
                    messageID: "terms-\(index)@studio.example", date: Date(timeIntervalSince1970: 1_792_411_200),
                    sender: ExplainPrompt.Person(name: "Mei Tan", address: "mei@harbor.example"), subject: mail.subject,
                    text: mail.text, visibleText: mail.text)
            }
            func termsRequest(_ email: ExplainService.Email, priority: ProjectsModelRequest.Priority = .user) async -> ProjectsModelRequest {
                let prompt = SearchTermsPrompt(searchText: await ExplainService.searchText(email), attachmentNames: [])
                return ProjectsModelRequest(prompt: prompt.text, maximumTokens: SearchTermsPrompt.maximumTokens, priority: priority)
            }
            // The job alone.
            _ = try await queue.run(await termsRequest(emails[0]))
            var times: [Double] = []
            var promptTokens: [Int] = []
            var answerTokens: [Int] = []
            var valid = 0
            for _ in 0..<3 {
                for email in emails {
                    let request = await termsRequest(email)
                    let started = ContinuousClock.now
                    let written = try await queue.run(request)
                    times.append(started.duration(to: .now) / .seconds(1))
                    promptTokens.append(counter.count(request.prompt))
                    answerTokens.append(counter.count(SearchTermsPrompt.prefill + written))
                    valid += SearchTermsPrompt.terms(written) == nil ? 0 : 1
                }
            }
            // Whole explanations through the same queue, with and without search terms.
            let project = ExplainService.Project(id: UUID(), name: "Harbor lobby", description: "The lobby of the harbor office, with Mei Tan.")
            let chunk = ChunkSearch.Hit(
                chunk: 1, project: project.id, file: URL(fileURLWithPath: "/Harbor/schedule.md"), page: nil, heading: nil,
                modified: Date(timeIntervalSince1970: 1_792_000_000), text: "The lobby lamps arrive on 22 November. Twelve brass lamps at CNY 980 each.",
                fileHiddenRuns: 0, score: 1)
            var explained: [String: [Double]] = [:]
            for withTerms in [false, true] {
                let service = ExplainService(
                    lookups: ExplainService.Lookups(
                        known: { _ in ExplainService.Known(ownName: "Lin", ownAddresses: ["me@studio.example"], projects: [project]) },
                        thread: { _ in [] }, projectMail: { _ in [] },
                        search: { _ in [chunk] }, newest: { _, _ in [] }, files: { _ in [] },
                        terms: { email in
                            guard withTerms else { return nil }
                            return try await SearchTerms.ask(for: email, run: { try await queue.run($0) }, sleep: { try await Task.sleep(for: $0) })
                        }),
                    run: { try await queue.run($0) },
                    loadTokenCounter: { counter.count },
                    save: { _ in },
                    language: .en)
                for var email in emails.prefix(6) {
                    email.project = project.id
                    let started = ContinuousClock.now
                    _ = try await service.explain(email)
                    explained[withTerms ? "with search terms" : "without search terms", default: []].append(started.duration(to: .now) / .seconds(1))
                }
            }
            // Dictations while terms jobs run back to back.
            var records: [Record] = []
            let conditions = ["no Projects work", "terms jobs"]
            let backgroundTerms = await termsRequest(emails[0], priority: .background)
            for round in 0..<Self.rounds {
                for condition in (round % 2 == 0 ? conditions : conditions.reversed()) {
                    let worker = condition == conditions[1] ? startWorker(backgroundTerms) : nil
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
                        _ = await stop(worker)
                    }
                }
            }
            _ = slices.take()
            _ = bursts.take()
            let limit = SearchTerms.timeLimit / .seconds(1)
            var report = "# Search terms next to dictation, chip \(SpeechCorpus.chip()), \(ProcessInfo.processInfo.physicalMemory) bytes of memory\n\n"
            report += "Cells are median / p90 / max.\n\n"
            report += "| measure | n | value |\n|---|---|---|\n"
            report += "| terms job, s | \(times.count) | \(Self.cell(times)) |\n"
            report += "| prompt tokens | \(promptTokens.count) | \(Self.cell(promptTokens.map(Double.init))) |\n"
            report += "| answer tokens, with the prefill | \(answerTokens.count) | \(Self.cell(answerTokens.map(Double.init))) |\n"
            for (name, values) in explained.sorted(by: { $0.key < $1.key }) {
                report += "| whole Explain \(name), s | \(values.count) | \(Self.cell(values)) |\n"
            }
            report += "\nUsable terms in \(valid) of \(times.count) answers. Jobs over the time limit of \(M.f(limit, 0)) s: \(times.filter { $0 > limit }.count). Bar of pull request E: median 2.0 s or less, p90 3.5 s or less, none over the limit.\n\n"
            report += "## Dictations while terms jobs run\n\n| path | condition | n | release to paste | missed limits |\n|---|---|---|---|---|\n"
            for path in Path.allCases {
                for condition in conditions {
                    let mine = records.filter { $0.condition == condition && $0.path == path }
                    report += "| \(path.rawValue) | \(condition) | \(mine.count) | \(Self.cell(mine.compactMap(\.total))) | \(mine.flatMap(\.calls).filter(\.missedLimit).count) |\n"
                }
            }
            try Self.write(report, named: "terms.md")
            #expect(times.allSatisfy { $0 <= limit }, "a terms job ran past the time limit")
            #expect(records.allSatisfy { $0.timings != nil }, "a dictation next to terms jobs pasted nothing")
            for path in Path.allCases {
                let none = records.filter { $0.condition == conditions[0] && $0.path == path }.compactMap(\.total)
                let busy = records.filter { $0.condition == conditions[1] && $0.path == path }.compactMap(\.total)
                #expect(records.filter { $0.path == path }.flatMap(\.calls).allSatisfy { !$0.missedLimit }, "a \(path.rawValue) call missed its limit next to terms jobs")
                #expect(LatencyMeasurement.percentile(busy, 0.5) - LatencyMeasurement.percentile(none, 0.5) <= 0.1, "\(path.rawValue) median next to terms jobs")
                #expect(LatencyMeasurement.percentile(busy, 0.9) - LatencyMeasurement.percentile(none, 0.9) <= 0.1, "\(path.rawValue) p90 next to terms jobs")
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

    /// Made up mails for the terms part, at .example addresses, 5 in Chinese and 5 in English.
    static let termMails: [(subject: String, text: String)] = [
        ("大堂灯具", "林老师好，\n\n大堂的灯具报价出来了吗？吊灯的安装高度和数量麻烦再确认一下。\n\n周敏"),
        ("台历打样", "林老师，\n\n第二次打样明天寄出，三月页的红色已经按色板调过，请收到后确认。\n\n何立伟"),
        ("厨房平面图", "林舟，\n\n厨房的平面图改好了吗？冰箱的位置和插座要一起定。\n\n陈默"),
        ("入职安排", "林老师好，\n\n我下周一入职，需要提前准备什么材料？电脑是工作室配吗？\n\n宋佳"),
        ("合同补充条款", "林老师，\n\n批发页的补充协议我们看过了，付款节点能不能改成两期？\n\n郑远山"),
        ("Hotel and flight", "Dear Lin,\n\nPlease confirm your arrival flight and the nights you need at the conference hotel.\n\nBest,\nHannah"),
        ("Wholesale samples", "Hi Lin,\n\nCould you send samples of the oolong and the black tea for our buyers, with the price list?\n\nOliver"),
        ("Take home task", "Hi Lin,\n\nI finished the take home task. The product page has a language switch and works on small screens.\n\nSam"),
        ("Corporate order", "Hello,\n\nWe would like 200 desk calendars with our logo on the box. What is the lead time?\n\nDaniel"),
        ("Slides", "Hi Lin,\n\nPlease upload your slides to the speaker portal by 5 November, as a PDF.\n\nHannah"),
    ]

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
