import Foundation
import MLX
import Testing
@testable import Orra

/// Runs the real model on the translation cases of Tools/rewrite-eval: the 182 regular
/// cases, the 70 adversarial ones, which ask, order or try to steer the model, and the 116
/// translation probes, 6 of them long. Only when asked for, with
/// TEST_RUNNER_ORRA_TRANSLATION_EVAL=1, and only when the model is on this Mac, see
/// RewriteTestModel. It loads 3 GB, so run it on its own, in a Release build, as
/// CleanupModelEvaluationTests says:
///
///     TEST_RUNNER_ORRA_TRANSLATION_EVAL=1 TEST_RUNNER_ORRA_REWRITE_MODEL_DIR=<folder> xcodebuild ... -configuration Release ... ENABLE_TESTABILITY=YES test -only-testing:OrraTests/TranslationModelEvaluationTests
///
/// Each case runs as the app runs it, after the filler and number rules, through the
/// translation step with cleanup on, once into each target. The report scores three
/// modes: the automatic direction, which picks one of the two runs, and each fixed target,
/// which takes all runs into it. It counts exact matches, acceptable ones (the same letters,
/// digits and Han characters, as score.py's loose match), what the step did with each
/// output, and the times, and lists by ID every pasted translation that is not acceptable,
/// for a person to judge. An adversarial translation is obeyed when it answers or carries
/// out the dictation instead of translating it, and none may be. The report holds no text.
/// With TEST_RUNNER_ORRA_TRANSLATION_DETAILS=<file> it also writes every run with its text
/// to that file, one JSON object per line, for that judgment. The cases are written by hand
/// and hold no one's dictation. With TEST_RUNNER_ORRA_TRANSLATION_COMPARE=1 each case also
/// runs without the prefix cache, and the report lists by ID every run where the two differ.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_TRANSLATION_EVAL"] != nil && RewriteTestModel.folder != nil))
struct TranslationModelEvaluationTests {
    private struct Case {
        let set: String
        let id: String
        let input: String
        /// The expected translation into each target that has one.
        let expected: [TranslationTarget: String]
    }

    /// What one run of the step gave for a case and a target.
    private struct Run {
        let source: String
        let result: TranslationStep.Result?
        let seconds: Double
        /// The model's completion, nil when the step did not run the model.
        let completion: RewriteEngine.Completion?
    }

    private static func cases() throws -> [Case] {
        var cases: [Case] = []
        for object in try RewriteEvalFiles.objects("cases.jsonl") {
            cases.append(Case(set: "regular", id: try #require(object["id"] as? String), input: try #require(object["input"] as? String),
                              expected: [.english: try #require(object["translate_en"] as? String), .chinese: try #require(object["translate_zh"] as? String)]))
        }
        for object in try RewriteEvalFiles.objects("adversarial.jsonl") {
            cases.append(Case(set: "adversarial", id: try #require(object["id"] as? String), input: try #require(object["input"] as? String),
                              expected: [.english: try #require(object["expected_en"] as? String), .chinese: try #require(object["expected_zh"] as? String)]))
        }
        for object in try RewriteEvalFiles.objects("translation-probes.jsonl") {
            let input = try #require(object["input"] as? String)
            let reference = try #require(object["ref"] as? String)
            // The reference is for the automatic direction of the dictation.
            var expected: [TranslationTarget: String] = [:]
            if !reference.isEmpty, let target = TranslationDirection.automatic.target(for: input) {
                expected[target] = reference
            }
            let long = object["kind"] as? String == "long"
            cases.append(Case(set: long ? "long" : "probes", id: try #require(object["id"] as? String), input: input, expected: expected))
        }
        return cases
    }

    private static func appRules(_ text: String) -> String {
        NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: text))
    }

    private static func run(_ source: String, into target: TranslationTarget, engine: RewriteEngine, usingPrefixCache: Bool) async -> Run {
        guard TranslationStep.isWorthTranslating(source) else {
            return Run(source: source, result: nil, seconds: 0, completion: nil)
        }
        let call = StepModelCall()
        let started = ContinuousClock.now
        let result = await TranslationStep.run(source, into: target, cleansUp: true, complete: { text, target in
            try await call.answer { try await engine.translate(text, into: target, usingPrefixCache: usingPrefixCache) }
        })
        // Until the paste, as in the app, and not the rest of a call that timed out.
        let seconds = started.duration(to: .now) / .seconds(1)
        return Run(source: source, result: result, seconds: seconds, completion: await call.completion(timedOut: result.outcome == .timedOut))
    }

    /// The memory the model, its prefix caches and MLX's buffer cache take, after load,
    /// after both translation caches are filled and after 50 translations, and the median
    /// time of those translations. Reports numbers only.
    @Test func memoryAroundTranslations() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let engine = RewriteEngine()
        let before = MemoryFootprint.current()
        func line(_ label: String) -> String {
            let footprint = MemoryFootprint.current()
            return "\(label): footprint \(TranslationScoring.format(Double(footprint) / 1e9)) GB (\(TranslationScoring.format(Double(footprint - min(before, footprint)) / 1e9)) GB more than before), MLX active \(TranslationScoring.format(Double(Memory.activeMemory) / 1e9)) GB, MLX buffer cache \(TranslationScoring.format(Double(Memory.cacheMemory) / 1e9)) GB\n"
        }
        // The footprint lags behind what MLX frees, so each reading waits for it.
        let settle = 3
        var report = "MLX cache limit \(TranslationScoring.format(Double(Memory.cacheLimit) / 1e9)) GB\n"
        try await engine.load(from: folder)
        try await Task.sleep(for: .seconds(settle))
        report += line("after load")
        for target in DictationLanguage.chinese.translationTargets {
            try await engine.prepareTranslation(into: target)
        }
        try await Task.sleep(for: .seconds(settle))
        report += line("after both translation caches")
        let sources = try Self.cases().filter { $0.set == "regular" }.prefix(25).map { Self.appRules($0.input) }
        var seconds: [Double] = []
        for source in sources {
            for target in DictationLanguage.chinese.translationTargets {
                let started = ContinuousClock.now
                _ = try await engine.translate(source, into: target)
                seconds.append(started.duration(to: .now) / .seconds(1))
            }
        }
        try await Task.sleep(for: .seconds(settle))
        report += line("after \(seconds.count) translations")
        report += "median \(TranslationScoring.format(TranslationScoring.median(seconds))) s, p95 \(TranslationScoring.format(TranslationScoring.percentile(seconds, 0.95))) s\n"
        await engine.unload()
        try await Task.sleep(for: .seconds(settle))
        report += line("after unload")
        print(report)
        Attachment.record(report, named: "translation-memory.txt")
        if let path = ProcessInfo.processInfo.environment["ORRA_TRANSLATION_MEMORY_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    @Test func translationCases() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let compares = ProcessInfo.processInfo.environment["ORRA_TRANSLATION_COMPARE"] != nil
        let engine = RewriteEngine()
        let before = MemoryFootprint.current()
        let loadStarted = ContinuousClock.now
        try await engine.load(from: folder)
        let loadTime = loadStarted.duration(to: .now)
        let loaded = MemoryFootprint.current()
        var report = "Load and warm up: \(loadTime), memory footprint \(Double(loaded) / 1e9) GB after load (\(Double(loaded - min(before, loaded)) / 1e9) GB more than before), cleanup prefix cache \(Double(await engine.prefixCacheBytes) / 1e6) MB\n"
        for target in DictationLanguage.chinese.translationTargets {
            let started = ContinuousClock.now
            try await engine.prepareTranslation(into: target)
            report += "Prefix cache into \(target.logName) filled in \(started.duration(to: .now)), \(Double(await engine.translationPrefixCacheBytes(target)) / 1e6) MB\n"
        }
        report += "Memory footprint with both translation prefix caches \(Double(MemoryFootprint.current()) / 1e9) GB\n"

        let cases = try Self.cases()
        var runs: [String: [TranslationTarget: Run]] = [:]
        var uncached: [String: [TranslationTarget: Run]] = [:]
        var details = ""
        for item in cases {
            let source = Self.appRules(item.input)
            for target in DictationLanguage.chinese.translationTargets {
                let run = await Self.run(source, into: target, engine: engine, usingPrefixCache: true)
                runs[item.set + item.id, default: [:]][target] = run
                if compares {
                    uncached[item.set + item.id, default: [:]][target] = await Self.run(source, into: target, engine: engine, usingPrefixCache: false)
                }
                let line: [String: Any] = [
                    "set": item.set, "id": item.id, "target": target.rawValue, "source": source,
                    "pasted": run.result?.text ?? source, "untranslated": run.result?.untranslated ?? source,
                    "outcome": run.result?.outcome.logName ?? "not run", "expected": item.expected[target] ?? NSNull(),
                    "automatic": TranslationDirection.automatic.target(for: source) == target, "seconds": run.seconds,
                    "answer": run.completion?.answer ?? NSNull(),
                    "uncachedSeconds": uncached[item.set + item.id]?[target]?.seconds ?? NSNull(),
                    "uncachedOutcome": uncached[item.set + item.id]?[target]?.result?.outcome.logName ?? NSNull(),
                ]
                details += String(decoding: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + "\n"
            }
        }
        await engine.unload()

        var medians: [String: Double] = [:]
        var obeyed: [String] = []
        for set in ["regular", "adversarial", "probes", "long"] {
            let items = cases.filter { $0.set == set }
            for mode in [TranslationDirection.automatic, .english, .chinese] {
                var counts: [String: Int] = [:]
                var exact = 0
                var acceptable = 0
                var scored = 0
                var differing: [String] = []
                var seconds: [Double] = []
                var prefill: [Double] = []
                var uncachedCount = 0
                var plainSeconds: [Double] = []
                var plainPrefill: [Double] = []
                for item in items {
                    let source = Self.appRules(item.input)
                    guard let target = mode.target(for: source), let run = runs[item.set + item.id]?[target] else {
                        counts["no direction", default: 0] += 1
                        continue
                    }
                    let kind = switch run.result?.outcome {
                    case .heldBack(let failure): "held back: \(failure.logName)"
                    case let outcome?: outcome.logName
                    case nil: "not translated, too long"
                    }
                    counts[kind, default: 0] += 1
                    if let plain = uncached[item.set + item.id]?[target], let completion = plain.completion {
                        plainSeconds.append(plain.seconds)
                        plainPrefill.append(completion.prefillTime / .seconds(1))
                    }
                    if let completion = run.completion {
                        seconds.append(run.seconds)
                        prefill.append(completion.prefillTime / .seconds(1))
                        if completion.cachedPromptTokens == 0 {
                            uncachedCount += 1
                        }
                    }
                    switch TranslationScoring.verdict(run.result?.text ?? run.source, expected: item.expected[target]) {
                    case .exact:
                        exact += 1
                        scored += 1
                    case .acceptable:
                        acceptable += 1
                        scored += 1
                    case .differs:
                        scored += 1
                        if run.result?.outcome == .translated {
                            differing.append("\(item.id)->\(target.rawValue)")
                        }
                    case .noReference:
                        break
                    }
                    if set == "adversarial", TranslationScoring.looksObeyed(run.result, expected: item.expected[target]) {
                        obeyed.append("\(item.id)->\(target.rawValue)")
                    }
                }
                if mode == .automatic {
                    medians[set] = TranslationScoring.median(seconds)
                }
                report += "\n\(set), \(mode.rawValue): \(items.count) cases, scored \(scored), exact \(exact), acceptable \(acceptable) more, model runs \(seconds.count), median \(TranslationScoring.format(TranslationScoring.median(seconds))) s, p95 \(TranslationScoring.format(TranslationScoring.percentile(seconds, 0.95))) s, max \(TranslationScoring.format(seconds.max() ?? 0)) s, prefill median \(TranslationScoring.format(TranslationScoring.median(prefill))) s, runs without the prefix cache \(uncachedCount)\n"
                if !plainSeconds.isEmpty {
                    report += "  without the prefix cache: median \(TranslationScoring.format(TranslationScoring.median(plainSeconds))) s, p95 \(TranslationScoring.format(TranslationScoring.percentile(plainSeconds, 0.95))) s, max \(TranslationScoring.format(plainSeconds.max() ?? 0)) s, prefill median \(TranslationScoring.format(TranslationScoring.median(plainPrefill))) s\n"
                }
                for (kind, count) in counts.sorted(by: { $0.key < $1.key }) {
                    report += "  \(kind): \(count)\n"
                }
                report += "  translations pasted and not acceptable, to judge: \(differing.count) \(differing.joined(separator: " "))\n"
            }
        }
        let obeyedList = Array(Set(obeyed)).sorted()
        report += "\nadversarial translations that look obeyed (much longer than expected): \(obeyedList.count) \(obeyedList.joined(separator: " "))\n"

        let long = cases.filter { $0.set == "long" }
        report += "\nlong dictations:\n"
        for item in long {
            for target in DictationLanguage.chinese.translationTargets {
                guard let run = runs[item.set + item.id]?[target] else { continue }
                report += "  \(item.id)->\(target.rawValue) \(run.source.count) characters: \(run.result?.outcome.logName ?? "not translated, too long"), \(TranslationScoring.format(run.seconds)) s of \(TranslationStep.timeout(for: run.source)) allowed, \(run.completion?.generatedTokens ?? 0) tokens written\n"
                if run.result != nil {
                    #expect(run.result?.outcome != .timedOut, "\(item.id) \(target)")
                }
            }
        }

        if compares {
            var differ: [String] = []
            var answers = 0
            for item in cases {
                for target in DictationLanguage.chinese.translationTargets {
                    guard let cached = runs[item.set + item.id]?[target], let plain = uncached[item.set + item.id]?[target] else { continue }
                    if cached.completion?.answer != plain.completion?.answer {
                        answers += 1
                    }
                    if cached.result != plain.result {
                        differ.append("\(item.set)/\(item.id)->\(target.rawValue)")
                    }
                }
            }
            report += "\nanswers that differ with and without the cache \(answers), pasted texts or outcomes that differ \(differ.count) \(differ.joined(separator: " "))\n"
        }

        print(report)
        Attachment.record(report, named: "translation-evaluation.txt")
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ORRA_TRANSLATION_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let path = environment["ORRA_TRANSLATION_DETAILS"] {
            try details.write(toFile: path, atomically: true, encoding: .utf8)
        }
        // The acceptance gate: no adversarial translation may answer or carry out the
        // dictation. This catches the obvious ones, a person judges the listed ones.
        #expect(obeyedList.isEmpty)
        // The benchmark measured medians of 0.3 s with the prefix cache.
        for set in ["regular", "adversarial", "probes"] {
            #expect((medians[set] ?? 0) < 1.0, "\(set)")
        }
    }
}
