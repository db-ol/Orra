import Foundation
import Testing
@testable import Orra

/// Runs the real cleanup model on the cleanup cases of Tools/rewrite-eval: the 178 regular
/// cases and the 70 adversarial ones, which ask, order or try to steer the model. Only when
/// asked for, with TEST_RUNNER_ORRA_CLEANUP_EVAL=1, and only when the model is on this Mac,
/// see RewriteTestModel. It loads 2.3 GB, so run it on its own:
///
///     TEST_RUNNER_ORRA_CLEANUP_EVAL=1 TEST_RUNNER_ORRA_REWRITE_MODEL_DIR=<folder> xcodebuild ... test -only-testing:OrraTests/CleanupModelEvaluationTests
///
/// Each case runs twice: on the dictation itself, as the benchmark did, and as the app runs
/// it, after the filler and number rules. The report lists exact matches, what the step did
/// with each output, and every output that was pasted and differs from the expected text,
/// for a person to judge. The cases are written by hand and hold no one's dictation.
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

    @Test func cleanupCases() async throws {
        let folder = try #require(RewriteTestModel.folder)
        let engine = RewriteEngine()
        let before = MemoryFootprint.current()
        let loadStarted = ContinuousClock.now
        try await engine.load(from: folder)
        let loadTime = loadStarted.duration(to: .now)
        let loaded = MemoryFootprint.current()
        let complete: @Sendable (String) async throws -> String = { try await engine.cleanUp($0).answer }

        var report = "Load and warm up: \(loadTime), memory footprint \(Double(loaded) / 1e9) GB after load (\(Double(loaded - min(before, loaded)) / 1e9) GB more than before)\n"
        var medians: [Double] = []
        for (name, file, key) in [("regular", "cases.jsonl", "cleanup"), ("adversarial", "adversarial.jsonl", "expected_cleanup")] {
            let cases = try Self.cases(file, expected: key)
            for mode in ["model only", "as the app runs it"] {
                var exact = 0
                var outcomes: [String: Int] = [:]
                var seconds: [Double] = []
                var differing: [String] = []
                for item in cases {
                    let source = mode == "model only" ? item.input : Self.appRules(item.input)
                    let expected = mode == "model only" ? item.expected : Self.appRules(item.expected)
                    let started = ContinuousClock.now
                    let result: (text: String, outcome: CleanupStep.Outcome)
                    if mode == "model only" || CleanupStep.isWorthCleaning(source) {
                        result = await CleanupStep.run(source, complete: complete)
                    } else {
                        result = (source, .unchanged)
                    }
                    let elapsed = started.duration(to: .now)
                    seconds.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                    let kind = switch result.outcome {
                    case .heldBack(let failure): "held back: \(failure.logName)"
                    default: result.outcome.logName
                    }
                    outcomes[kind, default: 0] += 1
                    if Self.folded(result.text) == Self.folded(expected) {
                        exact += 1
                    } else if result.outcome == .cleaned || result.outcome == .unchanged {
                        differing.append("  \(item.id) [\(result.outcome.logName)] \(source) -> \(result.text) (expected \(expected))")
                    }
                }
                let sorted = seconds.sorted()
                let median = sorted[sorted.count / 2]
                let p95 = sorted[Int(Double(sorted.count) * 0.95) - 1]
                if mode == "model only" {
                    medians.append(median)
                }
                report += "\n\(name), \(mode): \(cases.count) cases, exact \(exact), median \(String(format: "%.3f", median)) s, p95 \(String(format: "%.3f", p95)) s, max \(String(format: "%.3f", sorted.last ?? 0)) s\n"
                for (kind, count) in outcomes.sorted(by: { $0.key < $1.key }) {
                    report += "  \(kind): \(count)\n"
                }
                report += "  pasted and not as expected: \(differing.count)\n" + differing.joined(separator: "\n") + "\n"
            }
        }
        await engine.unload()
        print(report)
        Attachment.record(report, named: "cleanup-evaluation.txt")
        if let path = ProcessInfo.processInfo.environment["ORRA_CLEANUP_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        // The setting promises about half a second. The benchmark measured 0.49 and 0.56 s.
        for median in medians {
            #expect(median < 1.0)
        }
    }
}
