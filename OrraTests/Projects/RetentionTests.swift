import Foundation
import Synchronization
import Testing
@testable import Orra

/// Retention on a store in a temporary root, with the time set by the tests. The people
/// and mail are made up for these tests, at .example addresses.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RetentionTests {
    static let harbor = UUID()
    static let work = "bai.lu@lumenhaus.example"
    static let start = Date(timeIntervalSince1970: 1_760_000_000)

    let storage = ProjectsStorage(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("RetentionTests-\(UUID().uuidString)", isDirectory: true))

    private func cleanUp() {
        try? FileManager.default.removeItem(at: storage.root)
    }

    private func openStore() async throws -> MailStore {
        let store = MailStore(database: try await ProjectsDatabase.open(in: storage))
        try await store.add(project: Self.harbor)
        return store
    }

    private static func date(_ day: Double) -> Date {
        start.addingTimeInterval(day * 86_400)
    }

    private static func message(_ id: String, day: Double, text: String = "Please confirm the sizes.", inReplyTo: [String] = []) -> MailStore.Message {
        MailStore.Message(
            messageID: id, date: date(day), sender: MailStore.Person(address: "song.yutong@harborlights.example"),
            to: [MailStore.Person(address: work)], subject: "Signs", inReplyTo: inReplyTo, text: text, visibleText: text)
    }

    private static func explanation(_ id: String, draft: Explanation.Draft) -> Explanation {
        let hasDraft: Bool = if case .checked = draft { true } else { false }
        return Explanation(
            messageID: id, project: nil, language: .en, today: start, reply: .reply(.en), warnings: [], modelWarnings: [],
            points: [Explanation.Point(text: "The sizes need a confirmation.", sources: ["this email"], flags: [])],
            questions: [], draft: draft, draftCheck: hasDraft ? draftCheck : nil, sources: ["this email": .message(id)], removed: [:],
            problems: [], unknownSources: [])
    }

    /// What the draft check of a reply to Song Yutong reads.
    private static let draftCheck = DraftCheckInput(
        draft: "", language: .en, recipients: [DraftCheckInput.Person(name: "", address: "song.yutong@harborlights.example")],
        projectPeople: [], own: [DraftCheckInput.Person(name: "Bai Lu", address: work)], incomingText: "Please confirm the sizes.",
        today: start)

    private static let draft = Explanation.Draft.checked(DraftCheck.Result(draft: "The sizes are confirmed.", language: .en))

    private func bytesOnDisk(_ database: ProjectsDatabase) -> Data {
        ["", "-wal", "-shm", "-journal"].reduce(into: Data()) { bytes, suffix in
            bytes += (try? Data(contentsOf: URL(fileURLWithPath: database.file.path + suffix))) ?? Data()
        }
    }

    @Test func thePeriodsAreThoseOfDecisionEleven() {
        #expect(Retention.mailText == 90 * 86_400)
        #expect(Retention.emails == 180 * 86_400)
        #expect(Retention.drafts == 30 * 86_400)
        // A count goes only long after sorting reads it as zero, so removing it changes
        // nothing sorting sees.
        #expect(Retention.tallies > SortingService.fadePeriod)
        // As long as the longest days a scan reads back (MailChoice).
        #expect(Retention.goneIDs == 365 * 86_400)
        #expect(Retention.interval == .seconds(86_400))
        #expect(Retention.Removed().isEmpty)
        #expect(!Retention.Removed(tallies: 1).isEmpty)
    }

    /// Text is kept for 90 days from the read, also for mail that was older when read.
    @Test func theTextAndItsExplanationGoNinetyDaysAfterTheRead() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([Self.message("old@test.example", day: -60), Self.message("new@test.example", day: 0)], ownAddresses: [Self.work], at: Self.start)
        try await store.save(Self.explanation("old@test.example", draft: .noReply(.listMail)), at: Self.date(10))
        let retention = Retention.self
        // The old email's date is 91 days back, but it was read 31 days ago.
        #expect(try await retention.apply(to: store, now: Self.date(31)).isEmpty)
        #expect(try await retention.apply(to: store, now: Self.date(89)).isEmpty)
        #expect(try await store.explanation(for: "old@test.example") != nil)

        let removed = try await retention.apply(to: store, now: Self.date(91))
        #expect(removed == Retention.Removed(texts: 2, explanations: 1))
        let email = try #require(try await store.explainEmail("old@test.example"))
        #expect(email.text.isEmpty)
        #expect(email.visibleText.isEmpty)
        #expect(email.subject == "Signs")
        #expect(try await store.explanation(for: "old@test.example") == nil)
        #expect(try await store.list(.needsProject).map(\.hasText) == [false, false])
        // Mail without its text is no longer other mail of its project for an explanation.
        #expect(try await store.database.run("SELECT COUNT(*) FROM mail_messages WHERE words IS NOT NULL").first == [.integer(0)])
        #expect(try await retention.apply(to: store, now: Self.date(92)).isEmpty)
        await store.close()
    }

    /// The 180 days count from the read of the thread's newest message, so mail the user
    /// chose to read from further back stays as long as new mail.
    @Test func anEmailGoesWithItsThread180DaysAfterOrraReadTheThreadsNewestMessage() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([
            Self.message("root@test.example", day: -190),
            Self.message("lone@test.example", day: -100),
        ], ownAddresses: [Self.work], at: Self.date(-181))
        try await store.save([Self.message("reply@test.example", day: -10, inReplyTo: ["root@test.example"])], ownAddresses: [Self.work], at: Self.date(-10))
        // Dated a year back, read today, as with 365 days chosen.
        try await store.save([Self.message("backfill@test.example", day: -365)], ownAddresses: [Self.work], at: Self.start)
        // A date in the future keeps nothing longer.
        try await store.save([Self.message("future@test.example", day: 1_000)], ownAddresses: [Self.work], at: Self.date(-200))
        try await store.save(Self.explanation("lone@test.example", draft: Self.draft), at: Self.date(-100))
        #expect(try await store.save(ReviseService.Version(messageID: "lone@test.example", change: .tone(.warm), check: DraftCheck.Result(draft: "Hi", language: .en)), startedAt: Self.date(-1), at: Self.date(-1)) == 1)

        let removed = try await Retention.apply(to: store, now: Self.start)
        #expect(removed.emails == 2)
        for (id, kept) in [("root@test.example", true), ("reply@test.example", true), ("backfill@test.example", true), ("lone@test.example", false), ("future@test.example", false)] {
            #expect((try await store.sortingEmail(id) != nil) == kept)
        }
        // The scan still finds them known, so it never reads them again.
        #expect(try await store.known(["lone@test.example", "future@test.example", "other@test.example"]) == ["lone@test.example", "future@test.example"])
        // Their people and drafts go with them.
        #expect(try await store.database.run("SELECT COUNT(*) FROM mail_people").first == [.integer(6)])
        #expect(try await store.database.run("SELECT COUNT(*) FROM mail_draft_versions").first == [.integer(0)])
        await store.close()
    }

    /// A removed email's Message-ID stays known for 365 days after Orra read it, when no
    /// scan reaches back to it any more.
    @Test func goneMessageIDsGoWhenNoScanCanReachThem() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([Self.message("a@test.example", day: 0)], ownAddresses: [Self.work], at: Self.start)
        #expect(try await Retention.apply(to: store, now: Self.date(181)).emails == 1)
        #expect(try await store.known(["a@test.example"]) == ["a@test.example"])
        #expect(try await Retention.apply(to: store, now: Self.date(364)).isEmpty)
        #expect(try await Retention.apply(to: store, now: Self.date(366)) == Retention.Removed(goneIDs: 1))
        #expect(try await store.known(["a@test.example"]).isEmpty)
        await store.close()
    }

    /// A draft goes 30 days after its last change, with its versions. The explanation that
    /// holds the first draft stays without it, as long as the email's text, as an
    /// explanation without a draft does (decision 11).
    @Test func aDraftGoesThirtyDaysAfterItsLastChangeAndTheExplanationStays() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([
            Self.message("revised@test.example", day: 0),
            Self.message("drafted@test.example", day: 0),
            Self.message("noDraft@test.example", day: 0),
        ], ownAddresses: [Self.work], at: Self.start)
        try await store.save(Self.explanation("revised@test.example", draft: Self.draft), at: Self.date(1))
        try await store.save(ReviseService.Version(messageID: "revised@test.example", change: .instruction("Shorter"), check: DraftCheck.Result(draft: "Confirmed.", language: .en)), startedAt: Self.date(5), at: Self.date(5))
        try await store.save(Self.explanation("drafted@test.example", draft: Self.draft), at: Self.date(1))
        try await store.save(Self.explanation("noDraft@test.example", draft: .noReply(.listMail)), at: Self.date(1))
        let retention = Retention.self

        #expect(try await retention.apply(to: store, now: Self.date(32)) == Retention.Removed(drafts: 1))
        var expired = Self.explanation("drafted@test.example", draft: Self.draft)
        expired.draft = .expired
        expired.draftCheck = nil
        #expect(try await store.explanation(for: "drafted@test.example") == expired)
        #expect(try await store.list(.needsProject).first { $0.messageID == "drafted@test.example" }?.isExplained == true)
        #expect(try await store.explanation(for: "revised@test.example")?.draft == Self.draft)

        #expect(try await retention.apply(to: store, now: Self.date(36)) == Retention.Removed(drafts: 1, draftVersions: 1))
        #expect(try await store.versions(of: "revised@test.example").isEmpty)
        #expect(try await store.explanation(for: "revised@test.example")?.draft == .expired)
        #expect(try await store.explanation(for: "noDraft@test.example")?.draft == .noReply(.listMail))
        #expect(try await store.explainEmail("revised@test.example")?.text == "Please confirm the sizes.")
        #expect(try await retention.apply(to: store, now: Self.date(37)).isEmpty)

        // The explanations go with the text.
        #expect(try await retention.apply(to: store, now: Self.date(91)) == Retention.Removed(texts: 3, explanations: 3))
        #expect(try await store.explanation(for: "drafted@test.example") == nil)
        await store.close()
    }

    /// A revision that started before Retention removed its draft ends on nothing, so the
    /// draft never comes back under the explanation that stays.
    @Test func aRevisionThatEndsAfterItsDraftWentIsNotSaved() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([Self.message("a@test.example", day: 0)], ownAddresses: [Self.work], at: Self.start)
        try await store.save(Self.explanation("a@test.example", draft: Self.draft), at: Self.date(1))
        let late = ReviseService.Version(messageID: "a@test.example", change: .tone(.warm), check: DraftCheck.Result(draft: "Hi Song,", language: .en))
        #expect(try await Retention.apply(to: store, now: Self.date(32)) == Retention.Removed(drafts: 1))
        #expect(try await store.save(late, startedAt: Self.date(31), at: Self.date(32)) == nil)
        #expect(try await store.versions(of: "a@test.example").isEmpty)
        #expect(try await store.explanation(for: "a@test.example")?.draft == .expired)
        await store.close()
    }

    /// An explanation this Orra cannot read, as another Orra wrote it, cannot lose its draft
    /// alone, so it goes whole when the draft goes.
    @Test func anExplanationThatDoesNotReadGoesWholeWithItsDraft() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([Self.message("a@test.example", day: 0)], ownAddresses: [Self.work], at: Self.start)
        try await store.save(Self.explanation("a@test.example", draft: Self.draft), at: Self.date(1))
        try await store.database.run("UPDATE mail_messages SET explanation = ? WHERE message_id = ?", [.blob(Data("{\"form\": 2}".utf8)), .text("a@test.example")])
        #expect(try await Retention.apply(to: store, now: Self.date(32)) == Retention.Removed(explanations: 1))
        #expect(try await store.list(.needsProject).first?.isExplained == false)
        await store.close()
    }

    /// The text the user typed into a draft goes with the draft, 30 days after its last
    /// change, and typing counts as a change. Nothing of it stays in the file.
    @Test func typedTextGoesThirtyDaysAfterTheLastChangeOfItsDraft() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([Self.message("typed@test.example", day: 0), Self.message("old@test.example", day: 0)], ownAddresses: [Self.work], at: Self.start)
        for id in ["typed@test.example", "old@test.example"] {
            try await store.save(Self.explanation(id, draft: Self.draft), at: Self.date(1))
        }
        let secret = "marmotlantern"
        let typed = MailStore.EditedDraft(text: "The \(secret) sizes are confirmed.", editedFrom: MailStore.draftKey("The sizes are confirmed.", version: 0, explained: Self.start))
        #expect(try await store.save(typed, for: "typed@test.example", at: Self.date(20)))
        #expect(try await store.save(typed, for: "old@test.example", at: Self.date(1)))
        // 31 days after the explanations, 11 after the typing into one of them. The
        // explanation stays without its draft, see Explanation.Draft.expired.
        #expect(try await Retention.apply(to: store, now: Self.date(32)) == Retention.Removed(drafts: 1, editedDrafts: 1))
        #expect(try await store.editedDraft(of: "old@test.example") == nil)
        #expect(try await store.explanation(for: "old@test.example")?.draft == .expired)
        #expect(try await store.editedDraft(of: "typed@test.example") == typed)
        #expect(try await store.explanation(for: "typed@test.example")?.draft == Self.draft)
        #expect(try await Retention.apply(to: store, now: Self.date(49)).isEmpty)
        #expect(try await Retention.apply(to: store, now: Self.date(51)) == Retention.Removed(drafts: 1, editedDrafts: 1))
        #expect(try await store.editedDraft(of: "typed@test.example") == nil)
        #expect(try await store.explanation(for: "typed@test.example")?.draft == .expired)
        #expect(bytesOnDisk(store.database).range(of: Data(secret.utf8)) == nil)
        await store.close()
    }

    /// The text goes with the explanation and the drafts that hold it, also while the draft
    /// is recent.
    @Test func draftVersionsGoWithTheText() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([Self.message("a@test.example", day: 0)], ownAddresses: [Self.work], at: Self.start)
        try await store.save(Self.explanation("a@test.example", draft: Self.draft), at: Self.date(80))
        #expect(try await store.save(ReviseService.Version(messageID: "a@test.example", change: .tone(.formal), check: DraftCheck.Result(draft: "Dear Ms Song,", language: .en)), startedAt: Self.date(85), at: Self.date(85)) == 1)
        #expect(try await store.save(MailStore.EditedDraft(text: "Dear Ms Song, thanks.", editedFrom: MailStore.draftKey("Dear Ms Song,", version: 1, explained: Self.start)), for: "a@test.example", at: Self.date(86)))
        let removed = try await Retention.apply(to: store, now: Self.date(91))
        #expect(removed == Retention.Removed(texts: 1, explanations: 1, draftVersions: 1, editedDrafts: 1))
        #expect(try await store.versions(of: "a@test.example").isEmpty)
        #expect(try await store.editedDraft(of: "a@test.example") == nil)
        #expect(try await store.explanation(for: "a@test.example") == nil)
        #expect(try await Retention.apply(to: store, now: Self.date(116)).isEmpty)
        await store.close()
    }

    @Test func countsOfMovesGoAfterTheirPeriod() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.saveTally(SortingService.Tally(count: 1, last: Self.date(-181)), rule: .sender("kim@quay.example"), project: Self.harbor)
        try await store.saveTally(SortingService.Tally(count: 1, last: Self.date(-179)), rule: .domain("quay.example"), project: Self.harbor)
        #expect(try await Retention.apply(to: store, now: Self.start) == Retention.Removed(tallies: 1))
        #expect(try await store.tally(.sender("kim@quay.example"), project: Self.harbor) == nil)
        #expect(try await store.tally(.domain("quay.example"), project: Self.harbor) != nil)
        await store.close()
    }

    /// The text of the attachments is mail text, and goes with the email's text. Their
    /// names stay with the rest of the email.
    @Test func attachmentTextGoesWithTheText() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        var message = Self.message("a@test.example", day: 0)
        message.attachments = [MailAttachment(name: "sizes.txt", type: "text/plain", size: 20, state: .read, text: "Sizes: 60 by 90 cm.")]
        try await store.save([message], ownAddresses: [Self.work], at: Self.start)
        #expect(try await Retention.apply(to: store, now: Self.date(89)).isEmpty)
        #expect(try await store.explainEmail("a@test.example")?.attachments.first?.text == "Sizes: 60 by 90 cm.")
        #expect(try await Retention.apply(to: store, now: Self.date(91)).texts == 1)
        let email = try #require(try await store.explainEmail("a@test.example"))
        var kept = message.attachments[0]
        kept.text = nil
        #expect(email.attachments == [kept])
        #expect(try await store.database.run("SELECT COUNT(*) FROM mail_messages WHERE attachment_text IS NOT NULL").first == [.integer(0)])
        await store.close()
    }

    @Test func removedTextLeavesNoTraceInTheFile() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        let secret = "zanzibarquokka"
        var message = Self.message("a@test.example", day: 0, text: "The \(secret) signs.")
        let attached = "wombatlantern"
        message.attachments = [MailAttachment(name: "notes.txt", type: "text/plain", state: .read, text: "The \(attached) notes.")]
        try await store.save([message], ownAddresses: [Self.work], at: Self.start)
        try await store.database.run("PRAGMA wal_checkpoint(TRUNCATE)")
        #expect(bytesOnDisk(store.database).range(of: Data(secret.utf8)) != nil)
        #expect(bytesOnDisk(store.database).range(of: Data(attached.utf8)) != nil)
        #expect(try await Retention.apply(to: store, now: Self.date(91)).texts == 1)
        #expect(bytesOnDisk(store.database).range(of: Data(secret.utf8)) == nil)
        #expect(bytesOnDisk(store.database).range(of: Data(attached.utf8)) == nil)
        await store.close()
    }

    /// The time and the sleeps of `start`, which the test moves on itself, and the runs that
    /// removed something.
    final class Steps: Sendable {
        let now = Mutex(Date.distantPast)
        let removals = Mutex(0)
        let slept: AsyncStream<Duration>
        private let sleeps: AsyncStream<Duration>.Continuation
        private let pending = Mutex<[CheckedContinuation<Void, any Error>]>([])

        init() {
            (slept, sleeps) = AsyncStream.makeStream()
        }

        func sleep(_ duration: Duration) async throws {
            try await withCheckedThrowingContinuation { continuation in
                pending.withLock { $0.append(continuation) }
                sleeps.yield(duration)
            }
        }

        /// Ends the sleep under way, or makes it throw.
        func wake(throwing error: (any Error)? = nil) {
            for continuation in pending.withLock({ waiting in
                defer { waiting = [] }
                return waiting
            }) {
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    @Test func itRunsAtOnceAndThenEveryDayUntilStopped() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([Self.message("a@test.example", day: 0)], ownAddresses: [Self.work], at: Self.start)
        let steps = Steps()
        steps.now.withLock { $0 = Self.date(10) }
        var slept = steps.slept.makeAsyncIterator()
        let task = Retention.start(
            store: store, now: { steps.now.withLock { $0 } }, sleep: { try await steps.sleep($0) },
            removed: { steps.removals.withLock { $0 += 1 } })

        #expect(await slept.next() == Retention.interval)
        #expect(try await store.explainEmail("a@test.example")?.text.isEmpty == false)
        #expect(steps.removals.withLock { $0 } == 0)
        steps.now.withLock { $0 = Self.date(91) }
        steps.wake()
        #expect(await slept.next() == Retention.interval)
        #expect(try await store.explainEmail("a@test.example")?.text.isEmpty == true)
        // The window reads its mail again after a run that removed something.
        #expect(steps.removals.withLock { $0 } == 1)

        task.cancel()
        steps.wake(throwing: CancellationError())
        await task.value
        await store.close()
    }
}
