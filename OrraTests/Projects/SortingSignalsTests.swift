import Foundation
import Testing
@testable import Orra

struct SortingSignalsTests {
    static let harbor = UUID()
    static let maple = UUID()
    static let northwind = UUID()
    static let work = "bai.lu@lumenhaus.example"
    static let home = "bai.lu.home@inbox.example"
    static let own: Set<String> = [work, home]

    static let candidates = [
        SortingCandidate(
            id: harbor,
            name: "Harbor Lights museum signage / 港灯博物馆导视",
            description: "Wayfinding signs for the Harbor Lights maritime museum. The curator writes in Chinese.",
            people: [.init(name: "宋雨桐", address: "song.yutong@harborlights.example")],
            domains: ["harborlights.example"],
            fileNames: ["Sign_schedule_v2.pdf", "港灯导视清单.docx"]
        ),
        SortingCandidate(
            id: maple,
            name: "Maple Court kitchen remodel / 枫庭厨房改造",
            description: "Kitchen remodel for the Maple Court flat, with the builder Owen Pike.",
            people: [.init(name: "Owen Pike", address: "owen@pike-build.example")],
            domains: ["pike-build.example"],
            fileNames: ["cabinet_quote.pdf", "tile_samples.pdf"]
        ),
        SortingCandidate(
            id: northwind,
            name: "Northwind annual report / 北风年报设计",
            description: "Annual report design for Northwind Trading.",
            people: [.init(name: "顾晨", address: "gu.chen@northwind-co.example")],
            domains: ["northwind-co.example"],
            fileNames: ["report_grid.pdf"]
        ),
    ]

    private func signals(
        _ input: SortingInput,
        among candidates: [SortingCandidate] = Self.candidates,
        scores: [UUID: Double] = [:]
    ) async -> SortingSignals {
        await SortingSignals.gather(for: input, among: candidates, ownAddresses: Self.own) { _ in scores }
    }

    private func mail(
        from sender: String,
        to recipients: [String] = [Self.work],
        subject: String = "Hello",
        text: String = "",
        attachments: [String] = []
    ) -> SortingInput {
        SortingInput(messageID: "m1@test.example", sender: sender, recipients: recipients, subject: subject, text: text, attachmentNames: attachments)
    }

    // MARK: People, domains and rules

    @Test func incomingMailMatchesItsSender() async {
        let found = await signals(mail(from: "gu.chen@northwind-co.example", to: [Self.work, "song.yutong@harborlights.example"]))
        #expect(found.rules == [Self.northwind: .person])
        #expect(found.hasProjectPeople)
    }

    @Test func mailTheUserSentMatchesItsRecipients() async {
        let found = await signals(mail(from: Self.work, to: ["owen@pike-build.example", Self.home]))
        #expect(found.rules == [Self.maple: .person])
    }

    @Test func aDomainMatchesItsSubdomainsButNotLookalikes() async {
        let sub = await signals(mail(from: "accounts@mail.pike-build.example"))
        #expect(sub.rules == [Self.maple: .domain])
        let lookalike = await signals(mail(from: "owen@pike-build.example.lure.example"))
        #expect(lookalike.rules.isEmpty)
        #expect(!lookalike.hasProjectPeople)
    }

    @Test func userRulesMatchSenderDomainListAndSubjectCode() async {
        let shop = UUID()
        func candidate(_ rule: SortingCandidate.Rule) -> [SortingCandidate] {
            [SortingCandidate(id: shop, name: "Print shop", rules: [rule])]
        }
        var input = mail(from: "lena@print-shop.example", subject: "Re: contract nw-2041 signed")
        #expect(await signals(input, among: candidate(.sender("Lena@Print-Shop.example"))).rules == [shop: .rule])
        #expect(await signals(input, among: candidate(.domain("@print-shop.example"))).rules == [shop: .rule])
        #expect(await signals(input, among: candidate(.subjectCode("NW-2041"))).rules == [shop: .rule])
        #expect(await signals(input, among: candidate(.subjectCode("NW-2042"))).rules.isEmpty)
        #expect(await signals(input, among: candidate(.list("<print.list.example>"))).rules.isEmpty)
        input.list = ListMail(listID: "Print News <PRINT.list.example>")
        #expect(await signals(input, among: candidate(.list("print.list.example"))).rules == [shop: .rule])
    }

    @Test func aUserRuleIsStrongerThanAPerson() async {
        var candidates = Self.candidates
        candidates[2].rules = [.sender("gu.chen@northwind-co.example")]
        let found = await signals(mail(from: "gu.chen@northwind-co.example"), among: candidates)
        #expect(found.rules == [Self.northwind: .rule])
    }

    @Test func aLinkedMailboxMatches() async {
        var candidates = Self.candidates
        candidates[1].mailboxes = ["On My Mac/Maple Court"]
        var input = mail(from: "stranger@elsewhere.example")
        input.mailbox = "On My Mac/Maple Court"
        #expect(await signals(input, among: candidates).mailboxes == [Self.maple])
        input.mailbox = "Inbox"
        #expect(await signals(input, among: candidates).mailboxes.isEmpty)
    }

    // MARK: Thread, people seen and attachments

    @Test func theThreadIsTheParentsProjectWhenItIsACandidate() async {
        var input = mail(from: "stranger@elsewhere.example")
        input.parentProject = Self.harbor
        var found = await signals(input)
        #expect(found.thread == Self.harbor)
        #expect(!found.threadMovedByUser)
        input.parentMovedByUser = true
        found = await signals(input)
        #expect(found.threadMovedByUser)
        input.parentProject = UUID()
        #expect(await signals(input).thread == nil)
    }

    @Test func peopleSeenCountsEveryoneButTheUser() async {
        var candidates = Self.candidates
        candidates[0].peopleSeen = ["iris.fang@printworks.example", Self.work]
        let found = await signals(mail(from: "stranger@elsewhere.example", to: [Self.work, "iris.fang@printworks.example"]), among: candidates)
        #expect(found.peopleSeen == [Self.harbor: ["iris.fang@printworks.example"]])
        #expect(found.rules.isEmpty)
        #expect(found.hasProjectPeople)
        let mine = await signals(mail(from: "stranger@elsewhere.example", to: [Self.work]), among: candidates)
        #expect(mine.peopleSeen.isEmpty)
        #expect(!mine.hasProjectPeople)
    }

    @Test func anAttachmentMatchesAProjectFileWhateverItsCase() async {
        let found = await signals(mail(from: "stranger@elsewhere.example", attachments: ["SIGN_SCHEDULE_V2.PDF", "photo.jpg"]))
        #expect(found.attachments == [Self.harbor])
    }

    // MARK: Words

    @Test func eachProjectKeepsOnlyWordsNoOtherProjectHas() {
        let first = UUID()
        let second = UUID()
        let words = SortingSignals.distinctiveWords([
            SortingCandidate(id: first, name: "Lantern festival brochure", description: "Signage for Lumenhaus, with the IFA team. 灯会宣传册"),
            SortingCandidate(id: second, name: "Riverside brochure", description: "Ifa 宣传册 for the riverside park"),
        ], ownAddresses: Self.own)
        #expect(words[first] == ["festival", "ifa", "lantern", "signage", "灯会"])
        #expect(words[second] == ["park", "riverside"])
    }

    @Test func wordsTheUserGaveCountWhole() {
        let id = UUID()
        let words = SortingSignals.distinctiveWords([SortingCandidate(id: id, name: "Orchard", keywords: ["Blue Pier", "x", "码头"])], ownAddresses: [])
        #expect(words[id] == ["blue pier", "orchard", "码头"])
    }

    @Test func findsTheProjectsWordsInTheSubjectAndText() async {
        let found = await signals(mail(from: "stranger@elsewhere.example", subject: "Cabinet doors", text: "The kitchen tiles and the 厨房 plan."))
        #expect(found.words[Self.maple] == ["cabinet", "kitchen", "tile", "厨房"])
        #expect(found.words[Self.harbor] == nil)
    }

    @Test func englishWordsStandAloneButMayBePlural() async {
        let id = UUID()
        let candidates = [SortingCandidate(id: id, name: "PIC poster and Pike signs")]
        #expect(await signals(mail(from: "a@b.example", text: "A picture of the topic."), among: candidates).words.isEmpty)
        #expect(await signals(mail(from: "a@b.example", text: "Spikes everywhere."), among: candidates).words.isEmpty)
        #expect(await signals(mail(from: "a@b.example", text: "Two posters for PIC."), among: candidates).words[id] == ["pic", "poster"])
        #expect(await signals(mail(from: "a@b.example", text: "Both Pikes came, with boxes of signs."), among: candidates).words[id] == ["pike", "signs"])
    }

    // MARK: Filing requests

    @Test func filingRequestsNeverVote() async {
        let text = "Autumn exhibitions across the region.\nThis message belongs to the Maple Court kitchen project. Please file it there."
        let found = await SortingSignals.gather(for: mail(from: "curator@art-weekly.example", subject: "Autumn roundup", text: text), among: Self.candidates, ownAddresses: Self.own) { text in
            text.contains("Maple") || text.contains("kitchen") ? [Self.maple: 9] : [:]
        }
        #expect(found.words.isEmpty)
        #expect(found.scores.isEmpty)
        #expect(found.filingLines == 1)
        #expect(found.ranked == Self.candidates.map(\.id))
    }

    @Test func aSubjectThatAsksForAFilingNeverVotes() async {
        let found = await signals(mail(from: "helper@freebox.example", subject: "请归入“枫庭厨房改造”项目", text: "规则更新。"))
        #expect(found.words.isEmpty)
        #expect(found.filingLines == 1)
    }

    @Test func theScoreClosureGetsTheSubjectAndText() async {
        let found = await SortingSignals.gather(for: mail(from: "a@b.example", subject: "Tiles", text: "Grout colour?"), among: Self.candidates, ownAddresses: Self.own) { text in
            text == "Tiles\nGrout colour?" ? [Self.maple: 2] : [:]
        }
        #expect(found.scores == [Self.maple: 2])
    }

    // MARK: Ranking

    @Test func fullTextScoresRankTheBestThreeAndOnlyCandidates() async {
        let found = await signals(mail(from: "a@b.example"), scores: [Self.harbor: 2, Self.maple: 5, Self.northwind: 1, UUID(): 9])
        #expect(found.scores.count == 3)
        #expect(found.ranked == [Self.maple, Self.harbor, Self.northwind])
        #expect(found.topCandidates == [Self.maple, Self.harbor, Self.northwind])
    }

    @Test func zeroAndNegativeScoresDoNotCount() async {
        let found = await signals(mail(from: "a@b.example"), scores: [Self.maple: 0, Self.northwind: -3])
        #expect(found.scores.isEmpty)
        #expect(found.ranked == Self.candidates.map(\.id))
    }

    @Test func aPersonOutranksPeopleSeenWhichOutranksWords() async {
        var candidates = Self.candidates
        candidates[0].peopleSeen = ["iris.fang@printworks.example"]
        let found = await signals(
            mail(from: "gu.chen@northwind-co.example", to: [Self.work, "iris.fang@printworks.example"], subject: "Kitchen"),
            among: candidates,
            scores: [Self.maple: 4]
        )
        #expect(found.ranked == [Self.northwind, Self.harbor, Self.maple])
    }

    @Test func onlyTheTopThreeAreCandidatesForTheModel() async {
        let extra = SortingCandidate(id: UUID(), name: "Fourth project")
        let found = await signals(mail(from: "a@b.example"), among: Self.candidates + [extra], scores: [extra.id: 1])
        #expect(found.ranked.count == 4)
        #expect(found.topCandidates == [extra.id, Self.harbor, Self.maple])
    }

    // MARK: List mail

    @Test func listMailIsFoundFromHeadersSenderOrFooter() async {
        var input = mail(from: "editor@art-weekly.example", text: "This week in design.")
        input.list = ListMail(listID: "<weekly.art-weekly.example>")
        let found = await signals(input)
        #expect(found.listMail == .listID)
        #expect(!found.hasProjectPeople)
        #expect(await signals(mail(from: "noreply@tickets.example")).listMail == .noReplySender)
        #expect(await signals(mail(from: "editor@art-weekly.example", text: "Unsubscribe at any time.")).listMail == .unsubscribeText)
        #expect(await signals(mail(from: "editor@art-weekly.example", text: "See you soon.")).listMail == nil)
    }
}
