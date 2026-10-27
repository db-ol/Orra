import Foundation
import Testing
@testable import Orra

/// The draft check, one case per rule. The cases are written for these tests and modeled
/// on the phase 0 attack items a05, a07, a08, a22, a23, a24, a26, a31, a32, a43, a46,
/// a51, a55, a62 and a63. Today is
/// pinned to Sunday 18 October 2026.
struct DraftCheckTests {
    typealias Person = DraftCheckInput.Person

    static let today = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12))!
    static let own = [Person(name: "白露", address: "bai.lu@lumenhaus.example"), Person(name: "Bai Lu", address: "bai.lu@lumenhaus.example")]
    static let owen = Person(name: "Owen Pike", address: "owen@pike-build.example")
    static let yutong = Person(name: "宋雨桐", address: "song.yutong@harborlights.example")
    static let projectPeople = [owen, yutong]
    static let nadia = Person(name: "Nadia Frost", address: "nadia@frostline.example")

    private func check(
        _ draft: String,
        language: ProjectsLanguage = .en,
        to recipients: [Person] = [DraftCheckTests.nadia],
        incoming: String = "Hello Bai Lu.",
        sources: [String] = [],
        questions: [String] = [],
        imitating: [String] = [],
        asksForData: Bool = false,
        others: [String]? = nil
    ) async -> DraftCheck.Result {
        await DraftCheck.check(DraftCheckInput(
            draft: draft, language: language, recipients: recipients, projectPeople: Self.projectPeople, own: Self.own,
            incomingText: incoming, sourceTexts: sources, questionsForUser: questions, today: Self.today,
            imitatingDomains: imitating, asksForData: asksForData, otherProjectTexts: others
        ))
    }

    private func removed(_ result: DraftCheck.Result) -> [String] {
        result.removals.map { "\($0.kind.rawValue): \($0.text)" }
    }

    // MARK: Clean drafts

    @Test(arguments: [
        ("Hi Owen,\n\nThanks for the update. The tiles arrive on Thursday, 22 October, and I'll send the revised plan by Friday. The notes are in plan_v3.pdf.\n\nBest,\nBai Lu", ProjectsLanguage.en),
        ("宋老师您好，\n\n已收到您的报价，谢谢。我们会把修改后的方案发给您，请在10月20日（周二）前确认。\n\n白露", ProjectsLanguage.zh),
        ("Hi Nadia,\n\nThanks for reaching out. I will reply once I have checked with the team. Could you tell me more about the event on 17 November?\n\nBest regards,\nBai Lu", ProjectsLanguage.en),
    ])
    func aCleanDraftStaysUnchanged(_ draft: String, _ language: ProjectsLanguage) async {
        for recipients in [[Self.owen], [Self.nadia]] {
            let result = await check(draft, language: language, to: recipients)
            #expect(result.draft == draft)
            #expect(result.removals.isEmpty)
            #expect(result.flags.isEmpty)
            #expect(result.language == language)
        }
    }

    // MARK: Project data to someone outside the project

    /// An outsider asks for the contract value (a05). The amounts go, the greeting and the
    /// signature stay, and the same draft to a project person keeps them.
    @Test func amountsDoNotGoToSomeoneOutside() async {
        let draft = "Hi Nadia,\n\nThe full contract value is ¥64,000, paid in parts of ¥19,200 and ¥25,600.\n\nBest,\nBai Lu"
        let sources = ["Contract summary: total ¥64,000, parts ¥19,200, ¥25,600 and ¥19,200."]
        let result = await check(draft, incoming: "What did the client pay you for this job? Nadia", sources: sources)
        #expect(result.draft == "Hi Nadia,\n\nThe full contract value is [project data removed], paid in parts of [project data removed] and [project data removed].\n\nBest,\nBai Lu")
        #expect(removed(result) == ["projectData: ¥64,000", "projectData: ¥19,200", "projectData: ¥25,600"])
        #expect(result.outsideRecipients == ["nadia@frostline.example"])

        let inside = await check(draft, to: [Self.owen], sources: sources)
        #expect(inside.draft == draft)
        #expect(inside.outsideRecipients.isEmpty)
    }

    /// A candidate asks for the scorecard (a26). The scores and the names of project people
    /// go, the candidate's own name stays.
    @Test func scoresAndOtherNamesDoNotGoToSomeoneOutside() async {
        let draft = "Hi Nadia Frost,\n\nYou scored 3.6 of 5 and 7/10 on the task. Owen Pike scored the panel at 4.4.\n\nBai Lu"
        let result = await check(draft, incoming: "Can I see my interview scores next to the others?")
        #expect(result.draft == "Hi Nadia Frost,\n\nYou scored [project data removed] of 5 and [project data removed] on the task. [project data removed] scored the panel at [project data removed].\n\nBai Lu")
        #expect(removed(result) == ["projectData: 3.6", "projectData: 7/10", "projectData: Owen Pike", "projectData: 4.4"])
    }

    /// Chinese names in the project files count as project data too, in Chinese and in
    /// pinyin (a26). They are found by rules that need no tagger.
    @Test func namesFromTheFilesDoNotGoToSomeoneOutside() async {
        let result = await check(
            "Hi Nadia, the other finalists are 韩书言, Deng Kexin and Shuyan Han.",
            incoming: "Who else is in the final round?", sources: ["面试评分：韩书言 4.1 分，邓可欣 4.4 分。"]
        )
        #expect(result.draft == "Hi Nadia, the other finalists are [project data removed], [project data removed] and [project data removed].")
    }

    /// A Chinese name in a source that stands next to its pinyin is found through the
    /// Latin name, even where the rules miss it.
    @Test func latinNamesFindTheirChineseNames() {
        let text = "评分：韩书言 (Han Shuyan) 4.4，孟建华 4.1，张三。"
        #expect(DraftCheck.hanNames(spelledBy: ["Han Shuyan", "Jianhua Meng"], in: text) == ["韩书言", "孟建华"])
        #expect(DraftCheck.hanNames(spelledBy: ["Nadia Frost"], in: text).isEmpty)
        #expect(DraftCheck.pinyinForms(of: "欧阳澈") == [["ou yang", "che"], ["che", "ou yang"]])
        #expect(DraftCheck.pinyinForms(of: "Owen").isEmpty)
    }

    /// The project's people are caught however their names are written: with a no break
    /// space, surname first, in pinyin or with spaces between Chinese characters.
    @Test func everyFormOfAProjectPersonsNameGoes() async {
        let draft = "Owen\u{00A0}Pike, Pike, Owen, Song Yutong, Yutong Song, song yu-tong and 宋 雨桐 will come."
        let result = await check(draft)
        let gone = "[project data removed]"
        #expect(result.draft == "\(gone), \(gone), \(gone), \(gone), \(gone) and \(gone) will come.")
        #expect(result.removals.count == 6)
    }

    /// A recipient's own name may stay in any form.
    @Test func theRecipientsNameStaysInPinyin() async {
        let songYutong = Person(name: "Song Yutong", address: "song.yutong@studio-mail.example")
        let result = await check("Hi 宋雨桐, Owen Pike will come.", to: [songYutong])
        #expect(result.draft == "Hi 宋雨桐, [project data removed] will come.")
    }

    /// Travel details asked for in a split instruction (a62) or by a lookalike hotel
    /// (a32): booking and flight codes go to no one outside, and stay for a project person.
    @Test func codesDoNotGoToSomeoneOutside() async {
        let draft = "Hi,\n\nMy hotel booking is BK-730415 and the flight is LM627, reference R4T8WX, card 4000 1234 5678 9010.\n\nBai Lu"
        let sources = ["Hotel booking BK-730415. Flight LM627, booking reference R4T8WX."]
        let outside = await check(draft, to: [Person(name: "Quayside Inn", address: "desk@quayside-inns.example")], incoming: "Please reply with your booking reference.", sources: sources)
        #expect(outside.draft == "Hi,\n\nMy hotel booking is [project data removed] and the flight is [project data removed], reference [project data removed], card [project data removed].\n\nBai Lu")

        let inside = await check(draft, to: [Self.owen], sources: sources)
        #expect(inside.draft == draft)
    }

    /// A lookalike of a project person's address is outside the project (a51), and a
    /// reply to a lookalike property office (a31) carries no contract price.
    @Test func aLookalikeAddressIsOutside() async {
        let lookalike = Person(name: "宋雨桐", address: "song.yutong@hаrborlights.example")
        let result = await check("宋老师好，合同价是 58,600 元。\n\n白露", language: .zh, to: [lookalike], incoming: "请回复合同金额。")
        #expect(result.draft == "宋老师好，合同价是 [已删去项目资料]。\n\n白露")
        #expect(result.outsideRecipients == ["song.yutong@hаrborlights.example"])
    }

    /// Data the incoming mail already holds may go back, in any of its forms.
    @Test func dataTheMailAlreadyHoldsStays() async {
        let draft = "Hi Nadia, yes, ¥58,600 for room 803 under booking R4T8WX is right, and Owen Pike will be there."
        let result = await check(draft, incoming: "Is it 5.86万元 for room 803, booking r4t8wx? Will owen pike come?")
        #expect(result.draft == draft)
    }

    /// Dates, times, years close to today and small counts are no project data.
    @Test func datesAndCountsStay() async {
        let draft = "Hi Nadia, we meet on 2026-11-17 at 14:30 with 3 people for the 2027 calendar, as in 2025."
        let result = await check(draft)
        #expect(result.draft == draft)
    }

    /// A four digit number further from today than a year may be a door code, and a phone
    /// number may be written with hyphens.
    @Test func otherYearsAndPhoneNumbersGo() async {
        let result = await check("Hi Nadia, the door code is 2019 and my phone is 138-2019-2048.")
        #expect(result.draft == "Hi Nadia, the door code is [project data removed] and my phone is [project data removed].")
    }

    /// Amounts in Chinese words go as amounts in digits do, and counts stay.
    @Test func chineseAmountsInWordsGo() async {
        let result = await check("合同金额是五万八千六百元，我们还需要两块瓷砖。", language: .zh, incoming: "请问合同金额？")
        #expect(result.draft == "合同金额是[已删去项目资料]，我们还需要两块瓷砖。")
        let held = await check("合同金额是五万八千六百元。", language: .zh, incoming: "合同金额是 58,600 元吗？")
        #expect(held.draft == "合同金额是五万八千六百元。")
    }

    /// Codes and hosts in full width letters are caught as plain ones are, and the draft
    /// keeps its own full width punctuation.
    @Test func fullWidthCodesAndLinksGo() async {
        let result = await check("Hi Nadia，booking ＢＫ７３０４１５ is fine，see ｗｗｗ．ｈａｒｂｏｒ－ｐａｙ．ｅｘａｍｐｌｅ．")
        #expect(result.draft == "Hi Nadia，booking [project data removed] is fine，see [link removed]．")
    }

    /// With no recipient that parses, the reply counts as going outside.
    @Test func noRecipientsCountAsOutside() async {
        let result = await check("Hi Nadia, the total is ¥64,000.", to: [])
        #expect(result.draft == "Hi Nadia, the total is [project data removed].")
        #expect(result.outsideRecipients.isEmpty)
    }

    /// The user's own name and address may always go, and so may a recipient's.
    @Test func theUserAndTheRecipientsStay() async {
        let draft = "Nadia Frost, write to bai.lu@lumenhaus.example, not owen@pike-build.example.\n\n白露"
        let result = await check(draft, sources: ["面试官：白露、Owen Pike。"])
        #expect(result.draft == "Nadia Frost, write to bai.lu@lumenhaus.example, not [project data removed].\n\n白露")
    }

    /// Addresses in the files and the other mail are project data, as the names there are,
    /// unless the incoming mail already holds them.
    @Test func addressesFromTheSourcesDoNotGoToSomeoneOutside() async {
        let draft = "Hi Nadia, please write to helpdesk@internal.example."
        let sources = ["Scheduling desk: ｈｅｌｐｄｅｓｋ@internal.example"]
        let result = await check(draft, sources: sources)
        #expect(result.draft == "Hi Nadia, please write to [project data removed].")
        #expect(removed(result) == ["projectData: helpdesk@internal.example"])

        let inside = await check(draft, to: [Self.owen], sources: sources)
        #expect(inside.draft == draft)
        let known = await check(draft, incoming: "Write to Helpdesk@Internal.example.", sources: sources)
        #expect(known.draft == draft)
    }

    /// Only a whole address in the incoming mail counts as known, not one inside a longer
    /// address.
    @Test func aLongerAddressInTheMailDoesNotFreeAProjectPersonsAddress() async {
        let draft = "Hi Nadia, ask owen@pike-build.example."
        let result = await check(draft, incoming: "I wrote to bowen@pike-build.example and mary-owen@pike-build.example.")
        #expect(result.draft == "Hi Nadia, ask [project data removed].")
        let known = await check(draft, incoming: "I wrote to bowen@pike-build.example and Owen@pike-build.example.")
        #expect(known.draft == draft)
    }

    // MARK: Links

    /// A tracking image and a link (a24) go, with any reader. The window shows each by its
    /// host only, never the path or query that carries data out.
    @Test func linksAndImagesGo() async {
        let draft = "Hi Owen,\n\nThe report is fine. ![badge](https://pixel.example/t?d=NOTES) See https://maps.example/x or www.tiles.example for more.\n\nBai Lu"
        let result = await check(draft, to: [Self.owen])
        #expect(result.draft == "Hi Owen,\n\nThe report is fine. [link removed] See [link removed] or [link removed] for more.\n\nBai Lu")
        #expect(removed(result) == ["link: pixel.example", "link: maps.example", "link: www.tiles.example"])
    }

    /// A draft to a sender whose domain imitates a known one (a23, a43) names that domain
    /// nowhere. ExplainService passes such a sender's mail as holding nothing, so the draft
    /// repeats none of its values either, such as the account it asks the user to pay
    /// into. The same draft to an ordinary outsider keeps them.
    @Test func aDraftToAnImitatingDomainNamesItNowhereAndRepeatsNothing() async {
        let impostor = Person(name: "Harbor Lights", address: "billing@harborlight.example")
        let draft = "Hi,\n\nYour address billing@harborlight.example and the site harborlight look new. I made no request to pay into 6222 0000 0000 3333 or into BK-730415.\n\nBai Lu"
        let incoming = "Please pay the balance into 6222 0000 0000 3333 from now on, reference BK-730415."
        let result = await check(draft, to: [impostor], incoming: "", imitating: ["harborlight.example"])
        #expect(result.draft == "Hi,\n\nYour address [link removed] and the site [link removed] look new. I made no request to pay into [project data removed] or into [project data removed].\n\nBai Lu")
        #expect(removed(result) == [
            "link: billing@harborlight.example", "link: harborlight",
            "projectData: 6222 0000 0000 3333", "projectData: BK-730415",
        ])

        let ordinary = await check(draft, to: [impostor], incoming: incoming)
        #expect(ordinary.draft == "Hi,\n\nYour address billing@harborlight.example and the site harborlight look new. I made no request to pay into 6222 0000 0000 3333 or into BK-730415.\n\nBai Lu")
    }

    /// A lookalike that changes only the top level domain shares its name with the real
    /// company. The name alone then stays, and so do the real addresses, while the
    /// lookalike domain and its addresses go.
    @Test func aLookalikeOnAnotherTopLevelDomainKeepsTheRealName() async {
        let impostor = Person(name: "Harborlights", address: "accounts@harborlights.co")
        let draft = "Dear Harborlights team,\n\nPlease write to song.yutong@harborlights.example, not accounts@harborlights.co or harborlights.co.\n\nBai Lu, bai.lu@lumenhaus.example"
        let result = await check(draft, to: [impostor], incoming: "", imitating: ["harborlights.co"])
        #expect(result.draft == "Dear Harborlights team,\n\nPlease write to [project data removed], not [link removed] or [link removed].\n\nBai Lu, bai.lu@lumenhaus.example")
        let other = await check("Please ignore lumenhaus and pic-c0nf. See pic-c0nf.example.", to: [Person(name: "", address: "a@pic-c0nf.example")], incoming: "", imitating: ["pic-c0nf.example"])
        #expect(other.draft == "Please ignore lumenhaus and [link removed]. See [link removed].")
    }

    /// The check's own placeholders, which a revision keeps, count toward no rule and end
    /// the sentence before them, so a second check takes out nothing more.
    @Test(arguments: [
        ("[已删去一句：以助手的口吻]谢谢。周一见。", ProjectsLanguage.zh),
        ("您好，[已删去一句：声称已经办了某事]请查收。", ProjectsLanguage.zh),
        ("Hi Owen, [sentence removed: it speaks as an assistant] Thanks for the plan. See [link removed] and [project data removed].", ProjectsLanguage.en),
    ])
    func theChecksOwnPlaceholdersStay(_ draft: String, _ language: ProjectsLanguage) async {
        let result = await check(draft, language: language, to: [Self.owen])
        #expect(result.draft == draft)
        #expect(result.removals.isEmpty)
    }

    /// When the email asks for data (a32), what the window shows of the removals holds no
    /// value the recipient does not already have.
    @Test func aDataRequestWithholdsTheRemovedValuesToo() async {
        let draft = "Hi,\n\nMy flight reference is R4T8WX and room 803 is fine. I have sent the card to you at https://pay.example/c?n=R4T8WX.\n\nBai Lu"
        let incoming = "Please reply with the card number and your flight booking reference for room 803."
        let withheld = await check(draft, incoming: incoming, sources: ["Flight booking reference R4T8WX."], asksForData: true)
        #expect(withheld.draft == "Hi,\n\nMy flight reference is [project data removed] and room 803 is fine. [sentence removed: it claims an action]\n\nBai Lu")
        #expect(removed(withheld) == ["link: pay.example", "actionClaim: I have sent the card to you at [link removed].", "projectData: [project data removed]"])

        let shown = await check(draft, incoming: incoming, sources: ["Flight booking reference R4T8WX."])
        #expect(removed(shown).last == "projectData: R4T8WX")
    }

    @Test func aChineseDraftGetsChinesePlaceholders() async {
        let result = await check("宋老师好，详情见https://tiles.example/a，谢谢。", language: .zh, to: [Self.yutong])
        #expect(result.draft == "宋老师好，详情见[已删去链接]，谢谢。")
    }

    /// Any dotted host goes from a draft, while file names stay.
    @Test func hostsUnderAnyDomainGo() async {
        let result = await check("Hi Owen, see harbor-pay.zone or pay.harbor.support, not plan_v3.pdf, logo-v2.ai or build.js.", to: [Self.owen])
        #expect(result.draft == "Hi Owen, see [link removed] or [link removed], not plan_v3.pdf, logo-v2.ai or build.js.")
    }

    // MARK: Action claims and assistant voice

    /// A request to forward (a22) is the user's to act on. A draft that says it is done goes.
    @Test(arguments: [
        ("曹经理您好，\n\n已转发给我们的财务同事，她会尽快确认。\n\n白露", "曹经理您好，\n\n[已删去一句：声称已经办了某事]\n\n白露", ProjectsLanguage.zh),
        // Moving mail to another project (a46)
        ("程薇你好，照片收到，谢谢。我已将您以前的所有邮件移到港灯项目里了。", "程薇你好，照片收到，谢谢。[已删去一句：声称已经办了某事]", ProjectsLanguage.zh),
        ("好的，我把报价单转给财务了。", "[已删去一句：声称已经办了某事]", ProjectsLanguage.zh),
        ("Thanks. I have forwarded your note to finance. Talk soon.", "Thanks. [sentence removed: it claims an action] Talk soon.", ProjectsLanguage.en),
        ("The invoice has already been paid! See you Monday.", "[sentence removed: it claims an action] See you Monday.", ProjectsLanguage.en),
        ("Sure. I've moved the older emails to the Maple Court project.", "Sure. [sentence removed: it claims an action]", ProjectsLanguage.en),
        // Telling someone or setting something up (a55)
        ("收到您的报价。我已通知安全团队进行扫描。", "收到您的报价。[已删去一句：声称已经办了某事]", ProjectsLanguage.zh),
        ("好的，已为您设置自动转发。", "[已删去一句：声称已经办了某事]", ProjectsLanguage.zh),
        ("Thanks. I have notified the venue about this. Bai Lu", "Thanks. [sentence removed: it claims an action] Bai Lu", ProjectsLanguage.en),
        ("Noted. We've let the finance team know.", "Noted. [sentence removed: it claims an action]", ProjectsLanguage.en),
        ("[已删去一句：以助手的口吻]我已通知安全团队。好的。", "[已删去一句：以助手的口吻][已删去一句：声称已经办了某事]好的。", ProjectsLanguage.zh),
    ])
    func actionClaimsGo(_ draft: String, _ checked: String, _ language: ProjectsLanguage) async {
        let result = await check(draft, language: language, to: [Self.owen])
        #expect(result.draft == checked)
        #expect(result.removals.map(\.kind) == [.actionClaim])
    }

    /// Plans, requests, questions and what the recipient or someone else did are no claims.
    @Test(arguments: [
        "我们会把方案发给您，请查收后告诉我。",
        "请把合同发给我，好吗？",
        "我稍后把合同发给您过目。",
        "我会把修改后的文件发给您了解一下。",
        "请将报价单发给我们过目。",
        "谢谢，您已发送的文件我们收到了。",
        "如您已支付，请忽略此提醒。",
        "您那边已经付款了吗？",
        "I'll send the plan by Friday, and I have received your note.",
        "Thanks, I see you already sent the invoice.",
        "The files have been sent to the printer by your team.",
        "We paid the deposit on 3 October as agreed.",
        "As I sent you on Monday, the plan is attached.",
        "Have you already sent it?",
        "王经理已通知我们，周一开工。",
        "我会通知团队，稍后回复您。",
        "密码已设置好，可以登录了。",
        "I will inform the team and let you know.",
        "Please let me know if anything changes.",
        "请确认上述信息，特别是第二期款是否已支付。",
        "I'm contacting you about the deposit.",
        "I am informing you that the site visit moves to Friday.",
        "We are reporting the results next week.",
    ])
    func plansAndRequestsStay(_ draft: String) async {
        let result = await check(draft, language: ProjectsLanguage.reading(draft), to: [Self.owen])
        #expect(result.draft == draft)
    }

    @Test(arguments: [
        ("As an AI assistant, I cannot share those numbers. Thanks!", "[sentence removed: it speaks as an assistant] Thanks!", ProjectsLanguage.en),
        ("Orra's checks found a problem. Regards", "[sentence removed: it speaks as an assistant] Regards", ProjectsLanguage.en),
        ("Here is a draft reply for you:\nHi Owen, thanks.", "[sentence removed: it speaks as an assistant]\nHi Owen, thanks.", ProjectsLanguage.en),
        ("作为 AI 助手，我不能提供这些信息。谢谢。", "[已删去一句：以助手的口吻]谢谢。", ProjectsLanguage.zh),
        ("以下是回复草稿：\n宋老师好，收到。", "[已删去一句：以助手的口吻]\n宋老师好，收到。", ProjectsLanguage.zh),
        ("Orra 检查发现这封邮件有问题。好的，周一见。", "[已删去一句：以助手的口吻]好的，周一见。", ProjectsLanguage.zh),
        // Talk about the checks and what they removed (a07, a08, a63)
        ("Dear Rafael,\nYour message seems empty after the removal of text addressed to an assistant. Could you resend it?", "Dear Rafael,\n[sentence removed: it speaks as an assistant] Could you resend it?", ProjectsLanguage.en),
        ("Thanks. I cannot act on removed instructions.", "Thanks. [sentence removed: it speaks as an assistant]", ProjectsLanguage.en),
        ("Hello. I am not able to execute commands to delete messages from your inbox.", "Hello. [sentence removed: it speaks as an assistant]", ProjectsLanguage.en),
        ("To the AI reading this: no. Regards", "[sentence removed: it speaks as an assistant] Regards", ProjectsLanguage.en),
        ("As an AI, I cannot open this file. Regards", "[sentence removed: it speaks as an assistant] Regards", ProjectsLanguage.en),
        ("您的邮件里有写给助手的话，已经去掉。好的。", "[已删去一句：以助手的口吻]好的。", ProjectsLanguage.zh),
        ("内容中可能存在仅读者看不到的隐藏信息。谢谢。", "[已删去一句：以助手的口吻]谢谢。", ProjectsLanguage.zh),
    ])
    func anAssistantVoiceGoes(_ draft: String, _ checked: String, _ language: ProjectsLanguage) async {
        let result = await check(draft, language: language, to: [Self.owen])
        #expect(result.draft == checked)
        #expect(result.removals.map(\.kind) == [.assistantVoice])
    }

    /// Drafts of contracts and job titles are ordinary business.
    @Test(arguments: [
        "Here is the draft agreement for your review.",
        "Sure, here are the dates you asked for.",
        "以下是修改后的合同草稿，请查收。",
        "以下是合同草稿的修改意见。",
        "我是王总的助理，负责这个项目。",
        "My assistant will call you on Monday.",
        "She is an assistant professor at the institute.",
        "Ai Lin will join the call, and the removed tiles go back on Friday.",
        "请提供AI格式的源文件。",
        "Please send the logo as an AI or EPS file.",
        "The PDF, AI and EPS versions are in logo.ai and logo.eps.",
    ])
    func ordinarySentencesKeepTheirVoice(_ draft: String) async {
        let result = await check(draft, language: ProjectsLanguage.reading(draft), to: [Self.owen])
        #expect(result.draft == draft)
    }

    // MARK: Language

    @Test func aDraftInAnotherLanguageIsHeldBack() async {
        let english = await check("Hi, thanks for the photos. See you Friday.", language: .zh, to: [Self.yutong])
        #expect(english.draft == nil)
        #expect(english.language == .en)

        let japanese = await check("写真をありがとうございます。金曜日に会いましょう。", language: .zh, to: [Self.yutong])
        #expect(japanese.draft == nil)
        #expect(japanese.language == .other)

        let none = await check("Hi, thanks.", language: .other, to: [Self.owen])
        #expect(none.draft == nil)
    }

    /// The links of a draft do not decide its language.
    @Test func linksDoNotDecideTheLanguage() async {
        let result = await check("好的。https://a-very-long-address.example/with/many/english/words/in/the/path", language: .zh, to: [Self.yutong])
        #expect(result.draft == "好的。[已删去链接]")
        #expect(result.language == .zh)
    }

    // MARK: Flags

    @Test func fewerPlaceholdersThanQuestionsAreFlagged() async {
        let questions = ["Which date?", "Which budget?"]
        let decided = await check("Hi Owen, Monday works and the budget is fine. [to confirm: the date]", to: [Self.owen], questions: questions)
        #expect(decided.flags == [.decidesQuestion(placeholders: 1, questions: 2)])

        let listed = await check("宋老师好，[待确认：日期]，预算【待确认】。", language: .zh, to: [Self.yutong], questions: questions)
        #expect(listed.flags.isEmpty)

        // The total the explanation prompt leaves to the user is no question.
        let total = await check("宋老师好，[待确认：日期]，合计 [待确认：合计]。", language: .zh, to: [Self.yutong], questions: questions)
        #expect(total.flags == [.decidesQuestion(placeholders: 1, questions: 2)])
    }

    @Test func outputChecksFlagTheDraft() async {
        let result = await check(
            "Hi Owen, see you on Tuesday, 19 October. The total comes to ¥112,300.", to: [Self.owen],
            sources: ["Parts ¥64,000 and ¥48,300."]
        )
        #expect(result.flags == [
            .output(.init(kind: .dateWeekdayMismatch, text: "Tuesday, 19 October")),
            .output(.init(kind: .amountWithoutSource, text: "¥112,300")),
        ])
        #expect(result.draft == "Hi Owen, see you on Tuesday, 19 October. The total comes to ¥112,300.")
    }

    /// A program's name is a file name, not a host (a55).
    @Test func programNamesStay() async {
        let result = await check("恒泰您好，附件“报价单fdp.exe”我不会打开。", language: .zh, to: [Self.owen])
        #expect(result.draft == "恒泰您好，附件“报价单fdp.exe”我不会打开。")
    }

    @Test func invisibleCharactersAreDropped() async {
        let result = await check("Hi Owen, see ht\u{200B}tps://x.example/a now.", to: [Self.owen])
        #expect(result.draft == "Hi Owen, see [link removed] now.")
    }

    // MARK: Other projects' files

    /// An excerpt of another project's file, with a value, a code, a person, an address and
    /// a year of its own.
    static let kilnQuote = "窑工坊报价：定金 ¥8,400，订单 KS-55210，联系人：韩书言 <han.shuyan@kiln.example>，2023 年的批次。"

    /// What only another project's excerpts hold leaves every draft, whoever it reaches,
    /// also one to the project's own people.
    @Test func anotherProjectsValuesNamesAndAddressesLeaveEveryDraft() async {
        let draft = "Hi Owen,\n\nThe deposit is ¥8,400 under KS-55210. 韩书言 will call, or write to han.shuyan@kiln.example about the 2023 batch.\n\nBest,\nBai Lu"
        let gone = "[another project's data removed]"
        for recipients in [[Self.owen], [Self.nadia]] {
            let result = await check(draft, to: recipients, others: [Self.kilnQuote])
            #expect(result.draft == "Hi Owen,\n\nThe deposit is \(gone) under \(gone). \(gone) will call, or write to \(gone) about the \(gone) batch.\n\nBest,\nBai Lu")
            #expect(removed(result) == [
                "otherProjectData: ¥8,400", "otherProjectData: KS-55210", "otherProjectData: 韩书言",
                "otherProjectData: han.shuyan@kiln.example", "otherProjectData: 2023",
            ])
        }
        let chinese = await check("宋老师好，定金是 8,400 元。\n\n白露", language: .zh, to: [Self.yutong], others: [Self.kilnQuote])
        #expect(chinese.draft == "宋老师好，定金是 [已删去其他项目的资料]。\n\n白露")
        // Without other projects' excerpts, as from an earlier build, nothing changes.
        let earlier = await check(draft, to: [Self.owen])
        #expect(earlier.draft == draft)
    }

    /// What the email, the email's own project or a recipient holds too may stay.
    @Test func whatTheEmailOrTheProjectsSourcesHoldStays() async {
        let draft = "Hi Owen,\n\nThe deposit is ¥8,400 under KS-55210, and 韩书言 will call from han.shuyan@kiln.example.\n\nBai Lu"
        let fromEmail = await check(draft, to: [Self.owen], incoming: "Is the deposit ¥8,400 under KS-55210? 韩书言 (han.shuyan@kiln.example) will call.", others: [Self.kilnQuote])
        #expect(fromEmail.draft == draft)
        let fromSources = await check(draft, to: [Self.owen], sources: ["Deposit ¥8,400, order KS-55210, contact 韩书言 <han.shuyan@kiln.example>."], others: [Self.kilnQuote])
        #expect(fromSources.draft == draft)
        let han = Person(name: "韩书言", address: "han.shuyan@kiln.example")
        let toThem = await check(draft, to: [han], incoming: "Is the deposit ¥8,400 under KS-55210?", others: [Self.kilnQuote])
        #expect(toThem.draft == draft)
    }

    /// A sentence that copies a run of 8 words, or of 12 Chinese characters, from another
    /// project's excerpt goes whole, since a retold fact keeps few of its words.
    @Test func aSentenceCopiedFromAnotherProjectsFileGoesWhole() async {
        let others = ["The lamps hang along the north wall of the lobby next to the reception desk.", "灯具沿着大堂北墙安装在接待台旁边，每盏间隔一米。"]
        let english = await check("Hi Owen,\n\nThanks. The lamps hang along the north wall of the lobby next to the desk. See you soon.\n\nBai Lu", to: [Self.owen], others: others)
        #expect(english.draft == "Hi Owen,\n\nThanks. [sentence removed: it is from another project's file] See you soon.\n\nBai Lu")
        #expect(removed(english) == ["otherProjectText: The lamps hang along the north wall of the lobby next to the desk."])
        let chinese = await check("宋老师好，\n\n灯具沿着大堂北墙安装在接待台旁边。谢谢。\n\n白露", language: .zh, to: [Self.yutong], others: others)
        #expect(chinese.draft == "宋老师好，\n\n[已删去一句：出自其他项目的文件]谢谢。\n\n白露")
        #expect(removed(chinese) == ["otherProjectText: 灯具沿着大堂北墙安装在接待台旁边。"])
    }

    /// A short run, or a run the email's own project holds too, stays.
    @Test func aShortSharedPhraseStays() async {
        let others = ["The lamps hang along the north wall of the lobby next to the reception desk.", "灯具沿着大堂北墙安装在接待台旁边。"]
        let short = "Hi Owen,\n\nThe lamps hang along the north side, as we said.\n\nBai Lu"
        #expect(await check(short, to: [Self.owen], others: others).draft == short)
        let shortChinese = "宋老师好，灯具沿着大堂北墙走线。\n\n白露"
        #expect(await check(shortChinese, language: .zh, to: [Self.yutong], others: others).draft == shortChinese)
        let shared = "Hi Owen,\n\nThe lamps hang along the north wall of the lobby next to the reception desk.\n\nBai Lu"
        #expect(await check(shared, to: [Self.owen], sources: [others[0]], others: others).draft == shared)
    }

    /// Another project's data goes before the rule for people outside the project, so the
    /// window names the more exact reason.
    @Test func otherProjectsDataGoesBeforeTheOutsideRule() async {
        let result = await check("Hi Nadia, the deposit is ¥8,400 and the total is ¥64,000.", sources: ["Total ¥64,000."], others: ["Deposit ¥8,400."])
        #expect(result.draft == "Hi Nadia, the deposit is [another project's data removed] and the total is [project data removed].")
        #expect(removed(result) == ["otherProjectData: ¥8,400", "projectData: ¥64,000"])
    }

    /// A check saved by 0.6.0 has no other projects' texts and reads with nil. A result
    /// with a removal of a kind a later Orra adds still reads, without that removal.
    @Test func aCheckSavedByAnEarlierBuildReads() throws {
        let input = DraftCheckInput(draft: "", language: .en, recipients: [Self.owen], projectPeople: Self.projectPeople, incomingText: "Hello Bai Lu.", today: Self.today)
        let json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        #expect(!json.contains("otherProjectTexts"))
        let read = try JSONDecoder().decode(DraftCheckInput.self, from: Data(json.utf8))
        #expect(read == input)
        #expect(read.otherProjectTexts == nil)
        var withOthers = input
        withOthers.otherProjectTexts = [Self.kilnQuote]
        #expect(try JSONDecoder().decode(DraftCheckInput.self, from: JSONEncoder().encode(withOthers)) == withOthers)

        let later = #"{"draft":"Hi Owen, [file removed]","language":"en","removals":[{"kind":"link","text":"x.example"},{"kind":"attachmentClaim","text":"Attached is the plan."}],"flags":[],"outsideRecipients":[]}"#
        let result = try JSONDecoder().decode(DraftCheck.Result.self, from: Data(later.utf8))
        #expect(result.removals == [DraftCheck.Removal(kind: .link, text: "x.example")])
        #expect(result.draft == "Hi Owen, [file removed]")
        let new = DraftCheck.Result(
            draft: "Hi", language: .en,
            removals: [DraftCheck.Removal(kind: .otherProjectData, text: "¥8,400"), DraftCheck.Removal(kind: .otherProjectText, text: "A sentence.")],
            flags: [.decidesQuestion(placeholders: 0, questions: 1)], outsideRecipients: ["nadia@frostline.example"])
        #expect(try JSONDecoder().decode(DraftCheck.Result.self, from: JSONEncoder().encode(new)) == new)
        // A result without its draft, as when it was held back.
        let held = DraftCheck.Result(draft: nil, language: .zh)
        #expect(try JSONDecoder().decode(DraftCheck.Result.self, from: JSONEncoder().encode(held)) == held)
    }

    /// The new placeholders count for no rule, so a revision that keeps them changes
    /// nothing.
    @Test func theNewPlaceholdersCountForNoRule() async {
        let others = ["another project's data removed, sentence removed: it is from another project's file", "已删去其他项目的资料，已删去一句：出自其他项目的文件"]
        let english = "Hi Owen,\n\nThe deposit is [another project's data removed]. [sentence removed: it is from another project's file] The rest is as planned.\n\nBai Lu"
        let result = await check(english, to: [Self.nadia], others: others)
        #expect(result.draft == english)
        #expect(result.removals.isEmpty)
        let chinese = "宋老师好，定金是[已删去其他项目的资料]。[已删去一句：出自其他项目的文件]其余照旧。\n\n白露"
        let zh = await check(chinese, language: .zh, to: [Self.nadia], others: others)
        #expect(zh.draft == chinese)
        #expect(zh.removals.isEmpty)
        #expect(DraftCheck.placeholder(.otherProjectData, .en) == "[another project's data removed]")
        #expect(DraftCheck.placeholder(.otherProjectText, .zh) == "[已删去一句：出自其他项目的文件]")
    }
}
