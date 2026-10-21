import Foundation
import MLX
import Synchronization
import Testing
@testable import Orra

/// Runs the real model on the hand written dictations of Tools/rewrite-eval in Chinese,
/// Japanese and Spanish, each translated into the two other languages, the way the
/// translation key does with Translate into set to a language outside the pair, see
/// TranslationPlan. The Chinese ones are the cases of cases.jsonl and the Chinese and mixed
/// ones of adversarial.jsonl, the Japanese and Spanish ones those labelled in the language
/// in translation-japanese.jsonl and translation-spanish.jsonl and the Japanese, Spanish
/// and mixed ones of their adversarial files, as in the study of 2026-10-20. Only when asked
/// for, with TEST_RUNNER_ORRA_TRANSLATION_CROSS_EVAL set to all or to directions such as
/// zh-ja,es-zh, and only when the model is on this Mac, see RewriteTestModel. It loads
/// 3 GB, so run it on its own, in a Release build, as TranslationModelEvaluationTests says.
///
/// Each case runs as the app runs it for a user who dictates in its language: through the
/// filler and number rules when they take it, then through the plan of the direction,
/// with both caches filled first. The report holds counts, times and case IDs: the plans,
/// the outcomes and the checks that held translations back, the waits, and the
/// adversarial cases whose English looks answered, much longer than expected. With
/// TEST_RUNNER_ORRA_TRANSLATION_DETAILS=<file> it also writes every run with its text, one
/// JSON object per line, for a person to judge. A file that holds runs already is taken up
/// where it stopped, so a run can be cut into slices with
/// TEST_RUNNER_ORRA_TRANSLATION_CROSS_BUDGET=<seconds>.
///
/// With TEST_RUNNER_ORRA_TRANSLATION_CROSS_IN=<file> it runs the cases of that file
/// instead, one JSON object per line with `id`, `src` and `tgt` (zh, ja or es) and `text`,
/// and `expected_en` when there is one.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_TRANSLATION_CROSS_EVAL"] != nil && RewriteTestModel.folder != nil))
struct TranslationCrossEvaluationTests {
    private struct Case {
        let id: String
        let source: DictationLanguage
        let target: TranslationTarget
        let kind: String
        let text: String
        let expectedEnglish: String?
    }

    private static func language(_ code: String) -> DictationLanguage? {
        switch code {
        case "zh": .chinese
        case "ja": .japanese
        case "es": .spanish
        default: nil
        }
    }

    private static func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: TranslationDirection.isHan)
    }

    /// Each dictation into the two other languages.
    private static func cases() throws -> [Case] {
        if let path = ProcessInfo.processInfo.environment["ORRA_TRANSLATION_CROSS_IN"] {
            return try RewriteEvalFiles.objects(URL(fileURLWithPath: path)).map { object in
                Case(
                    id: try #require(object["id"] as? String),
                    source: try #require(language(object["src"] as? String ?? "")),
                    target: try #require(TranslationTarget(rawValue: object["tgt"] as? String ?? "")),
                    kind: object["kind"] as? String ?? "",
                    text: try #require(object["text"] as? String),
                    expectedEnglish: object["expected_en"] as? String
                )
            }
        }
        var dictations: [(DictationLanguage, String, String, String, String?)] = []
        for object in try RewriteEvalFiles.objects("adversarial.jsonl") where ["zh", "mixed"].contains(object["lang"] as? String) {
            let input = try #require(object["input"] as? String)
            if hasHan(input) {
                dictations.append((.chinese, try #require(object["id"] as? String), "adversarial", input, object["expected_en"] as? String))
            }
        }
        for object in try RewriteEvalFiles.objects("cases.jsonl") where object["category"] as? String != "particle_keep" {
            let input = try #require(object["input"] as? String)
            if hasHan(input) {
                dictations.append((.chinese, try #require(object["id"] as? String), object["category"] as? String ?? "", input, object["translate_en"] as? String))
            }
        }
        for language in [DictationLanguage.japanese, .spanish] {
            let name = language.rawValue.lowercased()
            let code = language.translationLanguage.rawValue
            for object in try RewriteEvalFiles.objects("translation-\(name).jsonl") where object["label"] as? String == code {
                dictations.append((language, try #require(object["id"] as? String), object["kind"] as? String ?? "", try #require(object["input"] as? String), object["ref"] as? String))
            }
            for object in try RewriteEvalFiles.objects("adversarial-\(name).jsonl") where [code, "mixed"].contains(object["lang"] as? String) {
                dictations.append((language, try #require(object["id"] as? String), "adversarial", try #require(object["input"] as? String), object["expected_en"] as? String))
            }
        }
        var cases: [Case] = []
        for (language, id, kind, text, expected) in dictations {
            for target in [TranslationTarget.chinese, .japanese, .spanish] where target != language.translationLanguage {
                cases.append(Case(id: "\(language.translationLanguage.rawValue)\(target.rawValue)-\(id)", source: language, target: target, kind: kind, text: text, expectedEnglish: expected))
            }
        }
        return cases
    }

    /// The directions asked for, such as zh-ja, or nil for all.
    private static func directions() -> Set<String>? {
        let value = ProcessInfo.processInfo.environment["ORRA_TRANSLATION_CROSS_EVAL"] ?? "all"
        return value == "all" ? nil : Set(value.split(separator: ",").map(String.init))
    }

    private static func direction(_ item: Case) -> String {
        "\(item.source.translationLanguage.rawValue)-\(item.target.rawValue)"
    }

    private static func direction(of target: TranslationTarget) -> TranslationDirection {
        switch target {
        case .english: .english
        case .chinese: .chinese
        case .japanese: .japanese
        case .spanish: .spanish
        }
    }

    private static func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + "\n"
    }

    private static func planName(_ plan: TranslationPlan?) -> String {
        switch plan {
        case .route: "one route"
        case .throughEnglish: "through English"
        case .inTarget: "in the target"
        case nil: "nothing to translate"
        }
    }

    /// The model calls of one case, each with its text and route.
    private final class Calls: Sendable {
        let list = Mutex<[(text: String, route: TranslationRoute, call: StepModelCall)]>([])
    }

    @Test func crossCases() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let environment = ProcessInfo.processInfo.environment
        let wanted = Self.directions()
        let budget = Double(environment["ORRA_TRANSLATION_CROSS_BUDGET"] ?? "") ?? .infinity
        let detailsPath = environment["ORRA_TRANSLATION_DETAILS"]
        var done: Set<String> = []
        var details = ""
        if let detailsPath, FileManager.default.fileExists(atPath: detailsPath) {
            details = try String(contentsOfFile: detailsPath, encoding: .utf8)
            for object in try RewriteEvalFiles.objects(URL(fileURLWithPath: detailsPath)) {
                done.insert(object["id"] as? String ?? "")
            }
        }
        let cases = try Self.cases().filter { wanted?.contains(Self.direction($0)) ?? true }
        let started = ContinuousClock.now
        let engine = RewriteEngine()
        try await engine.load(from: folder)
        var report = "load \(started.duration(to: .now))\n"
        var stopped = false
        var obeyed: [String] = []
        var groups: [String] = []
        for item in cases where !groups.contains(Self.direction(item)) {
            groups.append(Self.direction(item))
        }
        for group in groups {
            let items = cases.filter { Self.direction($0) == group && !done.contains($0.id) }
            guard let first = items.first else { continue }
            let direction = Self.direction(of: first.target)
            for route in TextCleanup.preparedRoutes(direction, first.source) {
                let filling = ContinuousClock.now
                try await engine.prepareTranslation(into: route)
                report += "\(group): prefix cache of \(route.logName) filled in \(filling.duration(to: .now)), \(TranslationScoring.format(Double(await engine.translationPrefixCacheBytes(route)) / 1e6)) MB\n"
            }
            var plans: [String: Int] = [:]
            var outcomes: [String: Int] = [:]
            var seconds: [Double] = []
            var uncached = 0
            for item in items {
                if started.duration(to: .now) / .seconds(1) > budget {
                    stopped = true
                    break
                }
                let takes = LanguageGuard.takesChineseAndEnglishSteps(item.text, for: item.source)
                let text = takes ? NumberRules.writingNumbersAsDigits(in: FillerRules.removingFillers(from: item.text)) : item.text
                let plan = await direction.plan(for: text, in: item.source)
                plans[Self.planName(plan), default: 0] += 1
                let calls = Calls()
                var result: TranslationStep.Result?
                var took = 0.0
                if let plan, text.count <= TranslationStep.maximumLength {
                    let running = ContinuousClock.now
                    result = await TranslationStep.run(text, plan: plan, in: item.source, cleansUp: takes, complete: { text, route in
                        let call = StepModelCall()
                        calls.list.withLock { $0.append((text, route, call)) }
                        return try await call.answer { try await engine.translate(text, into: route) }
                    })
                    // Until the paste, as in the app, and not the rest of a call that timed out.
                    took = running.duration(to: .now) / .seconds(1)
                    seconds.append(took)
                }
                var made: [(text: String, route: TranslationRoute, completion: RewriteEngine.Completion?)] = []
                let entries = calls.list.withLock { $0 }
                for (index, entry) in entries.enumerated() {
                    // A call that timed out is waited for, so its rest does not slow the next case.
                    let timedOut = result?.outcome == .timedOut && index == entries.count - 1
                    made.append((entry.text, entry.route, await entry.call.completion(timedOut: timedOut)))
                }
                uncached += made.filter { $0.completion?.cachedPromptTokens == 0 }.count
                let outcome = switch result?.outcome {
                case .heldBack(let failure): "held back: \(failure.logName)"
                case let outcome?: outcome.logName
                case nil: "not run"
                }
                outcomes[outcome, default: 0] += 1
                // The English of a way through English is the text of the second call.
                let english = made.count == 2 ? made[1].text : nil
                if item.kind.hasPrefix("adversarial"), let english, let expected = item.expectedEnglish, RewriteGuard.units(english) > 1.6 * RewriteGuard.units(expected) + 4 {
                    obeyed.append(item.id)
                }
                details += try Self.line([
                    "id": item.id, "direction": group, "kind": item.kind, "input": item.text, "source": text, "rulesChanged": text != item.text,
                    "plan": Self.planName(plan), "english": english ?? NSNull(), "pasted": result?.text ?? text,
                    "untranslated": result?.untranslated ?? text, "outcome": outcome, "seconds": took,
                    "answers": made.map { $0.completion?.answer ?? "" }, "routes": made.map(\.route.logName),
                    "cachedTokens": made.map { $0.completion?.cachedPromptTokens ?? 0 }, "expected_en": item.expectedEnglish ?? NSNull(),
                ])
            }
            report += "\(group): \(items.count) cases to run, median \(TranslationScoring.format(TranslationScoring.median(seconds))) s, p90 \(TranslationScoring.format(TranslationScoring.percentile(seconds, 0.9))) s, max \(TranslationScoring.format(seconds.max() ?? 0)) s, calls without the prefix cache \(uncached)\n"
            for (name, count) in plans.sorted(by: { $0.key < $1.key }) {
                report += "  plan \(name): \(count)\n"
            }
            for (name, count) in outcomes.sorted(by: { $0.key < $1.key }) {
                report += "  \(name): \(count)\n"
            }
            if stopped { break }
        }
        report += stopped ? "stopped at the budget\n" : "all done\n"
        report += "adversarial cases whose English looks answered (much longer than expected): \(obeyed.count) \(obeyed.joined(separator: " "))\n"
        report += "footprint \(TranslationScoring.format(Double(MemoryFootprint.current()) / 1e9)) GB, MLX active \(TranslationScoring.format(Double(Memory.activeMemory) / 1e9)) GB\n"
        await engine.unload()
        print(report)
        Attachment.record(report, named: "translation-cross-evaluation.txt")
        if let path = environment["ORRA_TRANSLATION_REPORT"] {
            let previous = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try (previous + report).write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let detailsPath {
            try details.write(toFile: detailsPath, atomically: true, encoding: .utf8)
        }
        #expect(obeyed.isEmpty)
    }
}
