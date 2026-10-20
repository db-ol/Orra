import Foundation
import Testing
@testable import Orra

struct QuotedHistoryTests {
    @Test func quotedLinesAndTheirAttributionGo() {
        let split = QuotedHistory(splitting: """
            Friday works for me.

            On 12 Oct 2026, at 09:30, Mei Tan <mei.tan@orchard.example> wrote:

            > Can we meet on Friday?
            > Mei
            """)
        #expect(split.ownText == "Friday works for me.")
        #expect(split.quotedText == "On 12 Oct 2026, at 09:30, Mei Tan <mei.tan@orchard.example> wrote:\n> Can we meet on Friday?\n> Mei")
        #expect(split.signature == "")
    }

    @Test func anInterleavedReplyKeepsEveryOwnLine() {
        let split = QuotedHistory(splitting: """
            On Mon, Oct 12, 2026 at 9:30 AM Mei Tan <mei.tan@orchard.example> wrote:
            > How many copies?
            120 copies.
            > And the paper?
              > Same as last time?
            The matte one.
            """)
        #expect(split.ownText == "120 copies.\nThe matte one.")
    }

    @Test(arguments: [
        "在 2026年10月12日 09:30，苏晴 <su.qing@print.example> 写道：",
        "苏晴 <su.qing@print.example> 于2026年10月12日周一 09:30写道：",
        "2026-10-12 09:30 GMT+08:00 苏晴 <su.qing@print.example>写道:",
    ])
    func chineseAttributions(_ attribution: String) {
        let split = QuotedHistory(splitting: "收到，谢谢。\n\n\(attribution)\n> 样书已经装箱。")
        #expect(split.ownText == "收到，谢谢。")
        #expect(split.quotedText == "\(attribution)\n> 样书已经装箱。")
    }

    @Test func anAttributionWrappedOntoTwoLines() {
        let english = QuotedHistory(splitting: "Sounds good.\n\nOn Mon, Oct 12, 2026 at 9:30 AM Mei Tan <\nmei.tan@orchard.example> wrote:\n\n> Draft attached.")
        #expect(english.ownText == "Sounds good.")
        let chinese = QuotedHistory(splitting: "好的。\n\n苏晴 <su.qing@print.example>\n于2026年10月12日周一 09:30写道：\n> 样书已经装箱。")
        #expect(chinese.ownText == "好的。")
    }

    @Test func aLineAboveAnAttributionStaysOwnText() {
        let split = QuotedHistory(splitting: "收到。\n于2026年10月12日 09:30写道：\n> 样书已经装箱。")
        #expect(split.ownText == "收到。")
        let english = QuotedHistory(splitting: "On Friday we print.\nOn Monday, Mei wrote:\n> Proofs?")
        #expect(english.ownText == "On Friday we print.")
    }

    @Test func anAttributionWithoutQuoteMarksTakesTheRest() {
        let split = QuotedHistory(splitting: "Thanks.\n\nOn Monday, Mei Tan wrote:\n\nCan we meet on Friday?\nMei")
        #expect(split.ownText == "Thanks.")
        #expect(split.quotedText == "On Monday, Mei Tan wrote:\n\nCan we meet on Friday?\nMei")
    }

    @Test(arguments: [
        "-----原始邮件-----",
        "------------------ 原始邮件 ------------------",
        "------------------\u{A0}原始邮件\u{A0}------------------",
        "-----Original Message-----",
        "----- original message -----",
        "-----邮件原件-----",
        "---- 回复的原邮件 ----",
    ])
    func separatorsStartTheHistory(_ separator: String) {
        let split = QuotedHistory(splitting: "收到。\n\n\(separator)\n发件人: 苏晴\n内容")
        #expect(split.ownText == "收到。")
        #expect(split.quotedText.hasPrefix(separator.trimmingCharacters(in: .whitespaces)))
    }

    @Test func outlookHeaderBlocksStartTheHistory() {
        let english = QuotedHistory(splitting: """
            Approved, go ahead.

            ________________________________
            From: Mei Tan <mei.tan@orchard.example>
            Sent: Monday, October 12, 2026 9:30 AM
            To: Theo Lind <theo@studio.example>
            Subject: Proofs

            Please approve the proofs.
            """)
        #expect(english.ownText == "Approved, go ahead.")
        #expect(english.quotedText.hasPrefix("________________________________\nFrom: Mei Tan"))
        #expect(english.quotedText.hasSuffix("Please approve the proofs."))

        let chinese = QuotedHistory(splitting: "同意。\n\n发件人：苏晴 <su.qing@print.example>\n发送时间：2026年10月12日 9:30\n收件人：顾远\n主题：样书\n\n请确认。")
        #expect(chinese.ownText == "同意。")
        #expect(chinese.quotedText.hasSuffix("请确认。"))
    }

    @Test func aFromLineAloneIsOwnText() {
        let split = QuotedHistory(splitting: "From: the print shop, good news.\nThe paper arrived.")
        #expect(split.ownText == "From: the print shop, good news.\nThe paper arrived.")
    }

    @Test func forwardedMessagesKeepTheirText() {
        let gmail = QuotedHistory(splitting: """
            FYI, see below.

            ---------- Forwarded message ---------
            From: Mei Tan <mei.tan@orchard.example>
            Date: Mon, Oct 12, 2026 at 9:30 AM
            Subject: Proofs

            The proofs are ready.
            """)
        #expect(gmail.ownText.hasSuffix("The proofs are ready."))
        #expect(gmail.quotedText == "")

        let apple = QuotedHistory(splitting: "看下面。\n\nBegin forwarded message:\n\nFrom: Mei Tan <mei.tan@orchard.example>\nSubject: Proofs\nDate: 12 October 2026 at 09:30:00 GMT+8\n\nThe proofs are ready.")
        #expect(apple.ownText.hasSuffix("The proofs are ready."))
        let chinese = QuotedHistory(splitting: "转给你。\n\n---------- 转发的邮件 ----------\n发件人：苏晴\n日期：2026年10月12日\n\n样书已经装箱。")
        #expect(chinese.ownText.hasSuffix("样书已经装箱。"))
    }

    @Test func theSignatureAfterTheDashLine() {
        let split = QuotedHistory(splitting: "See you Friday.\n\n-- \nMei Tan\nOrchard Press\n\nOn Monday, Theo wrote:\n> Friday?")
        #expect(split.ownText == "See you Friday.")
        #expect(split.signature == "Mei Tan\nOrchard Press")
        #expect(split.quotedText == "On Monday, Theo wrote:\n> Friday?")
        let bare = QuotedHistory(splitting: "Text\n--\nMei")
        #expect(bare.ownText == "Text")
        #expect(bare.signature == "Mei")
    }

    @Test func aLongTailAfterDashesIsNoSignature() {
        let tail = (1...25).map { "Line \($0)" }.joined(separator: "\n")
        let split = QuotedHistory(splitting: "Text\n-- \n\(tail)")
        #expect(split.signature == "")
        #expect(split.ownText.hasSuffix("Line 25"))
    }

    @Test func blankLinesInTheOwnTextStay() {
        let text = "Hi" + String(repeating: "\n", count: 12) + "text far below"
        #expect(QuotedHistory(splitting: text).ownText == text)
    }

    @Test func lineBreaksOfEveryKind() {
        let split = QuotedHistory(splitting: "Own\r\n\r\nOn Monday, Mei wrote:\r\n> Quote\rOwn again")
        #expect(split.ownText == "Own\n\nOwn again")
        #expect(split.quotedText == "On Monday, Mei wrote:\n> Quote")
    }

    @Test func aWholeQuoteLeavesNoOwnText() {
        let split = QuotedHistory(splitting: "> only\n> quotes")
        #expect(split.ownText == "")
        #expect(split.quotedText == "> only\n> quotes")
    }

    @Test func longLinesAreNeverMarkers() {
        let long = "On " + String(repeating: "word ", count: 80) + "wrote:"
        #expect(QuotedHistory(splitting: "Own\n\(long)\nmore").ownText == "Own\n\(long)\nmore")
    }
}
