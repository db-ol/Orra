import Foundation
import Testing
@testable import Orra

/// The grouping of Suggested Projects in code, and the read of Needs a Project from the
/// store. The people, companies and mail are made up for these tests, at .example
/// addresses and at a shared mail provider.
@Suite(.timeLimit(.minutes(1)))
struct ProjectSuggestionsTests {
    static let me = "me@studio.example"
    static let own = [me, "me@gmail.com"]
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// An email from `from` to `to` on `day`, the root of its own thread unless `parent`
    /// names the email it answers. Headers are "Name <address>" or an address.
    static func mail(
        _ id: String,
        from: String,
        to: [String] = [me],
        subject: String = "Hello",
        text: String = "",
        day: Double = 0,
        parent: String? = nil,
        root: String? = nil,
        mailbox: String? = nil,
        list: ListMail = ListMail(),
        moved: Bool = false
    ) -> ProjectSuggestions.Mail {
        ProjectSuggestions.Mail(
            messageID: id, date: start.addingTimeInterval(day * 86_400), sender: person(from), recipients: to.map(person),
            subject: subject, text: text, mailbox: mailbox, inReplyTo: parent.map { [$0] } ?? [],
            references: parent.map { [$0] } ?? [], threadRoot: root ?? parent ?? id, list: list, movedByUser: moved)
    }

    static func person(_ header: String) -> ProjectSuggestions.Person {
        let name = header.contains("<") ? header.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" : ""
        return ProjectSuggestions.Person(name: name, address: ProjectsAddress.normalized(header) ?? header)
    }

    static func groups(_ mail: [ProjectSuggestions.Mail], projects: [SortingCandidate] = [], dismissed: Set<String> = [], own: [String] = own) async -> [ProjectSuggestions.Group] {
        await ProjectSuggestions.groups(in: mail, ownAddresses: own, projects: projects, dismissed: dismissed)
    }

    /// Four mails of one client, in two threads and from two people, and three of another.
    static let twoClients: [ProjectSuggestions.Mail] = [
        mail("h1", from: "Mei Tan <mei@harbor.example>", subject: "The lobby quote", day: 1),
        mail("h2", from: me, to: ["Mei Tan <mei@harbor.example>"], subject: "Re: The lobby quote", day: 2, parent: "h1"),
        mail("h3", from: "Lu Wen <lu@harbor.example>", subject: "Site visit", day: 3),
        mail("h4", from: "Mei Tan <mei@harbor.example>", subject: "Lamps", day: 4),
        mail("k1", from: "Kai Moss <kai@kiln.example>", subject: "Tiles", day: 1),
        mail("k2", from: "Kai Moss <kai@kiln.example>", subject: "Glaze samples", day: 2),
        mail("k3", from: "Kai Moss <kai@kiln.example>", subject: "Kiln schedule", day: 5),
        mail("b1", from: "Bank <alerts@bank.example>", subject: "Your statement", day: 3),
    ]

    // MARK: Groups

    @Test func mailGroupsByTheDomainOfTheOtherSide() async throws {
        let groups = await Self.groups(Self.twoClients)
        #expect(groups.map(\.id) == ["domain:harbor.example", "domain:kiln.example"])
        let harbor = try #require(groups.first)
        #expect(harbor.domains == ["harbor.example"])
        #expect(harbor.people == [
            ProjectSuggestions.Person(name: "Mei Tan", address: "mei@harbor.example"),
            ProjectSuggestions.Person(name: "Lu Wen", address: "lu@harbor.example"),
        ])
        #expect(harbor.mailbox == nil)
        // Newest first, the reply the user sent among them.
        #expect(harbor.messageIDs == ["h4", "h3", "h2", "h1"])
        #expect(harbor.takes == ["h1", "h2", "h3", "h4"])
        #expect(harbor.fallbackName == "harbor.example")
        #expect(groups[1].takes == ["k1", "k2", "k3"])
    }

    @Test func aPersonAtASharedProviderAnchorsAGroupWithoutADomain() async throws {
        let mail = [
            Self.mail("a1", from: "Ana Ruiz <ana@gmail.com>", subject: "Venue", day: 1),
            Self.mail("a2", from: "Ana Ruiz <ana@gmail.com>", subject: "Menu", day: 2),
            Self.mail("a3", from: Self.me, to: ["ana@gmail.com"], subject: "Guests", day: 3),
            Self.mail("o1", from: "Olu <olu@gmail.com>", subject: "Camera", day: 2),
        ]
        let groups = await Self.groups(mail)
        #expect(groups.map(\.id) == ["person:ana@gmail.com"])
        #expect(groups.first?.domains == [])
        #expect(groups.first?.people == [ProjectSuggestions.Person(name: "Ana Ruiz", address: "ana@gmail.com")])
        #expect(groups.first?.takes == ["a1", "a2", "a3"])
        #expect(groups.first?.fallbackName == "Ana Ruiz")
    }

    /// Colleagues write about every project, so they hold no group together and a project
    /// made from a suggestion never takes all their mail.
    @Test func colleaguesAtTheUsersDomainNeitherAnchorNorJoin() async throws {
        var mail = Self.twoClients
        mail += [
            Self.mail("c1", from: "Jo <jo@studio.example>", subject: "Lunch", day: 1),
            Self.mail("c2", from: "Jo <jo@studio.example>", subject: "Printer", day: 2),
            Self.mail("c3", from: "Jo <jo@studio.example>", subject: "Holidays", day: 3),
            Self.mail("h5", from: Self.me, to: ["mei@harbor.example", "Jo <jo@studio.example>"], subject: "Plan", day: 6),
        ]
        let groups = await Self.groups(mail)
        #expect(!groups.contains { $0.id.contains("jo@studio.example") || $0.id == "domain:studio.example" })
        let harbor = try #require(groups.first { $0.id == "domain:harbor.example" })
        #expect(!harbor.people.contains { $0.address == "jo@studio.example" })
        #expect(harbor.takes.contains("h5"))
        #expect(!harbor.takes.contains("c1"))
    }

    /// A distributor who writes to the client and the user, with too little mail of their
    /// own, joins the client's group, and the project made from it takes their mail.
    @Test func aSmallGroupJoinsTheGroupItSharesAThreadWith() async throws {
        var mail = Self.twoClients
        mail += [
            Self.mail("d1", from: "Ola Grant <ola@port.example>", to: ["mei@harbor.example", Self.me], subject: "Distributor login", day: 5),
            Self.mail("d2", from: "Mei Tan <mei@harbor.example>", to: ["ola@port.example", Self.me], subject: "Re: Distributor login", day: 6, parent: "d1"),
            Self.mail("d3", from: "Ola Grant <ola@port.example>", subject: "Any news?", day: 8),
        ]
        let groups = await Self.groups(mail)
        #expect(!groups.contains { $0.id == "domain:port.example" })
        let harbor = try #require(groups.first { $0.id == "domain:harbor.example" })
        #expect(harbor.people.contains(ProjectSuggestions.Person(name: "Ola Grant", address: "ola@port.example")))
        #expect(harbor.domains == ["harbor.example"])
        #expect(Set(harbor.messageIDs).isSuperset(of: ["d1", "d2", "d3"]))
        #expect(Set(harbor.takes).isSuperset(of: ["d1", "d2", "d3"]))
    }

    @Test func aMailboxTheUserFilesIntoAnchorsAGroupAndIsLinked() async throws {
        var mail = Self.twoClients
        mail += [
            Self.mail("l1", from: "a@one.example", subject: "Lamp sketch", day: 1, mailbox: "Work/Clients/Lamp"),
            Self.mail("l2", from: "b@two.example", subject: "Lamp shade", day: 2, mailbox: "Work/Clients/Lamp"),
            Self.mail("l3", from: "c@three.example", subject: "Lamp base", day: 3, mailbox: "Work/Clients/Lamp"),
        ]
        let groups = await Self.groups(mail)
        let lamp = try #require(groups.first { $0.id == "mailbox:Work/Clients/Lamp" })
        #expect(lamp.mailbox == "Work/Clients/Lamp")
        #expect(lamp.domains == [])
        #expect(lamp.takes == ["l1", "l2", "l3"])
        #expect(lamp.fallbackName == "Lamp")

        // A mailbox that holds most of the mail, such as an imported one, sorts nothing.
        let imported = Self.twoClients.map { email in
            var email = email
            email.mailbox = "/Import/test"
            return email
        }
        #expect(await Self.groups(imported).map(\.id) == ["domain:harbor.example", "domain:kiln.example"])
        // Nor does one a project links already.
        let linked = SortingCandidate(id: UUID(), name: "Lamp", mailboxes: ["Work/Clients/Lamp"])
        #expect(!(await Self.groups(mail, projects: [linked])).contains { $0.mailbox != nil })
    }

    @Test func threadsLeftOverGroupByAWordTheirSubjectsShare() async throws {
        let mail = [
            Self.mail("w1", from: "ana@gmail.com", subject: "Wedding venue", day: 1),
            Self.mail("w2", from: "bo@qq.com", subject: "Re: Wedding photos", day: 2),
            Self.mail("w3", from: "cy@outlook.com", subject: "Fwd: the wedding cake", day: 3),
            Self.mail("x1", from: "dee@gmail.com", subject: "Photos from the trip", day: 4),
        ]
        let groups = await Self.groups(mail)
        #expect(groups.map(\.id) == ["word:wedding"])
        #expect(Set(groups.first?.people.map(\.address) ?? []) == ["ana@gmail.com", "bo@qq.com", "cy@outlook.com"])
        #expect(groups.first?.takes.count == 3)
        // Two threads are not enough, and Re: and Fwd: are no words.
        #expect(await Self.groups(Array(mail.prefix(2))).isEmpty)
        let replies = (1...3).map { Self.mail("r\($0)", from: "p\($0)@gmail.com", subject: "Re: Fwd: \($0)", day: Double($0)) }
        #expect(await Self.groups(replies).isEmpty)
    }

    @Test func movedListAndProjectMailIsLeftOut() async throws {
        var mail = Self.twoClients
        mail += [
            Self.mail("h0", from: "mei@harbor.example", subject: "Personal", day: 0.5, moved: true),
            Self.mail("n1", from: "news@letters.example", subject: "Issue 1", day: 1, list: ListMail(listID: "<weekly.letters.example>")),
            Self.mail("n2", from: "news@letters.example", subject: "Issue 2", day: 2, list: ListMail(listID: "<weekly.letters.example>")),
            Self.mail("n3", from: "news@letters.example", subject: "Issue 3", day: 3, list: ListMail(listID: "<weekly.letters.example>")),
        ]
        let groups = await Self.groups(mail)
        #expect(groups.map(\.id) == ["domain:harbor.example", "domain:kiln.example"])
        #expect(!groups[0].messageIDs.contains("h0"))
        #expect(!groups[0].takes.contains("h0"))

        // A project that names the domain, a person or a sender rule already.
        let kiln = SortingCandidate(id: UUID(), name: "Kiln", domains: ["kiln.example"])
        #expect(await Self.groups(mail, projects: [kiln]).map(\.id) == ["domain:harbor.example"])
        let mei = SortingCandidate(id: UUID(), name: "Mei", people: [SortingCandidate.Person(name: "Mei", address: "mei@harbor.example")])
        let lu = SortingCandidate(id: UUID(), name: "Lu", rules: [.sender("lu@harbor.example")])
        #expect(await Self.groups(mail, projects: [mei, lu]).map(\.id) == ["domain:kiln.example"])
    }

    @Test func dismissedSuggestionsAndAnUnknownUserGiveNone() async {
        let dismissed: Set<String> = [ProjectSuggestions.dismissalKey(.domain("harbor.example"))]
        #expect(await Self.groups(Self.twoClients, dismissed: dismissed).map(\.id) == ["domain:kiln.example"])
        #expect(await Self.groups(Self.twoClients, own: []).isEmpty)
        #expect(await Self.groups(Self.twoClients, own: ["not an address"]).isEmpty)
    }

    @Test func theDismissalKeyHoldsNoAddress() {
        let key = ProjectSuggestions.dismissalKey(.person("ana@gmail.com"))
        #expect(key.count == 64)
        #expect(key.allSatisfy { $0.isHexDigit })
        #expect(!key.contains("ana"))
        #expect(key != ProjectSuggestions.dismissalKey(.domain("ana@gmail.com")))
    }

    @Test func suggestionsAreOrderedByWhatTheyTakeAndCapped() async {
        var mail: [ProjectSuggestions.Mail] = []
        for client in 0..<10 {
            for index in 0..<(3 + client % 4) {
                mail.append(Self.mail("c\(client)-\(index)", from: "p@client\(client).example", subject: "Work \(index)", day: Double(index)))
            }
        }
        let groups = await Self.groups(mail)
        #expect(groups.count == ProjectSuggestions.maximumSuggestions)
        #expect(groups.map(\.takes.count) == groups.map(\.takes.count).sorted(by: >))
        #expect(groups.first?.takes.count == 6)
    }

    @Test func aGroupIsInTheLanguageMostOfItsMailIsIn() async throws {
        let mail = [
            Self.mail("z1", from: "何经理 <he@print.example>", subject: "报价单", text: "林老师您好，附件是台历的报价单，请查收。", day: 1),
            Self.mail("z2", from: "何经理 <he@print.example>", subject: "合同", text: "合同已经盖章，下周寄出。", day: 2),
            Self.mail("z3", from: "he@print.example", subject: "Invoice", text: "Please find the invoice attached.", day: 3),
        ]
        #expect(try #require(await Self.groups(mail).first).language == .zh)
        #expect(try #require(await Self.groups(Array(Self.twoClients.prefix(4))).first).language == .en)
    }

    // MARK: What a project would take

    /// A reply follows its thread into the new project although nothing names its sender,
    /// and an email that a project of the user names more exactly stays out.
    @Test func takesFollowsThreadsAndYieldsToAMoreExactSetting() async {
        let group = ProjectSuggestions.Group(
            anchor: .domain("harbor.example"), people: [], domains: ["harbor.example"], mailbox: nil,
            messageIDs: [], takes: [], language: .en)
        let existing = SortingCandidate(id: UUID(), name: "Kiln", people: [SortingCandidate.Person(name: "Kai", address: "kai@kiln.example")])
        let mail = [
            Self.mail("t2", from: "Jo <jo@studio.example>", subject: "Re: Lobby", day: 2, parent: "t1"),
            Self.mail("t1", from: "mei@harbor.example", subject: "Lobby", day: 1),
            Self.mail("t3", from: Self.me, to: ["mei@harbor.example", "kai@kiln.example"], subject: "Both", day: 3),
            Self.mail("t4", from: "jo@studio.example", subject: "Unrelated", day: 4),
        ]
        let taken = await ProjectSuggestions.takes(of: group, among: mail, existing: [existing], ownAddresses: Self.own)
        #expect(taken == ["t1", "t2"])
    }

    // MARK: The store

    @MainActor
    @Test func theStoreGivesTheMailOfNeedsAProjectThatSortingMayFile() async throws {
        let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("ProjectSuggestionsTests-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let store = MailStore(database: try await ProjectsDatabase.open(in: storage))
        let project = UUID()
        try await store.add(project: project)
        func message(_ id: String, day: Double, parent: String? = nil, text: String = "Could you send the plan?") -> MailStore.Message {
            MailStore.Message(
                messageID: id, mailbox: "Work/Clients", date: Self.start.addingTimeInterval(day * 86_400),
                sender: MailStore.Person(name: "Mei Tan", address: "mei@harbor.example"),
                to: [MailStore.Person(name: "Me", address: Self.me)], cc: [MailStore.Person(name: "Lu", address: "lu@harbor.example")],
                subject: "Lobby", inReplyTo: parent.map { [$0] } ?? [], references: parent.map { [$0] } ?? [],
                list: ListMail(listID: "<list.harbor.example>"), text: text, visibleText: text,
                attachments: [MailStore.Attachment(name: "plan.pdf", type: "application/pdf")])
        }
        try await store.save([
            message("a@x.example", day: 1),
            message("b@x.example", day: 2, parent: "a@x.example", text: String(repeating: "长", count: 3_000)),
            message("c@x.example", day: 3),
            message("d@x.example", day: 4),
            message("e@x.example", day: 5),
        ], ownAddresses: [Self.me], at: Self.start)
        // Filed in a project, moved there by the user, and set aside: not in the list.
        #expect(try await store.saveDecision(SortingDecision(project: project, level: .sure, reasons: [.domain]), for: "c@x.example"))
        #expect(try await store.move("d@x.example", to: nil))
        #expect(try await store.saveDecision(SortingDecision(project: nil, level: .setAside, reasons: [.listMail]), for: "e@x.example"))

        let mail = try await store.suggestionMail()
        #expect(mail.map(\.messageID) == ["b@x.example", "a@x.example"])
        let reply = try #require(mail.first)
        #expect(reply.threadRoot == "a@x.example")
        #expect(reply.inReplyTo == ["a@x.example"])
        #expect(reply.references == ["a@x.example"])
        #expect(reply.sender == ProjectSuggestions.Person(name: "Mei Tan", address: "mei@harbor.example"))
        #expect(reply.recipients == [ProjectSuggestions.Person(name: "Me", address: Self.me), ProjectSuggestions.Person(name: "Lu", address: "lu@harbor.example")])
        #expect(reply.mailbox == "Work/Clients")
        #expect(reply.attachmentNames == ["plan.pdf"])
        #expect(reply.list.listIdentifier == "list.harbor.example")
        #expect(reply.text.count == SuggestionPrompt.textLimit * 4)
        #expect(!reply.movedByUser)
        #expect(try await store.suggestionMail(limit: 1).map(\.messageID) == ["b@x.example"])
        await store.close()
    }
}
