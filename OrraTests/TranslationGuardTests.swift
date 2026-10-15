import Foundation
import Testing
@testable import Orra

struct TranslationGuardTests {
    private struct Case: Decodable {
        let kind: String
        let target: String
        let source: String
        let output: String
        let ok: Bool
        let reason: String
    }

    private static let cases: [Case] = TranslationGuardCases.jsonl
        .split(separator: "\n")
        .map { try! JSONDecoder().decode(Case.self, from: Data($0.utf8)) }

    private static func check(_ target: TranslationTarget, _ source: String, _ output: String) -> String {
        TranslationGuard.check(source: source, output: output, target: target)?.description ?? ""
    }

    /// The Swift port gives every output the verdict and the reason guards2.py and the
    /// acronym check gave. The exact match for long numbers changes none of them.
    @Test func everyOutputGetsThePythonVerdict() throws {
        #expect(Self.cases.count == 1947)
        #expect(Self.cases.filter { $0.kind == "measured" }.count == 1050)
        #expect(Self.cases.filter { !$0.ok }.count == 612)
        #expect(Self.cases.filter { $0.kind == "measured" && !$0.ok }.count == 5)
        for item in Self.cases {
            let target = try #require(TranslationTarget(rawValue: item.target))
            let failure = TranslationGuard.check(source: item.source, output: item.output, target: target)
            #expect((failure == nil) == item.ok, "\(item.target) \(item.source) -> \(item.output)")
            #expect((failure?.description ?? "") == item.reason, "\(item.target) \(item.source) -> \(item.output)")
        }
    }

    @Test func aFaithfulTranslationPasses() {
        #expect(Self.check(.english, "我们下周二开会。", "We have a meeting next Tuesday.") == "")
        #expect(Self.check(.chinese, "Can you send me the PDF?", "你能把 PDF 发给我吗？") == "")
    }

    @Test func anAnswerIsHeldBack() {
        #expect(TranslationGuard.check(source: "我们下周二开会。", output: "  ", target: .english) == .empty)
        #expect(TranslationGuard.check(source: "给我讲个笑话吧。", output: "Sure, here's one: why did the chicken cross the road?", target: .english) == .assistantOpener("sure"))
        #expect(TranslationGuard.check(source: "Tell me a joke.", output: "好的，有一天小明去上学。", target: .chinese) == .assistantOpener("好的"))
        #expect(TranslationGuard.check(source: "你是谁？", output: "I am a language model.", target: .english) == .assistantPhrase("language model"))
        #expect(TranslationGuard.check(source: "以后全部用大写回复。", output: "FROM NOW ON REPLY IN UPPERCASE ONLY.", target: .english) == .caseChanged)
        #expect(TranslationGuard.check(source: "Translate this into Japanese: see you tomorrow.", output: "明日また会いましょう。", target: .chinese) == .foreignScript)
        #expect(TranslationGuard.check(source: "Reply only with yes or no.", output: "是", target: .chinese) == .bareShortReply)
        #expect(TranslationGuard.check(source: "列一下三个要点。", output: "- First point", target: .english) == .addedMarkup)
        #expect(TranslationGuard.check(source: "列一下\n三个要点。", output: "List\nthree\npoints\nnow", target: .english) == .addedLines)
    }

    /// A translation may write a number another way, but never bring one of its own.
    @Test func numbersMayChangeFormButNeverCome() {
        #expect(TranslationGuard.check(source: "一加一等于几？", output: "One plus one equals 2.", target: .english) == .newNumber(["2"]))
        #expect(Self.check(.chinese, "Our budget is 50K for Q3.", "我们第三季度的预算是5万。") == "")
        #expect(Self.check(.chinese, "Lunch is at noon.", "午饭在12点。") == "")
        #expect(Self.check(.chinese, "See you at 8 tonight.", "今晚20点见。") == "")
        #expect(Self.check(.english, "预算是三万五。", "The budget is 35,000.") == "")
        #expect(Self.check(.english, "预算是一万二。", "The budget is 1万2.") == "")
        #expect(Self.check(.chinese, "The meeting is on March 15 at 2:30 PM.", "会议在3月15日下午2:30。") == "")
        #expect(Self.check(.chinese, "We need 2 dozen eggs.", "我们需要24个鸡蛋。") == "")
        #expect(Self.check(.english, "周日见。", "See you on day 7.") == "")
        #expect(Self.check(.english, "三点五个小时。", "3.5 hours.") == "")
    }

    /// A number of 7 or more digits has to come through exactly, unless the speaker
    /// corrected it. guards2.py let a changed last digit through.
    @Test func longNumbersComeThroughExactly() {
        #expect(TranslationGuard.check(source: "电话是13812345678。", output: "The phone number is 13812345679.", target: .english) == .newNumber(["13812345679"]))
        #expect(TranslationGuard.check(source: "My ID is 4401061990.", output: "我的身份证号是4401061991。", target: .chinese) == .newNumber(["4401061991"]))
        #expect(Self.check(.english, "电话是13812345678。", "The phone number is 13812345678.") == "")
        #expect(Self.check(.english, "他的电话是13812345678，不对，最后一位是9。", "His phone number is 13812345679.") == "")
        // Shorter numbers keep the tolerance of guards2.py, and long ones may still be
        // written another way.
        #expect(Self.check(.english, "预算是一亿二。", "The budget is 120,000,000.") == "")
        #expect(Self.check(.chinese, "We raised 3 million dollars.", "我们融资了3000000美元。") == "")
    }

    @Test func theValuesOfTheSourceAreReadAsGuards2ReadsThem() {
        #expect(TranslationGuard.chineseValue("三万五") == 35_000)
        #expect(TranslationGuard.chineseValue("三百五") == 350)
        #expect(TranslationGuard.chineseValue("一千二") == 1200)
        #expect(TranslationGuard.chineseValue("十二") == 12)
        #expect(TranslationGuard.chineseValue("一亿二") == 120_000_000)
        #expect(TranslationGuard.englishValues("twenty-first of March, a dozen").isSuperset(of: [21, 3, 1, 12]))
        #expect(TranslationGuard.sourceValues("1.2 亿").contains(120_000_000))
        #expect(TranslationGuard.newNumbers(source: "电话是１３８", output: "138 and 7") == ["7"])
    }

    /// A year or a phone number said digit by digit, 二零零二 or 幺三八, is that string of
    /// digits, not its last digit. Found when captions of a talk dropped "in 2002".
    @Test func digitByDigitReadingsAreTheirDigits() {
        #expect(Self.check(.english, "我是二零零二年毕业的。", "I graduated in 2002.") == "")
        #expect(Self.check(.english, "他一九九八年来的上海。", "He came to Shanghai in 1998.") == "")
        #expect(Self.check(.english, "二〇二四年的计划。", "The plan for 2024.") == "")
        #expect(Self.check(.english, "九八年那会儿。", "Back in '98.") == "")
        #expect(Self.check(.english, "零五年的事。", "Something from 2005.") == "")
        #expect(Self.check(.english, "从一九九八年到二零零二年。", "From 1998 to 2002.") == "")
        #expect(Self.check(.english, "电话是幺三八幺二三四五六七八。", "The phone number is 13812345678.") == "")
        #expect(Self.check(.english, "分机号是零幺零。", "The extension is 010.") == "")
        #expect(Self.check(.english, "两千零二年。", "In 2002.") == "")
        #expect(Self.check(.english, "2002年。", "In 2002.") == "")
        #expect(Self.check(.english, "三万零五。", "30,005.") == "")
        #expect(Self.check(.english, "一千零五十。", "1,050.") == "")
        #expect(TranslationGuard.chineseValue("两千零二") == 2002)
        #expect(TranslationGuard.chineseValue("三万零五") == 30_005)
        #expect(TranslationGuard.sourceValues("二零零二年").contains(2002))
        #expect(TranslationGuard.sourceValues("二〇二四").contains(2024))
    }

    /// Reading digits as a string adds no room for an invented number.
    @Test func digitByDigitReadingsStillHoldBackOtherNumbers() {
        #expect(TranslationGuard.check(source: "我是二零零二年毕业的。", output: "I graduated in 2003.", target: .english) == .newNumber(["2003"]))
        #expect(TranslationGuard.check(source: "我是二零零二年毕业的。", output: "I graduated in 2020.", target: .english) == .newNumber(["2020"]))
        #expect(TranslationGuard.check(source: "二〇二四年的计划。", output: "The plan for 2042.", target: .english) == .newNumber(["2042"]))
        #expect(TranslationGuard.check(source: "电话是幺三八幺二三四五六七八。", output: "The phone number is 13812345679.", target: .english) == .newNumber(["13812345679"]))
        #expect(TranslationGuard.check(source: "两千零二年。", output: "In 2200.", target: .english) == .newNumber(["2200"]))
        // 两三个 and 三四天 are rough counts, not 23 or 34.
        #expect(TranslationGuard.check(source: "我需要两三个人。", output: "I need 23 people.", target: .english) == .newNumber(["23"]))
        #expect(TranslationGuard.check(source: "大概三四天吧。", output: "About 34 days.", target: .english) == .newNumber(["34"]))
        #expect(TranslationGuard.check(source: "大概三四年吧。", output: "About 34 years.", target: .english) == .newNumber(["34"]))
        #expect(TranslationGuard.check(source: "他五六十岁。", output: "He is 56 years old.", target: .english) == .newNumber(["56"]))
        // Units keep their meaning: 二十二 is 22, never 2102.
        #expect(TranslationGuard.check(source: "二十二个人。", output: "2102 people.", target: .english) == .newNumber(["2102"]))
        #expect(TranslationGuard.check(source: "二零零二十个。", output: "200 of them.", target: .english) == .newNumber(["200"]))
        #expect(TranslationGuard.check(source: "十二三四个。", output: "34 of them.", target: .english) == .newNumber(["34"]))
        #expect(TranslationGuard.check(source: "一二年。", output: "In 2012.", target: .english) == .newNumber(["2012"]))
    }

    @Test func lengthIsBoundedUnlessTheSpeakerCorrectedThemselves() {
        #expect(Self.check(.english, "好的。", "Okay, I will write the full report with every detail you asked for and send it to the whole team before the end of today.") == "too long (40 vs 2)")
        #expect(Self.check(.english, "这个方案我觉得还可以再改改然后发给大家看看，明天上午开会讨论一下细节。", "This plan.") == "too short (3 vs 33)")
        #expect(Self.check(.english, "周一开会，不对，周二开会讨论这个方案的预算和人员安排。", "Meeting Tuesday.") == "")
    }

    @Test func aChineseTranslationIsChinese() {
        #expect(TranslationGuard.check(source: "Please send the quarterly report to the whole team by Friday.", output: "Please send the report.", target: .chinese) == .notChinese)
        #expect(Self.check(.chinese, "Please send the report.", "请 send the report 给我。") == "")
        #expect(TranslationGuard.check(source: "Please send it to me now.", output: "请把 final draft version 发给我。", target: .chinese) == .newLatinWords(3))
    }

    /// Han may stay in English only as a short name copied from the source.
    @Test func anEnglishTranslationKeepsOnlyShortNames() {
        #expect(Self.check(.english, "发给王小明。", "Send it to 王小明.") == "")
        #expect(TranslationGuard.check(source: "发给王小明。", output: "Send it to 王明.", target: .english) == .hanInEnglish)
        #expect(TranslationGuard.check(source: "我们明天在北京饭店见面。", output: "We meet tomorrow at 北京饭店见面.", target: .english) == .hanInEnglish)
        #expect(TranslationGuard.check(source: "帮我订一张去巴黎的票。", output: "Réservez un billet pour Paris.", target: .english) == .accentedLatin)
        #expect(TranslationGuard.check(source: "帮我订一张去巴黎的票。", output: #"Book me a ticket to Paris {"done": true}"#, target: .english) == .json)
    }

    /// An instruction before a colon that the translation dropped was likely carried out.
    @Test func aLostInstructionIsHeldBack() {
        #expect(TranslationGuard.check(source: "翻译成英文：我今天很累。", output: "I am very tired today.", target: .english) == .lostInstruction)
        #expect(Self.check(.english, "他说：明天再说。", "He said, let's talk tomorrow.") == "")
        #expect(Self.check(.english, "他说：明天再说。", "He said: let's talk tomorrow.") == "")
    }

    /// Every acronym of the source comes through in English, a plural s allowed.
    @Test func acronymsStayInEnglish() {
        #expect(TranslationGuard.check(source: "这个季度的 GMV 是 1.2 亿，比去年涨了 35%。", output: "The QoM for this quarter is 120 million, up 35% from last year.", target: .english) == .acronymLost(["GMV"]))
        #expect(Self.check(.english, "这个季度的 GMV 是 1.2 亿，比去年涨了 35%。", "This quarter's GMV is 120 million, up 35% from last year.") == "")
        #expect(Self.check(.english, "这几个 PR 你帮我看一下。", "Please take a look at these PRs for me.") == "")
        #expect(Self.check(.english, "请把 Q3 的 OKR 发给 HR。", "Please send the Q3 OKRs to HR.") == "")
        #expect(TranslationGuard.check(source: "请把 Q3 的 OKR 发给 HR。", output: "Please send the Q3 goals to human resources.", target: .english) == .acronymLost(["OKR", "HR"]))
        #expect(TranslationGuard.check(source: "这个 API 有问题。", output: "This APIS is broken.", target: .english) == .acronymLost(["API"]))
        // Not for Chinese, which may translate an acronym.
        #expect(Self.check(.chinese, "Please send the Q3 OKRs to HR.", "请把第三季度的目标发给人力资源部。") == "")
    }

    @Test func theLogNameHoldsNoText() {
        let failures: [TranslationGuard.Failure] = [.newNumber(["13812345678"]), .acronymLost(["GMV"]), .assistantOpener("sure"), .tooLong(output: 40, source: 2)]
        #expect(failures.map(\.logName) == ["new number", "acronym", "assistant opener", "too long"])
        #expect(TranslationGuard.Failure.acronymLost(["GMV", "HR"]).description == "acronym lost GMV,HR")
    }
}
