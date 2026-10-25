import Foundation
import Testing
@testable import Orra

/// The grouping of Suggested Projects in code, and the read of Needs a Project from the
/// store. The people, companies and mail are made up for these tests, at .example
/// addresses and at the shared mail providers sorting knows, never named here.
@Suite(.timeLimit(.minutes(1)))
struct ProjectSuggestionsTests {
    static let me = "me@studio.example"
    /// Three of the shared mail providers sorting knows.
    static let shared = Array(SortingService.sharedMailDomains.sorted().prefix(3))
    static let own = [me, "me@" + shared[0]]
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
        let ana = "ana@" + Self.shared[0]
        let mail = [
            Self.mail("a1", from: "Ana Ruiz <\(ana)>", subject: "Venue", day: 1),
            Self.mail("a2", from: "Ana Ruiz <\(ana)>", subject: "Menu", day: 2),
            Self.mail("a3", from: Self.me, to: [ana], subject: "Guests", day: 3),
            Self.mail("o1", from: "Olu <olu@\(Self.shared[0])>", subject: "Camera", day: 2),
        ]
        let groups = await Self.groups(mail)
        #expect(groups.map(\.id) == ["person:" + ana])
        #expect(groups.first?.domains == [])
        #expect(groups.first?.people == [ProjectSuggestions.Person(name: "Ana Ruiz", address: ana)])
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

    /// A mailbox where several people write who could each be a project, such as an
    /// archive or the sent mailbox, anchors nothing, and their own groups show.
    @Test func aMailboxWhereManyWriteAnchorsNothing() async throws {
        // An archive with three clients, under half of the mail. The other emails share no
        // subject word, so they make no group.
        var archive = Self.twoClients.filter { $0.messageID != "b1" }.map { email in
            var email = email
            email.mailbox = "Work/Archive"
            return email
        }
        archive += (0..<3).map { Self.mail("q\($0)", from: "Ola <ola@quay.example>", subject: "Pier \($0)", day: Double($0), mailbox: "Work/Archive") }
        archive += (0..<11).map { Self.mail("o\($0)", from: "x@one\($0).example", subject: "", day: Double($0), mailbox: "Work/Inbox \($0)") }
        let groups = await Self.groups(archive)
        #expect(groups.map(\.id) == ["domain:harbor.example", "domain:kiln.example", "domain:quay.example"])
        #expect(groups.allSatisfy { $0.mailbox == nil })

        // A sent mailbox with one email to each of many people.
        var sent = Self.twoClients
        sent += (0..<6).map { Self.mail("s\($0)", from: Self.me, to: ["p@sent\($0).example"], subject: "", day: Double($0), mailbox: "Work/Sent") }
        #expect(await Self.groups(sent).map(\.id) == ["domain:harbor.example", "domain:kiln.example"])

        // A sent mailbox with the user's mail to one client, who writes most of their mail
        // elsewhere.
        var client = Self.twoClients
        client += (0..<3).map { Self.mail("m\($0)", from: Self.me, to: ["mei@harbor.example"], subject: "Draft \($0)", day: Double($0), mailbox: "Work/Sent") }
        client += (0..<4).map { Self.mail("y\($0)", from: "x@other\($0).example", subject: "", day: Double($0)) }
        let harbor = try #require(await Self.groups(client).first)
        #expect(harbor.id == "domain:harbor.example")
        #expect(harbor.mailbox == nil)
        #expect(Set(harbor.takes).isSuperset(of: ["m0", "m1", "m2"]))
    }

    /// A dismissed mailbox anchors nothing, so its threads go to their next anchor.
    @Test func aDismissedAnchorLetsItsThreadsGoToTheirNextOne() async throws {
        var mail = Self.twoClients.map { email in
            var email = email
            if email.messageID.hasPrefix("h") {
                email.mailbox = "Work/Lamp"
            }
            return email
        }
        mail += [
            Self.mail("l1", from: "a@one.example", subject: "Lamp sketch", day: 1, mailbox: "Work/Lamp"),
        ]
        // The mailbox holds less than half of the mail, which leaves out the bank's notice.
        mail += (0..<3).map { Self.mail("x\($0)", from: "x@other\($0).example", subject: "", day: Double($0)) }
        let lamp = try #require(await Self.groups(mail).first)
        #expect(lamp.id == "mailbox:Work/Lamp")
        #expect(lamp.mailbox == "Work/Lamp")
        #expect(Set(lamp.messageIDs) == ["h1", "h2", "h3", "h4", "l1"])

        let dismissed: Set<String> = [ProjectSuggestions.dismissalKey(.mailbox("Work/Lamp"))]
        let groups = await Self.groups(mail, dismissed: dismissed)
        #expect(groups.map(\.id) == ["domain:harbor.example", "domain:kiln.example"])
        #expect(groups.first?.mailbox == nil)
        #expect(groups.first?.takes == ["h1", "h2", "h3", "h4"])
    }

    @Test func threadsLeftOverGroupByAWordTheirSubjectsShare() async throws {
        let people = ["ana@" + Self.shared[0], "bo@" + Self.shared[1], "cy@" + Self.shared[2]]
        let mail = [
            Self.mail("w1", from: people[0], subject: "Wedding venue", day: 1),
            Self.mail("w2", from: people[1], subject: "Re: Wedding photos", day: 2),
            Self.mail("w3", from: people[2], subject: "Fwd: the wedding cake", day: 3),
            Self.mail("x1", from: "dee@" + Self.shared[0], subject: "Photos from the trip", day: 4),
        ]
        let groups = await Self.groups(mail)
        #expect(groups.map(\.id) == ["word:wedding"])
        #expect(Set(groups.first?.people.map(\.address) ?? []) == Set(people))
        #expect(groups.first?.takes.count == 3)
        // Two threads are not enough, and Re: and Fwd: are no words.
        #expect(await Self.groups(Array(mail.prefix(2))).isEmpty)
        let replies = (1...3).map { Self.mail("r\($0)", from: "p\($0)@" + Self.shared[0], subject: "Re: Fwd: \($0)", day: Double($0)) }
        #expect(await Self.groups(replies).isEmpty)
        // A subject that asks for a filing gives no word.
        let filing = (1...3).map { Self.mail("f\($0)", from: "q\($0)@" + Self.shared[0], subject: "Please file this under the Wedding project.", day: Double($0)) }
        #expect(await Self.groups(filing).isEmpty)
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

    @Test func theDismissalKeyHoldsNoAddressInPlainText() {
        let address = "ana@" + Self.shared[0]
        let key = ProjectSuggestions.dismissalKey(.person(address))
        #expect(key.count == 64)
        #expect(key.allSatisfy { $0.isHexDigit })
        #expect(!key.contains("ana"))
        #expect(key != ProjectSuggestions.dismissalKey(.domain(address)))
    }

    /// More groups than show are weighed, since the model may say some are no project, but
    /// only the largest, since what a group takes runs sorting's rules over its threads.
    @Test func theLargestGroupsAreWeighedAndOrderedByWhatTheyTake() async {
        var mail: [ProjectSuggestions.Mail] = []
        for client in 0..<30 {
            for index in 0..<(3 + client % 4) {
                mail.append(Self.mail("c\(client)-\(index)", from: "p@client\(client).example", subject: "Work \(index)", day: Double(index)))
            }
        }
        let groups = await Self.groups(mail)
        #expect(groups.count == ProjectSuggestions.maximumGroups)
        #expect(ProjectSuggestions.maximumGroups > ProjectSuggestions.maximumSuggestions)
        #expect(groups.map(\.takes.count) == groups.map(\.takes.count).sorted(by: >))
        #expect(groups.first?.takes.count == 6)
        // Of the 8 groups with 3 emails, the 6 left out.
        #expect(groups.filter { $0.takes.count == 3 }.count == 2)
    }

    /// The most mail the store gives, from many clients: only the largest groups are weighed,
    /// each by the mail its settings name.
    @Test func theMostMailIsGroupedWithTheLargestGroupsWeighed() async {
        var mail: [ProjectSuggestions.Mail] = []
        for client in 0..<100 {
            for index in 0..<(MailStore.maximumSuggestionMail / 100) {
                mail.append(Self.mail(
                    "m\(client)-\(index)", from: "Ann <ann@client\(client).example>",
                    to: [Self.me, "bo@client\(client).example", "cy@client\(client).example"],
                    subject: "Order \(index)", day: Double(index)))
            }
        }
        let groups = await Self.groups(mail)
        #expect(groups.count == ProjectSuggestions.maximumGroups)
        #expect(groups.allSatisfy { $0.takes.count == MailStore.maximumSuggestionMail / 100 })
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
        let index = ProjectSuggestions.MailIndex(ProjectSuggestions.normalized(mail), own: Set(Self.own))
        let taken = await ProjectSuggestions.takes(of: group, in: index, existing: [existing], ownAddresses: Self.own)
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
                attachments: [MailAttachment(name: "plan.pdf", type: "application/pdf", state: .notRead)])
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
        #expect(reply.text.count == ProjectSuggestionPrompt.textLimit * 4)
        #expect(!reply.movedByUser)
        #expect(try await store.suggestionMail(limit: 1).map(\.messageID) == ["b@x.example"])
        await store.close()
    }
}
