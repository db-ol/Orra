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
        let split = QuotedHistory(splitting: "Thanks.\n\nOn 12 Oct 2026, Mei Tan wrote:\n\nCan we meet on Friday?\nMei")
        #expect(split.ownText == "Thanks.")
        #expect(split.quotedText == "On 12 Oct 2026, Mei Tan wrote:\n\nCan we meet on Friday?\nMei")
    }

    @Test(arguments: [
        "Hi Mei,\n\nOn Monday the printer wrote:\n\nThe ink is late, so we print on Friday.\nBest, Theo",
        "苏晴，\n\n供应商在邮件里写道：\n\n墨水晚到，周五开印。\n顾远",
    ])
    func aSentenceThatLooksLikeAnAttributionKeepsTheRest(_ text: String) {
        // Without a date or an address and without quoted lines, it is the email's own text.
        let split = QuotedHistory(splitting: text)
        #expect(split.ownText == text)
        #expect(split.quotedText == "")
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
        // Two dashes without the space only set text apart.
        let bare = QuotedHistory(splitting: "The list:\n--\nPay 2,000 by Friday\nShip on Monday")
        #expect(bare.ownText == "The list:\n--\nPay 2,000 by Friday\nShip on Monday")
        #expect(bare.signature == "")
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

    // MARK: Forwarded messages

    /// A forward as a mail program writes it, with the sender's note, the marker, the header
    /// block in the program's order and labels, and the forwarded text.
    struct Forwarded: CustomTestStringConvertible, Sendable {
        var client: String
        var text: String
        var subject = ""
        var sender: String
        var date: String
        var forwardedSubject = ""
        var to = ""

        var testDescription: String { client }
    }

    static let forwards: [Forwarded] = [
        Forwarded(
            client: "Gmail",
            text: "FYI, see below.\n\n---------- Forwarded message ---------\nFrom: Mei Tan <mei.tan@orchard.example>\nDate: Mon, Oct 12, 2026 at 9:30 AM\nSubject: Proofs\nTo: Theo Lind <theo@studio.example>\n\n\nThe proofs are ready.",
            sender: "Mei Tan <mei.tan@orchard.example>", date: "Mon, Oct 12, 2026 at 9:30 AM", forwardedSubject: "Proofs", to: "Theo Lind <theo@studio.example>"),
        Forwarded(
            client: "Gmail in Chinese",
            text: "FYI, see below.\n\n---------- 转发的邮件 ---------\n发件人： 苏晴 <su.qing@print.example>\n日期：2026年10月12日周一 上午9:30\n主题：样书\n收件人： <theo@studio.example>\n\nThe proofs are ready.",
            sender: "苏晴 <su.qing@print.example>", date: "2026年10月12日周一 上午9:30", forwardedSubject: "样书", to: "<theo@studio.example>"),
        Forwarded(
            client: "Gmail in traditional Chinese",
            text: "FYI, see below.\n\n---------- 已轉寄郵件 ----------\n寄件者：蘇晴 <su.qing@print.example>\nDate: 2026年10月12日 週一 上午9:30\nSubject: 樣書\n\nThe proofs are ready.",
            sender: "蘇晴 <su.qing@print.example>", date: "2026年10月12日 週一 上午9:30", forwardedSubject: "樣書"),
        Forwarded(
            client: "Apple Mail",
            text: "FYI, see below.\n\nBegin forwarded message:\n\nFrom: Mei Tan <mei.tan@orchard.example>\nSubject: Proofs\nDate: 12 October 2026 at 09:30:00 GMT+8\nTo: Theo Lind <theo@studio.example>\n\nThe proofs are ready.",
            sender: "Mei Tan <mei.tan@orchard.example>", date: "12 October 2026 at 09:30:00 GMT+8", forwardedSubject: "Proofs", to: "Theo Lind <theo@studio.example>"),
        Forwarded(
            client: "Apple Mail in Chinese",
            text: "FYI, see below.\n\n下面是被转发的邮件：\n\n发件人: 苏晴 <su.qing@print.example>\n主题: 样书\n日期: 2026年10月12日 GMT+8 09:30:00\n收件人: 顾远 <gu.yuan@studio.example>\n\nThe proofs are ready.",
            sender: "苏晴 <su.qing@print.example>", date: "2026年10月12日 GMT+8 09:30:00", forwardedSubject: "样书", to: "顾远 <gu.yuan@studio.example>"),
        Forwarded(
            client: "Thunderbird",
            text: "FYI, see below.\n\n-------- Forwarded Message --------\nSubject: \tProofs\nDate: \tMon, 12 Oct 2026 09:30:00 +0800\nFrom: \tMei Tan <mei.tan@orchard.example>\nTo: \tTheo Lind <theo@studio.example>\n\nThe proofs are ready.",
            sender: "Mei Tan <mei.tan@orchard.example>", date: "Mon, 12 Oct 2026 09:30:00 +0800", forwardedSubject: "Proofs", to: "Theo Lind <theo@studio.example>"),
        Forwarded(
            client: "Thunderbird in Chinese, and a header without a blank line after it",
            text: "FYI, see below.\n\n---------- 转发的消息 ----------\n发件人：方晓\n时间：2026-10-18 13:05\nThe proofs are ready.",
            sender: "方晓", date: "2026-10-18 13:05"),
        Forwarded(
            client: "Yahoo",
            text: "FYI, see below.\n\n----- Forwarded Message -----\nFrom: Mei Tan <mei.tan@orchard.example>\nTo: Theo Lind <theo@studio.example>\nSent: Monday, October 12, 2026, 09:30:00 AM GMT+8\nSubject: Proofs\n\nThe proofs are ready.",
            sender: "Mei Tan <mei.tan@orchard.example>", date: "Monday, October 12, 2026, 09:30:00 AM GMT+8", forwardedSubject: "Proofs", to: "Theo Lind <theo@studio.example>"),
        Forwarded(
            client: "NetEase 163 and 126",
            text: "FYI, see below.\n\n-------- 转发邮件信息 --------\n发件人：\"苏晴\" <su.qing@print.example>\n发送日期：2026-10-12 09:30:00\n收件人：\"顾远\" <gu.yuan@studio.example>\n主题：样书\n\nThe proofs are ready.",
            sender: "\"苏晴\" <su.qing@print.example>", date: "2026-10-12 09:30:00", forwardedSubject: "样书", to: "\"顾远\" <gu.yuan@studio.example>"),
        Forwarded(
            client: "Outlook",
            text: "FYI, see below.\n\n________________________________\nFrom: Mei Tan <mei.tan@orchard.example>\nSent: Monday, October 12, 2026 9:30 AM\nTo: Theo Lind <theo@studio.example>\nSubject: Proofs\n\nThe proofs are ready.",
            subject: "FW: Proofs",
            sender: "Mei Tan <mei.tan@orchard.example>", date: "Monday, October 12, 2026 9:30 AM", forwardedSubject: "Proofs", to: "Theo Lind <theo@studio.example>"),
        Forwarded(
            client: "Outlook in Chinese",
            text: "FYI, see below.\n\n-----原始邮件-----\n发件人: 苏晴 <su.qing@print.example>\n发送时间: 2026年10月12日 9:30\n收件人: 顾远 <gu.yuan@studio.example>\n主题: 样书\n\nThe proofs are ready.",
            subject: "转发: 样书",
            sender: "苏晴 <su.qing@print.example>", date: "2026年10月12日 9:30", forwardedSubject: "样书", to: "顾远 <gu.yuan@studio.example>"),
        Forwarded(
            client: "QQ Mail",
            text: "FYI, see below.\n\n\n------------------ 原始邮件 ------------------\n发件人: \"苏晴\"<su.qing@print.example>;\n发送时间: 2026年10月12日(星期一) 上午9:30\n收件人: \"顾远\"<gu.yuan@studio.example>;\n主题: 样书\n\nThe proofs are ready.",
            subject: "转发：样书",
            sender: "\"苏晴\"<su.qing@print.example>", date: "2026年10月12日(星期一) 上午9:30", forwardedSubject: "样书", to: "\"顾远\"<gu.yuan@studio.example>"),
        Forwarded(
            client: "Foxmail in English",
            text: "FYI, see below.\n\n------------------ Original ------------------\nFrom: \"Mei Tan\"<mei.tan@orchard.example>;\nDate: Mon, Oct 12, 2026 09:30 AM\nTo: \"Theo\"<theo@studio.example>;\nSubject: Proofs\n\nThe proofs are ready.",
            subject: "Fw: Proofs",
            sender: "\"Mei Tan\"<mei.tan@orchard.example>", date: "Mon, Oct 12, 2026 09:30 AM", forwardedSubject: "Proofs", to: "\"Theo\"<theo@studio.example>"),
        Forwarded(
            client: "Apple Mail in Japanese",
            text: "FYI, see below.\n\n転送されたメッセージ:\n\n差出人: Mei Tan <mei.tan@orchard.example>\n件名: Proofs\n日付: 2026年10月12日 9:30\n宛先: Theo Lind <theo@studio.example>\n\nThe proofs are ready.",
            sender: "Mei Tan <mei.tan@orchard.example>", date: "2026年10月12日 9:30", forwardedSubject: "Proofs", to: "Theo Lind <theo@studio.example>"),
        Forwarded(
            client: "Apple Mail in Spanish",
            text: "FYI, see below.\n\nInicio del mensaje reenviado:\n\nDe: Mei Tan <mei.tan@orchard.example>\nAsunto: Proofs\nFecha: 12 de octubre de 2026, 9:30\nPara: Theo Lind <theo@studio.example>\n\nThe proofs are ready.",
            sender: "Mei Tan <mei.tan@orchard.example>", date: "12 de octubre de 2026, 9:30", forwardedSubject: "Proofs", to: "Theo Lind <theo@studio.example>"),
    ]

    @Test(arguments: forwards)
    func eachMailProgramsForwardKeepsItsSenderDateAndText(_ forward: Forwarded) {
        let split = QuotedHistory(splitting: forward.text, subject: forward.subject)
        #expect(split.note == "FYI, see below.")
        #expect(split.forwards == [QuotedHistory.Forward(sender: forward.sender, date: forward.date, subject: forward.forwardedSubject, to: forward.to, text: "The proofs are ready.")])
        #expect(split.quotedText == "")
        #expect(split.ownText.hasPrefix("FYI, see below."))
        #expect(split.ownText.hasSuffix("The proofs are ready."))
        // The prompt splits the own text again and finds the same.
        let again = QuotedHistory(splitting: split.ownText, subject: forward.subject)
        #expect(again.note == split.note)
        #expect(again.forwards == split.forwards)
    }

    @Test func aReplyWithTheSameBlockIsHistory() {
        let outlook = "Approved.\n\n________________________________\nFrom: Mei Tan <mei.tan@orchard.example>\nSent: Monday, October 12, 2026 9:30 AM\nTo: Theo Lind <theo@studio.example>\nSubject: Proofs\n\nPlease approve the proofs."
        for subject in ["", "RE: Proofs", "Re: Fwd: Proofs", "回复：转发：样书", "Proofs: the second round"] {
            let split = QuotedHistory(splitting: outlook, subject: subject)
            #expect(split.ownText == "Approved.")
            #expect(split.forwards.isEmpty)
            #expect(split.quotedText.hasSuffix("Please approve the proofs."))
        }
        let qq = QuotedHistory(splitting: "好的。\n\n------------------ 原始邮件 ------------------\n发件人: \"苏晴\"<su.qing@print.example>;\n发送时间: 2026年10月12日(星期一) 上午9:30\n主题: 样书\n\n请确认。", subject: "回复：样书")
        #expect(qq.ownText == "好的。")
        #expect(qq.forwards.isEmpty)
    }

    @Test func theSubjectSaysForward() {
        for subject in ["FW: Proofs", "Fwd: Proofs", "fwd:Proofs", " Fw: Proofs", "转发：样书", "转发: 样书", "轉寄：樣書", "RV: Lámparas"] {
            #expect(QuotedHistory.isForward(subject: subject), "\(subject)")
        }
        for subject in ["Re: Fwd: Proofs", "Proofs", "Forward planning: Q4", "回复：转发：样书", "", "FWD"] {
            #expect(!QuotedHistory.isForward(subject: subject), "\(subject)")
        }
    }

    @Test func aForwardedMessagesOwnHistoryIsQuoted() {
        let split = QuotedHistory(splitting: """
            FYI

            ________________________________
            From: Mei Tan <mei.tan@orchard.example>
            Sent: Monday, October 12, 2026 9:30 AM
            To: Theo Lind <theo@studio.example>
            Subject: Proofs

            Please approve the proofs.

            ________________________________
            From: Theo Lind <theo@studio.example>
            Sent: Sunday, October 11, 2026 8:00 PM
            Subject: Proofs?

            Are they ready?
            """, subject: "FW: Proofs")
        #expect(split.note == "FYI")
        #expect(split.forwards.map(\.text) == ["Please approve the proofs."])
        #expect(split.quotedText.hasPrefix("________________________________\nFrom: Theo Lind"))
        #expect(split.quotedText.hasSuffix("Are they ready?"))

        let gmail = QuotedHistory(splitting: "See below.\n\n---------- Forwarded message ---------\nFrom: Mei Tan <mei.tan@orchard.example>\nDate: Mon, Oct 12, 2026\n\nYes, Friday.\n\nOn Sun, Oct 11, 2026 at 8:00 PM Theo Lind <theo@studio.example> wrote:\n> Friday?")
        #expect(gmail.forwards.map(\.text) == ["Yes, Friday."])
        #expect(gmail.quotedText == "On Sun, Oct 11, 2026 at 8:00 PM Theo Lind <theo@studio.example> wrote:\n> Friday?")
    }

    @Test func aForwardOfAForwardGivesBoth() {
        let split = QuotedHistory(splitting: """
            Look at this.

            ---------- Forwarded message ---------
            From: Kai Moss <kai@kiln.example>
            Date: Tue, Oct 13, 2026 at 8:00 AM
            Subject: Fwd: Lamps

            See Mei's note.

            ---------- Forwarded message ---------
            From: Mei Tan <mei.tan@orchard.example>
            Date: Mon, Oct 12, 2026 at 9:30 AM

            Twelve lamps, delivery in week 47.
            """)
        #expect(split.note == "Look at this.")
        #expect(split.forwards.map(\.sender) == ["Kai Moss <kai@kiln.example>", "Mei Tan <mei.tan@orchard.example>"])
        #expect(split.forwards.map(\.text) == ["See Mei's note.", "Twelve lamps, delivery in week 47."])
    }

    @Test func theSignatureIsTheSendersAndAForwardKeepsItsOwn() {
        let split = QuotedHistory(splitting: "FYI\n-- \nAmy Lu\nBridgeway\n\n---------- Forwarded message ---------\nFrom: Mei Tan <mei.tan@orchard.example>\nDate: Mon\n\nTwelve lamps.\n\n-- \nMei Tan\n")
        #expect(split.note == "FYI")
        #expect(split.signature == "Amy Lu\nBridgeway")
        #expect(split.forwards.map(\.text) == ["Twelve lamps.\n\n-- \nMei Tan"])
        #expect(!split.ownText.contains("Amy Lu"))
        #expect(split.ownText.hasSuffix("Mei Tan"))
    }

    @Test func aMarkerAloneStartsAForwardAndAMarkerInASentenceDoesNot() {
        let alone = QuotedHistory(splitting: "Begin forwarded message:\n\nThe lamps arrive on Friday.")
        #expect(alone.note == "")
        #expect(alone.forwards == [QuotedHistory.Forward(text: "The lamps arrive on Friday.")])

        for text in ["Please see the forwarded message below:\nIt is short.", "我把转发的邮件放在下面了：\n灯周五到。"] {
            let split = QuotedHistory(splitting: text)
            #expect(split.forwards.isEmpty)
            #expect(split.note == text)
        }
    }

    @Test func aForwardInsideQuotedHistoryIsNoForwardOfTheEmail() {
        let split = QuotedHistory(splitting: "Thanks!\n\nOn Mon, Oct 12, 2026 at 9:30 AM Mei Tan <mei.tan@orchard.example> wrote:\n> ---------- Forwarded message ---------\n> From: Kai Moss <kai@kiln.example>\n> Lamps.")
        #expect(split.ownText == "Thanks!")
        #expect(split.forwards.isEmpty)
        let separated = QuotedHistory(splitting: "Thanks!\n\n-----Original Message-----\nFrom: Mei Tan\nSent: Monday\n\n---------- Forwarded message ---------\nFrom: Kai Moss <kai@kiln.example>\n\nLamps.", subject: "RE: FW: Lamps")
        #expect(separated.ownText == "Thanks!")
        #expect(separated.forwards.isEmpty)
    }

    @Test func aHeaderLabelTwiceEndsTheHeader() {
        let split = QuotedHistory(splitting: "转给你。\n\n---------- 转发的邮件 ----------\n发件人：苏晴\n时间：2026-10-12 09:30\n时间：下周三下午开会\n请准时。")
        #expect(split.forwards == [QuotedHistory.Forward(sender: "苏晴", date: "2026-10-12 09:30", text: "时间：下周三下午开会\n请准时。")])
    }

    @Test func withoutAForwardTheNoteIsTheOwnText() {
        for text in ["See you Friday.\n\n-- \nMei Tan", "The list:\n-----\nPay 2,000 by Friday", "> only\n> quotes", "Thanks.\n\nOn 12 Oct 2026, Mei Tan wrote:\n\nCan we meet?"] {
            let split = QuotedHistory(splitting: text)
            #expect(split.forwards.isEmpty)
            #expect(split.note == split.ownText)
        }
    }
}
