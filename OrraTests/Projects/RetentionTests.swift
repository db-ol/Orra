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
        Explanation(
            messageID: id, project: nil, language: .en, today: start, reply: .reply(.en), warnings: [], modelWarnings: [],
            points: [Explanation.Point(text: "The sizes need a confirmation.", sources: ["this email"], flags: [])],
            questions: [], draft: draft, draftCheck: nil, sources: ["this email": .message(id)], removed: [:], problems: [],
            unknownSources: [])
    }

    private static let draft = Explanation.Draft.checked(DraftCheck.Result(draft: "The sizes are confirmed.", language: .en))

    private func bytesOnDisk(_ database: ProjectsDatabase) -> Data {
        ["", "-wal", "-shm", "-journal"].reduce(into: Data()) { bytes, suffix in
            bytes += (try? Data(contentsOf: URL(fileURLWithPath: database.file.path + suffix))) ?? Data()
        }
    }

    @Test func thePeriodsAreThoseOfDecisionEleven() {
        let retention = Retention()
        #expect(retention.mailText == 90 * 86_400)
        #expect(retention.emails == 180 * 86_400)
        #expect(retention.drafts == 30 * 86_400)
        // A count goes only long after sorting reads it as zero, so removing it changes
        // nothing sorting sees.
        #expect(retention.tallies > SortingService.fadePeriod)
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
        let retention = Retention()
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

    @Test func anEmailGoesWithItsThread180DaysAfterTheThreadsNewestMessage() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([
            Self.message("root@test.example", day: -190),
            Self.message("lone@test.example", day: -181),
        ], ownAddresses: [Self.work], at: Self.date(-190))
        try await store.save([Self.message("reply@test.example", day: -10, inReplyTo: ["root@test.example"])], ownAddresses: [Self.work], at: Self.date(-10))
        // A date far in the future counts as the day it was read.
        try await store.save([Self.message("future@test.example", day: 1_000)], ownAddresses: [Self.work], at: Self.date(-200))
        try await store.save(ReviseService.Version(messageID: "lone@test.example", change: .tone(.warm), check: DraftCheck.Result(draft: "Hi", language: .en)), at: Self.date(-1))

        let removed = try await Retention().apply(to: store, now: Self.start)
        #expect(removed.emails == 2)
        #expect(try await store.known(["root@test.example", "lone@test.example", "reply@test.example", "future@test.example"]) == ["root@test.example", "reply@test.example"])
        // Their people and drafts go with them.
        #expect(try await store.database.run("SELECT COUNT(*) FROM mail_people").first == [.integer(4)])
        #expect(try await store.database.run("SELECT COUNT(*) FROM mail_draft_versions").first == [.integer(0)])
        await store.close()
    }

    @Test func draftsGoThirtyDaysAfterTheirLastChangeWithTheExplanationThatHoldsOne() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.save([
            Self.message("revised@test.example", day: 0),
            Self.message("drafted@test.example", day: 0),
            Self.message("noDraft@test.example", day: 0),
        ], ownAddresses: [Self.work], at: Self.start)
        try await store.save(Self.explanation("revised@test.example", draft: Self.draft), at: Self.date(1))
        try await store.save(ReviseService.Version(messageID: "revised@test.example", change: .instruction("Shorter"), check: DraftCheck.Result(draft: "Confirmed.", language: .en)), at: Self.date(5))
        try await store.save(Self.explanation("drafted@test.example", draft: Self.draft), at: Self.date(1))
        try await store.save(Self.explanation("noDraft@test.example", draft: .noReply(.listMail)), at: Self.date(1))
        let retention = Retention()

        #expect(try await retention.apply(to: store, now: Self.date(32)) == Retention.Removed(explanations: 1))
        #expect(try await store.explanation(for: "drafted@test.example") == nil)
        #expect(try await store.explanation(for: "revised@test.example") != nil)

        #expect(try await retention.apply(to: store, now: Self.date(36)) == Retention.Removed(explanations: 1, draftVersions: 1))
        #expect(try await store.versions(of: "revised@test.example").isEmpty)
        #expect(try await store.explanation(for: "revised@test.example") == nil)
        // An explanation without a draft stays with the text, which stays too.
        #expect(try await store.explanation(for: "noDraft@test.example") != nil)
        #expect(try await store.explainEmail("revised@test.example")?.text == "Please confirm the sizes.")
        #expect(try await retention.apply(to: store, now: Self.date(37)).isEmpty)
        await store.close()
    }

    @Test func countsOfMovesGoAfterTheirPeriod() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        try await store.saveTally(SortingService.Tally(count: 1, last: Self.date(-181)), rule: .sender("kim@quay.example"), project: Self.harbor)
        try await store.saveTally(SortingService.Tally(count: 1, last: Self.date(-179)), rule: .domain("quay.example"), project: Self.harbor)
        #expect(try await Retention().apply(to: store, now: Self.start) == Retention.Removed(tallies: 1))
        #expect(try await store.tally(.sender("kim@quay.example"), project: Self.harbor) == nil)
        #expect(try await store.tally(.domain("quay.example"), project: Self.harbor) != nil)
        await store.close()
    }

    @Test func removedTextLeavesNoTraceInTheFile() async throws {
        defer { cleanUp() }
        let store = try await openStore()
        let secret = "zanzibarquokka"
        try await store.save([Self.message("a@test.example", day: 0, text: "The \(secret) signs.")], ownAddresses: [Self.work], at: Self.start)
        try await store.database.run("PRAGMA wal_checkpoint(TRUNCATE)")
        #expect(bytesOnDisk(store.database).range(of: Data(secret.utf8)) != nil)
        #expect(try await Retention().apply(to: store, now: Self.date(91)).texts == 1)
        #expect(bytesOnDisk(store.database).range(of: Data(secret.utf8)) == nil)
        await store.close()
    }

    /// The time and the sleeps of `start`, which the test moves on itself.
    final class Steps: Sendable {
        let now = Mutex(Date.distantPast)
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
        let task = Retention().start(store: store, now: { steps.now.withLock { $0 } }, sleep: { try await steps.sleep($0) })

        #expect(await slept.next() == Retention.interval)
        #expect(try await store.explainEmail("a@test.example")?.text.isEmpty == false)
        steps.now.withLock { $0 = Self.date(91) }
        steps.wake()
        #expect(await slept.next() == Retention.interval)
        #expect(try await store.explainEmail("a@test.example")?.text.isEmpty == true)

        task.cancel()
        steps.wake(throwing: CancellationError())
        await task.value
        await store.close()
    }
}
