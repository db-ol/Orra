import Foundation
import Testing
@testable import Orra

/// The number rules on the evaluation set in Tools/rewrite-eval and on focused cases.
struct NumberRulesTests {
    struct Case: Decodable, CustomTestStringConvertible {
        let id: String
        let kind: String
        let input: String
        let expected: String
        let note: String

        var testDescription: String { id }
    }

    /// A case of the cleanup evaluation set, for the cases without numbers.
    struct CleanupCase: Decodable {
        let id: String
        let cleanup: String
    }

    private static func lines(of name: String) -> [Substring] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/rewrite-eval/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
    }

    /// The cases of the number evaluation set, read from the source tree.
    static let cases: [Case] = {
        let decoder = JSONDecoder()
        return lines(of: "numbers.jsonl").compactMap { line in
            try? decoder.decode(Case.self, from: Data(line.utf8))
        }
    }()

    @Test func theEvaluationSetIsRead() {
        #expect(Self.cases.count >= 290)
        #expect(Set(Self.cases.map(\.id)).count == Self.cases.count)
        #expect(Self.cases.allSatisfy { $0.kind == "convert" || $0.kind == "keep" })
        // A case to keep expects its input, and a case to convert expects a change.
        #expect(Self.cases.allSatisfy { ($0.kind == "keep") == ($0.input == $0.expected) })
    }

    @Test(arguments: cases)
    func evaluationCase(_ item: Case) {
        #expect(NumberRules.writingNumbersAsDigits(in: item.input) == item.expected)
    }

    @Test(arguments: cases)
    func applyingTwiceChangesNothingMore(_ item: Case) {
        let once = NumberRules.writingNumbersAsDigits(in: item.input)
        #expect(NumberRules.writingNumbersAsDigits(in: once) == once)
    }

    /// Cleanups of the filler and correction set without a number, other than 一 or 两 on
    /// their own as in 一下 and 两个人, stay exactly as they are.
    @Test func cleanupsWithoutNumbersStayTheSame() throws {
        let decoder = JSONDecoder()
        let cleanups = try Self.lines(of: "cases.jsonl").map { line in
            try decoder.decode(CleanupCase.self, from: Data(line.utf8))
        }
        #expect(cleanups.count >= 170)
        let numerals = Set("零〇一二两三四五六七八九十百千万亿幺")
        var checked = 0
        for item in cleanups {
            let runs = item.cleanup.split { !numerals.contains($0) }
            guard runs.allSatisfy({ $0 == "一" || $0 == "两" }) else { continue }
            checked += 1
            #expect(NumberRules.writingNumbersAsDigits(in: item.cleanup) == item.cleanup, "\(item.id)")
        }
        #expect(checked >= 100)
    }

    @Test(arguments: [
        "The meeting is at 3pm, room 302.",
        "We shipped version 2.1 on October 10, 2026, to 1,200 users.",
        "I owe you twenty five dollars, not 250.",
        "Call me at 555 0123 or email aaron@example.com.",
        "iPhone 15 Pro Max, M4 Max, GPT-4o and RTX 4090.",
        "",
    ])
    func englishIsUntouched(_ text: String) {
        #expect(NumberRules.writingNumbersAsDigits(in: text) == text)
    }

    @Test(arguments: [
        // Ranges of times.
        ("下午三点半到四点开会。", "下午3点半到4点开会。"),
        ("晚上八点至十点。", "晚上8点至10点。"),
        // Large numbers keep 万 and 亿.
        ("一共一千二百三十四万五千元。", "一共1234.5万元。"),
        ("十亿", "10亿"),
        // A version after a Latin name, and a time after a name.
        ("跟 Tom 三点二十见面。", "跟 Tom 3点20见面。"),
        ("用 Python 三点十一 跑。", "用 Python 3.11 跑。"),
        // Units in Latin letters.
        ("四K屏幕和三D打印。", "4K屏幕和3D打印。"),
    ])
    func converts(_ input: String, _ expected: String) {
        #expect(NumberRules.writingNumbersAsDigits(in: input) == expected)
    }

    @Test(arguments: [
        "Starbucks 三个人", "我们 team 三五天", "用Excel三五天", "做PPT三个小时", "跟 Amy 四处走走",
        "十二月很冷", "去年十月", "十点建议", "有十点建议", "三号", "零点五", "两G", "三点到五点", "五点前",
        "《一千零一夜》", "七七四十九天", "一", "幺", "万", "第二十一点",
    ])
    func keeps(_ input: String) {
        #expect(NumberRules.writingNumbersAsDigits(in: input) == input)
    }

    @Test func longTextIsConvertedInOnePass() {
        let sentence = "二零二六年十月十号下午三点半，我们在 Lexus RX 三五零 里聊了三百五十块和百分之五十。一心一意，七八个人。"
        let expected = "2026年10月10号下午3点半，我们在 Lexus RX 350 里聊了350块和50%。一心一意，七八个人。"
        let text = String(repeating: sentence, count: 500)
        let clock = ContinuousClock()
        var result = ""
        let elapsed = clock.measure {
            result = NumberRules.writingNumbersAsDigits(in: text)
        }
        #expect(result == String(repeating: expected, count: 500))
        #expect(elapsed < .seconds(5))
        // A run of numerals as long as the dictation is read once too.
        let digits = String(repeating: "三五", count: 10_000)
        #expect(NumberRules.writingNumbersAsDigits(in: digits) == String(repeating: "35", count: 10_000))
    }

    @Test func thePreferenceIsOnUntilTurnedOff() throws {
        let suite = "io.github.db-ol.OrraTests.numbers-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(NumberPreference.load(from: defaults))
        NumberPreference.save(false, to: defaults)
        #expect(!NumberPreference.load(from: defaults))
        NumberPreference.save(true, to: defaults)
        #expect(NumberPreference.load(from: defaults))
    }
}
