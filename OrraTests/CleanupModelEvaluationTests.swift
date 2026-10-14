import Foundation
import Synchronization
import Testing
@testable import Orra

/// Runs the real cleanup model on the cleanup cases of Tools/rewrite-eval: the 178 regular
/// cases, the 70 adversarial ones, which ask, order or try to steer the model, and the 20
/// whose words carry meaning that a cleanup must keep. Only when
/// asked for, with TEST_RUNNER_ORRA_CLEANUP_EVAL=1, and only when the model is on this Mac,
/// see RewriteTestModel. It loads 3 GB, so run it on its own, in a Release build, since a
/// Debug build runs MLX without optimization and misses the time limit below:
///
///     TEST_RUNNER_ORRA_CLEANUP_EVAL=1 TEST_RUNNER_ORRA_REWRITE_MODEL_DIR=<folder> xcodebuild ... -configuration Release ... ENABLE_TESTABILITY=YES test -only-testing:OrraTests/CleanupModelEvaluationTests
///
/// Each case runs twice: on the dictation itself, as the benchmark did, and as the app runs
/// it, after the filler and number rules. The report lists exact matches, what the step did
/// with each output, and every output that was pasted and differs from the expected text,
/// for a person to judge. The cases are written by hand and hold no one's dictation.
/// With TEST_RUNNER_ORRA_CLEANUP_COMPARE=1 as well, each case also runs without the prefix
/// cache, and the report lists every case where the two differ.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_CLEANUP_EVAL"] != nil && RewriteTestModel.folder != nil))
struct CleanupModelEvaluationTests {
    private struct Case {
        let id: String
        let input: String
        let expected: String
    }

    private static func cases(_ file: String, expected key: String) throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/rewrite-eval/\(file)")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return Case(id: try #require(object["id"] as? String), input: try #require(object["input"] as? String), expected: try #require(object[key] as? String))
        }
    }

    /// Folds runs of white space, as the benchmark compared.
    private static func folded(_ text: String) -> String {
        text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appRules(_ text: String) -> String {
        NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: text))
    }

    /// Long dictations, written for this test, measured without a time limit: how long the
    /// model takes at the top of the length range, and whether the step finishes within the
    /// time it allows for that length.
    @Test func longDictations() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let engine = RewriteEngine()
        try await engine.load(from: folder)
        // Different sentences, since the model drops a sentence said twice.
        let chinese = [
            "呃，我们下周的项目评审会，那个，原来定在周三下午，哦不对，是周四下午，地点在三楼的大会议室。",
            "大家记得提前准备好各自负责部分的进度说明，还有遇到的问题和需要别人帮忙的地方。",
            "设计组这次要讲新版首页的改动，就是说，为什么把搜索框挪到了上面，以及用户测试的结果。",
            "后端那边呢，主要讲数据库迁移的计划，嗯，还有上个月那次故障的复盘，以后怎么避免。",
            "测试组要给出这一版的问题清单，按严重程度排好，哪些必须在发布前修，哪些可以放到下一版。",
            "市场部的同事也会来听，他们想知道新功能大概什么时候能上线，好安排宣传的时间。",
            "会议时间大概两个小时，中间休息十分钟，会议室里有投影，但是转接头要自己带。",
            "如果有人那天来不了，提前跟我说一声，然后把材料发到群里，我帮你讲一下。",
            "会后我会整理一份会议纪要，发给所有人，里面写清楚每个人接下来要做的事和截止时间。",
            "还有，那个，下个月的团建地点还没定，大家有什么想法可以在群里说，周五之前定下来。",
        ]
        let english = [
            "So, um, for the release next week we need to finish the migration and update the docs.",
            "The design team will walk through the new home page, mostly why the search box moved to the top.",
            "Backend will cover the database plan and, uh, the review of last month's outage.",
            "QA should bring the list of open bugs sorted by severity, so we can decide what blocks the release.",
            "Marketing wants a rough launch date, I mean a launch week, so they can plan the announcement.",
            "The meeting runs about two hours with a short break, and the room has a projector but no adapters.",
            "If you can't make it, let me know ahead of time and send your slides to the channel.",
            "I'll write up the notes afterwards with every owner and every deadline we agree on.",
            "Also, the offsite location is still open, so please post your ideas before Friday.",
            "Like, if anyone has a budget question, ask finance directly instead of waiting for the meeting.",
        ]
        var report = ""
        for (name, sentences) in [("Chinese", chinese), ("English", english)] {
            for count in [1, 3, 6, 10] {
                let text = sentences.prefix(count).joined(separator: name == "English" ? " " : "")
                let started = ContinuousClock.now
                let completion = try await engine.cleanUp(text)
                let elapsed = started.duration(to: .now)
                let step = await CleanupStep.run(text, complete: { try await engine.cleanUp($0).answer })
                report += "\(name) \(text.count) characters: \(elapsed), \(completion.promptTokens) prompt tokens, \(completion.generatedTokens) written, step \(step.outcome.logName), allowed \(CleanupStep.timeout(for: text)), cleaned \(CleanupStep.isWorthCleaning(text))\n"
                if CleanupStep.isWorthCleaning(text) {
                    #expect(step.outcome != .timedOut, "\(name) \(text.count) characters")
                }
            }
        }
        await engine.unload()
        print(report)
        Attachment.record(report, named: "cleanup-long-dictations.txt")
        if let path = ProcessInfo.processInfo.environment["ORRA_CLEANUP_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// What one run of the step gave for a case.
    private struct Run {
        let text: String
        let outcome: CleanupStep.Outcome
        let seconds: Double
        /// The model's completion, nil when the step did not run the model.
        let completion: RewriteEngine.Completion?
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The median and the 95th percentile, as the benchmark computed them.
    private static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private static func p95(_ values: [Double]) -> Double {
        values.sorted()[Int(Double(values.count) * 0.95) - 1]
    }

    private static func run(_ source: String, engine: RewriteEngine, usingPrefixCache: Bool) async -> Run {
        let completions = Mutex<[RewriteEngine.Completion]>([])
        let started = ContinuousClock.now
        let result = await CleanupStep.run(source, complete: { text in
            let completion = try await engine.cleanUp(text, usingPrefixCache: usingPrefixCache)
            completions.withLock { $0.append(completion) }
            return completion.answer
        })
        return Run(text: result.text, outcome: result.outcome, seconds: seconds(started.duration(to: .now)), completion: completions.withLock { $0.last })
    }

    /// Runs every case with the prefix cache, as the app does. With
    /// TEST_RUNNER_ORRA_CLEANUP_COMPARE=1 it also runs each case without the cache, right
    /// after, and reports both and every case where the two differ.
    @Test func cleanupCases() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let compares = ProcessInfo.processInfo.environment["ORRA_CLEANUP_COMPARE"] != nil
        let engine = RewriteEngine()
        let before = MemoryFootprint.current()
        let loadStarted = ContinuousClock.now
        try await engine.load(from: folder)
        let loadTime = loadStarted.duration(to: .now)
        let loaded = MemoryFootprint.current()

        var report = "Load and warm up: \(loadTime), memory footprint \(Double(loaded) / 1e9) GB after load (\(Double(loaded - min(before, loaded)) / 1e9) GB more than before), prefix cache \(Double(await engine.prefixCacheBytes) / 1e6) MB\n"
        var medians: [Double] = []
        for (name, file, key) in [("regular", "cases.jsonl", "cleanup"), ("adversarial", "adversarial.jsonl", "expected_cleanup"), ("meaning", "meaning.jsonl", "cleanup")] {
            let cases = try Self.cases(file, expected: key)
            var exactIDs: [String: Set<String>] = [:]
            for mode in ["model only", "as the app runs it", "with the skip gate"] {
                var runs: [String: [Run]] = [:]
                var sources: [String] = []
                var expectations: [String] = []
                for item in cases {
                    let source = mode == "model only" ? item.input : Self.appRules(item.input)
                    let skipped = mode == "with the skip gate" && !CleanupStep.hasWorkForModel(source, heard: item.input)
                    sources.append(source)
                    expectations.append(mode == "model only" ? item.expected : Self.appRules(item.expected))
                    for (way, cached) in [("cached", true), ("uncached", false)] where cached || compares {
                        let run = if mode == "model only" || (CleanupStep.isWorthCleaning(source) && !skipped) {
                            await Self.run(source, engine: engine, usingPrefixCache: cached)
                        } else {
                            Run(text: source, outcome: .unchanged, seconds: 0, completion: nil)
                        }
                        runs[way, default: []].append(run)
                    }
                }
                for way in ["cached", "uncached"] {
                    guard let results = runs[way] else { continue }
                    var exact = 0
                    var outcomes: [String: Int] = [:]
                    var differing: [String] = []
                    for (index, result) in results.enumerated() {
                        let kind = switch result.outcome {
                        case .heldBack(let failure): "held back: \(failure.logName)"
                        default: result.outcome.logName
                        }
                        outcomes[kind, default: 0] += 1
                        if Self.folded(result.text) == Self.folded(expectations[index]) {
                            exact += 1
                            if way == "cached" { exactIDs[mode, default: []].insert(cases[index].id) }
                        } else if result.outcome == .cleaned || result.outcome == .unchanged {
                            differing.append("  \(cases[index].id) [\(result.outcome.logName)] \(sources[index]) -> \(result.text) (expected \(expectations[index]))")
                        }
                    }
                    let seconds = results.map(\.seconds)
                    let completions = results.compactMap(\.completion)
                    if mode == "model only" && way == "cached" {
                        medians.append(Self.median(seconds))
                    }
                    report += "\n\(name), \(mode), \(way): \(cases.count) cases, exact \(exact), median \(String(format: "%.3f", Self.median(seconds))) s, p95 \(String(format: "%.3f", Self.p95(seconds))) s, max \(String(format: "%.3f", seconds.max() ?? 0)) s\n"
                    if !completions.isEmpty {
                        let prefill = completions.map { Self.seconds($0.prefillTime) }
                        let read = completions.map { Double($0.promptTokens - $0.cachedPromptTokens) }
                        report += "  model runs \(completions.count), prompt tokens median \(Int(Self.median(completions.map { Double($0.promptTokens) }))), cached median \(Int(Self.median(completions.map { Double($0.cachedPromptTokens) }))), read median \(Int(Self.median(read))), prefill median \(String(format: "%.3f", Self.median(prefill))) s, p95 \(String(format: "%.3f", Self.p95(prefill))) s\n"
                    }
                    if mode == "with the skip gate" && way == "cached" {
                        let skippedCount = zip(sources, cases).filter { !CleanupStep.hasWorkForModel($0, heard: $1.input) }.count
                        let app = exactIDs["as the app runs it", default: []]
                        let gated = exactIDs[mode, default: []]
                        report += "  skipped \(skippedCount), exact lost against the app \(app.subtracting(gated).sorted()), gained \(gated.subtracting(app).sorted())\n"
                    }
                    for (kind, count) in outcomes.sorted(by: { $0.key < $1.key }) {
                        report += "  \(kind): \(count)\n"
                    }
                    report += "  pasted and not as expected: \(differing.count)\n" + differing.joined(separator: "\n") + "\n"
                }
                if let cached = runs["cached"], let uncached = runs["uncached"] {
                    var lines: [String] = []
                    var answers = 0
                    for index in cached.indices {
                        if cached[index].completion?.answer != uncached[index].completion?.answer {
                            answers += 1
                        }
                        if cached[index].text != uncached[index].text || cached[index].outcome != uncached[index].outcome {
                            lines.append("  \(cases[index].id) \(sources[index]) -> cached [\(cached[index].outcome.logName)] \(cached[index].text) | uncached [\(uncached[index].outcome.logName)] \(uncached[index].text)")
                        }
                    }
                    report += "\(name), \(mode): answers that differ with and without the cache \(answers), pasted texts or outcomes that differ \(lines.count)\n" + lines.joined(separator: "\n") + "\n"
                }
            }
        }
        await engine.unload()
        print(report)
        Attachment.record(report, named: "cleanup-evaluation.txt")
        if let path = ProcessInfo.processInfo.environment["ORRA_CLEANUP_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        // The setting promises under a second. A Release build measured 0.17 and 0.21 s
        // with the prefix cache, and 0.66 and 0.74 s without it.
        for median in medians {
            #expect(median < 1.0)
        }
    }
}
