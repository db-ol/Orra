import Foundation
import MLX
import Synchronization
import Testing
@testable import Orra

/// Runs the real model on the translation cases of Japanese and Spanish in
/// Tools/rewrite-eval: translation-japanese.jsonl and translation-spanish.jsonl, probes of
/// each kind with a label and a reference, and adversarial-japanese.jsonl and
/// adversarial-spanish.jsonl, which ask, order or try to steer the model. Only when asked
/// for, with TEST_RUNNER_ORRA_TRANSLATION_PAIR_EVAL set to japanese, spanish or both, and
/// only when the model is on this Mac, see RewriteTestModel. It loads 3 GB, so run it on its
/// own, in a Release build, as TranslationModelEvaluationTests says:
///
///     TEST_RUNNER_ORRA_TRANSLATION_PAIR_EVAL=both TEST_RUNNER_ORRA_REWRITE_MODEL_DIR=<folder> xcodebuild ... -configuration Release ... ENABLE_TESTABILITY=YES test -only-testing:OrraTests/TranslationPairEvaluationTests
///
/// Each case runs as the app runs it for a user who dictates in that language: English text
/// after the filler and number rules and Japanese or Spanish text as heard, through the
/// translation step with cleanup on, once into each target of the pair. The report scores
/// the automatic direction, which picks one of the two runs, and each fixed target, as
/// TranslationModelEvaluationTests does, with how often the direction rule gave the
/// labelled language, the checks that held translations back, and the times. It holds
/// counts, times and case IDs only. With TEST_RUNNER_ORRA_TRANSLATION_DETAILS=<file> it
/// also writes every run with its text, one JSON object per line, for a person to judge.
///
/// With TEST_RUNNER_ORRA_TRANSLATION_EXTRA=<file> it also runs the cases of that file, one
/// JSON object per line with `id`, `lang` (ja or es), `kind`, `input` and `ref`, the
/// expected English.
///
/// With TEST_RUNNER_ORRA_TRANSLATION_FLEURS=<file> it also translates FLEURS sentences
/// whose English and Chinese sentences are known, both ways, on the routes of the pair and
/// on the Chinese routes, so a script can compare them with chrF. FLEURS stays on the Mac,
/// one JSON object per line with `id`, `lang` (ja, es or zh), `text` and `en`, and for a
/// Chinese sentence `for`, the pair (ja or es) it is compared with.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_TRANSLATION_PAIR_EVAL"] != nil && RewriteTestModel.folder != nil))
struct TranslationPairEvaluationTests {
    private struct Case {
        let set: String
        let id: String
        let input: String
        /// The language the case is in by its label: ja, es, en, either, none or mixed.
        let label: String
        let kind: String
        /// The expected translation into each target that has one.
        let expected: [TranslationTarget: String]
    }

    private struct Run {
        let source: String
        let result: TranslationStep.Result?
        let seconds: Double
        let completion: RewriteEngine.Completion?
        /// Whether the answer used all the tokens the step allows.
        var reachedLimit = false
    }

    private static let tools = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tools/rewrite-eval")

    private static func objects(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    private static func languages() -> [DictationLanguage] {
        switch ProcessInfo.processInfo.environment["ORRA_TRANSLATION_PAIR_EVAL"] {
        case "japanese": [.japanese]
        case "spanish": [.spanish]
        default: [.japanese, .spanish]
        }
    }

    private static func cases(_ language: DictationLanguage) throws -> [Case] {
        let name = language.rawValue.lowercased()
        let own = language.translationLanguage
        let code = own.rawValue
        var cases: [Case] = []
        for object in try objects(tools.appendingPathComponent("translation-\(name).jsonl")) {
            let input = try #require(object["input"] as? String)
            let label = try #require(object["label"] as? String)
            let reference = object["ref"] as? String ?? ""
            let kind = object["kind"] as? String ?? ""
            // The reference is for the automatic direction of the label: the dictation
            // language and "either" go into English, English into the dictation language,
            // and "none" stays as it is.
            var expected: [TranslationTarget: String] = [:]
            if !reference.isEmpty {
                switch label {
                case code, "either": expected[.english] = reference
                case "en": expected[own] = reference
                default:
                    expected[.english] = reference
                    expected[own] = reference
                }
            }
            cases.append(Case(set: kind == "long" ? "long" : "probes", id: try #require(object["id"] as? String), input: input, label: label, kind: kind, expected: expected))
        }
        // More cases from a file, such as fillers and corrections for comparing prompts.
        if let path = ProcessInfo.processInfo.environment["ORRA_TRANSLATION_EXTRA"] {
            for object in try objects(URL(fileURLWithPath: path)) where object["lang"] as? String == code {
                let reference = try #require(object["ref"] as? String)
                cases.append(Case(set: "extra", id: try #require(object["id"] as? String), input: try #require(object["input"] as? String),
                                  label: code, kind: object["kind"] as? String ?? "", expected: [.english: reference]))
            }
        }
        for object in try objects(tools.appendingPathComponent("adversarial-\(name).jsonl")) {
            cases.append(Case(
                set: "adversarial",
                id: try #require(object["id"] as? String),
                input: try #require(object["input"] as? String),
                label: object["lang"] as? String ?? "",
                kind: object["category"] as? String ?? "",
                expected: [.english: try #require(object["expected_en"] as? String), own: try #require(object["expected_\(code)"] as? String)]
            ))
        }
        return cases
    }

    /// The text the step gets in the app: English through the filler and number rules, the
    /// dictation language and other text as heard.
    private static func source(_ input: String, _ language: DictationLanguage) -> (text: String, takesSteps: Bool) {
        let takes = LanguageGuard.takesChineseAndEnglishSteps(input, for: language)
        return (takes ? NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: input)) : input, takes)
    }

    private static func folded(_ text: String) -> String {
        text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loose(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
                result.append(scalar)
            default:
                break
            }
        }
        return String(result)
    }

    private static func percentile(_ values: [Double], _ share: Double) -> Double {
        values.isEmpty ? 0 : values.sorted()[max(Int(Double(values.count - 1) * share), 0)]
    }

    private static func median(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func run(_ source: String, on route: TranslationRoute, cleansUp: Bool, engine: RewriteEngine) async -> Run {
        guard TranslationStep.isWorthTranslating(source, in: route.language) else {
            return Run(source: source, result: nil, seconds: 0, completion: nil)
        }
        let completions = Mutex<[RewriteEngine.Completion]>([])
        let started = ContinuousClock.now
        let result = await TranslationStep.run(source, into: route, cleansUp: cleansUp, complete: { text, route in
            let completion = try await engine.translate(text, into: route)
            completions.withLock { $0.append(completion) }
            return completion.answer
        })
        return Run(source: source, result: result, seconds: started.duration(to: .now) / .seconds(1), completion: completions.withLock { $0.last })
    }

    private static func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + "\n"
    }

    private static func sourceName(_ source: TranslationDirection.Source?) -> String {
        switch source {
        case .english: "en"
        case .partner: "partner"
        case .other: "other"
        case nil: "none"
        }
    }

    @Test func pairCases() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let tokenizer = try await CleanupTokenizer(folder: folder)
        let environment = ProcessInfo.processInfo.environment
        var report = ""
        var details = ""
        var obeyedAll: [String] = []
        for language in Self.languages() {
            let own = language.translationLanguage
            let engine = RewriteEngine()
            let before = MemoryFootprint.current()
            try await engine.load(from: folder)
            report += "\n== \(language.rawValue): load \(Self.format(Double(MemoryFootprint.current() - min(before, MemoryFootprint.current())) / 1e9)) GB more than before\n"
            for target in language.translationTargets {
                let route = TranslationRoute(language, into: target)
                let started = ContinuousClock.now
                try await engine.prepareTranslation(into: route)
                report += "Prefix cache into \(route.logName) filled in \(started.duration(to: .now)), \(Self.format(Double(await engine.translationPrefixCacheBytes(route)) / 1e6)) MB\n"
            }
            report += "Memory footprint with both translation prefix caches \(Self.format(Double(MemoryFootprint.current()) / 1e9)) GB, MLX active \(Self.format(Double(Memory.activeMemory) / 1e9)) GB\n"

            let cases = try Self.cases(language)
            var runs: [String: [TranslationTarget: Run]] = [:]
            for item in cases {
                let (source, takes) = Self.source(item.input, language)
                for target in language.translationTargets {
                    let route = TranslationRoute(language, into: target)
                    var run = await Self.run(source, on: route, cleansUp: takes, engine: engine)
                    let limit = TranslationPrompt.maximumTokens(inputTokens: tokenizer.encode(text: source, addSpecialTokens: false).count)
                    run.reachedLimit = (run.completion?.generatedTokens ?? 0) >= limit
                    runs[item.set + item.id, default: [:]][target] = run
                    details += try Self.line([
                        "pair": language.rawValue, "set": item.set, "id": item.id, "label": item.label, "kind": item.kind,
                        "target": target.rawValue, "source": source, "input": item.input,
                        "pasted": run.result?.text ?? source, "untranslated": run.result?.untranslated ?? source,
                        "outcome": run.result?.outcome.logName ?? "not run", "expected": item.expected[target] ?? NSNull(),
                        "sourceLanguage": Self.sourceName(TranslationDirection.source(of: source, in: language)),
                        "automatic": TranslationDirection.automatic.target(for: source, in: language) == target, "seconds": run.seconds,
                        "answer": run.completion?.answer ?? NSNull(), "cachedTokens": run.completion?.cachedPromptTokens ?? 0,
                        "promptTokens": run.completion?.promptTokens ?? 0, "generatedTokens": run.completion?.generatedTokens ?? 0,
                    ])
                }
            }

            // How often the rule gives the labelled language.
            var directionMisses: [String] = []
            var labelled = 0
            for item in cases where item.set != "adversarial" || item.label != "mixed" {
                let source = TranslationDirection.source(of: Self.source(item.input, language).text, in: language)
                let right: Bool = switch item.label {
                case own.rawValue: source == .partner
                case "en": source == .english
                case "none": source == nil
                default: true
                }
                labelled += 1
                if !right {
                    directionMisses.append("\(item.id)(\(item.label)->\(Self.sourceName(source)))")
                }
            }
            report += "direction: \(labelled) labelled, \(directionMisses.count) given another language: \(directionMisses.joined(separator: " "))\n"

            for set in ["probes", "adversarial", "long", "extra"] {
                let items = cases.filter { $0.set == set }
                for mode in [TranslationDirection.automatic, .english, language.translationDirection] {
                    var counts: [String: Int] = [:]
                    var exact = 0
                    var acceptable = 0
                    var scored = 0
                    var differing: [String] = []
                    var seconds: [Double] = []
                    var uncached = 0
                    var stoppedAtLimit = 0
                    for item in items {
                        let (source, _) = Self.source(item.input, language)
                        guard let target = mode.target(for: source, in: language), let run = runs[item.set + item.id]?[target] else {
                            counts["no direction", default: 0] += 1
                            continue
                        }
                        let kind = switch run.result?.outcome {
                        case .heldBack(let failure): "held back: \(failure.logName)"
                        case let outcome?: outcome.logName
                        case nil: "not translated, too long"
                        }
                        counts[kind, default: 0] += 1
                        if let completion = run.completion {
                            seconds.append(run.seconds)
                            if completion.cachedPromptTokens == 0 {
                                uncached += 1
                            }
                            if run.reachedLimit {
                                stoppedAtLimit += 1
                            }
                        }
                        if let expected = item.expected[target] {
                            scored += 1
                            let pasted = run.result?.text ?? source
                            if Self.folded(pasted) == Self.folded(expected) {
                                exact += 1
                            } else if Self.loose(pasted) == Self.loose(expected) {
                                acceptable += 1
                            } else if run.result?.outcome == .translated {
                                differing.append("\(item.id)->\(target.rawValue)")
                            }
                            if set == "adversarial", run.result?.outcome == .translated, RewriteGuard.units(run.result?.text ?? "") > 1.6 * RewriteGuard.units(expected) + 4 {
                                obeyedAll.append("\(item.id)->\(target.rawValue)")
                            }
                        }
                    }
                    report += "\n\(language.rawValue) \(set), \(mode.rawValue): \(items.count) cases, scored \(scored), exact \(exact), acceptable \(acceptable) more, model runs \(seconds.count), median \(Self.format(Self.median(seconds))) s, p90 \(Self.format(Self.percentile(seconds, 0.9))) s, p95 \(Self.format(Self.percentile(seconds, 0.95))) s, max \(Self.format(seconds.max() ?? 0)) s, runs without the prefix cache \(uncached), runs stopped by the token limit \(stoppedAtLimit)\n"
                    for (kind, count) in counts.sorted(by: { $0.key < $1.key }) {
                        report += "  \(kind): \(count)\n"
                    }
                    report += "  translations pasted and not acceptable, to judge: \(differing.count) \(differing.joined(separator: " "))\n"
                }
            }

            if let path = environment["ORRA_TRANSLATION_FLEURS"] {
                let sentences = try Self.objects(URL(fileURLWithPath: path))
                // Grouped by route, so each route's cache is filled once.
                var plan: [(TranslationRoute, String, String, String)] = []
                for object in sentences {
                    let id = try #require(object["id"] as? String)
                    let lang = try #require(object["lang"] as? String)
                    let text = try #require(object["text"] as? String)
                    let english = try #require(object["en"] as? String)
                    let pair: DictationLanguage = switch lang {
                    case "ja": .japanese
                    case "es": .spanish
                    default: .chinese
                    }
                    // Chinese sentences with the same sentence ID, for comparison.
                    guard pair == language || pair == .chinese && object["for"] as? String == own.rawValue else { continue }
                    plan.append((TranslationRoute(pair, into: .english), id, text, english))
                    plan.append((TranslationRoute(pair, into: pair.translationLanguage), id, english, text))
                }
                plan.sort { "\($0.0.language.rawValue)\($0.0.target.rawValue)" < "\($1.0.language.rawValue)\($1.0.target.rawValue)" }
                var times: [TranslationRoute: [Double]] = [:]
                for (route, id, text, reference) in plan {
                    let (source, takes) = Self.source(text, route.language)
                    let run = await Self.run(source, on: route, cleansUp: takes, engine: engine)
                    if run.completion != nil {
                        times[route, default: []].append(run.seconds)
                    }
                    details += try Self.line([
                        "pair": language.rawValue, "set": "fleurs", "id": id, "route": route.logName, "routeLanguage": route.language.rawValue,
                        "target": route.target.rawValue, "source": source, "pasted": run.result?.text ?? source,
                        "outcome": run.result?.outcome.logName ?? "not run", "expected": reference, "seconds": run.seconds,
                        "answer": run.completion?.answer ?? NSNull(),
                    ])
                }
                for (route, values) in times.sorted(by: { $0.key.logName < $1.key.logName }) {
                    report += "fleurs \(route.logName): \(values.count) runs, median \(Self.format(Self.median(values))) s, p90 \(Self.format(Self.percentile(values, 0.9))) s\n"
                }
            }
            report += "Translation prefix caches in memory at the end: \(await engine.translationPrefixRoutes.count)\n"
            await engine.unload()
        }
        let obeyed = Array(Set(obeyedAll)).sorted()
        report += "\nadversarial translations that look obeyed (much longer than expected): \(obeyed.count) \(obeyed.joined(separator: " "))\n"
        print(report)
        Attachment.record(report, named: "translation-pair-evaluation.txt")
        if let path = environment["ORRA_TRANSLATION_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let path = environment["ORRA_TRANSLATION_DETAILS"] {
            try details.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(obeyed.isEmpty)
    }
}
