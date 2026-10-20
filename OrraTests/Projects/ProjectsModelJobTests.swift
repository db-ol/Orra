import Foundation
import MLX
import Synchronization
import Testing
@testable import Orra

/// Projects jobs on the real cleanup model. Only when asked for, with
/// TEST_RUNNER_ORRA_PROJECTS_JOBS=1, never in CI, in a Release build, since a Debug build
/// runs MLX without optimization:
///
///     TEST_RUNNER_ORRA_PROJECTS_JOBS=1 TEST_RUNNER_ORRA_PROJECTS_JOBS_OUT=<folder> xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/ProjectsModelJobTests
///
/// - Slices that end where one call ends its windows of 512 tokens write exactly the
///   answer of one call, so a job keeps the model's state whole from call to call, with
///   MLX's buffer cache cleared in between.
/// - The queue's slices, sized by time, read the prompt in other pieces. That changes how
///   bf16 values round, so where two words are close the greedy answer can take the
///   other one. Replaying the queue's own slices gives exactly its answer. The report says
///   how much of it matches one call, and how much longer slices of 256 take to the first
///   token than one call.
/// - A slice's `ran` leaves out its wait for the engine.
/// - The answer decodes whole however small the bursts, also in Chinese.
///
/// The prompts are a made up thread with invented people and companies at .example
/// addresses. The report holds counts and the answers to these prompts only.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_PROJECTS_JOBS"] != nil && RewriteTestModel.folder != nil))
@MainActor
struct ProjectsModelJobTests {
    /// The longest answer of these prompts.
    private static let maximumTokens = 96
    /// The windows one call reads a prompt in, GenerateParameters.prefillStepSize.
    private static let window = 512
    /// How often each time to the first token is measured, the median counts.
    private static let timings = 5

    @Test func slicesWriteTheAnswerOfOneCall() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let tokenizer = try await CleanupTokenizer(folder: folder)
        let engine = RewriteEngine()
        try await engine.load(from: folder)
        var report = "# Projects jobs, chip \(SpeechCorpus.chip())\n\n"
        for target in [2_048, RewriteEngine.maximumJobPromptTokens] {
            let prompt = SyntheticThread.prompt(fitting: target, question: SyntheticThread.englishQuestion, tokenizer: tokenizer)
            let reference = try await Self.oneCall(prompt, engine: engine)
            #expect(reference.start.promptTokens <= target && reference.start.promptTokens > target - 400)
            // The answer spans more than one burst, so the bursts are tested.
            #expect(reference.tokens > ProjectsModelQueue.burstTokens)
            let aligned = try await Self.sliced(prompt, slices: Self.windows(reference.start.promptTokens), burst: ProjectsModelQueue.burstTokens, engine: engine)
            #expect(aligned == reference.answer)
            // The queue, and its own slices again outside it.
            let (queued, slices) = try await Self.queued(prompt, engine: engine)
            let replayed = try await Self.sliced(prompt, slices: slices, burst: 1, engine: engine)
            #expect(replayed == queued)
            let same = zip(queued, reference.answer).prefix { $0 == $1 }.count
            let oneCallTime = try await Self.timeToFirstToken(prompt, slices: [], engine: engine)
            let slicedTime = try await Self.timeToFirstToken(prompt, slices: Self.slices(of: 256, covering: reference.start.promptTokens), engine: engine)
            report += "- \(reference.start.promptTokens) prompt tokens: one call wrote \(reference.tokens) tokens. The queue read the prompt in \(slices.count) slices of \(slices.min() ?? 0) to \(slices.max() ?? 0) tokens, and its answer matches the first \(same) of \(reference.answer.count) characters of one call's, \(queued == reference.answer ? "all of it" : "then takes another word"). Time to the first token, median of \(Self.timings): one call \(Self.seconds(oneCallTime)), slices of 256 \(Self.seconds(slicedTime)) (\(String(format: "%+.1f", (slicedTime / oneCallTime - 1) * 100)) %).\n  - One call: \(reference.answer)\n  - Queue: \(queued)\n"
        }
        await engine.unload()
        try Self.write(report, named: "jobs.md")
    }

    @Test func aSliceRanLeavesOutItsWaitForTheEngine() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let tokenizer = try await CleanupTokenizer(folder: folder)
        let engine = RewriteEngine()
        try await engine.load(from: folder)
        // A long burst of one job holds the engine while a slice of another one waits.
        let long = SyntheticThread.prompt(fitting: 1_024, question: SyntheticThread.longReplyQuestion, tokenizer: tokenizer)
        let busy = try await engine.startJob(long, maximumTokens: 400)
        let other = try await engine.startJob(SyntheticThread.prompt(fitting: 1_024, question: SyntheticThread.englishQuestion, tokenizer: tokenizer), maximumTokens: 8)
        let writing = Task.detached { try await engine.writeBurst(busy.id, tokens: 200) }
        try await Task.sleep(for: .milliseconds(200))
        let asked = ContinuousClock.now
        let slice = try await engine.readSlice(other.id, tokens: 64)
        let waited = asked.duration(to: .now)
        let burst = try await writing.value
        #expect(burst.written > 100)
        #expect(slice.read == 64)
        #expect(waited > .milliseconds(300))
        #expect(slice.ran * 4 < waited, "ran \(slice.ran), waited \(waited)")
        _ = try await engine.endJob(busy.id)
        _ = try await engine.endJob(other.id)
        await engine.unload()
    }

    /// Prints the report, attaches it to the result and writes it to the folder in
    /// TEST_RUNNER_ORRA_PROJECTS_JOBS_OUT, when set.
    private static func write(_ text: String, named name: String) throws {
        print(text)
        Attachment.record(text, named: name)
        if let folder = ProcessInfo.processInfo.environment["ORRA_PROJECTS_JOBS_OUT"] {
            try text.write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
        }
    }

    @Test func aChineseAnswerWrittenInSmallBurstsDecodesWhole() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let tokenizer = try await CleanupTokenizer(folder: folder)
        let engine = RewriteEngine()
        try await engine.load(from: folder)
        let prompt = SyntheticThread.prompt(fitting: 2_048, question: SyntheticThread.chineseQuestion, tokenizer: tokenizer)
        let reference = try await Self.oneCall(prompt, engine: engine)
        #expect(reference.answer.unicodeScalars.contains { $0.properties.isIdeographic })
        #expect(!reference.answer.contains("\u{FFFD}"))
        // Bursts of 1 and 3 tokens end inside many characters made of several tokens.
        for burst in [1, 3] {
            let sliced = try await Self.sliced(prompt, slices: Self.windows(reference.start.promptTokens), burst: burst, engine: engine)
            #expect(sliced == reference.answer)
        }
        let (queued, _) = try await Self.queued(prompt, engine: engine)
        #expect(!queued.contains("\u{FFFD}"))
        #expect(queued.unicodeScalars.contains { $0.properties.isIdeographic })
        await engine.unload()
    }

    @Test func thePromptBudgetAndAnUnloadEndJobs() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let tokenizer = try await CleanupTokenizer(folder: folder)
        let engine = RewriteEngine()
        try await engine.load(from: folder)
        let tooLong = SyntheticThread.prompt(fitting: RewriteEngine.maximumJobPromptTokens + 600, question: SyntheticThread.englishQuestion, tokenizer: tokenizer)
        #expect(tokenizer.encode(text: tooLong, addSpecialTokens: false).count > RewriteEngine.maximumJobPromptTokens)
        await #expect(throws: RewriteError.promptTooLong) { try await engine.startJob(tooLong, maximumTokens: 8) }
        // An unload drops the jobs under way.
        let prompt = SyntheticThread.prompt(fitting: 1_024, question: SyntheticThread.englishQuestion, tokenizer: tokenizer)
        let job = try await engine.startJob(prompt, maximumTokens: 8)
        _ = try await engine.readSlice(job.id, tokens: 256)
        await engine.unload()
        try await engine.load(from: folder)
        await #expect(throws: RewriteError.jobDropped) { try await engine.readSlice(job.id, tokens: 256) }
        await #expect(throws: RewriteError.jobDropped) { try await engine.writeBurst(job.id, tokens: 32) }
        await #expect(throws: RewriteError.jobDropped) { try await engine.endJob(job.id) }
        await engine.unload()
    }

    // MARK: Helpers

    /// The job read and written in one call each: the whole prompt, then the whole answer,
    /// the way cleanup and translation read a prompt without the prefix cache.
    private static func oneCall(_ prompt: String, engine: RewriteEngine) async throws -> (start: RewriteEngine.JobStart, answer: String, tokens: Int) {
        let start = try await engine.startJob(prompt, maximumTokens: maximumTokens)
        let burst = try await engine.writeBurst(start.id, tokens: maximumTokens)
        #expect(burst.finished)
        expectCacheCleared()
        let answer = try await engine.endJob(start.id)
        return (start, answer, burst.written)
    }

    /// The slices that end where the windows of one call end. The first burst reads the
    /// rest, as one call reads it after its last window.
    private static func windows(_ promptTokens: Int) -> [Int] {
        Array(repeating: window, count: max(promptTokens - 1, 0) / window)
    }

    /// Slices of one size until all but the last prompt token are read, which the first
    /// burst reads.
    private static func slices(of size: Int, covering promptTokens: Int) -> [Int] {
        let left = max(promptTokens - 1, 0)
        return Array(repeating: size, count: left / size) + (left % size > 0 ? [left % size] : [])
    }

    /// The median time from the start of a job until its first answer token, read in the
    /// given slices, or in one call without any.
    private static func timeToFirstToken(_ prompt: String, slices: [Int], engine: RewriteEngine) async throws -> Duration {
        var times: [Duration] = []
        for _ in 0..<timings {
            let started = ContinuousClock.now
            let start = try await engine.startJob(prompt, maximumTokens: maximumTokens)
            for size in slices {
                _ = try await engine.readSlice(start.id, tokens: size)
            }
            _ = try await engine.writeBurst(start.id, tokens: 1)
            times.append(started.duration(to: .now))
            _ = try await engine.endJob(start.id)
        }
        return times.sorted()[times.count / 2]
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.3f s", duration / .seconds(1))
    }

    /// The job read in the given slices and written in bursts of a fixed size. Checks that
    /// each call left MLX's buffer cache empty.
    private static func sliced(_ prompt: String, slices: [Int], burst: Int, engine: RewriteEngine) async throws -> String {
        let start = try await engine.startJob(prompt, maximumTokens: maximumTokens)
        for size in slices {
            let run = try await engine.readSlice(start.id, tokens: size)
            #expect(run.read == size)
            expectCacheCleared()
        }
        var finished = false
        while !finished {
            let run = try await engine.writeBurst(start.id, tokens: burst)
            #expect(run.written <= burst)
            expectCacheCleared()
            finished = run.finished
        }
        let answer = try await engine.endJob(start.id)
        expectCacheCleared()
        return answer
    }

    /// MLX's buffer cache is empty after a call, but for buffers the GPU let go of just
    /// after the call cleared it, such as those of one answer token. A slice that kept its
    /// freed buffers would leave hundreds of MB.
    private static func expectCacheCleared(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(Memory.cacheMemory < 16 << 20, sourceLocation: sourceLocation)
    }

    /// The prompt through the queue on the engine, with nothing to wait for, and the
    /// tokens each of its slices read.
    private static func queued(_ prompt: String, engine: RewriteEngine) async throws -> (answer: String, slices: [Int]) {
        let jobs = CleanupEngine.live(engine, gate: ModelGate())
        let readSlice = jobs.readSlice
        let slices = SliceSizes()
        let queue = ProjectsModelQueue(environment: ProjectsModelEnvironment(
            startJob: jobs.startJob,
            readSlice: { job, tokens in
                let run = try await readSlice(job, tokens)
                slices.add(run.read)
                return run
            },
            writeBurst: jobs.writeBurst,
            endJob: jobs.endJob,
            isDictating: { false },
            captionsOn: { false },
            memoryPressure: { .normal },
            voiceLoaded: { false },
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            waitUntilLoaded: { true },
            holdModel: {},
            releaseModel: {},
            sleep: { try await Task.sleep(for: $0) }
        ))
        let answer = try await queue.run(ProjectsModelRequest(prompt: prompt, maximumTokens: maximumTokens, priority: .user))
        expectCacheCleared()
        return (answer, slices.all.filter { $0 > 0 })
    }

    nonisolated final class SliceSizes: Sendable {
        private let sizes = Mutex<[Int]>([])

        func add(_ size: Int) {
            sizes.withLock { $0.append(size) }
        }

        var all: [Int] {
            sizes.withLock { $0 }
        }
    }

    /// A made up mail thread with project notes, in English and Chinese, and a question
    /// about its last email.
    enum SyntheticThread {
        static let englishQuestion = "Summarize what the last email asks for and what the sender needs by when, in three or four full sentences."
        static let chineseQuestion = "请用中文写三到四句话，说明最后一封邮件要求做什么，以及对方需要在什么时间之前得到答复。"
        /// Asks for an answer of several hundred tokens, as a draft can be.
        static let longReplyQuestion = "Draft a detailed reply to the last email. Go through every project in the notes and every open point of the thread one by one, with the dates and amounts, in at least 600 words."

        /// The prompt with as many emails of the thread as fit in `tokens`.
        static func prompt(fitting tokens: Int, question: String, tokenizer: CleanupTokenizer) -> String {
            let head = "<|im_start|>system\nYou help a user with their work email. You read the project notes and the email thread, then answer the question.<|im_end|>\n<|im_start|>user\nProject notes and email thread:\n\n"
            let tail = "\n\n" + question + "<|im_end|>\n<|im_start|>assistant\n" + RewritePrompt.noThinking
            func prompt(_ messages: Int) -> String {
                head + thread(messages: messages) + tail
            }
            var low = 0
            var high = 400
            while low < high {
                let middle = (low + high + 1) / 2
                if tokenizer.encode(text: prompt(middle), addSpecialTokens: false).count <= tokens {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            return prompt(low)
        }

        /// The notes of four invented projects, then the emails.
        static func thread(messages: Int) -> String {
            var text = """
            Project: Harbour Lane office fit out. Owner: Mira Holt. Due 2026-11-20. Budget 240,000 EUR. Changes above 8 percent need the client's written approval.
            Project: Spring catalogue print run. Owner: Ana Ruiz. Due 2026-12-05. Paper stock and cover lamination still open.
            项目：深圳供应商审核。负责人：王静。第一批交货日期为 2026-11-12，预算 120 万元。
            Project: Norrby Analytics annual report. Owner: Tomas Berg. Draft due 2026-11-28.


            """
            let english = ["the meeting room glass walls", "the second floor carpet", "the reception desk", "the acoustic panels"]
            let chinese = ["包装盒样品", "第二批面料", "质检报告", "出货单"]
            for index in 0..<messages {
                let day = 1 + index % 28
                if index % 2 == 0 {
                    let item = english[index % english.count]
                    text += "From: Mira Holt <mira.holt@norrby-analytics.example>\nTo: Tomas Berg <tomas@bergbuild.example>\nDate: 2026-10-\(String(format: "%02d", day))\nSubject: Re: \(item)\n\nHi Tomas,\n\nThe quote for \(item) came in at \(12_000 + index * 37) EUR, which is \(3 + index % 9) percent above the budget line. Could you check with the supplier whether the delivery on 2026-11-\(String(format: "%02d", day)) still holds if we split the order into two shipments? I also need the revised floor plan before Thursday.\n\nBest,\nMira\n\n---\n\n"
                } else {
                    let item = chinese[index % chinese.count]
                    text += "发件人：王静 <wangjing@lanshan-supply.example>\n收件人：陈晓 <chenxiao@ourteam.example>\n日期：2026-10-\(String(format: "%02d", day))\n主题：回复：\(item)\n\n陈晓你好，\n\n关于\(item)的报价，供应商今天回复说单价是 \(300 + index) 元，比上次高了 \(2 + index % 7)%。交货期也要推迟到 2026-11-\(String(format: "%02d", day))。请在下周一之前确认第一批的数量。\n\n谢谢，\n王静\n\n---\n\n"
                }
            }
            return text
        }
    }
}
