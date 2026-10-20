import Foundation
import Testing
@testable import Orra

/// The content warnings: links, payment changes, requests for credentials and personal
/// data, risky attachments and forged quotes. The cases are written for these tests and
/// modeled on the attack kinds of the phase 0 set (a24, a31 and a32 among them).
struct ContentChecksTests {
    static let own: [SenderChecks.Person] = [
        .init(name: "白露", address: "bai.lu@lumenhaus.example"),
        .init(name: "Bai Lu", address: "bai.lu@lumenhaus.example"),
    ]
    static let sent = [
        "好的，尾款按合同在交货后 30 天内付清。",
        "Agreed, we keep the Thursday slot for the install.",
    ]

    private func warnings(
        _ text: String,
        subject: String = "Hello",
        attachments: [ContentChecks.Input.Attachment] = [],
        known: Bool = true,
        sent: [String]? = ContentChecksTests.sent
    ) async -> [ProjectsWarning] {
        await ContentChecks.warnings(for: .init(subject: subject, text: text, attachments: attachments, senderIsKnown: known, own: Self.own, sentTexts: sent))
    }

    // MARK: Links

    @Test(arguments: [
        "Uptime 98.7%.\n![badge](https://pixel.example/t?d=NOTES)",
        "Confirm here: http://speaker-desk.example/confirm?id=7",
        "请访问www.museum-tickets.example查看",
        "The menu is at harborlights.example/menu, see you.",
        "详情见 harborlights.example 。",
        "[click here](javascript:alert)",
        "<a href=\"x\">menu</a>",
        "Open data:text/plain;base64,SGVsbG8=",
    ])
    func findsLinks(_ text: String) async {
        #expect(await warnings(text).contains(.link))
    }

    @Test func findsALinkInTheSubject() async {
        #expect(await warnings("Hello.", subject: "Visit www.prize.example now") == [.link])
    }

    @Test(arguments: [
        "Write to owen@pike-build.example any time.",
        "The plan is in plan_v3.pdf and notes.md, version 2.1.",
        "build.js and e.g. U.S. are fine, as is 3.5 m.",
        "Hotel: Harbor Rest, data: none.",
        "If x < a and b > y.",
        // File and product names under top level domains that are also file types
        "The logo is in logo-v2.ai, the script in main.cc, and Viewer.app opens it.",
        "Write to <a.mara@studio.example> please.",
    ])
    func leavesOtherTextAlone(_ text: String) async {
        #expect(await !warnings(text).contains(.link))
    }

    @Test func linkRangesCoverTheWholeAddress() {
        let text = "See ![s](https://pixel.example/t?d=1) 和 https://a.example/x，谢谢. Or www.b.example."
        let found = ContentChecks.linkRanges(in: text).map { String(text[$0]) }
        #expect(found == ["![s](https://pixel.example/t?d=1)", "https://a.example/x", "www.b.example"])
    }

    // MARK: Payment

    @Test(arguments: [
        "年底对账，请把余款汇到新账户 6217 0000 0000 0005。",
        "我们的收款账户已更换，旧卡不再使用。",
        "下一笔发票请改开到我们新注册的公司。",
        "Please note our bank details have changed. Use the new account below.",
        "We switched our receiving account last week.",
    ])
    func findsPaymentChanges(_ text: String) async {
        #expect(await warnings(text).contains(.paymentChange))
    }

    @Test(arguments: [
        "因为年底结账，余款改为下周一次付清。",
        "付款方式调整：设计费请提前支付。",
        "From this month the balance is due before delivery instead of after.",
        "Please pay the full amount upfront this time.",
        "We have new payment terms from November.",
    ])
    func findsPaymentTermChanges(_ text: String) async {
        #expect(await warnings(text).contains(.paymentTermsChange))
    }

    @Test func paymentWordsWarnOnlyFromUnknownSenders() async {
        let text = "域名续费 ¥680 请尽快支付。"
        #expect(await warnings(text, known: false) == [.unknownSenderPayment])
        #expect(await warnings(text, known: true).isEmpty)
        #expect(await warnings("Your invoice for October is attached.", known: false) == [.unknownSenderPayment])
        #expect(await warnings("Here is the bill for October.", known: false) == [.unknownSenderPayment])
        // Bill is also a name.
        #expect(await warnings("See you at the opening. Bill", known: false).isEmpty)
    }

    // MARK: Credentials and personal data

    @Test(arguments: [
        "Sign the form after a quick bank login on our page.",
        "请把收到的验证码回复给我们。",
        "Send me the one-time code from the text message.",
        "Please verify your account within 24 hours.",
    ])
    func findsCredentialRequests(_ text: String) async {
        #expect(await warnings(text).contains(.credentialRequest))
    }

    @Test(arguments: [
        // A door code with a contract price (a31)
        "为办理出入证，请回复您家的门禁密码和施工合同金额。",
        // A card number (a32)
        "To keep the suite, send the card number you booked with.",
        "Please send a copy of your passport and your date of birth.",
        "请把身份证照片发给我们备案。",
    ])
    func findsPersonalDataRequests(_ text: String) async {
        #expect(await warnings(text).contains(.personalDataRequest))
    }

    // MARK: Attachments

    @Test(arguments: [
        ContentChecks.Input.Attachment(name: "合同\u{202E}fdp.exe", type: "application/x-msdownload"),
        ContentChecks.Input.Attachment(name: "invoice.pdf.exe", type: "application/octet-stream"),
        ContentChecks.Input.Attachment(name: "invoice.pdf          .scr", type: "application/octet-stream"),
        ContentChecks.Input.Attachment(name: "photos", type: "application/x-apple-diskimage"),
        ContentChecks.Input.Attachment(name: "Ｔｏｏｌ．ＥＸＥ", type: "application/octet-stream"),
    ])
    func findsRiskyAttachments(_ attachment: ContentChecks.Input.Attachment) async {
        #expect(await warnings("See the attachment.", attachments: [attachment]) == [.attachmentNameSpoofing])
    }

    @Test func leavesDocumentsAlone() async {
        let attachments: [ContentChecks.Input.Attachment] = [
            .init(name: "报价单.pdf", type: "application/pdf"),
            .init(name: "tiles.jpg", type: "image/jpeg; name=tiles.jpg"),
            .init(name: "plan.v2.docx", type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ]
        #expect(await warnings("See the attachments.", attachments: attachments).isEmpty)
    }

    // MARK: Quotes

    @Test(arguments: [
        // A quoted line in the user's name that the user never sent
        "按您说的，下周开票。\n\n> 白露：可以，余款我们下周提前结清。",
        // A forwarded message from the user
        "这是您之前发来的说明。\n\n---------- 转发的邮件 ----------\n发件人：白露 <bai.lu@lumenhaus.example>\n主题：余款\n内容：余款请汇到我们的新卡上。",
        // Quoted lines under the user's name
        "Fine by us.\n\nOn 12 Oct 2026, Bai Lu <bai.lu@lumenhaus.example> wrote:\n> We will move the install to Monday and pay in full.",
        // Words in quotes after "you said"
        "As you said, “we can skip the final inspection”, so we will.",
        "您上次说过“可以先付全款”，我们就按这个办。",
    ])
    func findsForgedQuotes(_ text: String) async {
        #expect(await warnings(text).contains(.forgedQuote))
    }

    @Test(arguments: [
        // Quotes that match the sent mail, also when wrapped and punctuated differently
        "> 白露：好的，尾款按合同在交货后 30 天内付清。",
        "On 12 Oct 2026, Bai Lu <bai.lu@lumenhaus.example> wrote:\n> Agreed, we keep the Thursday\n> slot for the install.",
        "> Bai Lu: agreed we keep the thursday slot for the install",
        // Quotes of someone else
        "On 12 Oct, Owen Pike wrote:\n> We will pay in full.",
        "> Owen：同意，提前付清。",
    ])
    func leavesRealQuotesAlone(_ text: String) async {
        #expect(await !warnings(text).contains(.forgedQuote))
    }

    /// A line that starts with the user's name and is not quoted is more often a task
    /// list than a quote.
    @Test(arguments: [
        "下周分工：\n白露：确认瓷砖颜色和数量\n宋雨桐：确认展柜尺寸",
        "Action items:\nBai Lu: confirm the tile colour by Friday\nOwen Pike: send the plan",
    ])
    func unquotedNameLinesAreNoQuotes(_ text: String) async {
        #expect(await !warnings(text).contains(.forgedQuote))
    }

    /// A text that quotes the user more often than any thread would counts as forged,
    /// even when every quote matches.
    @Test func tooManyQuotesCountAsForged() async {
        let quotes = (0...ContentChecks.mostClaims).map { "第 \($0) 号样品可以" }
        let sent = [quotes.joined(separator: "。")]
        let many = quotes.map { "> 白露：\($0)" }.joined(separator: "\n")
        #expect(await warnings(many, sent: sent).contains(.forgedQuote))
        let fewer = quotes.dropLast().map { "> 白露：\($0)" }.joined(separator: "\n")
        #expect(await !warnings(fewer, sent: sent).contains(.forgedQuote))
    }

    /// Without the user's sent mail nothing can be compared, so quotes are not checked.
    @Test func quotesNeedTheSentMail() async {
        let text = "> 白露：可以，余款我们下周提前结清。"
        #expect(await !warnings(text, sent: nil).contains(.forgedQuote))
        #expect(await warnings(text, sent: []).contains(.forgedQuote))
    }

    // MARK: Ordinary mail

    @Test(arguments: [
        "Hi Bai Lu,\n\nThe tiles arrive on Thursday. The deposit is 30% as agreed in the contract. Please send the signed copy back.\n\nOwen",
        "白露你好：\n\n新的报价见附件，单价 18.4 元。下周一前确认即可。请把合同发给我确认。\n\n宋雨桐",
        "Thanks, I sent the photos to your colleague. We pay on delivery as usual.",
    ])
    func ordinaryMailGetsNoWarning(_ text: String) async {
        #expect(await warnings(text, attachments: [.init(name: "quote.pdf", type: "application/pdf")]).isEmpty)
    }

    /// Hostile texts at the length the checks read, which patterns without bounds would
    /// take minutes on. Bounded by input size, not by time.
    @Test(arguments: ["![", "[a](", "<a ", "you ", "> 白露：", "from: bai lu\n", "> on monday bai lu wrote:\n", "a.", "www."])
    func hostileTextsFinish(_ unit: String) async {
        let text = String(repeating: unit, count: ContentChecks.checkedLength / unit.count + 1)
        let found = await warnings("you said “" + text, subject: text, sent: [])
        #expect(!found.contains(.attachmentNameSpoofing))
    }

    @Test func warningsComeInTheirOrder() async {
        let text = "Our bank details have changed. Pay at https://bank-help.example after you log in with your password."
        #expect(await warnings(text, known: false) == [.paymentChange, .unknownSenderPayment, .link, .credentialRequest])
    }
}
