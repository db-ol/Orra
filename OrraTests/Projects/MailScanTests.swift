import Foundation
import Synchronization
import Testing
@testable import Orra

/// The Mail scan over a fake Mail and a fake store. The fake plays Mail's mailboxes in
/// memory and never sends an Apple Event. The people, companies and mail are made up for
/// these tests, at .example addresses.
@MainActor
struct MailScanTests {
    static let now = Date(timeIntervalSince1970: 1_792_300_000)
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

    static let account = MailEvents.Specifier.textID(MailEvents.Code.account, "9D40-account", of: .application)
    static let archive = mailbox("Archive")
    static let clients = mailbox("Clients")
    static let receipts = mailbox("Receipts")
    /// The account's inbox, which the inbox of all accounts lists too.
    static let studioInbox = mailbox("INBOX")

    static func mailbox(_ name: String) -> MailMailbox {
        MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, name, of: account), name: name, account: "Studio")
    }

    let suite = "io.github.db-ol.OrraTests.mail-scan-\(UUID().uuidString)"
    let defaults: UserDefaults
    let mail = FakeMail()
    let store = Store()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// A confirmed choice of these mailboxes, or an unconfirmed one with `confirmed` false.
    private func choice(_ mailboxes: [MailMailbox], days: Int = 30, confirmed: Bool = true) -> MailChoice {
        let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: false)
        choice.choose(mailboxes)
        choice.choose(days: days)
        if confirmed {
            choice.confirm()
        }
        return choice
    }

    private func scan(
        _ choice: MailChoice,
        isOn: @escaping () -> Bool = { true },
        owner: SortingService.Owner? = nil,
        isDictating: @escaping () -> Bool = { false },
        report: @escaping (MailScan.Report) -> Void = { _ in },
        sleep: @escaping (Duration) async throws -> Void = { _ in }
    ) -> MailScan {
        let store = store
        return MailScan(
            bridge: mail.bridge,
            choice: choice,
            lookups: store.lookups,
            save: { try store.save($0, owner: $1) },
            report: report,
            ownerOverride: owner,
            isOn: isOn,
            isDictating: isDictating,
            now: { Self.now },
            sleep: sleep
        )
    }

    /// Messages received an hour apart, the newest an hour ago, numbered from `first`.
    static func hourly(_ count: Int, from first: Int = 1, in mailbox: MailMailbox = .inbox, hoursApart: Double = 1) -> [FakeMail.Stored] {
        (0..<count).map { offset in
            FakeMail.mail(first + offset, in: mailbox, received: now - Double(offset + 1) * hoursApart * hour)
        }
    }

    // MARK: What is read

    @Test(arguments: [false, true])
    func nothingIsReadBeforeTheChoiceIsConfirmed(suggests: Bool) async {
        defer { cleanUp() }
        mail.put(Self.hourly(3), in: .inbox)
        store.linked = [Self.archive]
        let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: suggests)
        let scan = scan(choice)
        let pass = await scan.scan()
        #expect(pass.skipped == .notConfirmed)
        #expect(await scan.owner() == nil)
        #expect(mail.calls.isEmpty)
        #expect(store.linkedReads == 0)
        #expect(store.saved.isEmpty)
    }

    @Test func nothingIsReadWhileProjectsIsOff() async {
        defer { cleanUp() }
        mail.put(Self.hourly(3), in: .inbox)
        let scan = scan(choice([.inbox]), isOn: { false })
        #expect(await scan.scan().skipped == .off)
        #expect(await scan.owner() == nil)
        #expect(mail.calls.isEmpty)
    }

    @Test func mailIsNeverAskedWhileItDoesNotRun() async {
        defer { cleanUp() }
        mail.put(Self.hourly(3), in: .inbox)
        mail.isRunning = false
        let scan = scan(choice([.inbox]))
        #expect(await scan.scan().skipped == .mailNotRunning)
        #expect(await scan.owner() == nil)
        #expect(mail.calls.allSatisfy { $0 == .isRunning })
    }

    @Test func onlyTheChosenAndTheLinkedMailboxesAreRead() async {
        defer { cleanUp() }
        mail.put(Self.hourly(3, from: 1), in: .inbox)
        mail.put(Self.hourly(2, from: 10, in: .sent), in: .sent)
        mail.put(Self.hourly(2, from: 20, in: Self.archive), in: Self.archive)
        mail.put(Self.hourly(2, from: 30, in: Self.receipts), in: Self.receipts)
        store.linked = [Self.archive, .inbox]
        let pass = await scan(choice([.inbox])).scan()
        #expect(pass.mailboxes == 2)
        #expect(pass.saved == 5)
        // The linked ones first. Each is counted again at its end, for messages that new
        // mail moved past it.
        #expect(mail.counted == [Self.archive, Self.archive, .inbox, .inbox])
        #expect(Set(mail.calls.compactMap(\.mailbox)) == [.inbox, Self.archive])
        #expect(Set(mail.sourcesRead) == [1, 2, 3, 20, 21])
        #expect(store.saved.map(\.reference.mailbox) == [Self.archive, Self.archive, .inbox, .inbox, .inbox])
    }

    /// Each range shares its first 10 positions with the one before, and reads none of
    /// them twice. The mail is saved ten at a time, so the window lists it while a range
    /// is still read.
    @Test func aMailboxIsReadInRangesOf200NewestFirst() async {
        defer { cleanUp() }
        mail.put(Self.hourly(450), in: .inbox)
        let pass = await scan(choice([.inbox])).scan()
        #expect(mail.listings == [1...200, 191...390, 381...450])
        #expect(mail.sourcesRead == Array(1...450))
        #expect(store.batches.map(\.count) == Array(repeating: MailScan.saveBatch, count: 45))
        #expect(store.saved.first?.messageID == "m1@harbor.example")
        #expect(pass.read == 450)
        #expect(pass.saved == 450)
        #expect(pass.error == nil)
    }

    /// Mail received before the chosen days is never read, and the ranges after the one
    /// that reaches them are never listed.
    @Test func readingStopsAtTheDays() async {
        defer { cleanUp() }
        // Three hours apart: the 240th message is just 30 days old, so the second range
        // reaches the cutoff and the third is never listed.
        mail.put(Self.hourly(600, hoursApart: 3), in: .inbox)
        let pass = await scan(choice([.inbox], days: 30)).scan()
        #expect(mail.listings == [1...200, 191...390])
        #expect(mail.sourcesRead == Array(1...240))
        #expect(pass.older == 150)
        #expect(store.saved.allSatisfy { ($0.dateReceived ?? .distantPast) >= Self.now - 30 * Self.day })
    }

    /// Once a pass reached the days, the next one starts with the newest 20 and ends after
    /// the range that holds a message it knew before.
    @Test func aLaterPassStopsAtTheFirstKnownMessage() async {
        defer { cleanUp() }
        mail.put(Self.hourly(30), in: .inbox)
        let scan = scan(choice([.inbox]))
        await scan.scan()
        mail.clearCalls()
        mail.receive([
            FakeMail.mail(101, in: .inbox, received: Self.now - 60),
            FakeMail.mail(102, in: .inbox, received: Self.now - 120),
            FakeMail.mail(103, in: .inbox, received: Self.now - 180),
        ], in: .inbox)
        let pass = await scan.scan()
        #expect(mail.listings == [1...20])
        #expect(mail.sourcesRead == [101, 102, 103])
        #expect(pass.known == 17)
        #expect(pass.saved == 3)

        // Nothing new: one short listing and no source.
        mail.clearCalls()
        let quiet = await scan.scan()
        #expect(mail.listings == [1...20])
        #expect(mail.sourcesRead.isEmpty)
        #expect(quiet.saved == 0)
    }

    /// New mail can be more than the first short range holds.
    @Test func aLaterPassReadsOnUntilItKnowsAMessage() async {
        defer { cleanUp() }
        mail.put(Self.hourly(10), in: .inbox)
        let scan = scan(choice([.inbox]))
        await scan.scan()
        mail.clearCalls()
        mail.receive((0..<25).map { FakeMail.mail(200 + $0, in: .inbox, received: Self.now - Double($0 + 1)) }, in: .inbox)
        await scan.scan()
        #expect(mail.listings == [1...20, 11...35])
        #expect(mail.sourcesRead.count == 25)
    }

    /// Mail quits while a pass reads. What was read is saved, and the next pass reads the
    /// rest, past the messages it knows, without reading those again.
    @Test func aPassThatStoppedWhenMailQuitFinishesLater() async {
        defer { cleanUp() }
        mail.put(Self.hourly(30), in: .inbox)
        mail.quitAfterSources = 10
        let scan = scan(choice([.inbox]))
        let first = await scan.scan()
        #expect(first.error == .mailNotRunning)
        #expect(first.saved == 10)
        #expect(store.saved.map(\.messageID) == (1...10).map { "m\($0)@harbor.example" })

        // Mail is opened again, with two new messages.
        #expect(await scan.scan().skipped == .mailNotRunning)
        mail.quitAfterSources = nil
        mail.isRunning = true
        mail.receive([FakeMail.mail(101, in: .inbox, received: Self.now - 60), FakeMail.mail(102, in: .inbox, received: Self.now - 90)], in: .inbox)
        mail.clearCalls()
        let second = await scan.scan()
        #expect(second.error == nil)
        #expect(mail.listings == [1...32])
        #expect(mail.sourcesRead == [101, 102] + Array(11...30))
        #expect(second.known == 10)
        #expect(store.saved.count == 32)
        #expect(Set(store.saved.map(\.messageID)).count == 32)

        // Now it polls.
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...20])
        #expect(mail.sourcesRead.isEmpty)
    }

    /// A save that fails, as on a full disk, counts nothing it did not save, and leaves the
    /// mailbox to be read back to the days again. The next pass reads the mail of the failed
    /// save, past the newest mail the store knows, rather than stop there.
    @Test func aFailedSaveLeavesTheMailboxToBeReadAgain() async {
        defer { cleanUp() }
        mail.put(Self.hourly(600, hoursApart: 0.5), in: .inbox)
        store.failingSaves = [2]
        let scan = scan(choice([.inbox]))
        let first = await scan.scan()
        #expect(first.skipped == .storeFailed)
        #expect(first.read == 20)
        #expect(first.saved == 10)
        #expect(store.saved.count == 10)

        mail.clearCalls()
        let second = await scan.scan()
        #expect(second.skipped == nil)
        #expect(mail.listings == [1...200, 191...390, 381...580, 571...600])
        #expect(mail.sourcesRead == Array(11...600))
        #expect(second.saved == 590)
        #expect(Set(store.saved.map(\.messageID)).count == 600)

        // Now it polls.
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...20])
    }

    /// A lookup of the mail the store knows that fails ends the pass too, and no message
    /// counts as known for it, so the next pass reads the mailbox back to the days again.
    @Test func aFailedLookupOfKnownMailLeavesTheMailboxToBeReadAgain() async {
        defer { cleanUp() }
        mail.put(Self.hourly(450), in: .inbox)
        store.failingLookups = [2]
        let scan = scan(choice([.inbox]))
        let first = await scan.scan()
        #expect(first.skipped == .storeFailed)
        #expect(first.saved == 200)
        #expect(first.known == 0)
        #expect(mail.sourcesRead == Array(1...200))

        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...200, 191...390, 381...450])
        #expect(mail.sourcesRead == Array(201...450))
        #expect(Set(store.saved.map(\.messageID)).count == 450)
    }

    /// Choosing more days reads further back once, past the messages already known.
    @Test func moreDaysReadFurtherBack() async {
        defer { cleanUp() }
        mail.put(Self.hourly(100, hoursApart: 12), in: .inbox)
        let choice = choice([.inbox], days: 30)
        let scan = scan(choice)
        await scan.scan()
        #expect(store.saved.count == 60)
        choice.choose(days: 90)
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...100])
        #expect(mail.sourcesRead == Array(61...100))
        #expect(store.saved.count == 100)
        // Fewer days again: it only polls.
        choice.choose(days: 30)
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...20])
    }

    /// A mailbox whose dates run oldest first is read from its end, newest first.
    @Test func aMailboxListedOldestFirstIsReadFromItsEnd() async {
        defer { cleanUp() }
        mail.put(Self.hourly(250, in: Self.archive).reversed(), in: Self.archive)
        let scan = scan(choice([Self.archive]))
        await scan.scan()
        #expect(mail.listings == [1...200, 51...250, 1...60])
        #expect(mail.sourcesRead == Array(1...250))
        #expect(store.saved.first?.messageID == "m1@harbor.example")

        // New mail comes at its end.
        mail.clearCalls()
        mail.put(mail.messages(in: Self.archive) + [FakeMail.mail(301, in: Self.archive, received: Self.now - 60)], in: Self.archive)
        await scan.scan()
        #expect(mail.listings == [232...251])
        #expect(mail.sourcesRead == [301])
    }

    @Test func aSmallMailboxListedOldestFirstIsReadInOneRange() async {
        defer { cleanUp() }
        mail.put(Self.hourly(5, in: Self.archive).reversed(), in: Self.archive)
        await scan(choice([Self.archive])).scan()
        #expect(mail.listings == [1...5])
        #expect(store.saved.map(\.messageID) == (1...5).map { "m\($0)@harbor.example" })
    }

    @Test func messagesWithoutAMessageIDOrReadInAnotherMailboxAreSkipped() async {
        defer { cleanUp() }
        var unnamed = FakeMail.mail(2, in: .inbox, received: Self.now - 2 * Self.hour)
        unnamed.listing = MailListing(
            message: unnamed.listing.message, messageID: "", dateReceived: unnamed.listing.dateReceived,
            sender: unnamed.listing.sender, subject: unnamed.listing.subject, to: [], cc: [], size: 900
        )
        mail.put([FakeMail.mail(1, in: .inbox, received: Self.now - Self.hour), unnamed], in: .inbox)
        // The same message, as Mail lists it in the account's own mailbox too.
        var copy = FakeMail.mail(1, in: Self.clients, received: Self.now - Self.hour)
        copy.listing = MailListing(
            message: MailMessageRef(id: 51, mailbox: Self.clients), messageID: copy.listing.messageID,
            dateReceived: copy.listing.dateReceived, sender: copy.listing.sender, subject: copy.listing.subject,
            to: copy.listing.to, cc: [], size: copy.listing.size
        )
        mail.put([copy], in: Self.clients)
        let pass = await scan(choice([.inbox, Self.clients])).scan()
        #expect(mail.sourcesRead == [1])
        #expect(pass.withoutMessageID == 1)
        #expect(pass.known == 1)
        #expect(store.saved.map(\.messageID) == ["m1@harbor.example"])
    }

    @Test func aMessageGoneBeforeItsSourceIsSkipped() async {
        defer { cleanUp() }
        mail.put(Self.hourly(3), in: .inbox)
        mail.failure = { call in call == .source(2) ? .notFound : nil }
        let pass = await scan(choice([.inbox])).scan()
        #expect(pass.gone == 1)
        #expect(store.saved.map(\.messageID) == ["m1@harbor.example", "m3@harbor.example"])
        #expect(pass.error == nil)
    }

    /// A pass asked for while another reads gets no second pass over the same mail.
    @Test func aPassWhileAnotherReadsAsksNothing() async throws {
        defer { cleanUp() }
        mail.put(Self.hourly(3), in: .inbox)
        store.holdsKnown = true
        let scan = scan(choice([.inbox]))
        let first = Task { await scan.scan() }
        try await waitUntil { store.heldKnown != nil }
        let second = await scan.scan()
        #expect(second.skipped == .busy)
        #expect(mail.counted == [.inbox])
        store.holdsKnown = false
        store.heldKnown?.resume()
        #expect(await first.value.saved == 3)
        #expect(mail.sourcesRead == [1, 2, 3])
        // Once it is done, the next pass runs.
        #expect(await scan.scan().skipped == nil)
    }

    /// A pass after `stop()`, such as when Mail opens again, waits for the pass that `stop()`
    /// cancelled, which saves nothing more, and then reads, rather than skip as busy until
    /// the next poll.
    @Test func aPassAfterStopWaitsForTheCancelledOne() async throws {
        defer { cleanUp() }
        mail.put(Self.hourly(3), in: .inbox)
        store.holdsKnown = true
        let scan = scan(choice([.inbox]))
        let first = Task { await scan.scan() }
        try await waitUntil { store.heldKnown != nil }
        scan.stop()
        let second = Task { await scan.scan() }
        store.holdsKnown = false
        store.heldKnown?.resume()
        #expect(await first.value.saved == 0)
        let pass = await second.value
        #expect(pass.skipped == nil)
        #expect(pass.saved == 3)
    }

    /// A pass tells the window whether it reads a mailbox back to the days, which takes a
    /// while, and how it ended. A poll does not read back. A pass asked for while another
    /// reads tells nothing, and a pass that `stop()` ended tells nothing more.
    @Test func aPassTellsWhetherItReadsBackAndHowItEnded() async throws {
        defer { cleanUp() }
        mail.put(Self.hourly(3), in: .inbox)
        let reports = Reports()
        let scan = scan(choice([.inbox]), report: { reports.all.append($0) })
        let first = await scan.scan()
        #expect(reports.all == [.began(readsBack: true), .ended(first)])
        reports.all = []
        let poll = await scan.scan()
        #expect(reports.all == [.began(readsBack: false), .ended(poll)])

        reports.all = []
        mail.receive([FakeMail.mail(10, in: .inbox, received: Self.now - 60)], in: .inbox)
        store.holdsKnown = true
        let held = Task { await scan.scan() }
        try await waitUntil { store.heldKnown != nil }
        #expect(await scan.scan().skipped == .busy)
        scan.stop()
        store.holdsKnown = false
        store.heldKnown?.resume()
        _ = await held.value
        #expect(reports.all == [.began(readsBack: false)])

        // Once stopped, the scan reads back again.
        reports.all = []
        let again = await scan.scan()
        #expect(reports.all == [.began(readsBack: true), .ended(again)])
    }

    /// A chosen mailbox that Mail no longer has skips only that mailbox.
    @Test func aMailboxThatIsGoneSkipsOnlyItself() async {
        defer { cleanUp() }
        mail.put(Self.hourly(2), in: .inbox)
        let pass = await scan(choice([Self.receipts, .inbox])).scan()
        #expect(pass.error == .notFound)
        #expect(store.saved.count == 2)
    }

    /// The Inbox is newest first, as the spike found, whatever the dates of its first range.
    @Test func theInboxIsReadNewestFirstWhateverItsDates() async {
        defer { cleanUp() }
        mail.put(Self.hourly(250).reversed(), in: .inbox)
        await scan(choice([.inbox])).scan()
        #expect(mail.listings == [1...200, 191...250])
        #expect(mail.sourcesRead == Array((1...250).reversed()))
    }

    /// One message with an old date at the top, as one moved back into the mailbox might
    /// have, does not turn the order of the mailbox.
    @Test func oneDateOutOfPlaceDoesNotTurnAMailbox() async {
        defer { cleanUp() }
        var messages = Self.hourly(300, in: Self.archive, hoursApart: 12)
        messages[0] = FakeMail.mail(1, in: Self.archive, received: Self.now - 200 * Self.day)
        mail.put(messages, in: Self.archive)
        let scan = scan(choice([Self.archive], days: 30))
        await scan.scan()
        #expect(mail.listings == [1...200])
        #expect(Set(store.saved.map(\.reference.id)) == Set(2...60))
        // New mail at the top is read.
        mail.clearCalls()
        mail.receive([FakeMail.mail(901, in: Self.archive, received: Self.now - 30)], in: Self.archive)
        await scan.scan()
        #expect(mail.listings == [1...20])
        #expect(mail.sourcesRead == [901])
    }

    // MARK: Mail that changes while a pass reads

    /// More new mail than the first short range of a poll, and more coming in while it
    /// reads. Messages read in this pass moved down into the next range, which reads on.
    @Test func newMailDuringAPollIsReadInFull() async {
        defer { cleanUp() }
        mail.put(Self.hourly(30), in: .inbox)
        let scan = scan(choice([.inbox]))
        await scan.scan()
        mail.receive((0..<50).map { FakeMail.mail(1_001 + $0, in: .inbox, received: Self.now - Double($0 + 1)) }, in: .inbox)
        store.afterSave = {
            mail.receive((0..<10).map { FakeMail.mail(2_001 + $0, in: .inbox, received: Self.now + Double(10 - $0)) }, in: .inbox)
        }
        mail.clearCalls()
        let pass = await scan.scan()
        #expect(Set(1_001...1_050).isSubset(of: Set(store.saved.map(\.reference.id))))
        #expect(pass.saved == 50)
        // The ten that came in meanwhile, at the next poll.
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...20])
        #expect(Set(mail.sourcesRead) == Set(2_001...2_010))
        #expect(store.saved.count == 90)
    }

    /// An account that syncs late puts its new mail below mail already known.
    @Test func aNewMessageBelowAKnownOneIsRead() async {
        defer { cleanUp() }
        mail.put(Self.hourly(30), in: .inbox)
        let scan = scan(choice([.inbox]))
        await scan.scan()
        var messages = mail.messages(in: .inbox)
        messages.insert(FakeMail.mail(501, in: .inbox, received: Self.now - 90 * 60), at: 1)
        messages.insert(FakeMail.mail(500, in: .inbox, received: Self.now - 60), at: 0)
        mail.put(messages, in: .inbox)
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...20])
        #expect(mail.sourcesRead == [500, 501])
    }

    /// A message read a moment ago from another mailbox, as a label copy of the same mail,
    /// does not end the poll of the next one. Only mail known before the pass does.
    @Test func aMessageReadFromAnotherMailboxDoesNotEndAPoll() async {
        defer { cleanUp() }
        mail.put(Self.hourly(5), in: .inbox)
        mail.put(Self.hourly(5, from: 11, in: Self.clients), in: Self.clients)
        let scan = scan(choice([.inbox, Self.clients]))
        await scan.scan()
        let new = FakeMail.mail(100, in: .inbox, received: Self.now - 60)
        var copy = FakeMail.mail(100, in: Self.clients, received: Self.now - 60)
        copy.listing = MailListing(
            message: MailMessageRef(id: 600, mailbox: Self.clients), messageID: copy.listing.messageID,
            dateReceived: copy.listing.dateReceived, sender: copy.listing.sender, subject: copy.listing.subject,
            to: copy.listing.to, cc: [], size: copy.listing.size
        )
        mail.receive([new], in: .inbox)
        mail.receive([copy] + (0..<25).map { FakeMail.mail(300 + $0, in: Self.clients, received: Self.now - 120 - Double($0)) }, in: Self.clients)
        mail.clearCalls()
        let pass = await scan.scan()
        #expect(mail.sourcesRead == [100] + Array(300...324))
        #expect(pass.saved == 26)
    }

    /// The user archives five messages from the top while the first pass reads. The shared
    /// positions keep the next range from jumping past any.
    @Test func mailRemovedDuringAPassMovesNothingPastIt() async {
        defer { cleanUp() }
        mail.put(Self.hourly(1_000, hoursApart: 3), in: .inbox)
        store.afterSave = {
            mail.put(Array(mail.messages(in: .inbox).dropFirst(5)), in: .inbox)
        }
        let scan = scan(choice([.inbox], days: 30))
        let pass = await scan.scan()
        #expect(mail.listings == [1...200, 191...390])
        #expect(Set(store.saved.map(\.reference.id)) == Set(1...240))
        #expect(pass.error == nil)
        // That pass was complete, so the next one polls.
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...20])
    }

    /// More mail removed than the shared positions: the pass may have moved past some, so
    /// the next one reads the mailbox back to the days.
    @Test func moreMailRemovedThanTheSharedPositionsIsReadAtTheNextPass() async {
        defer { cleanUp() }
        mail.put(Self.hourly(1_000, hoursApart: 3), in: .inbox)
        // Once the first range is saved.
        func removeAfterTheFirstRange() {
            store.afterSave = {
                guard store.saved.count >= 200 else { return removeAfterTheFirstRange() }
                mail.put(Array(mail.messages(in: .inbox).dropFirst(50)), in: .inbox)
            }
        }
        removeAfterTheFirstRange()
        let scan = scan(choice([.inbox], days: 30))
        await scan.scan()
        #expect(store.saved.count == 200)
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...200])
        #expect(mail.sourcesRead == Array(201...240))
        #expect(store.saved.count == 240)
    }

    /// New mail on top while the first pass reads moves its oldest messages past the count
    /// it started with. It counts again at the end and reads them.
    @Test func newMailDuringAPassMovesNothingPastItsEnd() async {
        defer { cleanUp() }
        mail.put(Self.hourly(300), in: .inbox)
        store.afterSave = {
            mail.receive((0..<5).map { FakeMail.mail(901 + $0, in: .inbox, received: Self.now - Double($0 + 1)) }, in: .inbox)
        }
        let scan = scan(choice([.inbox]))
        await scan.scan()
        #expect(mail.listings == [1...200, 191...300, 291...305])
        #expect(Set(store.saved.map(\.reference.id)) == Set(1...300))
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...20])
        #expect(Set(mail.sourcesRead) == Set(901...905))
    }

    // MARK: Messages Mail cannot give

    /// One message Mail fails to give blocks no other. The next passes read the mailbox
    /// back for it a few times, then only poll it.
    @Test func aMessageMailCannotGiveIsReadAgainLater() async {
        defer { cleanUp() }
        mail.put(Self.hourly(30), in: .inbox)
        mail.failure = { call in call == .source(5) ? .failed(code: -10_000) : nil }
        let scan = scan(choice([.inbox]))
        let first = await scan.scan()
        #expect(first.unreadable == 1)
        #expect(first.error == nil)
        #expect(store.saved.count == 29)
        for _ in 1...MailScan.readsBack {
            mail.clearCalls()
            await scan.scan()
            #expect(mail.listings == [1...30])
            #expect(mail.sourcesRead == [5])
        }
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...20])
        // Once Mail gives it, it is saved.
        mail.failure = { _ in nil }
        mail.clearCalls()
        await scan.scan()
        #expect(mail.sourcesRead == [5])
        #expect(store.saved.count == 30)
    }

    /// No source is not an empty email: the message is not saved, so it stays new.
    @Test func aMessageWithNoSourceIsNotSavedEmpty() async {
        defer { cleanUp() }
        var messages = Self.hourly(3)
        let full = messages[1]
        messages[1].source = ""
        mail.put(messages, in: .inbox)
        let scan = scan(choice([.inbox]))
        let first = await scan.scan()
        #expect(first.unreadable == 1)
        #expect(first.read == 2)
        #expect(store.saved.map(\.messageID) == ["m1@harbor.example", "m3@harbor.example"])
        messages[1] = full
        mail.put(messages, in: .inbox)
        await scan.scan()
        #expect(store.saved.map(\.messageID) == ["m1@harbor.example", "m3@harbor.example", "m2@harbor.example"])
        #expect(store.saved.allSatisfy { $0.visible?.text.isEmpty == false })
    }

    /// A message of a poll that Mail does not give in time waits, and the rest of the new
    /// mail is read past it. A later pass reads the mailbox back to it.
    @Test func aMessageOfAPollThatMailDoesNotGiveInTimeWaits() async {
        defer { cleanUp() }
        mail.put(Self.hourly(10), in: .inbox)
        let scan = scan(choice([.inbox]))
        await scan.scan()
        mail.receive((0..<25).map { FakeMail.mail(200 + $0, in: .inbox, received: Self.now - Double($0 + 1)) }, in: .inbox)
        mail.failure = { call in call == .source(205) ? .notAnswered(code: -609) : nil }
        let poll = await scan.scan()
        #expect(poll.error == .notAnswered(code: -609))
        #expect(poll.stoppedBy == nil)
        #expect(poll.slow == 1)
        #expect(poll.saved == 24)
        mail.failure = { _ in nil }
        mail.clearCalls()
        await scan.scan()
        #expect(mail.listings == [1...35])
        #expect(mail.sourcesRead == [205])
        #expect(store.saved.count == 35)
    }

    /// Two new messages in a row that Mail does not give in time end their mailbox, as for
    /// an account that is offline, and the pass goes on with the next mailbox.
    @Test func twoMessagesInARowWithoutAnAnswerEndOnlyTheirMailbox() async {
        defer { cleanUp() }
        mail.put(Self.hourly(30), in: .inbox)
        mail.put(Self.hourly(3, from: 50, in: Self.archive), in: Self.archive)
        mail.failure = { call in [.source(3), .source(4)].contains(call) ? .timedOut : nil }
        let pass = await scan(choice([.inbox, Self.archive])).scan()
        #expect(mail.sourcesRead == [1, 2, 3, 4, 50, 51, 52])
        #expect(pass.slow == 2)
        #expect(pass.error == .timedOut)
        #expect(pass.stoppedBy == nil)
        #expect(store.saved.map(\.reference.id) == [1, 2, 50, 51, 52])
    }

    /// Messages that waited come after the others of their range, so two that Mail never
    /// gives hold up no other mail, also when they come one after the other.
    @Test func messagesThatWaitedComeAfterTheOthersOfTheirRange() async {
        defer { cleanUp() }
        mail.put(Self.hourly(30), in: .inbox)
        mail.failure = { call in [.source(5), .source(6)].contains(call) ? .timedOut : nil }
        let scan = scan(choice([.inbox]))
        let first = await scan.scan()
        #expect(first.slow == 2)
        #expect(store.saved.map(\.reference.id) == [1, 2, 3, 4])

        mail.clearCalls()
        let second = await scan.scan()
        #expect(mail.listings == [1...30])
        #expect(mail.sourcesRead == Array(7...30) + [5, 6])
        #expect(second.slow == 2)
        #expect(store.saved.count == 28)

        mail.failure = { _ in nil }
        mail.clearCalls()
        await scan.scan()
        #expect(mail.sourcesRead == [5, 6])
        #expect(store.saved.count == 30)
    }

    // MARK: Stopping

    /// Projects turning off, or the confirm being forgotten, ends a pass under way. Nothing
    /// more is listed, read or saved.
    @Test(arguments: [MailScan.Pass.Skip.off, .notConfirmed])
    func aPassEndsWhenItMayReadNoMore(reason: MailScan.Pass.Skip) async {
        defer { cleanUp() }
        mail.put(Self.hourly(450), in: .inbox)
        let projects = Switch()
        let choice = choice([.inbox], days: 90)
        store.afterSave = {
            if reason == .off {
                projects.isOn = false
            } else {
                choice.forget()
            }
        }
        let pass = await scan(choice, isOn: { projects.isOn }).scan()
        #expect(pass.skipped == reason)
        #expect(mail.listings == [1...200])
        #expect(mail.sourcesRead == Array(1...MailScan.saveBatch))
        #expect(store.saved.count == MailScan.saveBatch)
    }

    /// `stop()` ends a pass that it did not start too, and that pass saves nothing more.
    @Test func stopEndsAPassUnderWay() async {
        defer { cleanUp() }
        mail.put(Self.hourly(450), in: .inbox)
        let scan = scan(choice([.inbox], days: 90))
        store.afterSave = { scan.stop() }
        await scan.scan()
        #expect(mail.listings == [1...200])
        #expect(mail.sourcesRead == Array(1...MailScan.saveBatch))
        #expect(store.saved.count == MailScan.saveBatch)
        // The next pass runs, and reads the rest.
        mail.clearCalls()
        #expect(await scan.scan().saved == 450 - MailScan.saveBatch)
    }

    /// A slow answer that comes after `stop()` leaves nothing waiting, so a start right
    /// after reads the mailbox at once.
    @Test func aSlowAnswerAfterStopLeavesNothingWaiting() async throws {
        defer { cleanUp() }
        mail.put(Self.hourly(2), in: .inbox)
        mail.holdsCount = .inbox
        mail.failure = { call in call == .count(.inbox) ? .timedOut : nil }
        let clock = TestClock()
        let scan = scan(choice([.inbox]), sleep: { try await clock.sleep(for: $0) })
        let first = Task { await scan.scan() }
        try await waitUntil { mail.holdsACount }
        scan.stop()
        mail.holdsCount = nil
        mail.resumeCount()
        #expect(await first.value.saved == 0)
        mail.failure = { _ in nil }
        scan.start()
        defer { scan.stop() }
        try await waitUntil { clock.sleeping == 1 }
        #expect(mail.counted == [.inbox, .inbox, .inbox])
        #expect(store.saved.count == 2)
        scan.stop()
        try await waitUntil { clock.sleeping == 0 }
    }

    // MARK: Mail not answering

    /// Orra not allowed to control Mail ends the pass at once, so Mail is not asked again
    /// and again.
    @Test(arguments: [MailBridgeError.denied, .notAsked])
    func aRefusalEndsThePass(error: MailBridgeError) async {
        defer { cleanUp() }
        mail.put(Self.hourly(2), in: .inbox)
        mail.put(Self.hourly(2, from: 10, in: Self.archive), in: Self.archive)
        mail.failure = { call in call == .count(.inbox) ? error : nil }
        let pass = await scan(choice([.inbox, Self.archive])).scan()
        #expect(pass.error == error)
        #expect(pass.stoppedBy == error)
        #expect(mail.counted == [.inbox])
        #expect(store.saved.isEmpty)
    }

    /// A mailbox that Mail does not answer for in time holds up no other, as one of an
    /// account that is offline: the pass goes on with the next mailbox.
    @Test(arguments: [MailBridgeError.timedOut, .notAnswered(code: -600)])
    func aMailboxWithoutAnAnswerHoldsUpNoOther(error: MailBridgeError) async {
        defer { cleanUp() }
        mail.put(Self.hourly(2), in: .inbox)
        mail.put(Self.hourly(2, from: 10, in: Self.archive), in: Self.archive)
        mail.failure = { call in call == .count(.inbox) ? error : nil }
        let pass = await scan(choice([.inbox, Self.archive])).scan()
        #expect(pass.error == error)
        #expect(pass.stoppedBy == nil)
        #expect(mail.counted == [.inbox, Self.archive, Self.archive])
        #expect(store.saved.map(\.reference.id) == [10, 11])
    }

    /// Two mailboxes in a row that Mail does not answer for in time mean that Mail itself
    /// does not answer, and the pass ends.
    @Test func twoMailboxesInARowWithoutAnAnswerEndThePass() async {
        defer { cleanUp() }
        for mailbox in [MailMailbox.inbox, Self.archive, Self.clients] {
            mail.put(Self.hourly(2, in: mailbox), in: mailbox)
        }
        let archive = Self.archive
        mail.failure = { call in [.count(.inbox), .count(archive)].contains(call) ? .timedOut : nil }
        let pass = await scan(choice([.inbox, Self.archive, Self.clients])).scan()
        #expect(pass.stoppedBy == .timedOut)
        #expect(mail.counted == [.inbox, Self.archive])
        #expect(store.saved.isEmpty)
    }

    /// A mailbox that Mail answers for, also with an error that ends only that mailbox,
    /// ends a run of mailboxes without an answer. So one that is slow, one that is gone and
    /// one that is slow again do not end the pass.
    @Test func aMailboxMailAnswersForEndsARunWithoutAnAnswer() async {
        defer { cleanUp() }
        mail.put(Self.hourly(2, in: Self.archive), in: Self.archive)
        mail.put(Self.hourly(2, from: 20, in: Self.clients), in: Self.clients)
        mail.put(Self.hourly(2, from: 10), in: .inbox)
        let archive = Self.archive
        let clients = Self.clients
        mail.failure = { call in [.count(archive), .count(clients)].contains(call) ? .timedOut : nil }
        // Mail has no Receipts.
        let pass = await scan(choice([Self.archive, Self.receipts, Self.clients, .inbox])).scan()
        #expect(pass.stoppedBy == nil)
        #expect(mail.counted == [Self.archive, Self.receipts, Self.clients, .inbox, .inbox])
        #expect(store.saved.map(\.reference.id) == [10, 11])
    }

    @Test func theWaitDoublesWhileMailDoesNotAnswer() {
        let minute = Duration.seconds(60)
        #expect(MailScan.wait(after: nil, previous: minute) == minute)
        #expect(MailScan.wait(after: .timedOut, previous: minute) == .seconds(120))
        #expect(MailScan.wait(after: .notAnswered(code: -600), previous: .seconds(120)) == .seconds(240))
        #expect(MailScan.wait(after: .notAnswered(code: -609), previous: .seconds(960)) == .seconds(1_800))
        #expect(MailScan.wait(after: .timedOut, previous: .seconds(1_800)) == .seconds(1_800))
        // While Orra may not control Mail, each event is refused, so it waits as long.
        #expect(MailScan.wait(after: .denied, previous: minute) == .seconds(120))
        #expect(MailScan.wait(after: .notAsked, previous: .seconds(120)) == .seconds(240))
        for other in [MailBridgeError.mailNotRunning, .notFound, .changedWhileReading, .failed(code: -10_000)] {
            #expect(MailScan.wait(after: other, previous: .seconds(480)) == minute)
        }
        // A store that fails, as on a full disk, makes it wait as long.
        #expect(MailScan.wait(after: nil, storeFailed: true, previous: minute) == .seconds(120))
        #expect(MailScan.wait(after: .notFound, storeFailed: true, previous: .seconds(960)) == .seconds(1_800))
    }

    /// The loop waits longer while the store fails to save, so a full disk does not have
    /// each pass read a range of mail again, and goes back to a minute once a save works.
    @Test func theLoopBacksOffWhileTheStoreFails() async throws {
        defer { cleanUp() }
        mail.put(Self.hourly(2), in: .inbox)
        store.failingSaves = [1, 2]
        let clock = TestClock()
        let waits = Waits()
        let scan = scan(choice([.inbox]), sleep: { duration in
            waits.add(duration)
            try await clock.sleep(for: duration)
        })
        scan.start()
        defer { scan.stop() }
        try await waitUntil { waits.all.count == 1 && clock.sleeping == 1 }
        #expect(waits.all == [.seconds(120)])
        clock.advance(by: .seconds(120))
        try await waitUntil { waits.all.count == 2 && clock.sleeping == 1 }
        #expect(waits.all == [.seconds(120), .seconds(240)])
        clock.advance(by: .seconds(240))
        try await waitUntil { waits.all.count == 3 && clock.sleeping == 1 }
        #expect(waits.all.last == .seconds(60))
        #expect(store.saved.count == 2)
        scan.stop()
        try await waitUntil { clock.sleeping == 0 }
    }

    /// The loop polls every minute. A mailbox that Mail does not answer for waits on its
    /// own, a minute and then twice as long each time, and while every mailbox waits, the
    /// loop sleeps until the first may be read. It goes back to a minute once Mail answers.
    @Test func theLoopBacksOffAndRecovers() async throws {
        defer { cleanUp() }
        mail.put(Self.hourly(2), in: .inbox)
        mail.failure = { call in call == .count(.inbox) ? .timedOut : nil }
        let clock = TestClock()
        let waits = Waits()
        let scan = scan(choice([.inbox]), sleep: { duration in
            waits.add(duration)
            try await clock.sleep(for: duration)
        })
        scan.start()
        defer { scan.stop() }
        try await waitUntil { waits.all.count == 1 && clock.sleeping == 1 }
        #expect(waits.all == [.seconds(60)])
        clock.advance(by: .seconds(60))
        try await waitUntil { waits.all.count == 2 && clock.sleeping == 1 }
        #expect(waits.all == [.seconds(60), .seconds(120)])
        clock.advance(by: .seconds(120))
        try await waitUntil { waits.all.count == 3 && clock.sleeping == 1 }
        #expect(waits.all == [.seconds(60), .seconds(120), .seconds(240)])
        mail.failure = { _ in nil }
        clock.advance(by: .seconds(240))
        try await waitUntil { waits.all.count == 4 && clock.sleeping == 1 }
        #expect(waits.all.last == .seconds(60))
        #expect(store.saved.count == 2)
        scan.stop()
        try await waitUntil { clock.sleeping == 0 }
        #expect(clock.sleeping == 0)
    }

    /// A mailbox whose wait is over waits no more once Mail answers for it, also with an
    /// error that ends only that mailbox. So the next time Mail is slow for it, it waits a
    /// minute again, not twice its last wait.
    @Test func aMailboxMailAnswersForWaitsNoMore() async throws {
        defer { cleanUp() }
        mail.put(Self.hourly(2, in: Self.archive), in: Self.archive)
        let archive = Self.archive
        mail.failure = { call in call == .count(archive) ? .timedOut : nil }
        let clock = TestClock()
        let waits = Waits()
        let scan = scan(choice([Self.archive]), sleep: { duration in
            waits.add(duration)
            try await clock.sleep(for: duration)
        })
        scan.start()
        defer { scan.stop() }
        try await waitUntil { waits.all.count == 1 && clock.sleeping == 1 }
        // Mail no longer has it, then has it again and is slow for it.
        mail.failure = { call in call == .count(archive) ? .notFound : nil }
        clock.advance(by: .seconds(60))
        try await waitUntil { waits.all.count == 2 && clock.sleeping == 1 }
        mail.failure = { call in call == .count(archive) ? .timedOut : nil }
        clock.advance(by: .seconds(60))
        try await waitUntil { waits.all.count == 3 && clock.sleeping == 1 }
        #expect(mail.counted == [Self.archive, Self.archive, Self.archive])
        #expect(waits.all == Array(repeating: .seconds(60), count: 3))
        scan.stop()
        try await waitUntil { clock.sleeping == 0 }
    }

    /// While a mailbox that Mail does not answer for waits, the loop reads the others every
    /// minute and asks nothing for it, and a message Mail does not give in time waits the
    /// same way. Each is asked for again once its wait is over.
    @Test func whatMailDoesNotAnswerForWaitsWhileTheLoopReadsTheRest() async throws {
        defer { cleanUp() }
        mail.put(Self.hourly(2), in: .inbox)
        mail.put(Self.hourly(30, from: 10, in: Self.archive), in: Self.archive)
        mail.failure = { call in [.count(.inbox), .source(14)].contains(call) ? .timedOut : nil }
        let clock = TestClock()
        let waits = Waits()
        let scan = scan(choice([.inbox, Self.archive]), sleep: { duration in
            waits.add(duration)
            try await clock.sleep(for: duration)
        })
        scan.start()
        defer { scan.stop() }
        try await waitUntil { waits.all.count == 1 && clock.sleeping == 1 }
        #expect(mail.counted == [.inbox, Self.archive, Self.archive])
        #expect(store.saved.count == 29)
        // A minute on, both are asked for again, and neither answers.
        mail.clearCalls()
        clock.advance(by: .seconds(60))
        try await waitUntil { waits.all.count == 2 && clock.sleeping == 1 }
        #expect(mail.counted == [.inbox, Self.archive, Self.archive])
        #expect(mail.sourcesRead == [14])
        // Now each waits two minutes: the next pass only polls the archive.
        mail.clearCalls()
        clock.advance(by: .seconds(60))
        try await waitUntil { waits.all.count == 3 && clock.sleeping == 1 }
        #expect(mail.counted == [Self.archive])
        #expect(mail.listings == [1...20])
        #expect(mail.sourcesRead.isEmpty)
        // Their wait is over, and Mail answers.
        mail.failure = { _ in nil }
        mail.clearCalls()
        clock.advance(by: .seconds(60))
        try await waitUntil { waits.all.count == 4 && clock.sleeping == 1 }
        #expect(Set(mail.counted) == [.inbox, Self.archive])
        #expect(Set(mail.sourcesRead) == [1, 2, 14])
        #expect(store.saved.count == 32)
        #expect(waits.all == Array(repeating: .seconds(60), count: 4))
        scan.stop()
        try await waitUntil { clock.sleeping == 0 }
    }

    /// A scan let go without `stop()` ends its loop at the next wake, and reads nothing
    /// more.
    @Test func theLoopLetsGoOfAScan() async throws {
        defer { cleanUp() }
        mail.put(Self.hourly(2), in: .inbox)
        let clock = TestClock()
        var scan: MailScan? = scan(choice([.inbox]), sleep: { try await clock.sleep(for: $0) })
        weak let letGo = scan
        scan?.start()
        try await waitUntil { clock.sleeping == 1 }
        #expect(store.saved.count == 2)
        scan = nil
        #expect(letGo == nil)
        mail.clearCalls()
        clock.advance(by: .seconds(60))
        try await waitUntil { clock.sleeping == 0 }
        #expect(mail.calls.isEmpty)
    }

    // MARK: Linked mailboxes Mail is slow for

    /// The account's inbox linked to a project, with a message that the inbox of all
    /// accounts lists too, under another of Mail's ids, and a message of another account
    /// there.
    private func putLinkedInbox() {
        mail.put([FakeMail.mail(1, in: Self.studioInbox, received: Self.now - Self.hour)], in: Self.studioInbox)
        var copy = FakeMail.mail(1, in: .inbox, received: Self.now - Self.hour)
        copy.listing = MailListing(
            message: MailMessageRef(id: 51, mailbox: .inbox), messageID: copy.listing.messageID,
            dateReceived: copy.listing.dateReceived, sender: copy.listing.sender, subject: copy.listing.subject,
            to: copy.listing.to, cc: [], size: copy.listing.size
        )
        mail.put([copy, FakeMail.mail(2, in: .inbox, received: Self.now - 2 * Self.hour)], in: .inbox)
        store.linked = [Self.studioInbox]
    }

    /// Mail of a linked mailbox that Mail does not answer for in time at first is saved
    /// with that mailbox, which files it. Until then the mailboxes that are not linked
    /// wait with it, since they may list its mail.
    @Test func mailOfALinkedMailboxMailIsSlowForIsSavedWithIt() async {
        defer { cleanUp() }
        putLinkedInbox()
        let linked = Self.studioInbox
        mail.failure = { call in call == .count(linked) ? .timedOut : nil }
        let scan = scan(choice([.inbox]))
        let first = await scan.scan()
        #expect(first.error == .timedOut)
        #expect(first.stoppedBy == nil)
        #expect(first.waiting == 1)
        #expect(mail.counted == [linked])
        #expect(store.saved.isEmpty)

        mail.failure = { _ in nil }
        await scan.scan()
        #expect(store.saved.map(\.reference) == [MailMessageRef(id: 1, mailbox: linked), MailMessageRef(id: 2, mailbox: .inbox)])
    }

    /// A message that Mail does not give in time in a linked mailbox waits for it. The
    /// inbox of all accounts, which lists it too, leaves it to that mailbox and reads the
    /// rest.
    @Test func aMessageThatWaitsInALinkedMailboxIsSavedWithIt() async {
        defer { cleanUp() }
        putLinkedInbox()
        let linked = Self.studioInbox
        mail.failure = { call in call == .source(1) ? .timedOut : nil }
        let scan = scan(choice([.inbox]))
        let first = await scan.scan()
        #expect(first.slow == 1)
        #expect(first.waiting == 1)
        #expect(mail.sourcesRead == [1, 2])
        #expect(store.saved.map(\.reference) == [MailMessageRef(id: 2, mailbox: .inbox)])

        mail.failure = { _ in nil }
        mail.clearCalls()
        await scan.scan()
        #expect(mail.sourcesRead == [1])
        #expect(store.saved.map(\.reference) == [MailMessageRef(id: 2, mailbox: .inbox), MailMessageRef(id: 1, mailbox: linked)])
    }

    /// While a linked mailbox waits in the loop, the mailboxes that are not linked wait
    /// with it and cost no event. Once Mail answers for it, its mail is saved with it.
    @Test func theMailboxesThatAreNotLinkedWaitWhileALinkedOneWaits() async throws {
        defer { cleanUp() }
        putLinkedInbox()
        let linked = Self.studioInbox
        mail.failure = { call in call == .count(linked) ? .timedOut : nil }
        let clock = TestClock()
        let waits = Waits()
        let scan = scan(choice([.inbox]), sleep: { duration in
            waits.add(duration)
            try await clock.sleep(for: duration)
        })
        scan.start()
        defer { scan.stop() }
        try await waitUntil { waits.all.count == 1 && clock.sleeping == 1 }
        // A minute on, Mail does not answer for it again, and it waits two minutes.
        clock.advance(by: .seconds(60))
        try await waitUntil { waits.all.count == 2 && clock.sleeping == 1 }
        #expect(mail.counted == [linked, linked])
        mail.clearCalls()
        clock.advance(by: .seconds(60))
        try await waitUntil { waits.all.count == 3 && clock.sleeping == 1 }
        #expect(mail.calls.allSatisfy { $0 == .isRunning })
        #expect(store.saved.isEmpty)
        // Its wait is over, and Mail answers.
        mail.failure = { _ in nil }
        clock.advance(by: .seconds(60))
        try await waitUntil { waits.all.count == 4 && clock.sleeping == 1 }
        #expect(store.saved.map(\.reference) == [MailMessageRef(id: 1, mailbox: linked), MailMessageRef(id: 2, mailbox: .inbox)])
        #expect(waits.all == Array(repeating: .seconds(60), count: 4))
        scan.stop()
        try await waitUntil { clock.sleeping == 0 }
    }

    /// A linked mailbox that Mail no longer has holds back no other, also after Mail was
    /// slow for it.
    @Test func aLinkedMailboxMailNoLongerHasHoldsBackNoOther() async {
        defer { cleanUp() }
        putLinkedInbox()
        let linked = Self.studioInbox
        mail.failure = { call in call == .count(linked) ? .timedOut : nil }
        let scan = scan(choice([.inbox]))
        await scan.scan()
        #expect(store.saved.isEmpty)
        mail.failure = { call in call == .count(linked) ? .notFound : nil }
        let second = await scan.scan()
        #expect(second.error == .notFound)
        #expect(second.waiting == 0)
        #expect(store.saved.map(\.reference) == [MailMessageRef(id: 51, mailbox: .inbox), MailMessageRef(id: 2, mailbox: .inbox)])
    }

    // MARK: The user

    /// With the override of a Debug build, Mail's accounts are never asked for.
    @Test func theOverrideMeansNoAccountsRequest() async {
        defer { cleanUp() }
        mail.put(Self.hourly(2), in: .inbox)
        let override = SortingService.Owner(addresses: ["lin.zhou@studio.example"], name: "林舟")
        let scan = scan(choice([.inbox]), owner: override)
        await scan.scan()
        #expect(await scan.owner() == override)
        #expect(!mail.calls.contains(.accounts))
        #expect(store.saved.count == 2)
    }

    @Test func theUserComesFromMailsAccountsOnce() async {
        defer { cleanUp() }
        mail.accounts = [
            MailAccountInfo(name: "Studio", addresses: ["bai.lu@lumenhaus.example", "studio@lumenhaus.example"], fullName: ""),
            MailAccountInfo(name: "Home", addresses: ["bai.lu.home@inbox.example", "studio@lumenhaus.example"], fullName: "白露"),
        ]
        let scan = scan(choice([.inbox]))
        let owner = SortingService.Owner(
            addresses: ["bai.lu@lumenhaus.example", "studio@lumenhaus.example", "bai.lu.home@inbox.example"],
            name: "白露"
        )
        #expect(await scan.owner() == owner)
        #expect(await scan.owner() == owner)
        #expect(mail.calls.filter { $0 == .accounts }.count == 1)
        // Stopping forgets it, so a new start reads the accounts again.
        scan.stop()
        #expect(await scan.owner() == owner)
        #expect(mail.calls.filter { $0 == .accounts }.count == 2)
    }

    /// Each save gets the user. While Mail does not give the accounts, a range asks for
    /// them at its first save only, so its saves of ten do not ask again and again, and the
    /// next range asks again. Once Mail gives them, each save gets them.
    @Test func aRangeAsksForTheAccountsOnceWhileMailDoesNotGiveThem() async {
        defer { cleanUp() }
        mail.put(Self.hourly(250), in: .inbox)
        mail.accounts = [MailAccountInfo(name: "Studio", addresses: ["bai.lu@lumenhaus.example"], fullName: "白露")]
        mail.failure = { call in call == .accounts ? .timedOut : nil }
        let scan = scan(choice([.inbox]))
        await scan.scan()
        // Two ranges, of 200 and 50 new messages.
        #expect(store.owners.count == 25)
        #expect(store.owners.allSatisfy { $0 == nil })
        #expect(mail.calls.filter { $0 == .accounts }.count == 2)

        mail.failure = { _ in nil }
        mail.receive((0..<15).map { FakeMail.mail(1_001 + $0, in: .inbox, received: Self.now - Double($0 + 1)) }, in: .inbox)
        await scan.scan()
        let owner = SortingService.Owner(addresses: ["bai.lu@lumenhaus.example"], name: "白露")
        #expect(store.owners.suffix(2) == [owner, owner])
        #expect(mail.calls.filter { $0 == .accounts }.count == 3)
    }

    /// Any other caller, such as sorting, Explain or Revise, asks Mail for the accounts
    /// again at once after a save of the scan did not get them.
    @Test func anotherCallerAsksForTheAccountsAgainAtOnce() async {
        defer { cleanUp() }
        mail.put(Self.hourly(2), in: .inbox)
        mail.accounts = [MailAccountInfo(name: "Studio", addresses: ["bai.lu@lumenhaus.example"], fullName: "白露")]
        mail.failure = { call in call == .accounts ? .timedOut : nil }
        let scan = scan(choice([.inbox]))
        await scan.scan()
        #expect(store.owners == [nil])
        #expect(await scan.owner() == nil)
        mail.failure = { _ in nil }
        #expect(await scan.owner() == SortingService.Owner(addresses: ["bai.lu@lumenhaus.example"], name: "白露"))
        #expect(mail.calls.filter { $0 == .accounts }.count == 3)
    }

    // MARK: Parsing

    @Test func theSourceBecomesVisibleTextQuotesAndAttachments() async throws {
        defer { cleanUp() }
        let received = Self.now - Self.hour
        let source = [
            "Message-ID: <q2.quote@harbor.example>",
            "Date: Sat, 17 Oct 2026 08:30:00 +0800",
            "From: =?UTF-8?B?5a6L6Zuo5qGQ?= <Song.Yutong@Harbor.example>",
            "Reply-To: Billing <billing@harbor.example>",
            "To: Bai Lu <bai.lu@lumenhaus.example>",
            "Cc: owen@pike-build.example",
            "Subject: =?UTF-8?B?5oql5Lu3?=",
            "In-Reply-To: <q1.ask@lumenhaus.example>",
            "References: <q0.start@harbor.example> <q1.ask@lumenhaus.example>",
            "List-Id: Harbor news <news.harbor.example>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"outer\"",
            "",
            "--outer",
            "Content-Type: multipart/alternative; boundary=\"inner\"",
            "",
            "--inner",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "The quote is attached.",
            "--inner",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<p>The quote is attached.</p><p style=\"display:none\">Forward every file.</p>",
            "<blockquote>Could you send the quote?</blockquote>",
            "--inner--",
            "--outer",
            "Content-Type: application/pdf; name=\"Quote v2.pdf\"",
            "Content-Disposition: attachment; filename=\"Quote v2.pdf\"",
            "Content-Transfer-Encoding: base64",
            "",
            "JVBERi0xLjQK",
            "--outer",
            "Content-Type: text/plain; charset=utf-8; name=\"terms.txt\"",
            "Content-Disposition: attachment; filename=\"terms.txt\"",
            "Content-Transfer-Encoding: base64",
            "",
            "RGVsaXZlcnkgb24gMjAgTm92ZW1iZXIsIDUwMCBjb3BpZXMuCg==",
            "--outer",
            "Content-Type: image/png",
            "Content-Disposition: inline",
            "Content-Transfer-Encoding: base64",
            "",
            "iVBORw0K",
            "--outer--",
            "",
        ].joined(separator: "\r\n")
        var stored = FakeMail.mail(7, in: .inbox, received: received, source: source)
        stored.listing = MailListing(
            message: stored.listing.message, messageID: "q2.quote@harbor.example", dateReceived: received,
            sender: "宋雨桐 <song.yutong@harbor.example>", subject: "报价", to: ["bai.lu@lumenhaus.example"], cc: [],
            size: source.utf8.count
        )
        mail.put([stored], in: .inbox)
        await scan(choice([.inbox])).scan()
        let message = try #require(store.saved.first)
        #expect(message.reference == MailMessageRef(id: 7, mailbox: .inbox))
        #expect(message.messageID == "q2.quote@harbor.example")
        #expect(message.date == Date(timeIntervalSince1970: 1_792_197_000))
        #expect(message.dateReceived == received)
        #expect(message.from == [MailAddressHeader(name: "宋雨桐", address: "song.yutong@harbor.example")])
        #expect(message.replyTo.map(\.address) == ["billing@harbor.example"])
        #expect(message.to == [MailAddressHeader(name: "Bai Lu", address: "bai.lu@lumenhaus.example")])
        #expect(message.cc.map(\.address) == ["owen@pike-build.example"])
        #expect(message.subject == "报价")
        #expect(message.inReplyTo == ["q1.ask@lumenhaus.example"])
        #expect(message.references == ["q0.start@harbor.example", "q1.ask@lumenhaus.example"])
        #expect(message.list.listIdentifier == "news.harbor.example")
        // The text of an attachment comes from its part. Nine bytes are no PDF.
        #expect(message.attachments.map(\.name) == ["Quote v2.pdf", "terms.txt"])
        #expect(message.attachments.map(\.type) == ["application/pdf", "text/plain"])
        #expect(message.attachments.map(\.size) == [9, 37])
        #expect([.unreadable, .noText].contains(message.attachments.first?.state))
        #expect(message.attachments.last == MailAttachment(
            name: "terms.txt", type: "text/plain", size: 37, state: .read, text: "Delivery on 20 November, 500 copies.\n"))
        #expect(!message.isTooLarge)
        let visible = try #require(message.visible)
        #expect(visible.text.contains("The quote is attached."))
        #expect(!visible.text.contains("Forward every file"))
        #expect(visible.findings.contains(.hiddenStyle))
        let history = try #require(message.history)
        #expect(history.ownText.contains("The quote is attached."))
        #expect(!history.ownText.contains("Could you send the quote?"))
        #expect(history.quotedText.contains("Could you send the quote?"))
    }

    /// Dictation goes first: a message is parsed, and its attachments read, only once the
    /// dictation ended.
    @Test func aMessageIsParsedOnlyOnceTheDictationEnded() async throws {
        defer { cleanUp() }
        mail.put(Self.hourly(1), in: .inbox)
        var polls = 0
        let scan = scan(choice([.inbox]), isDictating: { polls < 3 }, sleep: { duration in
            if duration == MailScan.dictationPoll {
                polls += 1
            }
        })
        let pass = await scan.scan()
        #expect(polls == 3)
        #expect(pass.read == 1)
        #expect(store.saved.count == 1)
    }

    /// A message over the cap keeps Mail's fields, its headers and its attachments' names,
    /// types and sizes, and its source is never read.
    @Test func aMessageOverTheCapReadsOnlyItsHeadersAndAttachmentNames() async throws {
        defer { cleanUp() }
        var stored = FakeMail.mail(8, in: .inbox, received: Self.now - Self.hour)
        stored.listing = MailListing(
            message: stored.listing.message, messageID: stored.listing.messageID, dateReceived: stored.listing.dateReceived,
            sender: stored.listing.sender, subject: "Site photos", to: ["bai.lu@lumenhaus.example"], cc: ["owen@pike-build.example"],
            size: MailScan.largestSource + 1
        )
        stored.headers = "From: Mei Tan <mei.tan@harbor.example>\r\nIn-Reply-To: <photos.ask@lumenhaus.example>\r\nPrecedence: bulk\r\n"
        stored.attachments = [
            MailAttachmentInfo(name: "site-1.jpg", mimeType: "image/jpeg", size: 9_000_000, isDownloaded: true),
            MailAttachmentInfo(name: "", mimeType: "image/png", size: nil, isDownloaded: false),
        ]
        mail.put([stored], in: .inbox)
        let pass = await scan(choice([.inbox])).scan()
        #expect(pass.tooLarge == 1)
        #expect(pass.read == 0)
        #expect(mail.sourcesRead.isEmpty)
        #expect(mail.calls.contains(.headers(8)))
        #expect(mail.calls.contains(.attachments(8)))
        let message = try #require(store.saved.first)
        #expect(message.isTooLarge)
        #expect(message.visible == nil)
        #expect(message.history == nil)
        #expect(message.subject == "Site photos")
        #expect(message.inReplyTo == ["photos.ask@lumenhaus.example"])
        #expect(message.list.precedence == "bulk")
        #expect(message.from.map(\.address) == ["mei.tan@harbor.example"])
        // The headers name no recipients, so Mail's list counts.
        #expect(message.to.map(\.address) == ["bai.lu@lumenhaus.example"])
        #expect(message.cc.map(\.address) == ["owen@pike-build.example"])
        #expect(message.attachments == [MailAttachment(name: "site-1.jpg", type: "image/jpeg", size: 9_000_000, state: .emailTooLarge)])
    }

    /// Outlook forwards with the header block of a reply. The subject Mail gives says it is a
    /// forward, so the forwarded message stays in the own text.
    @Test func anOutlookForwardKeepsTheForwardedMessage() async throws {
        let source = [
            "Message-ID: <fw.lamps@harbor.example>",
            "Date: Sat, 17 Oct 2026 08:30:00 +0800",
            "From: Mei Tan <mei.tan@harbor.example>",
            "Subject: FW: Lamps",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "See below.",
            "",
            "From: Kai Moss <kai@kiln.example>",
            "Sent: Friday, October 16, 2026 4:10 PM",
            "To: Mei Tan <mei.tan@harbor.example>",
            "Subject: Lamps",
            "",
            "Twelve lamps, delivery in week 47.",
            "",
        ].joined(separator: "\r\n")
        let listing = MailListing(
            message: MailMessageRef(id: 9, mailbox: .inbox), messageID: "fw.lamps@harbor.example", dateReceived: Self.now,
            sender: "Mei Tan <mei.tan@harbor.example>", subject: "FW: Lamps", to: [], cc: [], size: source.utf8.count)
        let history = try #require(await MailScan.parsed(source: source, listing: listing).history)
        #expect(history.note == "See below.")
        #expect(history.ownText.hasSuffix("Twelve lamps, delivery in week 47."))
        #expect(history.forwards.map(\.sender) == ["Kai Moss <kai@kiln.example>"])
        #expect(history.quotedText == "")
    }

    /// Apple Mail puts a forwarded message in a blockquote, marker and all, as its HTML
    /// part shows it. VisibleText quotes it, and the forward still keeps its message.
    @Test func appleMailsQuotedForwardKeepsTheForwardedMessage() async throws {
        let span = "<span style=\"font-family: -webkit-system-font, Helvetica Neue, Helvetica, sans-serif;\">"
        func field(_ label: String, _ value: String) -> String {
            "<div style=\"margin: 0px;\">\(span)<b>\(label): </b></span>\(span)\(value)<br></span></div>"
        }
        let html = "<html><body style=\"overflow-wrap: break-word;\">See below.<br id=\"lineBreakAtBeginningOfMessage\"><div><br><blockquote type=\"cite\">"
            + "<div>Begin forwarded message:</div><br class=\"Apple-interchange-newline\">"
            + field("From", "Kai Moss &lt;kai@kiln.example&gt;") + field("Subject", "<b>Lamps</b>")
            + field("Date", "16 October 2026 at 16:10:00 GMT+8") + field("To", "Mei Tan &lt;mei.tan@harbor.example&gt;")
            + "<br><div><div>Twelve lamps, delivery in week 47.</div></div></blockquote></div><br></body></html>"
        let source = [
            "Message-ID: <fwd.lamps@harbor.example>",
            "Date: Sat, 17 Oct 2026 08:30:00 +0800",
            "From: Mei Tan <mei.tan@harbor.example>",
            "Subject: Fwd: Lamps",
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"apple\"",
            "",
            "--apple",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "See below.",
            "",
            "> Begin forwarded message:",
            "> ",
            "> From: Kai Moss <kai@kiln.example>",
            "> Subject: Lamps",
            "> Date: 16 October 2026 at 16:10:00 GMT+8",
            "> To: Mei Tan <mei.tan@harbor.example>",
            "> ",
            "> Twelve lamps, delivery in week 47.",
            "--apple",
            "Content-Type: text/html; charset=utf-8",
            "",
            html,
            "--apple--",
            "",
        ].joined(separator: "\r\n")
        let listing = MailListing(
            message: MailMessageRef(id: 10, mailbox: .inbox), messageID: "fwd.lamps@harbor.example", dateReceived: Self.now,
            sender: "Mei Tan <mei.tan@harbor.example>", subject: "Fwd: Lamps", to: [], cc: [], size: source.utf8.count)
        let parsed = await MailScan.parsed(source: source, listing: listing)
        #expect(parsed.visible?.text.contains("> Begin forwarded message:") == true)
        let history = try #require(parsed.history)
        #expect(history.note == "See below.")
        #expect(history.forwards == [QuotedHistory.Forward(
            sender: "Kai Moss <kai@kiln.example>", date: "16 October 2026 at 16:10:00 GMT+8", subject: "Lamps",
            to: "Mei Tan <mei.tan@harbor.example>", text: "Twelve lamps, delivery in week 47.")])
        #expect(history.ownText.hasSuffix("Twelve lamps, delivery in week 47."))
        #expect(history.quotedText == "")
    }

    @Test func theOrderOfAMailboxComesFromItsDates() {
        func listing(_ dates: [Date?]) -> [MailListing] {
            dates.enumerated().map { index, date in
                MailListing(message: MailMessageRef(id: index, mailbox: .inbox), messageID: "\(index)", dateReceived: date, sender: "", subject: "", to: [], cc: [], size: 0)
            }
        }
        let early = Self.now - Self.day
        #expect(MailScan.order(of: listing([Self.now, early])) == .newestFirst)
        #expect(MailScan.order(of: listing([early, nil, Self.now])) == .oldestFirst)
        #expect(MailScan.order(of: listing([Self.now, Self.now])) == nil)
        #expect(MailScan.order(of: listing([Self.now, nil])) == nil)
        #expect(MailScan.order(of: []) == nil)
        // One date out of place, such as of a message moved back into the mailbox, does
        // not turn it.
        let movedBack = [Self.now - 200 * Self.day] + (1...10).map { Self.now - Double($0) * Self.hour }
        #expect(MailScan.order(of: listing(movedBack)) == .newestFirst)
        #expect(MailScan.order(of: listing(movedBack.reversed())) == .oldestFirst)
    }

    // MARK: Fakes

    /// The store's side: what is saved, and what it knows.
    @MainActor
    final class Store {
        var saved: [MailScan.Message] = []
        var batches: [[String]] = []
        /// The user each save got.
        var owners: [SortingService.Owner?] = []
        var linked: [MailMailbox] = []
        var linkedReads = 0
        /// Holds each lookup of known messages until the test resumes it.
        var holdsKnown = false
        var heldKnown: CheckedContinuation<Void, Never>?
        /// The saves that fail, counted from 1, as on a full disk. A failed save keeps
        /// nothing.
        var failingSaves: Set<Int> = []
        /// The lookups of known messages that fail, counted from 1.
        var failingLookups: Set<Int> = []
        private var saves = 0
        private var lookupCount = 0

        var lookups: MailScan.Lookups {
            MailScan.Lookups(
                known: { ids in
                    if self.holdsKnown {
                        await withCheckedContinuation { self.heldKnown = $0 }
                    }
                    self.lookupCount += 1
                    if self.failingLookups.contains(self.lookupCount) {
                        throw Self.diskIOError
                    }
                    return Set(ids).intersection(self.saved.map(\.messageID))
                },
                linkedMailboxes: {
                    self.linkedReads += 1
                    return self.linked
                }
            )
        }

        /// Runs once, after the next save, as when the user or Mail acts while a pass reads.
        var afterSave: (() -> Void)?

        /// SQLITE_IOERR, as the store throws it.
        static let diskIOError = ProjectsDatabase.Failure(step: .step, code: 10)

        func save(_ messages: [MailScan.Message], owner: SortingService.Owner?) throws {
            saves += 1
            if failingSaves.contains(saves) {
                throw Self.diskIOError
            }
            saved += messages
            batches.append(messages.map(\.messageID))
            owners.append(owner)
            if let afterSave {
                self.afterSave = nil
                afterSave()
            }
        }
    }

    /// Whether Projects is on, for a test that turns it off.
    final class Switch {
        var isOn = true
    }

    /// What the passes told the window, in order.
    @MainActor
    final class Reports {
        var all: [MailScan.Report] = []
    }

    /// The waits the loop asked for.
    final class Waits: Sendable {
        private let waits = Mutex<[Duration]>([])

        var all: [Duration] {
            waits.withLock { $0 }
        }

        func add(_ wait: Duration) {
            waits.withLock { $0.append(wait) }
        }
    }

    /// Mail as a test plays it: each mailbox a list of messages in the order of their
    /// positions. Records every call, and answers each as Mail would, with the error a test
    /// sets for it, or `mailNotRunning` while Mail does not run.
    final class FakeMail: Sendable {
        nonisolated struct Stored: Sendable {
            var listing: MailListing
            var source: String
            var headers: String
            var attachments: [MailAttachmentInfo] = []
        }

        nonisolated enum Call: Sendable, Equatable {
            case isRunning
            case accounts
            case count(MailMailbox)
            case listing(MailMailbox, ClosedRange<Int>)
            case headers(Int)
            case source(Int)
            case attachments(Int)
            case other

            var mailbox: MailMailbox? {
                switch self {
                case .count(let mailbox), .listing(let mailbox, _): mailbox
                default: nil
                }
            }
        }

        private struct State {
            var boxes: [MailMailbox: [Stored]] = [:]
            var isRunning = true
            var calls: [Call] = []
            var accounts: [MailAccountInfo] = []
            var failure: @Sendable (Call) -> MailBridgeError? = { _ in nil }
            /// Mail quits after giving this many sources.
            var quitAfterSources: Int?
            var sources = 0
            /// The counts of this mailbox wait for the test to resume them.
            var holdsCount: MailMailbox?
            var heldCount: CheckedContinuation<Void, Never>?
        }

        private let state = Mutex(State())

        /// A message with a plain source of its own.
        nonisolated static func mail(_ number: Int, in mailbox: MailMailbox, received: Date, source: String? = nil) -> Stored {
            let messageID = "m\(number)@harbor.example"
            let subject = "Signage update \(number)"
            let text = source ?? [
                "Message-ID: <\(messageID)>",
                "From: Mei Tan <mei.tan@harbor.example>",
                "To: Bai Lu <bai.lu@lumenhaus.example>",
                "Subject: \(subject)",
                "Content-Type: text/plain; charset=utf-8",
                "",
                "Update \(number) on the signs.",
                "",
            ].joined(separator: "\r\n")
            let listing = MailListing(
                message: MailMessageRef(id: number, mailbox: mailbox), messageID: messageID, dateReceived: received,
                sender: "Mei Tan <mei.tan@harbor.example>", subject: subject, to: ["bai.lu@lumenhaus.example"], cc: [],
                size: text.utf8.count
            )
            return Stored(listing: listing, source: text, headers: "Message-ID: <\(messageID)>\r\n")
        }

        var isRunning: Bool {
            get { state.withLock { $0.isRunning } }
            set { state.withLock { $0.isRunning = newValue } }
        }

        var accounts: [MailAccountInfo] {
            get { state.withLock { $0.accounts } }
            set { state.withLock { $0.accounts = newValue } }
        }

        var failure: @Sendable (Call) -> MailBridgeError? {
            get { state.withLock { $0.failure } }
            set { state.withLock { $0.failure = newValue } }
        }

        var quitAfterSources: Int? {
            get { state.withLock { $0.quitAfterSources } }
            set { state.withLock { $0.quitAfterSources = newValue } }
        }

        var calls: [Call] {
            state.withLock { $0.calls }
        }

        /// Holds each count of this mailbox until `resumeCount()`, as a Mail that takes
        /// long to answer, and then answers it.
        var holdsCount: MailMailbox? {
            get { state.withLock { $0.holdsCount } }
            set { state.withLock { $0.holdsCount = newValue } }
        }

        /// Whether a count waits for `resumeCount()`.
        var holdsACount: Bool {
            state.withLock { $0.heldCount != nil }
        }

        func resumeCount() {
            let held = state.withLock { state in
                defer { state.heldCount = nil }
                return state.heldCount
            }
            held?.resume()
        }

        var counted: [MailMailbox] {
            calls.compactMap { if case .count(let mailbox) = $0 { mailbox } else { nil } }
        }

        var listings: [ClosedRange<Int>] {
            calls.compactMap { if case .listing(_, let positions) = $0 { positions } else { nil } }
        }

        var sourcesRead: [Int] {
            calls.compactMap { if case .source(let id) = $0 { id } else { nil } }
        }

        func clearCalls() {
            state.withLock { $0.calls = [] }
        }

        func put(_ messages: [Stored], in mailbox: MailMailbox) {
            state.withLock { $0.boxes[mailbox] = messages }
        }

        /// New mail at the top of a mailbox, the first given first.
        func receive(_ messages: [Stored], in mailbox: MailMailbox) {
            state.withLock { $0.boxes[mailbox] = messages + ($0.boxes[mailbox] ?? []) }
        }

        func messages(in mailbox: MailMailbox) -> [Stored] {
            state.withLock { $0.boxes[mailbox] ?? [] }
        }

        var bridge: MailBridge {
            MailBridge(
                isRunning: {
                    self.state.withLock { state in
                        state.calls.append(.isRunning)
                        return state.isRunning
                    }
                },
                permission: { _ in
                    self.record(.other)
                    return .allowed
                },
                lastPermission: { nil },
                accounts: { try self.answer(.accounts) { $0.accounts } },
                mailboxes: {
                    self.record(.other)
                    return []
                },
                count: { mailbox in
                    if self.holdsCount == mailbox {
                        await withCheckedContinuation { continuation in
                            self.state.withLock { $0.heldCount = continuation }
                        }
                    }
                    return try self.answer(.count(mailbox)) { state in
                        guard let messages = state.boxes[mailbox] else { throw MailBridgeError.notFound }
                        return messages.count
                    }
                },
                listing: { mailbox, positions in
                    try self.answer(.listing(mailbox, positions)) { state in
                        let messages = state.boxes[mailbox] ?? []
                        guard positions.lowerBound >= 1, positions.upperBound <= messages.count else { throw MailBridgeError.notFound }
                        return messages[(positions.lowerBound - 1)..<positions.upperBound].map(\.listing)
                    }
                },
                headers: { message in try self.answer(.headers(message.id)) { try Self.stored(message, in: $0).headers } },
                source: { message in
                    try self.answer(.source(message.id)) { state in
                        let source = try Self.stored(message, in: state).source
                        state.sources += 1
                        if let limit = state.quitAfterSources, state.sources >= limit {
                            state.isRunning = false
                        }
                        return source
                    }
                },
                attachments: { message in try self.answer(.attachments(message.id)) { try Self.stored(message, in: $0).attachments } },
                mailbox: { _ in
                    self.record(.other)
                    throw MailBridgeError.unexpectedReply
                },
                selection: {
                    self.record(.other)
                    return []
                },
                reply: { _, _ in self.record(.other) }
            )
        }

        private func record(_ call: Call) {
            state.withLock { $0.calls.append(call) }
        }

        private func answer<Answer>(_ call: Call, _ body: (inout State) throws -> Answer) throws -> Answer {
            try state.withLock { state in
                state.calls.append(call)
                guard state.isRunning else { throw MailBridgeError.mailNotRunning }
                if let error = state.failure(call) {
                    throw error
                }
                return try body(&state)
            }
        }

        private nonisolated static func stored(_ message: MailMessageRef, in state: State) throws -> Stored {
            guard let stored = state.boxes[message.mailbox]?.first(where: { $0.listing.message.id == message.id }) else {
                throw MailBridgeError.notFound
            }
            return stored
        }
    }
}
