import Foundation
import Synchronization
import Testing
@testable import Orra

/// The Mail bridge over a fake sender, which answers each request as a test says and never
/// sends an Apple Event: how error codes and a hanging permission check come out, what the
/// bridge remembers of the permission, and how Mail's answers become values.
struct MailBridgeTests {
    private typealias Code = MailEvents.Code
    private typealias Specifier = MailEvents.Specifier
    private typealias Value = MailEvents.Value
    private typealias Request = MailEvents.Request

    private static let account = Specifier.textID(Code.account, "7A31-account", of: .application)
    private static let archive = Specifier.name(Code.mailbox, "Archive", of: account)
    private static let mailbox = MailMailbox(kind: .mailbox, reference: archive, name: "Archive", account: "Work")
    private static let message = MailMessageRef(id: 4217, mailbox: mailbox)

    // MARK: Errors and the permission

    @Test func errorCodesTellWhatHappened() async {
        let cases: [(code: Int, running: Bool, error: MailBridgeError)] = [
            (-1712, true, .timedOut),
            (-1743, true, .denied),
            (-1744, true, .notAsked),
            (-1728, true, .notFound),
            (-600, true, .notAnswered(code: -600)),
            (-609, true, .notAnswered(code: -609)),
            (-600, false, .mailNotRunning),
            (-609, false, .mailNotRunning),
            (-10000, true, .failed(code: -10000)),
        ]
        for item in cases {
            let mail = FakeMail()
            mail.isRunning = item.running
            mail.answer(.get(.property(Code.source, of: Self.message.reference)), with: .failure(.init(code: item.code)))
            let bridge = MailBridge(events: mail.events())
            await #expect(throws: item.error) { try await bridge.source(Self.message) }
        }
    }

    @Test func eventsTellThePermissionAndOtherFailuresKeepIt() async throws {
        let mail = FakeMail()
        let bridge = MailBridge(events: mail.events())
        let headers = Request.get(.property(Code.allHeaders, of: Self.message.reference))
        #expect(bridge.lastPermission() == nil)

        mail.answer(headers, with: .failure(.init(code: -1744)))
        _ = try? await bridge.headers(Self.message)
        #expect(bridge.lastPermission() == .notAsked)

        mail.answer(headers, with: .failure(.init(code: -1743)))
        _ = try? await bridge.headers(Self.message)
        #expect(bridge.lastPermission() == .denied)

        mail.answer(headers, with: .failure(.init(code: -1712)))
        _ = try? await bridge.headers(Self.message)
        #expect(bridge.lastPermission() == .denied)

        mail.answer(headers, with: .success(.text("Subject: Q4")))
        #expect(try await bridge.headers(Self.message) == "Subject: Q4")
        #expect(bridge.lastPermission() == .allowed)
        #expect(mail.permissionChecks == [])
    }

    /// -600 means that Mail does not run only while it does not. From a Mail that runs it
    /// is no answer, as for the events, so Settings says to try again, not to open Mail.
    @Test func permissionAnswersAreRemembered() async {
        let answers: [(status: Int, mailRunning: Bool, permission: MailPermission)] = [
            (0, true, .allowed), (-1743, true, .denied), (-1744, true, .notAsked), (-600, false, .mailNotRunning),
            (-600, true, .unknown), (-50, true, .unknown),
        ]
        for answer in answers {
            let mail = FakeMail()
            mail.isRunning = answer.mailRunning
            let bridge = MailBridge(events: mail.events(permission: { _ in answer.status }))
            #expect(await bridge.permission(false) == answer.permission)
            #expect(bridge.lastPermission() == answer.permission)
            #expect(bridge.lastPermission() == answer.permission)
            #expect(mail.permissionChecks == [false])
        }
    }

    @Test func onlyAskTrueMayLetMacOSAsk() async {
        let mail = FakeMail()
        let bridge = MailBridge(events: mail.events(permission: { ask in ask ? 0 : -1744 }))
        #expect(await bridge.permission(false) == .notAsked)
        #expect(await bridge.permission(true) == .allowed)
        #expect(mail.permissionChecks == [false, true])
    }

    /// A check that never answers stops at its limit as unknown, whether it asks or not.
    @Test(arguments: [false, true])
    func aHangingPermissionCheckIsUnknown(ask: Bool) async {
        let mail = FakeMail()
        let hanging = mail.events(permission: { _ in
            try? await Task.sleep(for: .seconds(3_600))
            return 0
        })
        let bridge = MailBridge(events: hanging, permissionLimit: { _ in .milliseconds(50) })
        #expect(await bridge.permission(ask) == .unknown)
        #expect(bridge.lastPermission() == .unknown)
    }

    @Test func aCheckThatAsksWaitsLongerForTheUser() {
        #expect(MailBridge.permissionLimit(ask: false) == .seconds(5))
        #expect(MailBridge.permissionLimit(ask: true) == .seconds(120))
    }

    // MARK: Reading

    @Test func listingReadsEveryFieldOfARange() async throws {
        let mail = FakeMail()
        let messages = Specifier.range(Code.message, 1, 2, of: MailMailbox.inbox.reference)
        let received = Date(timeIntervalSince1970: 1_760_000_000)
        mail.answerListing(of: messages, ids: [[11, 12]], extra: [
            Code.messageID: .list([.text("<q4.figures@harbor.example>"), .text(" 7f2@mail.harbor.example ")]),
            Code.dateReceived: .list([.date(received), .missing]),
            Code.sender: .list([.text("Mei Tan <mei.tan@harbor.example>"), .text("noreply@news.example")]),
            Code.subject: .list([.text("Q4 figures"), .missing]),
            Code.messageSize: .list([.integer(1_200), .integer(34_000)]),
        ], to: .list([.list([.text("Lin.Ko@Riverbend.example"), .text("not an address")]), .list([])]),
           cc: .list([.missing, .list([.text("ana@harbor.example")])]))

        let listing = try await MailBridge(events: mail.events()).listing(.inbox, 1...2)
        #expect(listing == [
            MailListing(
                message: MailMessageRef(id: 11, mailbox: .inbox), messageID: "q4.figures@harbor.example",
                dateReceived: received, sender: "Mei Tan <mei.tan@harbor.example>", subject: "Q4 figures",
                to: ["lin.ko@riverbend.example"], cc: [], size: 1_200
            ),
            MailListing(
                message: MailMessageRef(id: 12, mailbox: .inbox), messageID: "7f2@mail.harbor.example",
                dateReceived: nil, sender: "noreply@news.example", subject: "",
                to: [], cc: ["ana@harbor.example"], size: 34_000
            ),
        ])
        #expect(mail.asked.count == 9)
        #expect(mail.asked.allSatisfy { $0.event == .get && $0.timeout == 30 })
    }

    /// New mail moves the older messages down. The ids read at the end show it, and the
    /// listing reads the range again.
    @Test func listingReadsAgainWhenNewMailMovesThePositions() async throws {
        let mail = FakeMail()
        let messages = Specifier.range(Code.message, 1, 2, of: MailMailbox.inbox.reference)
        mail.answerListing(of: messages, ids: [[11, 12], [10, 11], [10, 11], [10, 11]])
        let listing = try await MailBridge(events: mail.events()).listing(.inbox, 1...2)
        #expect(listing.map(\.message.id) == [10, 11])
        #expect(mail.asked.count == 18)
    }

    @Test func listingGivesUpWhenMailKeepsChanging() async {
        let mail = FakeMail()
        let messages = Specifier.range(Code.message, 1, 2, of: MailMailbox.inbox.reference)
        mail.answerListing(of: messages, ids: [[1, 2], [3, 4], [5, 6], [7, 8]])
        await #expect(throws: MailBridgeError.changedWhileReading) {
            try await MailBridge(events: mail.events()).listing(.inbox, 1...2)
        }
    }

    @Test func aFieldWithTheWrongCountIsRefused() async {
        let mail = FakeMail()
        let messages = Specifier.range(Code.message, 1, 2, of: MailMailbox.inbox.reference)
        mail.answerListing(of: messages, ids: [[11, 12]], extra: [Code.subject: .list([.text("Q4 figures")])])
        await #expect(throws: MailBridgeError.unexpectedReply) {
            try await MailBridge(events: mail.events()).listing(.inbox, 1...2)
        }
    }

    @Test func aListingOfOneMessageTakesItsRecipientsFlat() async throws {
        let mail = FakeMail()
        let messages = Specifier.range(Code.message, 5, 5, of: Self.archive)
        mail.answerListing(of: messages, ids: [[31]], to: .list([.text("a@harbor.example"), .text("b@harbor.example")]))
        let listing = try await MailBridge(events: mail.events()).listing(Self.mailbox, 5...5)
        #expect(listing.map(\.to) == [["a@harbor.example", "b@harbor.example"]])
        #expect(listing.first?.message == MailMessageRef(id: 31, mailbox: Self.mailbox))
    }

    @Test func aRangeBeforeTheFirstMessageAsksNothing() async {
        let mail = FakeMail()
        await #expect(throws: MailBridgeError.unexpectedReply) {
            try await MailBridge(events: mail.events()).listing(.inbox, 0...3)
        }
        #expect(mail.asked.isEmpty)
    }

    @Test func countHeadersAndSourceReadOneValueEach() async throws {
        let mail = FakeMail()
        mail.answer(.count(Code.message, in: Self.archive), with: .success(.integer(42)))
        mail.answer(.get(.property(Code.allHeaders, of: Self.message.reference)), with: .success(.text("From: Mei Tan")))
        mail.answer(.get(.property(Code.source, of: Self.message.reference)), with: .success(.text("From: Mei Tan\r\n\r\nHello")))
        let bridge = MailBridge(events: mail.events())
        #expect(try await bridge.count(Self.mailbox) == 42)
        #expect(try await bridge.headers(Self.message) == "From: Mei Tan")
        #expect(try await bridge.source(Self.message) == "From: Mei Tan\r\n\r\nHello")
        #expect(mail.asked.map(\.timeout) == [30, 10, 10])

        mail.answer(.count(Code.message, in: Self.archive), with: .success(.text("42")))
        await #expect(throws: MailBridgeError.unexpectedReply) { try await bridge.count(Self.mailbox) }
    }

    @Test func accountsGiveTheirAddressesAndFullName() async throws {
        let mail = FakeMail()
        let every = Specifier.every(Code.account, of: .application)
        mail.answer(.get(.property(Code.name, of: every)), with: .success(.list([.text("Work"), .text("Home")])))
        mail.answer(.get(.property(Code.emailAddresses, of: every)), with: .success(.list([
            .list([.text("Mei.Tan@Harbor.example"), .text("mt@harbor.example")]),
            .list([.text("mei@home.example")]),
        ])))
        mail.answer(.get(.property(Code.fullName, of: every)), with: .success(.list([.text("Mei Tan"), .missing])))
        let accounts = try await MailBridge(events: mail.events()).accounts()
        #expect(accounts == [
            MailAccountInfo(name: "Work", addresses: ["mei.tan@harbor.example", "mt@harbor.example"], fullName: "Mei Tan"),
            MailAccountInfo(name: "Home", addresses: ["mei@home.example"], fullName: ""),
        ])
    }

    @Test func mailboxesListTheTwoOfAllAccountsThenEachAccountsTree() async throws {
        let mail = FakeMail()
        let inbox = Specifier.name(Code.mailbox, "INBOX", of: Self.account)
        let year = Specifier.name(Code.mailbox, "Archive/2026", of: Self.account)
        let imported = Specifier.name(Code.mailbox, "Imported", of: .application)
        let accounts = Specifier.every(Code.account, of: .application)
        mail.answer(.get(accounts), with: .success(.list([.reference(Self.account)])))
        mail.answer(.get(.property(Code.name, of: accounts)), with: .success(.list([.text("Work")])))
        mail.answerMailboxes(in: Self.account, [(inbox, "INBOX"), (Self.archive, "Archive")])
        mail.answerMailboxes(in: Self.archive, [(year, "2026")])
        mail.answerMailboxes(in: .application, [(imported, "Imported")])

        let mailboxes = try await MailBridge(events: mail.events()).mailboxes()
        #expect(mailboxes.map(\.kind) == [.inbox, .sent, .mailbox, .mailbox, .mailbox, .mailbox])
        #expect(mailboxes.map(\.reference) == [
            MailMailbox.inbox.reference, MailMailbox.sent.reference, inbox, Self.archive, year, imported,
        ])
        #expect(mailboxes.map(\.name) == ["", "", "INBOX", "Archive", "Archive/2026", "Imported"])
        #expect(mailboxes.map(\.account) == [nil, nil, "Work", "Work", "Work", nil])
        // A mailbox with no mailboxes in it takes one request, not two.
        for leaf in [inbox, year, imported] {
            #expect(!mail.asked.contains(.get(.property(Code.name, of: .every(Code.mailbox, of: leaf)))))
        }
    }

    /// Mail may list a mailbox in its account and again in its parent. It shows once, under
    /// the name with its parent.
    @Test func aMailboxListedTwiceShowsOnceWithItsParent() async throws {
        let mail = FakeMail()
        let year = Specifier.name(Code.mailbox, "Archive/2026", of: Self.account)
        let accounts = Specifier.every(Code.account, of: .application)
        mail.answer(.get(accounts), with: .success(.list([.reference(Self.account)])))
        mail.answer(.get(.property(Code.name, of: accounts)), with: .success(.list([.text("Work")])))
        mail.answerMailboxes(in: Self.account, [(Self.archive, "Archive"), (year, "2026")])
        mail.answerMailboxes(in: Self.archive, [(year, "2026")])

        let mailboxes = try await MailBridge(events: mail.events()).mailboxes()
        #expect(mailboxes.map(\.name) == ["", "", "Archive", "Archive/2026"])
    }

    /// Mail may list every nested mailbox flat in its account, in any order. Each still takes
    /// the names of all the mailboxes it sits in.
    @Test(arguments: [false, true])
    func aMailboxThreeLevelsDownKeepsEveryParent(reversed: Bool) async throws {
        let mail = FakeMail()
        let year = Specifier.name(Code.mailbox, "Archive/2026", of: Self.account)
        let quarter = Specifier.name(Code.mailbox, "Archive/2026/Q1", of: Self.account)
        let accounts = Specifier.every(Code.account, of: .application)
        mail.answer(.get(accounts), with: .success(.list([.reference(Self.account)])))
        mail.answer(.get(.property(Code.name, of: accounts)), with: .success(.list([.text("Work")])))
        let flat = [(Self.archive, "Archive"), (year, "2026"), (quarter, "Q1")]
        mail.answerMailboxes(in: Self.account, reversed ? flat.reversed() : flat)
        mail.answerMailboxes(in: Self.archive, [(year, "2026")])
        mail.answerMailboxes(in: year, [(quarter, "Q1")])

        let mailboxes = try await MailBridge(events: mail.events()).mailboxes()
        let names = Dictionary(mailboxes.map { ($0.reference, $0.name) }, uniquingKeysWith: { first, _ in first })
        #expect(mailboxes.count == 5)
        #expect(names[Self.archive] == "Archive")
        #expect(names[year] == "Archive/2026")
        #expect(names[quarter] == "Archive/2026/Q1")
    }

    @Test func attachmentsGiveNamesTypesSizesAndWhetherDownloaded() async throws {
        let mail = FakeMail()
        let every = Specifier.every(Code.attachment, of: Self.message.reference)
        mail.answer(.get(.property(Code.name, of: every)), with: .success(.list([.text("Quote v2.pdf"), .text("logo.png")])))
        mail.answer(.get(.property(Code.mimeType, of: every)), with: .success(.list([.text("Application/PDF; name=\"Quote v2.pdf\""), .text("image/png")])))
        mail.answer(.get(.property(Code.fileSize, of: every)), with: .success(.list([.integer(48_213), .missing])))
        mail.answer(.get(.property(Code.downloaded, of: every)), with: .success(.list([.boolean(true), .boolean(false)])))
        let attachments = try await MailBridge(events: mail.events()).attachments(Self.message)
        #expect(attachments == [
            MailAttachmentInfo(name: "Quote v2.pdf", mimeType: "application/pdf", size: 48_213, isDownloaded: true),
            MailAttachmentInfo(name: "logo.png", mimeType: "image/png", size: nil, isDownloaded: false),
        ])
    }

    @Test func aMessageWithoutAttachmentsTakesOneRequest() async throws {
        let mail = FakeMail()
        #expect(try await MailBridge(events: mail.events()).attachments(Self.message) == [])
        #expect(mail.asked.count == 1)
    }

    @Test func theMailboxOfAMessageComparesWithTheChosenOne() async throws {
        let mail = FakeMail()
        let inboxMessage = MailMessageRef(id: 9, mailbox: .inbox)
        mail.answer(.get(.property(Code.mailbox, of: inboxMessage.reference)), with: .success(.reference(Self.archive)))
        let mailbox = try await MailBridge(events: mail.events()).mailbox(inboxMessage)
        #expect(mailbox == Self.mailbox)
        #expect(mailbox.name.isEmpty)
    }

    @Test func selectionKeepsOnlyMessages() async throws {
        let mail = FakeMail()
        mail.answer(.get(.property(Code.selection, of: .application)), with: .success(.list([
            .reference(Self.message.reference), .reference(Self.archive), .text("Archive"),
        ])))
        #expect(try await MailBridge(events: mail.events()).selection() == [Self.message])
    }

    @Test(arguments: [false, true])
    func replyAsksMailForAReplyWindow(all: Bool) async throws {
        let mail = FakeMail()
        try await MailBridge(events: mail.events()).reply(Self.message, all)
        #expect(mail.asked == [.reply(to: Self.message.reference, all: all)])
    }

    /// A mailbox is the same whatever names the picker gave it, and keeps its reference
    /// through JSON, as the chosen mailboxes will be saved.
    @Test func mailboxesCompareByReference() throws {
        let bare = MailMailbox(kind: .mailbox, reference: Self.archive, name: "", account: nil)
        #expect(bare == Self.mailbox)
        #expect(Set([bare, Self.mailbox]).count == 1)
        #expect(MailMailbox.inbox != MailMailbox.sent)
        let saved = try JSONEncoder().encode([Self.mailbox, .inbox])
        let loaded = try JSONDecoder().decode([MailMailbox].self, from: saved)
        #expect(loaded == [Self.mailbox, .inbox])
        #expect(loaded.map(\.name) == ["Archive", ""])
    }

    // MARK: The fake

    /// Mail as a test plays it. Each request gets the answers set for it in turn, the last
    /// one again and again, and an empty list when none is set. Records what was asked.
    private final class FakeMail: Sendable {
        private struct State {
            var answers: [Request: [Result<Value, MailEvents.Failure>]] = [:]
            var asked: [Request] = []
            var isRunning = true
            var permissionChecks: [Bool] = []
        }

        private let state = Mutex(State())

        var isRunning: Bool {
            get { state.withLock { $0.isRunning } }
            set { state.withLock { $0.isRunning = newValue } }
        }

        var asked: [Request] {
            state.withLock { $0.asked }
        }

        var permissionChecks: [Bool] {
            state.withLock { $0.permissionChecks }
        }

        func answer(_ request: Request, with answers: Result<Value, MailEvents.Failure>...) {
            state.withLock { $0.answers[request] = answers }
        }

        /// The answers of a listing of a range, with the ids it reads at its start and end
        /// in turn, and empty text or no recipients for the fields not given.
        func answerListing(
            of messages: Specifier,
            ids: [[Int]],
            extra: [FourCharCode: Value] = [:],
            to: Value? = nil,
            cc: Value? = nil
        ) {
            let count = ids[0].count
            let empty = Value.list(Array(repeating: .missing, count: count))
            let idAnswers = ids.map { Result<Value, MailEvents.Failure>.success(.list($0.map { .integer($0) })) }
            state.withLock { $0.answers[.get(.property(Code.id, of: messages))] = idAnswers }
            for code in [Code.messageID, Code.dateReceived, Code.sender, Code.subject] {
                answer(.get(.property(code, of: messages)), with: .success(extra[code] ?? empty))
            }
            let sizes = Value.list(Array(repeating: .integer(0), count: count))
            answer(.get(.property(Code.messageSize, of: messages)), with: .success(extra[Code.messageSize] ?? sizes))
            let noRecipients = Value.list(Array(repeating: .list([]), count: count))
            answer(.get(.property(Code.address, of: .every(Code.toRecipient, of: messages))), with: .success(to ?? noRecipients))
            answer(.get(.property(Code.address, of: .every(Code.ccRecipient, of: messages))), with: .success(cc ?? noRecipients))
        }

        /// The mailboxes directly in a container, with their own names.
        func answerMailboxes(in container: Specifier, _ mailboxes: [(Specifier, String)]) {
            let every = Specifier.every(Code.mailbox, of: container)
            answer(.get(every), with: .success(.list(mailboxes.map { .reference($0.0) })))
            answer(.get(.property(Code.name, of: every)), with: .success(.list(mailboxes.map { .text($0.1) })))
        }

        func events(permission: @escaping @Sendable (Bool) async -> Int = { _ in 0 }) -> MailEvents {
            MailEvents(
                isRunning: { self.isRunning },
                send: { request in try self.send(request) },
                permission: { ask in
                    self.state.withLock { $0.permissionChecks.append(ask) }
                    return await permission(ask)
                }
            )
        }

        private func send(_ request: Request) throws -> Value {
            let answer = state.withLock { state -> Result<Value, MailEvents.Failure> in
                state.asked.append(request)
                guard var answers = state.answers[request], let first = answers.first else { return .success(.list([])) }
                if answers.count > 1 {
                    answers.removeFirst()
                    state.answers[request] = answers
                }
                return first
            }
            return try answer.get()
        }
    }
}
