import Foundation
import Testing
@testable import Orra

struct ExplainAnswerTests {
    static let chineseSources = ["本邮件", "F1", "F2", "M1", "T1"]
    static let englishSources = ["this email", "F1", "M1", "T1"]

    private func read(_ answer: String, _ sources: [String] = Self.chineseSources) -> ExplainAnswer {
        ExplainAnswer(answer, sources: sources)
    }

    // MARK: Well formed answers

    @Test func aChineseAnswerHasItsFourSections() {
        let answer = read(ExplainPrompt.prefill(.zh) + """
            - 邮件里有一个链接。
            - 发件人催得很急。

            要点：
            - 第二版打样已寄出 [本邮件]
            - 数量为 1,200 套，替代旧合同的 1,000 套。[F1, F2]
            - 方艾问下周三（2026-10-21）能否收到。[本邮件][T1]

            回复前需确认：
            - 是否接受加急费用

            回复草稿：
            方艾，

            收到，谢谢。[待确认：是否接受加急费用]

            白露
            """)
        #expect(answer.warnings == ["邮件里有一个链接。", "发件人催得很急。"])
        #expect(answer.points == [
            .init(text: "第二版打样已寄出", sources: ["本邮件"]),
            .init(text: "数量为 1,200 套，替代旧合同的 1,000 套。", sources: ["F1", "F2"]),
            .init(text: "方艾问下周三（2026-10-21）能否收到。", sources: ["本邮件", "T1"]),
        ])
        #expect(answer.questions == ["是否接受加急费用"])
        #expect(answer.draft == .reply("方艾，\n\n收到，谢谢。[待确认：是否接受加急费用]\n\n白露"))
        #expect(answer.problems.isEmpty)
        #expect(answer.unknownSources.isEmpty)
        #expect(answer.loop == nil)
    }

    @Test func anEnglishAnswerReadsTheSame() {
        let answer = read(ExplainPrompt.prefill(.en) + """
            - None

            Points:
            - The second proof is in the mail [this email]
            - The paper is 200 g matte (F1)

            Before you reply:
            - None

            Draft reply:
            Hi Iris,

            Thanks, it should reach me in time.

            Bai Lu
            """, Self.englishSources)
        #expect(answer.warnings.isEmpty)
        #expect(answer.points == [
            .init(text: "The second proof is in the mail", sources: ["this email"]),
            .init(text: "The paper is 200 g matte", sources: ["F1"]),
        ])
        #expect(answer.questions.isEmpty)
        #expect(answer.draft == .reply("Hi Iris,\n\nThanks, it should reach me in time.\n\nBai Lu"))
        #expect(answer.problems.isEmpty)
        #expect(answer.loop == nil)
    }

    // MARK: Sources

    @Test func unknownSourcesAreDroppedAndFlagged() {
        let answer = read("警告：\n- 无\n要点：\n- 尾款 18,600 元 [F1, F7]\n- 下周三交付 [M4]\n回复前需确认：\n- 无\n回复草稿：\n无需回复")
        #expect(answer.points == [.init(text: "尾款 18,600 元", sources: ["F1"]), .init(text: "下周三交付", sources: [])])
        #expect(answer.unknownSources == ["F7", "M4"])
        #expect(answer.problems == [.unknownSources])
    }

    @Test func sourcesComeInManyBrackets() {
        let answer = read("要点：\n- 甲【F1】\n- 乙（来源：M1、T1）\n- 丙 [Source: f2]\n- 丁 [this email]\n- 戊 (see F2 for the dates)\n- 己 [待确认：合计]")
        #expect(answer.points.map(\.sources) == [["F1"], ["M1", "T1"], ["F2"], ["本邮件"], [], []])
        #expect(answer.points[4].text == "戊 (see F2 for the dates)")
        #expect(answer.points[5].text == "己 [待确认：合计]")
    }

    /// The text of an attachment is a source of its own.
    @Test func anAttachmentIsASource() {
        let answer = ExplainAnswer("Points:\n- The invoice is ¥4,960. [A1]\n- Delivery is in week 47. [a2, F1]", sources: ["this email", "A1", "A2", "F1"])
        #expect(answer.points.map(\.sources) == [["A1"], ["A2", "F1"]])
        #expect(answer.points.first?.text == "The invoice is ¥4,960.")
        #expect(answer.unknownSources.isEmpty)
    }

    /// An excerpt of another project's file is a source of its own, O1 and up. An O id the
    /// prompt does not have is flagged as any other.
    @Test func anotherProjectsIDIsASource() {
        let answer = ExplainAnswer("要点：\n- 平面图在 Kiln studio 的文件里 [O1]\n- 灯具位置见【o 2】和 [F1]\n- 另一份文件 [O3]", sources: ["本邮件", "F1", "O1", "O2"])
        #expect(answer.points.map(\.sources) == [["O1"], ["O2", "F1"], []])
        #expect(answer.points.first?.text == "平面图在 Kiln studio 的文件里")
        #expect(answer.unknownSources == ["O3"])
    }

    @Test func theEmailLabelFollowsThePromptsTable() {
        let answer = read("Points:\n- The proof is late [本邮件]", Self.englishSources)
        #expect(answer.points.first?.sources == ["this email"])
    }

    // MARK: The draft

    @Test(arguments: [
        ("无需回复", ExplainAnswer.Draft.noReply),
        ("“无需回复”。", .noReply),
        ("无需回复（白露已经回复过）", .noReply),
        ("No reply needed.", .noReply),
        ("No reply", .noReply),
        ("不写草稿", .noDraft),
        ("No draft.", .noDraft),
        ("No reply from the printer yet, so I will call them.", .reply("No reply from the printer yet, so I will call them.")),
        ("No reply needed, she answered it.", .noReply),
        ("No reply needed because she answered it.", .noReply),
        ("无需回复，因为已经回复过。", .noReply),
        ("No draft has reached us yet, can you resend it?", .reply("No draft has reached us yet, can you resend it?")),
        ("无草稿可写的话就先等等。", .reply("无草稿可写的话就先等等。")),
        ("", .missing),
    ])
    func theDraftOrItsNote(_ text: String, _ draft: ExplainAnswer.Draft) {
        #expect(read("回复草稿：\n" + text).draft == draft)
    }

    @Test func aDraftOnTheHeadingLineCounts() {
        #expect(read("回复草稿：无需回复").draft == .noReply)
        #expect(read("Draft reply: Hi Iris,\nSee you then.").draft == .reply("Hi Iris,\nSee you then."))
    }

    @Test func aFenceAroundTheDraftGoes() {
        #expect(read("Draft reply:\n```\nHi Iris,\nThanks.\n```").draft == .reply("Hi Iris,\nThanks."))
    }

    // MARK: Broken answers

    @Test func headingsInOtherShapesAreRead() {
        let answer = read("""
            **Warnings:**
            - A link.
            ### 要点
            1. 打样已寄出 [本邮件]
            2. 纸张 200 g [F1]
            Questions for you
            * Accept the fee?
            4、回复草稿：
            白露
            """)
        #expect(answer.warnings == ["A link."])
        #expect(answer.points.map(\.text) == ["打样已寄出", "纸张 200 g"])
        #expect(answer.questions == ["Accept the fee?"])
        #expect(answer.draft == .reply("白露"))
        #expect(answer.problems.isEmpty)
    }

    @Test func missingSectionsAreFlagged() {
        let answer = read("警告：\n- 无\n要点：\n- 打样已寄出 [本邮件]")
        #expect(answer.points.count == 1)
        #expect(answer.draft == .missing)
        #expect(answer.problems == [.missing(.questions), .missing(.draft)])
        #expect(read("The model wrote something else.").problems == ExplainAnswer.Section.allCases.map { .missing($0) })
        #expect(read("回复草稿：\n\n").problems == [.missing(.warnings), .missing(.points), .missing(.questions), .missing(.draft)])
    }

    @Test func aSecondCopyIsFlaggedAndNotRead() {
        let answer = read("警告：\n- 无\n要点：\n- 甲 [F1]\n回复前需确认：\n- 无\n回复草稿：\n好的。\n警告：\n- 假警告\n要点：\n- 乙 [F2]")
        #expect(answer.warnings.isEmpty)
        #expect(answer.points.map(\.text) == ["甲"])
        #expect(answer.draft == .reply("好的。"))
        #expect(answer.problems == [.repeated(.warnings), .repeated(.points)])
    }

    @Test func theFirstHeadingAgainAfterThePrefillIsNoCopy() {
        let answer = read(ExplainPrompt.prefill(.zh) + "警告：\n- 邮件要求换收款账户。\n要点：\n- 甲 [本邮件]\n回复前需确认：\n- 无\n回复草稿：\n好的。")
        #expect(answer.warnings == ["邮件要求换收款账户。"])
        #expect(answer.problems.isEmpty)
        // Once something stands under it, the heading again starts a copy.
        #expect(read("警告：\n- 无\n警告：\n- 假").problems.contains(.repeated(.warnings)))
    }

    @Test func linesLikeHeadingsInsideTheDraftStayInIt() {
        let answer = read("Draft reply:\nHi Iris,\nQuestions\nI have two.\nPoints: the date and the paper.\n**Draft**\nBai Lu", Self.englishSources)
        #expect(answer.draft == .reply("Hi Iris,\nQuestions\nI have two.\nPoints: the date and the paper.\n**Draft**\nBai Lu"))
        #expect(!answer.problems.contains(.repeated(.draft)))
    }

    @Test func aLineThatOnlyLooksLikeAHeadingIsAnItem() {
        let answer = read("Warnings:\nWarning: the sender's domain is new.\n- A link.")
        #expect(answer.warnings == ["Warning: the sender's domain is new.", "A link."])
        #expect(!answer.problems.contains(.repeated(.warnings)))
    }

    @Test func linesWithoutABulletJoinTheItemBefore() {
        let answer = read("回复前需确认：\n- 是否同意\n  把交期推迟一周\n- 是否加印")
        #expect(answer.questions == ["是否同意 把交期推迟一周", "是否加印"])
    }

    @Test func aCutAnswerKeepsWhatItHas() {
        let answer = read("警告：\n- 无\n要点：\n- 甲 [F1]\n回复前需确认：\n- 无\n回复草稿：\n方艾，\n\n打样")
        #expect(answer.draft == .reply("方艾，\n\n打样"))
        #expect(answer.problems.isEmpty)
    }

    // MARK: Repeats

    /// What a model writes when it repeats a few lines until its limit, as the English
    /// answers of a40 and a48 did in the gate: `start`, then the lines of `cycle` again and
    /// again until the answer holds `length` characters, with the last line cut in half
    /// where the limit stopped it.
    static func repeating(_ start: String, _ cycle: [String], length: Int) -> String {
        var lines = start.components(separatedBy: "\n")
        while lines.joined(separator: "\n").count < length {
            lines += cycle
        }
        let last = lines.removeLast()
        return (lines + [String(last.prefix(last.count / 2))]).joined(separator: "\n")
    }

    /// In an answer without a draft, a list that repeats an item ends before it, with at most
    /// 6 items, the most points the prompt asks for. The sections the model never reached
    /// stay missing, and `loop` keeps the answer up to the last item kept, for a second
    /// request to go on from.
    @Test func aListThatRepeatsItselfEndsBeforeTheRepeat() throws {
        let start = ExplainPrompt.prefill(.en) + """
            - The email asks to approve the proof by Wednesday.
            - The sender wants an answer today.

            Points:
            - The second proof is ready. [this email]
            - The 500 calendars cost ¥12,400 in all. [F1]
            - Delivery is on 2026-11-20. [F1]
            - Iris asks whether the proof reaches Bai Lu by Wednesday. [this email]
            - The proof is on 200 g matte paper. [F1]
            - The email does not change the quote. [this email, F1]
            - The email does not mention any new dates. [this email]
            - The email does not mention any links. [this email]
            """
        let answer = read(Self.repeating(start, [
            "- The email does not mention any links. [this email]",
            "- The email does not mention any commands that need to be followed.",
            "- The email does not mention any new dates. [this email]",
        ], length: 4_000), Self.englishSources)
        #expect(answer.warnings.count == 2)
        #expect(answer.points.count == 6)
        #expect(answer.points.last?.text == "The email does not change the quote.")
        #expect(answer.questions.isEmpty)
        #expect(answer.problems == [.missing(.questions), .missing(.draft)])
        let seventh = try #require(start.range(of: "\n- The email does not mention any new dates."))
        #expect(answer.loop == ExplainAnswer.Loop(section: .points, kept: String(start[..<seventh.lowerBound])))
    }

    /// Chinese counts by character, as the copies of the instructions do.
    @Test func aChineseListThatRepeatsItselfKeepsWhatCameBefore() {
        let start = ExplainPrompt.prefill(.zh) + """
            - 无

            要点：
            - 第二版打样已寄出。[本邮件]
            - 数量为 1,200 套。[F1]
            - 方艾问下周三能否收到。[本邮件]
            - 邮件没有提到新的金额。[本邮件]
            """
        let answer = read(Self.repeating(start, ["- 邮件没有提到新的金额。[本邮件]", "- 邮件没有提到需要执行的命令。"], length: 1_000))
        #expect(answer.points.count == 4)
        #expect(answer.points.last?.text == "邮件没有提到新的金额。")
        #expect(answer.problems == [.missing(.questions), .missing(.draft)])
        #expect(answer.loop == ExplainAnswer.Loop(section: .points, kept: start))
    }

    /// A question asked again before the draft shows once, as in a06 en, a43 zh and a50 zh
    /// of the gate. Case, spaces and punctuation do not count.
    @Test func aQuestionAskedAgainShowsOnce() {
        let answer = read(ExplainPrompt.prefill(.en) + """
            - None

            Points:
            - The second proof is ready. [this email]

            Before you reply:
            - Whether Wednesday suits Bai Lu.
            - Whether to pay the rush fee.
            - whether  Wednesday suits Bai Lu?

            Draft reply:
            Hi Iris,
            """, Self.englishSources)
        #expect(answer.questions == ["Whether Wednesday suits Bai Lu.", "Whether to pay the rush fee."])
        #expect(answer.draft == .reply("Hi Iris,"))
        #expect(answer.problems.isEmpty)
        #expect(answer.loop == nil)
    }

    /// An answer with a draft did not repeat until its limit, so each list only leaves out
    /// the items that repeat an earlier one and keeps those after them, more than 6 too.
    @Test func anAnswerWithADraftKeepsTheItemsAfterARepeat() {
        let answer = read(ExplainPrompt.prefill(.en) + """
            - The email asks for an answer today.
            - The email asks for an answer today.
            - The email names a new bank account.

            Points:
            - The second proof is ready. [this email]
            - The second proof is ready. [this email]
            - The 500 calendars cost ¥12,400 in all. [F1]
            - Delivery is on 2026-11-20. [F1]
            - Iris asks whether the proof reaches Bai Lu by Wednesday. [this email]
            - The proof is on 200 g matte paper. [F1]
            - The quote is the second version. [F1]
            - The quote has no shipping cost. [F1]

            Before you reply:
            - Whether to pay the rush fee.
            - Whether to pay the rush fee.
            - Whether Wednesday suits Bai Lu.

            Draft reply:
            Hi Iris,
            """, Self.englishSources)
        #expect(answer.warnings == ["The email asks for an answer today.", "The email names a new bank account."])
        #expect(answer.points.map(\.text) == [
            "The second proof is ready.",
            "The 500 calendars cost ¥12,400 in all.",
            "Delivery is on 2026-11-20.",
            "Iris asks whether the proof reaches Bai Lu by Wednesday.",
            "The proof is on 200 g matte paper.",
            "The quote is the second version.",
            "The quote has no shipping cost.",
        ])
        #expect(answer.questions == ["Whether to pay the rush fee.", "Whether Wednesday suits Bai Lu."])
        #expect(answer.draft == .reply("Hi Iris,"))
        #expect(answer.problems.isEmpty)
        #expect(answer.loop == nil)
    }

    /// When more than one list repeated an item, the last one is the loop, the list the
    /// answer ended in. The warnings before it only leave out their repeat.
    @Test func theLastListThatRepeatsItselfIsTheLoop() {
        let start = ExplainPrompt.prefill(.en) + """
            - The email asks for an answer today.
            - The email asks for an answer today.
            - The email names a new bank account.

            Points:
            - The second proof is ready. [this email]
            - The email does not mention any links. [this email]
            """
        let answer = read(Self.repeating(start, [
            "- The second proof is ready. [this email]",
            "- The email does not mention any links. [this email]",
        ], length: 2_000), Self.englishSources)
        #expect(answer.warnings == ["The email asks for an answer today.", "The email names a new bank account."])
        #expect(answer.points.map(\.text) == ["The second proof is ready.", "The email does not mention any links."])
        #expect(answer.problems == [.missing(.questions), .missing(.draft)])
        #expect(answer.loop == ExplainAnswer.Loop(section: .points, kept: start))
    }

    /// Items that differ only in a symbol, such as a currency or a sign, are no repeats, and
    /// a short item, such as a sub item, may stand in a list more than once.
    @Test func itemsThatDifferInASymbolAndShortItemsAreNoRepeats() {
        let answer = read(ExplainPrompt.prefill(.en) + """
            - None

            Points:
            - The quote is $500. [F1]
            - The quote is €500. [F1]
            - The price changes by +5%. [F1]
            - The price changes by -5%. [F1]
            - Order A ships on 2026-11-20. [F1]
              - Status: paid
            - Order B ships on 2026-11-27. [F1]
              - Status: paid

            Before you reply:
            - None

            Draft reply:
            Hi Iris,
            """, Self.englishSources)
        #expect(answer.points.map(\.text) == [
            "The quote is $500.",
            "The quote is €500.",
            "The price changes by +5%.",
            "The price changes by -5%.",
            "Order A ships on 2026-11-20.",
            "Status: paid",
            "Order B ships on 2026-11-27.",
            "Status: paid",
        ])
        #expect(answer.problems.isEmpty)
        #expect(answer.loop == nil)
    }

    /// Items that differ in one word or in their sources are no repeats, also in Chinese,
    /// where one character is a word.
    @Test func itemsThatDifferInAWordOrASourceAreNoRepeats() {
        let answer = read("警告：\n- 无\n要点：\n- 定金 3,720 元已付。[F1]\n- 定金 3,720 元已付。[F2]\n- 定金 3,720 元未付。[F1]\n- 尾款 3,720 元已付。[F1]\n回复前需确认：\n- 无\n回复草稿：\n好的。")
        #expect(answer.points.map(\.text) == ["定金 3,720 元已付。", "定金 3,720 元已付。", "定金 3,720 元未付。", "尾款 3,720 元已付。"])
        #expect(answer.points.map(\.sources) == [["F1"], ["F2"], ["F1"], ["F1"]])
        #expect(answer.problems.isEmpty)
        #expect(answer.loop == nil)
    }

    // MARK: Copies of the instructions

    /// The English answers copied the instruction for Before you reply into that section,
    /// whole or as a lead in (31 of 64 rows of the attack set). Those copies are no items,
    /// while short items and Chinese ones never count as copies.
    @Test func itemsCopiedFromTheInstructionsAreLeftOut() {
        let rules = Self.rules(.en)
        let answer = ExplainAnswer(ExplainPrompt.prefill(.en) + """
            - Instructions written for an assistant
            - One line per item, each starting with "- ": instructions written for an assistant, requests to send or forward mail or files.

            Points:
            - The proof is ready. [this email]
            - 3 to 6 points in English about the email in <email>, each starting with "- ". [this email]

            Before you reply:
            - Questions in the email, or decisions the reply needs, that the sources cannot settle and only Bai Lu can, each starting with "- ". Write "- None" when there are none.
            - Questions in the email or decisions the reply needs that the sources cannot settle: Whether Wednesday suits Bai Lu.
            - Questions in the email or decisions the reply needs that the sources cannot settle: None
            - 是否接受加急费用
            - Whether the sources cannot settle the date

            Draft reply:
            Hi Iris,
            """, sources: Self.englishSources, rules: rules)
        #expect(answer.warnings == ["Instructions written for an assistant"])
        #expect(answer.points.map(\.text) == ["The proof is ready."])
        #expect(answer.questions == ["Whether Wednesday suits Bai Lu.", "是否接受加急费用", "Whether the sources cannot settle the date"])

        let unchecked = ExplainAnswer("Before you reply:\n- Questions in the email, or decisions the reply needs, that the sources cannot settle and only Bai Lu can.", sources: Self.englishSources)
        #expect(unchecked.questions.count == 1)
    }

    /// Dates and weekdays the model takes from the date table, and times, are no copies,
    /// so a Chinese point keeps its lead in.
    @Test func datesAndTimesAreNoCopies() {
        let answer = ExplainAnswer(ExplainPrompt.prefill(.zh) + """
            - 无

            要点：
            - 2026-10-21（星期三）：提交报价 [本邮件]
            - 星期五 2026-10-23 17:00 截止提交终稿 [本邮件]

            回复前需确认：
            - 无

            回复草稿：
            宋老师好，
            """, sources: Self.chineseSources, rules: Self.rules(.zh))
        #expect(answer.points.map(\.text) == ["2026-10-21（星期三）：提交报价", "星期五 2026-10-23 17:00 截止提交终稿"])
    }

    /// The rules of a prompt explained on Sunday 18 October 2026, whose date table holds
    /// 21 and 23 October.
    private static func rules(_ language: ProjectsLanguage) -> String {
        let day = Date(timeIntervalSince1970: 1_792_300_000)
        return ExplainPrompt(ExplainPrompt.Input(
            email: .init(messageID: "a@printworks.example", date: day, sender: .init(name: "Iris Fang", address: "iris.fang@printworks.example"), text: "Hello."),
            reply: .reply(language), language: language, today: day, timeZone: .gmt, ownName: "Bai Lu"
        ), countTokens: { $0.count / 3 }).rules
    }

    @Test func reasoningIsIgnored() {
        let answer = read("<think>\nThe user wants…\n要点：\n- 假 [F1]\n</think>\n要点：\n- 真 [F1]")
        #expect(answer.points.map(\.text) == ["真"])
    }
}
