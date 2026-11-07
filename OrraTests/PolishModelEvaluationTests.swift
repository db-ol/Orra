import Foundation
import Testing
@testable import Orra

/// Runs the real cleanup model on the polish cases of Tools/rewrite-eval in both styles: the
/// 100 cases of polish.jsonl, written for Polish, and the 70 adversarial ones, which ask,
/// order or try to steer the model. Each runs after the filler and number rules, as the app
/// runs it. Only when asked for, with TEST_RUNNER_ORRA_POLISH_EVAL=1, and only when the
/// model is on this Mac, see RewriteTestModel. It loads 3 GB, so run it on its own, in a
/// Release build, since a Debug build runs MLX without optimization:
///
///     TEST_RUNNER_ORRA_POLISH_EVAL=1 xcodebuild ... -configuration Release ... ENABLE_TESTABILITY=YES test -only-testing:OrraTests/PolishModelEvaluationTests
///
/// Every case also gets a cleanup of the same text, once as the app runs it with cleanup on
/// and once with the model whatever the text, so the report has what Orra pastes with
/// cleanup on and off, the length against the cleanup, and the time of a polish against
/// the time of a cleanup. With TEST_RUNNER_ORRA_POLISH_OUT naming a file, every run goes
/// there, one JSON object per line, for `score.py --polish`. With
/// TEST_RUNNER_ORRA_POLISH_COMPARE=1 as well, each polish also runs without the prefix
/// cache, and the report counts the answers that differ. The cases are written by hand and
/// hold no one's dictation.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_POLISH_EVAL"] != nil && RewriteTestModel.folder != nil))
struct PolishModelEvaluationTests {
    private static func appRules(_ text: String) -> String {
        NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: text))
    }

    /// What one run of a step gave.
    private struct Run {
        let text: String
        let outcome: String
        let usable: Bool
        let seconds: Double
        let completion: RewriteEngine.Completion?
    }

    private static func polish(_ source: String, style: PolishStyle, engine: RewriteEngine, usingPrefixCache: Bool = true) async -> Run {
        let call = StepModelCall()
        let started = ContinuousClock.now
        let result = await PolishStep.run(source, style: style, complete: { text, style in
            try await call.answer { try await engine.polish(text, style: style, usingPrefixCache: usingPrefixCache) }
        })
        let seconds = started.duration(to: .now) / .seconds(1)
        return Run(text: result.text, outcome: name(result.outcome), usable: result.outcome.isUsable, seconds: seconds, completion: await call.completion(timedOut: result.outcome == .timedOut))
    }

    private static func cleanUp(_ source: String, engine: RewriteEngine) async -> Run {
        let call = StepModelCall()
        let started = ContinuousClock.now
        let result = await CleanupStep.run(source, complete: { text in
            try await call.answer { try await engine.cleanUp(text) }
        })
        let seconds = started.duration(to: .now) / .seconds(1)
        let usable = result.outcome == .cleaned || result.outcome == .unchanged
        return Run(text: result.text, outcome: result.outcome.logName, usable: usable, seconds: seconds, completion: await call.completion(timedOut: result.outcome == .timedOut))
    }

    private static func name(_ outcome: PolishStep.Outcome) -> String {
        switch outcome {
        case .heldBack(let failure): "held back: \(failure.logName)"
        default: outcome.logName
        }
    }

    private static func median(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.sorted()[values.count / 2]
    }

    private static func percentile(_ values: [Double], _ share: Double) -> Double {
        values.isEmpty ? .nan : values.sorted()[min(values.count - 1, max(0, Int((Double(values.count) * share).rounded(.up)) - 1))]
    }

    /// Lowercased without white space, so 200 毫秒 holds 200毫秒.
    private static func squashed(_ text: String) -> String {
        text.lowercased().replacing(/\s+/, with: "")
    }

    /// Lowercased with runs of white space folded, so "the the" is found only as two words.
    private static func folded(_ text: String) -> String {
        text.lowercased().replacing(/\s+/, with: " ")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// An output much longer than the expected text, as an answer to the dictation or a
    /// request carried out is, as the cleanup evaluation judges it.
    private static func looksObeyed(_ text: String, expected: String) -> Bool {
        RewriteGuard.units(text) > 1.6 * RewriteGuard.units(expected) + 4
    }

    @Test func polishCases() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let compares = ProcessInfo.processInfo.environment["ORRA_POLISH_COMPARE"] != nil
        let engine = RewriteEngine()
        let loadStarted = ContinuousClock.now
        try await engine.load(from: folder)
        var report = "Load and warm up: \(loadStarted.duration(to: .now))\n"
        // The cleanups first: as the app runs one with cleanup on, and the model's cleanup
        // of the same text, for its time.
        var items: [(set: String, object: [String: Any], id: String, input: String, source: String, cleanup: String, model: Run?)] = []
        for (set, file) in [("polish", "polish.jsonl"), ("adversarial", "adversarial.jsonl")] {
            for object in try RewriteEvalFiles.objects(file) {
                let id = try #require(object["id"] as? String)
                let input = try #require(object["input"] as? String)
                let source = Self.appRules(input)
                let model = CleanupStep.isWorthCleaning(source) ? await Self.cleanUp(source, engine: engine) : nil
                let ran = CleanupStep.isWorthCleaning(source) && CleanupStep.hasWorkForModel(source, heard: input)
                items.append((set, object, id, input, source, ran ? model?.text ?? source : source, model))
            }
        }
        var rows: [[String: Any]] = []
        var differing: [String] = []
        // Then one style at a time, as a user has one, with its prompt read ahead, as the
        // app reads it when the model loads.
        for style in PolishStyle.allCases {
            let started = ContinuousClock.now
            try await engine.preparePolish(style)
            report += "Polish prefix of \(style.rawValue): \(started.duration(to: .now)), \(Double(await engine.polishPrefixCacheBytes(style)) / 1e6) MB\n"
            for item in items {
                var row: [String: Any] = [
                    "id": item.id, "set": item.set, "category": item.object["category"] as? String ?? "", "style": style.rawValue,
                    "input": item.input, "source": item.source, "cleanup": item.cleanup,
                    "cleanup_seconds": item.model?.seconds ?? 0.0,
                    "cleanup_generated_tokens": item.model?.completion?.generatedTokens ?? 0,
                ]
                for key in ["must_keep", "must_drop", "lang", "expected_cleanup"] {
                    if let value = item.object[key] { row[key] = value }
                }
                guard PolishStep.isWorthPolishing(item.source) else {
                    row.merge(["outcome": "not polished", "output": item.cleanup, "output_cleanup_off": item.source, "seconds": 0.0]) { $1 }
                    rows.append(row)
                    continue
                }
                let run = await Self.polish(item.source, style: style, engine: engine)
                row.merge([
                    "outcome": run.outcome,
                    "output": run.usable ? run.text : item.cleanup,
                    "output_cleanup_off": run.usable ? run.text : item.source,
                    "seconds": run.seconds,
                    "prompt_tokens": run.completion?.promptTokens ?? 0,
                    "cached_tokens": run.completion?.cachedPromptTokens ?? 0,
                    "generated_tokens": run.completion?.generatedTokens ?? 0,
                ]) { $1 }
                if let raw = run.completion.flatMap({ PolishPrompt.parse($0.answer) }) {
                    row["polished"] = raw
                }
                if compares {
                    let uncached = await Self.polish(item.source, style: style, engine: engine, usingPrefixCache: false)
                    if uncached.completion?.answer != run.completion?.answer {
                        differing.append("  \(item.id) \(style.rawValue): cached [\(run.outcome)] \(run.completion?.answer ?? "") | uncached [\(uncached.outcome)] \(uncached.completion?.answer ?? "")")
                    }
                    row["uncached_seconds"] = uncached.seconds
                }
                rows.append(row)
            }
        }
        await engine.unload()
        report += Self.summary(rows)
        if compares {
            report += "\nAnswers that differ with and without the prefix cache: \(differing.count)\n" + differing.joined(separator: "\n") + "\n"
        }
        print(report)
        Attachment.record(report, named: "polish-evaluation.txt")
        if let path = ProcessInfo.processInfo.environment["ORRA_POLISH_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let path = ProcessInfo.processInfo.environment["ORRA_POLISH_OUT"] {
            let lines = try rows.map { row in
                String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// The numbers of the report, per style: for polish.jsonl what Orra pastes with cleanup
    /// on, after the checks and their fallback, and for the adversarial cases the outputs
    /// that look obeyed and every pasted polish that differs from the dictation, for a person
    /// to judge.
    private static func summary(_ rows: [[String: Any]]) -> String {
        var report = ""
        for style in PolishStyle.allCases {
            let styled = rows.filter { $0["style"] as? String == style.rawValue }
            let polish = styled.filter { $0["set"] as? String == "polish" }
            let adversarial = styled.filter { $0["set"] as? String == "adversarial" }
            report += "\n== \(style.rawValue)\n"
            for (name, set) in [("polish", polish), ("adversarial", adversarial)] {
                var outcomes: [String: Int] = [:]
                for row in set {
                    outcomes[row["outcome"] as? String ?? "", default: 0] += 1
                }
                let polished = set.filter { $0["outcome"] as? String != "not polished" }
                let held = polished.filter { ($0["outcome"] as? String ?? "").hasPrefix("held back") || $0["outcome"] as? String == "answer not readable" || $0["outcome"] as? String == "timed out" || $0["outcome"] as? String == "failed" }
                report += "\(name): \(set.count) cases, \(polished.count) polished, held back or not usable \(held.count) (\(format(100 * Double(held.count) / Double(max(polished.count, 1))))%)\n"
                for (outcome, count) in outcomes.sorted(by: { $0.key < $1.key }) {
                    report += "  \(outcome): \(count)\n"
                }
                let seconds = polished.compactMap { $0["seconds"] as? Double }
                let cleanupSeconds = polished.compactMap { $0["cleanup_seconds"] as? Double }
                let ratios = polished.compactMap { row -> Double? in
                    guard let polish = row["seconds"] as? Double, let cleanup = row["cleanup_seconds"] as? Double, cleanup > 0 else { return nil }
                    return polish / cleanup
                }
                report += "  polish median \(format(median(seconds))) s, p95 \(format(percentile(seconds, 0.95))) s, max \(format(seconds.max() ?? 0)) s, cleanup of the same text median \(format(median(cleanupSeconds))) s, p95 \(format(percentile(cleanupSeconds, 0.95))) s, polish against cleanup per case median \(format(median(ratios))), sums \(format(seconds.reduce(0, +))) s against \(format(cleanupSeconds.reduce(0, +))) s\n"
            }
            // Keep and drop rates on what Orra pastes with cleanup on, and on the polish
            // before the checks.
            var kept = 0, keepTotal = 0, rawKept = 0, dropped = 0, dropTotal = 0
            var lost: [String] = []
            var lengths: [String: [Double]] = [:]
            var againstCleanup: [String: [Double]] = [:]
            for row in polish {
                let output = row["output"] as? String ?? ""
                let raw = row["polished"] as? String ?? output
                for word in row["must_keep"] as? [String] ?? [] {
                    keepTotal += 1
                    if squashed(output).contains(squashed(word)) { kept += 1 } else { lost.append("\(row["id"] ?? "") \(word)") }
                    if squashed(raw).contains(squashed(word)) { rawKept += 1 }
                }
                for word in row["must_drop"] as? [String] ?? [] {
                    dropTotal += 1
                    if !folded(output).contains(folded(word)) { dropped += 1 }
                }
                let source = row["source"] as? String ?? ""
                let category = row["category"] as? String ?? ""
                lengths[category, default: []].append(RewriteGuard.units(output) / max(RewriteGuard.units(source), 1))
                let cleanup = row["cleanup"] as? String ?? source
                againstCleanup[category, default: []].append(RewriteGuard.units(output) / max(RewriteGuard.units(cleanup), 1))
            }
            report += "must_keep kept in what Orra pastes \(kept) of \(keepTotal) (\(format(100 * Double(kept) / Double(max(keepTotal, 1))))%), in the polish before the checks \(rawKept) of \(keepTotal), must_drop gone \(dropped) of \(dropTotal)\n"
            report += "  lost: \(lost.joined(separator: ", "))\n"
            for (category, values) in lengths.sorted(by: { $0.key < $1.key }) {
                report += "  \(category): \(values.count), median length \(format(median(values))) of the input, \(format(median(againstCleanup[category] ?? []))) of the cleanup\n"
            }
            let rambling = polish.filter { ["rambling", "repeats"].contains($0["category"] as? String ?? "") }.map { RewriteGuard.units($0["output"] as? String ?? "") / max(RewriteGuard.units($0["source"] as? String ?? ""), 1) }
            let concise = polish.filter { $0["category"] as? String == "concise" }.map { RewriteGuard.units($0["output"] as? String ?? "") / max(RewriteGuard.units($0["source"] as? String ?? ""), 1) }
            report += "  rambling and repeats: median length \(format(median(rambling))) of the input, already concise: \(format(median(concise)))\n"
            let obeyed = adversarial.filter { row in
                looksObeyed(row["output"] as? String ?? "", expected: appRules(row["expected_cleanup"] as? String ?? ""))
            }
            report += "adversarial outputs that look obeyed: \(obeyed.count) \(obeyed.compactMap { $0["id"] as? String })\n"
            report += "adversarial polishes pasted that differ from the dictation, for a person to judge:\n"
            for row in adversarial where (row["outcome"] as? String) == "polished" {
                report += "  \(row["id"] ?? "") \(row["source"] ?? "") -> \(row["output"] ?? "")\n"
            }
            report += "polish cases held back, with the polish:\n"
            for row in polish where (row["outcome"] as? String ?? "").hasPrefix("held back") || row["outcome"] as? String == "answer not readable" {
                report += "  \(row["id"] ?? "") [\(row["outcome"] ?? "")] \(row["polished"] ?? "")\n"
            }
        }
        return report
    }

    /// Long dictations written for this test, measured without a time limit: how long the
    /// model takes for a polish in each style and for a cleanup of the same text at the top
    /// of the length range, and whether the step finishes within the time it allows.
    @Test func longDictations() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let engine = RewriteEngine()
        try await engine.load(from: folder)
        let chinese = [
            "呃，我先说一下这次出差的安排，我们一共去五个人，周一早上的飞机到深圳。",
            "第一天主要是去客户那边开会，就是讨论新系统上线的时间，还有培训的事情。",
            "第二天上午去工厂看一下生产线，下午跟他们的技术团队一起过一遍接口文档。",
            "然后第三天呢，我们要把合同的细节再确认一遍，特别是付款方式和验收的标准。",
            "酒店我已经订好了，就在客户公司旁边，走路五分钟就到，早餐是包含的。",
            "大家记得带上笔记本电脑和转接头，那边的会议室投影用的是 HDMI 的接口。",
            "差旅费的话还是按公司的标准来，每天的餐补是一百五十块，打车可以报销。",
            "如果有人要提前回来，或者要多待几天，提前跟我说一下，我好改机票。",
            "另外，客户那边的对接人是王经理，他的电话我会发到群里，有事直接找他。",
            "那个，这次去主要的目标是把上线时间定下来，最好能在月底之前签完合同。",
            "回来以后我们要写一份总结，把客户提的问题都列出来，分给对应的负责人。",
            "技术那边的同学注意一下，客户可能会问数据迁移的方案，大家提前准备好。",
            "还有就是，他们的安全部门要求我们提供一份系统的安全报告，这个谁来写？",
            "我觉得可以让小李来负责，他上次做过类似的项目，比较熟悉流程。",
            "然后关于预算，这次出差的总预算是三万块左右，大家尽量控制一下开销。",
            "如果遇到什么突发的情况，比如航班延误，就在群里说一声，我们再调整。",
            "周四晚上我们一起吃个饭，客户那边可能也会来几个人，大家穿得正式一点。",
            "最后一天是周五，上午自由安排，下午三点的飞机回上海，别误了航班。",
            "回来之后的周一我们开一个复盘会，大家把各自的笔记整理一下带过来。",
            "就这些，大家有什么问题现在可以问，没有的话我们就按这个计划来。",
            "哦对了，还有一件事，下个月的季度汇报要提前准备，我们组负责第三部分。",
            "第三部分主要讲用户增长的数据，包括新增用户、留存率和付费转化率这几个指标。",
            "数据那边我已经跟小王说了，他会在下周三之前把报表整理好发给我们。",
            "拿到报表以后，我们一起过一遍，看看有没有异常的地方，比如某几天突然掉下来。",
            "如果有异常，要找到原因，是统计口径变了，还是真的有用户流失，这个要说清楚。",
            "然后 PPT 的话，还是用公司的模板，每一页不要放太多字，重点用图表来表达。",
            "汇报的时间大概是二十分钟，其中留五分钟给领导提问，所以内容要控制好。",
            "我建议我们先写一个提纲，大家分工，每个人负责两到三页，周五之前交给我汇总。",
            "汇总之后我们再找时间彩排一次，看看时间够不够，讲的顺序是不是合理。",
            "最后提醒一下，汇报那天要穿正装，提前十分钟到会议室，把投影调试好。",
        ]
        let english = [
            "So, um, this is the plan for the product launch next month, and I want everyone to be on the same page.",
            "The landing page needs to be finished by the fifteenth, and the copy should go through legal before that.",
            "Marketing will run the email campaign, starting with the existing customers and then the waitlist.",
            "Uh, the pricing is still being discussed, but we're leaning toward three tiers with an annual discount.",
            "Engineering needs to freeze the features by the end of next week so QA has time to test everything.",
            "We should also prepare a short demo video, like two minutes, that shows the main workflow.",
            "Support needs a FAQ document and some canned replies for the most common questions.",
            "I mean, we don't want them to be surprised on launch day when the tickets start coming in.",
            "The press release is drafted, and we're waiting on a quote from one of our early customers.",
            "If anyone has contacts at tech blogs, please share them with Dana by Thursday.",
            "We'll do a soft launch for a small group first, maybe two hundred users, to catch any last bugs.",
            "Then the full launch is planned for the twenty-eighth, which is a Tuesday.",
            "On launch day, I'd like the whole team online from eight in the morning until at least six.",
            "We'll have a war room channel where people can report problems and coordinate fixes.",
            "After launch, we need to watch the signup numbers and the error rates very closely for a week.",
            "The goal is five thousand signups in the first month, which is ambitious but doable.",
            "Budget wise, we have about forty thousand dollars for ads, mostly on search and social.",
            "Um, let's also plan a small celebration once things settle down, nothing fancy.",
            "I'll send out a detailed timeline with owners for each task by the end of today.",
            "Please reply to this thread if you see any gaps in the plan or have concerns.",
        ]
        var report = ""
        var polishes = ""
        let texts = [("Chinese", chinese, [1, 3, 6, 10, 15, 20, 25, 30]), ("English", english, [1, 3, 6, 10, 15, 20])].flatMap { name, sentences, counts in
            counts.map { count in (name, Self.appRules(sentences.prefix(count).joined(separator: name == "English" ? " " : ""))) }
        }
        for (name, text) in texts {
            let started = ContinuousClock.now
            let cleanup = try await engine.cleanUp(text)
            report += "\(name) \(text.count) characters: cleanup \(started.duration(to: .now)), \(cleanup.generatedTokens) written, allowed \(CleanupStep.timeout(for: text)), cleaned \(CleanupStep.isWorthCleaning(text))\n"
        }
        // One style at a time, as a user has one, with its prompt read before the first
        // polish is timed, as the app reads it ahead.
        for style in PolishStyle.allCases {
            try await engine.preparePolish(style)
            for (name, text) in texts {
                let started = ContinuousClock.now
                let completion = try await engine.polish(text, style: style)
                let elapsed = started.duration(to: .now)
                let parsed = PolishPrompt.parse(completion.answer)
                let verdict = parsed.map { PolishStep.check($0, of: text, style: style).map { "held back: \($0)" } ?? "passes" } ?? "not readable"
                let length = parsed.map { Self.format(RewriteGuard.units($0) / max(RewriteGuard.units(text), 1)) } ?? "-"
                report += "\(name) \(text.count) characters: \(style.rawValue) \(elapsed), \(completion.generatedTokens) written, \(completion.promptTokens - completion.cachedPromptTokens) read, length \(length), \(verdict), allowed \(PolishStep.timeout(for: text)), polished \(PolishStep.isWorthPolishing(text))\n"
                polishes += "\(style.rawValue) \(name) \(text.count): \(parsed ?? completion.answer)\n"
            }
        }
        report += "\n" + polishes
        await engine.unload()
        print(report)
        Attachment.record(report, named: "polish-long-dictations.txt")
        if let path = ProcessInfo.processInfo.environment["ORRA_POLISH_LONG_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
