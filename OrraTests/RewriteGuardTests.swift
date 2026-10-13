import Foundation
import Testing
@testable import Orra

struct RewriteGuardTests {
    private struct Case: Decodable {
        let source: String
        let output: String
        let ok: Bool
        let reason: String
    }

    private static let cases: [Case] = RewriteGuardCases.jsonl
        .split(separator: "\n")
        .map { try! JSONDecoder().decode(Case.self, from: Data($0.utf8)) }

    /// The Swift port gives every measured output the verdict and the reason guards.py gave.
    @Test func everyMeasuredOutputGetsThePythonVerdict() {
        #expect(Self.cases.count == 448)
        #expect(Self.cases.filter { !$0.ok }.count == 43)
        for item in Self.cases {
            let failure = RewriteGuard.check(source: item.source, output: item.output)
            #expect((failure == nil) == item.ok, "\(item.source) -> \(item.output)")
            #expect((failure?.description ?? "") == item.reason, "\(item.source) -> \(item.output)")
        }
    }

    @Test func aFaithfulCleanupPasses() {
        #expect(RewriteGuard.check(source: "呃，我们下周一，哦不是，下周二开会。", output: "我们下周二开会。") == nil)
        #expect(RewriteGuard.check(source: "Um, can you send me the file? I mean the PDF.", output: "Can you send me the PDF?") == nil)
    }

    @Test func anAnswerIsHeldBack() {
        #expect(RewriteGuard.check(source: "给我讲个笑话吧。", output: "好的，有一天小明去上学，老师问他为什么迟到。") == .assistantOpener("好的"))
        #expect(RewriteGuard.check(source: "What's the capital of France?", output: "Paris.")?.description == "much shorter than source (2 vs 8)")
        #expect(RewriteGuard.check(source: "你是谁？", output: "我是一个人工智能语言模型。")?.logName == "assistant phrase")
        #expect(RewriteGuard.check(source: "列一下三个要点。", output: "- 第一\n- 第二") == .addedMarkup)
    }

    @Test func anOpenerTheSpeakerSaidIsKept() {
        #expect(RewriteGuard.check(source: "Sure, I can do that tomorrow.", output: "Sure, I can do that tomorrow.") == nil)
        // A hesitation sound can come out as Okay.
        #expect(RewriteGuard.check(source: "嗯 okay let's go", output: "Okay let's go") == nil)
    }

    @Test func numbersMayGoButNeverCome() {
        #expect(RewriteGuard.check(source: "两点，哦不对，3点开会", output: "3点开会") == nil)
        #expect(RewriteGuard.check(source: "电话是1381234567", output: "电话是13812345678") == .newNumber(["13812345678"]))
        // A thousands separator joins a number and full width digits count as digits.
        #expect(RewriteGuard.check(source: "一共１,５００元", output: "一共1500元") == nil)
    }

    @Test func lengthIsBounded() {
        #expect(RewriteGuard.check(source: "我们明天开会", output: "我们明天下午三点在会议室开会讨论")?.description == "longer than source (16 vs 6)")
        #expect(RewriteGuard.check(source: "这个方案我觉得还可以再改改然后发给大家看看", output: "这个")?.description == "much shorter than source (2 vs 21)")
    }

    @Test func anEmptyOutputPassesOnlyForFillerAlone() {
        #expect(RewriteGuard.check(source: "嗯嗯", output: "") == nil)
        #expect(RewriteGuard.check(source: "我们明天开会", output: " ") == .empty)
    }

    @Test func theLogNameHoldsNoText() {
        let failure = RewriteGuard.Failure.newNumber(["13812345678"])
        #expect(failure.description == "new number 13812345678")
        #expect(failure.logName == "new number")
    }

    @Test func unitsCountHanWordsAndDistinctNumbers() {
        #expect(RewriteGuard.units("我们 meet at 3 and 3") == 2 + 1.6 * 3 + 1)
        #expect(RewriteGuard.numbers("7:30 and 1,234 and ７") == ["7": 2, "30": 1, "1234": 1])
    }
}
