import Foundation
import os

/// Reads new mail from the Mail mailboxes the user chose, and from those linked to a
/// project, while Mail runs and Projects is on.
///
/// - Nothing is read before the user confirmed the mailbox choice once, see MailChoice.
///   Then only the linked and the chosen mailboxes are read, in that order, and in them only
///   mail Mail received within the chosen days. Mail is never opened, and nothing is read while it
///   does not run. A pass checks again before each mailbox, range and message, and ends
///   when Projects goes off, the confirm is forgotten or `stop()` is called.
/// - A mailbox is read in ranges of 200 positions, never with `whose`. The spike found the
///   Inbox newest first. The order of other mailboxes is unverified, so a mailbox whose
///   first range shows its dates mostly oldest first is read from its end.
/// - Each range shares its first positions with the one before, so mail removed meanwhile
///   moves no message past the scan. Messages read already in the pass are skipped.
/// - A pass reads a mailbox back to the days, and skips the messages already known without
///   reading them again, until one pass did so to its end. Plan section 5 says a pass stops
///   at the first known Message-ID. That holds only once a pass reached the days: the next
///   ones start with the newest 20, and end after the first range that holds a message
///   known before the pass. A pass that ends midway, for any cause, leaves the next one to
///   read back to the days again, and so does one that left a message unread, a few times.
///   A save or a lookup of the store that fails ends the pass, so mail it did not save is
///   read again, and a message is never known only because the store could not answer.
/// - For each new message it reads the raw source and parses it off the main actor with
///   MIMEMessage, VisibleText and QuotedHistory. Mail's `content` is never read. The text
///   of its attachments comes from the MIME parts of that source, see MailAttachment. A
///   message over `largestSource` bytes by the listing's size is too large: only its
///   headers and its attachments' names, types and sizes are read. A message Mail cannot
///   give, or gives with no source, is not saved, and a later pass reads it again.
/// - Dictation goes first: parsing a message and reading each of its attachments wait
///   while the user dictates, and a pass runs at utility priority, as background work.
/// - It saves the new messages through a closure every `saveBatch` messages and at the end
///   of each range, so the window lists mail while a long range is still read. It asks
///   which messages are known through another closure, so it never waits for the store and
///   tests pass fakes. Each throws when the store fails.
/// - It polls every minute. When Orra may not control Mail, the pass ends and the scan waits
///   twice as long each time, up to 30 minutes. It does the same when the store fails.
/// - When Mail does not answer in time (-1712) or does not take an event twice (-600 or
///   -609 while it runs), only what was asked for waits: a message is left for later and
///   the mailbox goes on, and a mailbox whose count or listing gets no answer, or that gets
///   none for two new messages in a row, is left for later and the pass goes on with the
///   next one. So an account that is offline holds up no other. Each is asked for again at
///   the next pass, then after twice the last wait each time, up to 30 minutes. A message
///   that waited comes after the others of its range. The loop sleeps longer only while
///   every mailbox waits. When two mailboxes in a row get no answer, Mail itself does not
///   answer: the pass ends and the scan waits as after a refusal.
/// - A linked mailbox may file mail that a mailbox that is not linked lists too, as the
///   inbox of all accounts lists the inbox of each account. So while a linked mailbox
///   waits, the mailboxes that are not linked wait with it, and a message that waits in a
///   linked mailbox waits in the others too. That mail is then saved with the mailbox that
///   files it.
/// - It tells the window when a pass begins, whether that pass reads a mailbox back to the
///   days, and how it ended, see `Report`.
///
/// The user's own addresses and name come from Mail's accounts, or from the override that
/// a Debug build passes in, with which the scan never asks Mail for the accounts.
///
/// Logs counts, times and error codes only.
final class MailScan {
    /// A new message, read and parsed.
    nonisolated struct Message: Sendable, Equatable {
        /// Mail's handle of the message, in the mailbox it was read in. It holds for this
        /// Mail session only, to read the message again or to reply to it.
        var reference: MailMessageRef
        /// The Message-ID, without angle brackets, which Projects keys mail by.
        var messageID: String
        /// The date of the Date header, or when Mail received it when the header has none.
        var date: Date?
        /// When Mail received it, which the days of MailChoice count by. Nil when Mail gives
        /// no date.
        var dateReceived: Date?
        /// The sender as Mail gives it, such as "Mei Tan <mei@harbor.example>".
        var sender: String
        /// The address fields of the headers, with their names decoded. From, To and Cc
        /// fall back to what Mail lists when the headers hold none.
        var from: [MailAddressHeader]
        var replyTo: [MailAddressHeader]
        var to: [MailAddressHeader]
        var cc: [MailAddressHeader]
        /// The subject as Mail gives it, or decoded from the headers when Mail gives none.
        var subject: String
        /// The Message-IDs of In-Reply-To and References, without angle brackets.
        var inReplyTo: [String]
        var references: [String]
        var list: ListMail
        /// The attachments that have a file name, in the order of their parts, with the text
        /// of those MailAttachment reads.
        var attachments: [MailAttachment]
        /// The size in bytes, as Mail counts it.
        var size: Int
        /// The text a reader sees and the text the email hides. Nil for a message over
        /// `largestSource`, whose source is never read.
        var visible: VisibleText?
        /// The visible text split into the email's own text, its quoted history, its
        /// signature and the messages it forwards. Nil when `visible` is.
        var history: QuotedHistory?

        var isTooLarge: Bool {
            visible == nil
        }
    }

    /// What the scan reads from the store. Closures, so it never waits for the store and
    /// tests pass fakes.
    struct Lookups {
        /// Which of these Message-IDs are saved already. Throws when the store cannot say.
        var known: ([String]) async throws -> Set<String>
        /// The mailboxes linked to a project, read along with the chosen ones.
        var linkedMailboxes: () async -> [MailMailbox]
    }

    /// What one pass did, for the log, the window and the tests.
    nonisolated struct Pass: Sendable, Equatable {
        /// Why a pass asked Mail nothing, or nothing more.
        nonisolated enum Skip: Sendable, Equatable {
            case off
            case notConfirmed
            case mailNotRunning
            /// Another pass is under way, which reads the same new mail.
            case busy
            /// The store could not save what the pass read, or say which mail it knows.
            /// The next pass reads the mailbox back to the days again.
            case storeFailed
        }

        /// Why the pass asked Mail nothing, or why it stopped asking once it had started:
        /// Projects went off, the confirm was forgotten or the store failed.
        var skipped: Skip?
        var mailboxes = 0
        /// Messages whose source was read.
        var read = 0
        /// Messages over `largestSource`, of which only the headers were read.
        var tooLarge = 0
        /// Messages the store saved.
        var saved = 0
        /// Messages known already, or read already in this pass from another mailbox.
        var known = 0
        /// Messages Mail received before the chosen days.
        var older = 0
        var withoutMessageID = 0
        /// Messages gone from Mail between their listing and their reading.
        var gone = 0
        /// Messages Mail failed to give, or gave with no source. A later pass reads them
        /// again.
        var unreadable = 0
        /// Messages Mail did not give in time. Each waits, and a later pass asks for it
        /// again.
        var slow = 0
        /// Mailboxes and messages that wait after Mail did not answer in time lately, for
        /// them or for a linked mailbox that may file them, so the pass did not ask for them.
        var waiting = 0
        /// The error that ended the pass, or else the last one that ended a mailbox or left
        /// a mailbox or a message for later.
        var error: MailBridgeError?
        /// The error that ended the pass before it read every mailbox: Mail quit, Orra may
        /// not control it, or Mail did not answer for two mailboxes in a row.
        var stoppedBy: MailBridgeError?
    }

    /// What a pass tells the window. A pass that `stop()` ended, or one that found another
    /// under way, tells nothing more.
    nonisolated enum Report: Sendable, Equatable {
        /// A pass began to read. `readsBack` when it reads a mailbox back to the days, which
        /// takes much longer than a poll, or tries to, as for a mailbox Mail no longer has.
        case began(readsBack: Bool)
        case ended(Pass)
    }

    /// The positions a range covers (plan section 5).
    nonisolated static let rangeSize = 200
    /// How many messages are saved at once while a range is read (a guess). The window
    /// lists them at each save, so the first ten show after ten sources, not after a range.
    nonisolated static let saveBatch = 10
    /// How many new messages in a row Mail may not give in time before the scan leaves
    /// their mailbox for later, as one of an account that is offline, and how many
    /// mailboxes in a row before the pass ends, as Mail itself does not answer then.
    nonisolated static let slowInARow = 2
    /// The positions the first range of a poll covers, since new mail is usually little.
    nonisolated static let pollRangeSize = 20
    /// The positions each range shares with the one before. Mail removed above the scan
    /// meanwhile moves the later messages up, by fewer than this most of the time. When
    /// more move, the next pass reads the mailbox back to the days.
    nonisolated static let sharedPositions = 10
    /// How many passes in a row read a mailbox back to the days again while it holds a
    /// message left unread (a guess). After that the later passes only poll it, until a
    /// pass leaves nothing unread or the scan starts again.
    nonisolated static let readsBack = 3
    /// The largest message whose source is read, by the listing's size (a guess). It holds
    /// most mail with a few attachments, and keeps a single reply from Mail to tens of
    /// megabytes.
    nonisolated static let largestSource = 16 << 20
    /// How long the scan waits between passes (a guess).
    nonisolated static let pollInterval = Duration.seconds(60)
    /// The longest wait while Mail does not answer (a guess).
    nonisolated static let longestWait = Duration.seconds(30 * 60)
    /// How often the scan looks whether a dictation ended, as the folder index does.
    nonisolated static let dictationPoll = Duration.milliseconds(100)

    /// The order of a mailbox's positions.
    nonisolated enum Order: Sendable, Equatable {
        case newestFirst
        case oldestFirst
    }

    /// What the scan learned about a mailbox while it runs.
    private struct Progress {
        var order: Order?
        /// The days of the last pass that read the mailbox back to them or to its end. Nil
        /// before one did, and while a pass reads it.
        var readDays: Int?
        /// Passes in a row that left a message unread, or may have missed one.
        var incomplete = 0
        /// Set while the mailbox waits after Mail did not answer for it in time.
        var retry: Retry?
        /// The messages Mail did not give in time, by Message-ID. A pass that reaches one
        /// after its wait asks for it again, so the mailbox is read back to it then.
        var slow: [String: Retry] = [:]
    }

    /// When a mailbox or a message that Mail did not answer for in time is asked for again,
    /// on the clock of the loop's waits, so a pass that takes long never shortens it.
    private struct Retry {
        var at: Duration
        /// The wait before `at`, which the next one doubles.
        var wait: Duration
        var error: MailBridgeError
    }

    /// Why a pass reads nothing more.
    private struct Stop: Error {
        var reason: Pass.Skip
    }

    private let bridge: MailBridge
    private let choice: MailChoice
    private let lookups: Lookups
    private let save: ([Message]) async throws -> Void
    private let report: (Report) -> Void
    private let ownerOverride: SortingService.Owner?
    private let isOn: () -> Bool
    private let isDictating: () -> Bool
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var progress: [MailMailbox: Progress] = [:]
    /// The time the loop waited between its passes since the scan started, the clock of
    /// `Retry`.
    private var waited = Duration.zero
    /// The mailboxes of the last pass, of which the loop wakes for the first that may be
    /// read when all wait.
    private var lastMailboxes: [MailMailbox] = []
    /// The user as Mail's accounts gave it, read once while the scan runs.
    private var accountsOwner: SortingService.Owner?
    /// The time the loop had waited when Mail last did not give the accounts.
    private var accountsFailed: Duration?
    private var loop: Task<Void, Never>?
    /// The pass under way. Two passes at once would read the same mail twice.
    private var current: Task<Pass, Never>?

    /// - Parameters:
    ///   - save: saves the new messages of a range, newest first, and throws when it could
    ///     not. Each later call of a pass holds older mail than the one before, so a caller
    ///     that sorts the mail should do so after the pass, oldest first, such as with
    ///     `SortingService.sortWaiting()`.
    ///   - report: hears when each pass begins and ends, for the window.
    ///   - ownerOverride: the user's addresses and name in a Debug build that sets them, so
    ///     Mail's accounts are never read.
    ///   - isOn: whether Projects is on.
    ///   - isDictating: whether a dictation runs, from the press of a key until it is pasted
    ///     or cancelled, see EngineTurns.isDictating.
    ///   - now: the time, which the days count back from.
    ///   - sleep: waits between passes, Task.sleep in the app.
    init(
        bridge: MailBridge,
        choice: MailChoice,
        lookups: Lookups,
        save: @escaping ([Message]) async throws -> Void,
        report: @escaping (Report) -> Void = { _ in },
        ownerOverride: SortingService.Owner? = nil,
        isOn: @escaping () -> Bool,
        isDictating: @escaping () -> Bool = { false },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.bridge = bridge
        self.choice = choice
        self.lookups = lookups
        self.save = save
        self.report = report
        self.ownerOverride = ownerOverride
        self.isOn = isOn
        self.isDictating = isDictating
        self.now = now
        self.sleep = sleep
    }

    // MARK: Polling

    /// Starts polling: a pass at once, then one every `pollInterval`, longer while Mail
    /// does not answer. Call `stop()` when Projects turns off.
    func start() {
        guard loop == nil else { return }
        let sleep = self.sleep
        // The loop holds the scan only during a pass, so a scan let go without `stop()`
        // ends its loop at the next wake.
        loop = Task(priority: .utility) { [weak self] in
            var wait = MailScan.pollInterval
            while !Task.isCancelled, let pass = await self?.scan(leavesWaiting: true), let next = self?.wait(after: pass, previous: wait) {
                wait = next
                do {
                    try await sleep(wait)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.waited += wait
            }
        }
        Logger.projectsMail.notice("Mail scan: started")
    }

    /// Stops polling and the pass under way, which reads and saves nothing more, and
    /// forgets what the scan learned about the mailboxes and the user, so mailboxes and
    /// messages that waited are asked for again at once.
    func stop() {
        loop?.cancel()
        loop = nil
        current?.cancel()
        progress = [:]
        waited = .zero
        lastMailboxes = []
        accountsOwner = nil
        accountsFailed = nil
        Logger.projectsMail.notice("Mail scan: stopped")
    }

    /// The wait before the next pass. After Mail did not answer, timed out, or refused
    /// Orra, or after the store failed, twice the last wait, at least two poll intervals and
    /// at most `longestWait`. Otherwise one poll interval. A store that keeps failing, as on
    /// a full disk, would otherwise have each pass read a range of mail from Mail again,
    /// only to fail to save it.
    nonisolated static func wait(after error: MailBridgeError?, storeFailed: Bool = false, previous: Duration) -> Duration {
        let waitsLonger = switch error {
        case .notAnswered?, .timedOut?, .denied?, .notAsked?: true
        default: storeFailed
        }
        return waitsLonger ? min(max(previous * 2, pollInterval * 2), longestWait) : pollInterval
    }

    /// The loop's wait after a pass: as `wait(after:storeFailed:previous:)` for the error
    /// that stopped the pass, or once every mailbox waits, until the first may be read.
    private func wait(after pass: Pass, previous: Duration) -> Duration {
        let wait = Self.wait(after: pass.stoppedBy, storeFailed: pass.skipped == .storeFailed, previous: previous)
        guard wait == Self.pollInterval, pass.skipped == nil, !lastMailboxes.isEmpty else { return wait }
        let retries = lastMailboxes.map { progress[$0]?.retry?.at }
        guard !retries.contains(nil), let first = retries.compactMap(\.self).min() else { return wait }
        return max(first - waited, Self.pollInterval)
    }

    /// Whether Mail did not answer in time (-1712), or did not take the event while it runs
    /// (-600 or -609), which may pass.
    private nonisolated static func isSlow(_ error: MailBridgeError) -> Bool {
        switch error {
        case .timedOut, .notAnswered: true
        default: false
        }
    }

    /// When a mailbox or message that Mail did not answer for in time is asked for again:
    /// at the next pass of the loop, then after twice the last wait each time, up to
    /// `longestWait`.
    private func retry(after error: MailBridgeError, previous: Retry?) -> Retry {
        let wait = previous.map { min($0.wait * 2, Self.longestWait) } ?? Self.pollInterval
        return Retry(at: waited + wait, wait: wait, error: error)
    }

    /// Whether a mailbox or message waits now, after Mail did not answer for it in time.
    private func waits(_ retry: Retry?) -> Bool {
        retry.map { $0.at > waited } ?? false
    }

    // MARK: The user

    /// The user's own addresses and name: the override of a Debug build, else Mail's
    /// accounts, read once while the scan runs. Nil while Projects is off, before the user
    /// confirmed the mailbox choice, while Mail does not run, or when Mail does not answer.
    /// After Mail did not give the accounts, they are asked for again only once the loop
    /// waited, so the saves of one pass, ten messages each, do not ask again and again.
    func owner() async -> SortingService.Owner? {
        if let ownerOverride {
            return ownerOverride
        }
        if let accountsOwner {
            return accountsOwner
        }
        guard isOn(), choice.isConfirmed, bridge.isRunning(), accountsFailed != waited else { return nil }
        do {
            let accounts = try await bridge.accounts()
            var seen = Set<String>()
            let addresses = accounts.flatMap(\.addresses).filter { seen.insert($0).inserted }
            let owner = SortingService.Owner(addresses: addresses, name: accounts.map(\.fullName).first { !$0.isEmpty })
            accountsOwner = owner
            Logger.projectsMail.notice("Mail scan: \(accounts.count, privacy: .public) accounts with \(addresses.count, privacy: .public) addresses")
            return owner
        } catch {
            accountsFailed = waited
            Logger.projectsMail.error("Mail scan: reading the accounts failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: A pass

    /// Reads the new mail of every chosen and linked mailbox once, as the loop of `start()`
    /// does, but also asks for the mailboxes and messages that wait, as on the user's click.
    /// While another pass is under way it returns at once. That covers a `start()` right
    /// after `stop()`, while the stopped pass still waits for Mail's answer.
    @discardableResult
    func scan() async -> Pass {
        await scan(leavesWaiting: false)
    }

    /// A pass. With `leavesWaiting`, as the loop runs it, it asks nothing for the mailboxes
    /// and messages that wait after Mail did not answer for them in time.
    private func scan(leavesWaiting: Bool) async -> Pass {
        // A pass that `stop()` cancelled ends at its next step. A pass after `start()`, such
        // as when Mail opens again, waits for it rather than skip as busy for a poll interval.
        if let previous = current, previous.isCancelled {
            _ = await previous.value
            if current == previous {
                current = nil
            }
        }
        guard current == nil else {
            return Pass(skipped: .busy)
        }
        let task = Task(priority: .utility) { await self.readMailboxes(leavesWaiting: leavesWaiting) }
        current = task
        let pass = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        // A pass that waited for this one may run already.
        if current == task {
            current = nil
        }
        if !task.isCancelled {
            report(.ended(pass))
        }
        return pass
    }

    private func readMailboxes(leavesWaiting: Bool) async -> Pass {
        var pass = Pass()
        guard isOn() else {
            pass.skipped = .off
            return pass
        }
        guard choice.isConfirmed else {
            pass.skipped = .notConfirmed
            return pass
        }
        guard bridge.isRunning() else {
            pass.skipped = .mailNotRunning
            return pass
        }
        let started = ContinuousClock.now
        var unique = Set<MailMailbox>()
        // The linked mailboxes first: a message in a linked account Inbox, which the inbox
        // of all accounts lists too, is then saved with the mailbox that files it.
        let linked = (await lookups.linkedMailboxes()).filter { unique.insert($0).inserted }
        let mailboxes = linked + choice.mailboxes.filter { unique.insert($0).inserted }
        let days = choice.days
        lastMailboxes = mailboxes
        if !Task.isCancelled {
            // As the loop below decides, except for a linked mailbox Mail does not answer
            // for during the pass.
            let linkedWaits = leavesWaiting && linked.contains { waits(progress[$0]?.retry) }
            report(.began(readsBack: mailboxes.contains { mailbox in
                let skips = (leavesWaiting && waits(progress[mailbox]?.retry)) || (linkedWaits && !linked.contains(mailbox))
                return !skips && !polls(mailbox, days: days, leavesWaiting: leavesWaiting)
            }))
        }
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        var seen = Set<String>()
        // Mailboxes in a row that Mail did not answer for in time.
        var unanswered = 0
        for mailbox in mailboxes {
            if leavesWaiting, let retry = progress[mailbox]?.retry, waits(retry) {
                pass.waiting += 1
                pass.error = retry.error
                continue
            }
            let isLinked = linked.contains(mailbox)
            if !isLinked, let retry = linked.lazy.compactMap({ self.progress[$0]?.retry }).first {
                // A linked mailbox that Mail did not answer for may file mail this one lists
                // too. This one waits with it, so that mail is saved with the linked one.
                pass.waiting += 1
                pass.error = retry.error
                continue
            }
            do {
                try checkMayRead()
                pass.mailboxes += 1
                let held = isLinked ? [:] : waitingMessages(in: linked)
                try await read(mailbox, cutoff: cutoff, days: days, leavesWaiting: leavesWaiting, held: held, seen: &seen, pass: &pass)
                progress[mailbox]?.retry = nil
                unanswered = 0
            } catch let stop as Stop {
                pass.skipped = stop.reason
                break
            } catch let error as MailBridgeError where Self.isSlow(error) {
                // After `stop()` the scan forgot the mailbox, and notes no wait for it again.
                guard !Task.isCancelled else { break }
                // Only this mailbox waits, so an account that is offline holds up no other,
                // unless Mail itself does not answer.
                pass.error = error
                progress[mailbox, default: Self.progress(of: mailbox)].retry = retry(after: error, previous: progress[mailbox]?.retry)
                unanswered += 1
                if unanswered >= Self.slowInARow {
                    pass.stoppedBy = error
                    break
                }
            } catch let error as MailBridgeError {
                pass.error = error
                // Mail quit, or Orra may not read it: the pass ends. A mailbox that is gone
                // or changed only skips that mailbox.
                if !Self.endsOnlyItsMailbox(error) {
                    pass.stoppedBy = error
                    break
                }
                // Mail answered for it, so it waits no more.
                progress[mailbox]?.retry = nil
                unanswered = 0
            } catch {
                break
            }
        }
        log(pass, since: started)
        return pass
    }

    /// What the scan knows of a mailbox before it read it: the Inbox is newest first.
    private static func progress(of mailbox: MailMailbox) -> Progress {
        Progress(order: mailbox.kind == .inbox ? .newestFirst : nil)
    }

    /// The messages that wait in these linked mailboxes, by Message-ID. A mailbox that is
    /// not linked leaves them to the linked one, which files them.
    private func waitingMessages(in linked: [MailMailbox]) -> [String: Retry] {
        linked.reduce(into: [:]) { waiting, mailbox in
            waiting.merge(progress[mailbox]?.slow ?? [:]) { first, _ in first }
        }
    }

    /// Whether a pass only polls the mailbox: one read it back to the days before, and no
    /// message that Mail did not give in time may be asked for again yet.
    private func polls(_ mailbox: MailMailbox, days: Int, leavesWaiting: Bool) -> Bool {
        guard let state = progress[mailbox], (state.readDays ?? 0) >= days else { return false }
        return !state.slow.values.contains { !leavesWaiting || !waits($0) }
    }

    /// Throws when the pass may read nothing more: it was cancelled, Projects went off, or
    /// the confirm was forgotten.
    private func checkMayRead() throws {
        try Task.checkCancellation()
        guard isOn() else { throw Stop(reason: .off) }
        guard choice.isConfirmed else { throw Stop(reason: .notConfirmed) }
    }

    /// Whether an error ends only the mailbox it came from, not the pass.
    private nonisolated static func endsOnlyItsMailbox(_ error: MailBridgeError) -> Bool {
        switch error {
        case .notFound, .changedWhileReading, .unexpectedReply, .failed: true
        case .mailNotRunning, .notAnswered, .timedOut, .denied, .notAsked: false
        }
    }

    /// Whether an error of reading one message skips only that message: it is gone, or
    /// Mail could not give it.
    private nonisolated static func endsOnlyItsMessage(_ error: MailBridgeError) -> Bool {
        switch error {
        case .notFound, .unexpectedReply, .failed: true
        case .mailNotRunning, .notAnswered, .timedOut, .denied, .notAsked, .changedWhileReading: false
        }
    }

    /// Reads one mailbox, range by range from its newest message, until the days or its
    /// end. Once a pass read it back to the days, the next ones only poll it: they end
    /// after the first range that holds a message known before the pass. A message that
    /// Mail did not give in time has the mailbox read back to it once its wait is over.
    /// `held` are the messages that wait in a linked mailbox, which this one leaves to it.
    private func read(
        _ mailbox: MailMailbox,
        cutoff: Date,
        days: Int,
        leavesWaiting: Bool,
        held: [String: Retry],
        seen: inout Set<String>,
        pass: inout Pass
    ) async throws {
        var total = try await bridge.count(mailbox)
        try checkMayRead()
        let polls = self.polls(mailbox, days: days, leavesWaiting: leavesWaiting)
        var state = progress[mailbox] ?? Self.progress(of: mailbox)
        let readBefore = state.readDays
        // Until this pass is done, the next one reads back to the days, so a pass that ends
        // midway misses nothing.
        state.readDays = nil
        progress[mailbox] = state
        // The messages that wait stay noted when Mail stops answering midway, unless the
        // scan stopped and forgot the mailbox.
        defer {
            progress[mailbox]?.slow = state.slow
        }
        let unreadable = pass.unreadable
        var complete = true
        // Mail's ids of the messages this pass listed in this mailbox, and their Message-IDs.
        var listed = Set<Int>()
        var met = Set<String>()
        // Counted from the newest message: the first not listed yet.
        var next = 1
        var size = polls ? Self.pollRangeSize : Self.rangeSize
        while true {
            try checkMayRead()
            if next > total {
                // New mail on top of a mailbox read newest first moves its oldest messages
                // past the count. Mail read from its end gets new mail after it.
                guard total > 0, state.order != .oldestFirst else { break }
                let counted = try await bridge.count(mailbox)
                try checkMayRead()
                guard counted > total else { break }
                total = counted
            }
            let shared = next > 1 ? min(Self.sharedPositions, next - 1) : 0
            let first = next - shared
            let last = min(first + size - 1, total)
            let fromEnd = state.order == .oldestFirst
            let positions = fromEnd ? (total - last + 1)...(total - first + 1) : first...last
            var listings = try await bridge.listing(mailbox, positions)
            try checkMayRead()
            if fromEnd {
                listings.reverse()
            }
            if next == 1, state.order == nil, let order = Self.order(of: listings) {
                state.order = order
                progress[mailbox] = state
                if order == .oldestFirst {
                    // Read it again from the end, so the newest come first.
                    if last < total {
                        continue
                    }
                    listings.reverse()
                }
            }
            if shared > 0, !listings.prefix(shared).contains(where: { listed.contains($0.message.id) }) {
                // More mail than the shared positions was removed above the scan, so some
                // messages may have moved past it.
                complete = false
            }
            next = last + 1
            size = Self.rangeSize
            let done = try await take(
                listings, cutoff: cutoff, polls: polls, leavesWaiting: leavesWaiting, held: held,
                listed: &listed, met: &met, slow: &state.slow, seen: &seen, pass: &pass)
            if done {
                break
            }
        }
        try checkMayRead()
        if !polls {
            // A message that waits and that a pass back to the days did not meet is gone.
            state.slow = state.slow.filter { met.contains($0.key) }
        }
        if pass.unreadable > unreadable {
            complete = false
        }
        state.incomplete = complete ? 0 : state.incomplete + 1
        if complete || state.incomplete > Self.readsBack {
            state.readDays = max(readBefore ?? 0, days)
        }
        progress[mailbox] = state
    }

    /// The order of a mailbox from the dates of a range, read in the order of its
    /// positions: oldest first when more neighbors rise than fall, else newest first. So
    /// one date out of place, such as of a message moved back into the mailbox, does not
    /// turn it. Nil while no two neighbors differ.
    nonisolated static func order(of listings: [MailListing]) -> Order? {
        let dates = listings.compactMap(\.dateReceived)
        var rising = 0
        var falling = 0
        for (earlier, later) in zip(dates, dates.dropFirst()) {
            if earlier < later {
                rising += 1
            } else if later < earlier {
                falling += 1
            }
        }
        guard rising + falling > 0 else { return nil }
        return rising > falling ? .oldestFirst : .newestFirst
    }

    /// Reads and saves the new messages of a range, newest first, and skips those listed
    /// before in this pass. True when the mailbox is done: the oldest message of the range
    /// came before the days, or, while the mailbox is polled, the range held a message
    /// known before the pass. A message that Mail does not give in time waits in `slow`,
    /// and the range goes on, unless `slowInARow` in a row do not come, which ends the
    /// mailbox. A message in `held` waits in `slow` too, with the wait it has in a linked
    /// mailbox, and is never read here.
    private func take(
        _ listings: [MailListing],
        cutoff: Date,
        polls: Bool,
        leavesWaiting: Bool,
        held: [String: Retry],
        listed: inout Set<Int>,
        met: inout Set<String>,
        slow: inout [String: Retry],
        seen: inout Set<String>,
        pass: inout Pass
    ) async throws -> Bool {
        let fresh = listings.filter { listed.insert($0.message.id).inserted }
        let ids = fresh.map(\.messageID).filter { !$0.isEmpty }
        let known: Set<String>
        do {
            known = ids.isEmpty ? [] : try await lookups.known(ids)
        } catch {
            throw Stop(reason: .storeFailed)
        }
        var found: [Message] = []
        var knownBefore = false
        // Slow answers in a row, and whether messages that waited are asked for again. They
        // come after the others of the range, so two that never come hold up no other mail.
        var unanswered = 0
        var asksAgain = true
        let ordered = fresh.filter { slow[$0.messageID] == nil } + fresh.filter { slow[$0.messageID] != nil }
        do {
            for listing in ordered {
                // Noted again below only while it still waits.
                let retry = slow.removeValue(forKey: listing.messageID)
                met.insert(listing.messageID)
                if let date = listing.dateReceived, date < cutoff {
                    pass.older += 1
                    continue
                }
                guard !listing.messageID.isEmpty else {
                    pass.withoutMessageID += 1
                    continue
                }
                // Read in this pass, from another mailbox or from this one before new mail
                // moved it. The store knows it by now, but it says nothing of older mail.
                if seen.contains(listing.messageID) {
                    pass.known += 1
                    continue
                }
                if known.contains(listing.messageID) {
                    pass.known += 1
                    knownBefore = true
                    continue
                }
                if let wait = held[listing.messageID] {
                    // The linked mailbox that files it asks for it again. This one reads back
                    // to it once that wait is over, and reads it then if the linked one no
                    // longer has it.
                    slow[listing.messageID] = wait
                    pass.waiting += 1
                    pass.error = wait.error
                    continue
                }
                if let retry, !asksAgain || (leavesWaiting && waits(retry)) {
                    slow[listing.messageID] = retry
                    pass.waiting += 1
                    pass.error = retry.error
                    continue
                }
                try checkMayRead()
                do {
                    found.append(try await message(listing, pass: &pass))
                    seen.insert(listing.messageID)
                    unanswered = 0
                    if found.count >= Self.saveBatch {
                        let batch = found
                        found = []
                        try await keep(batch, pass: &pass)
                    }
                } catch let error as MailBridgeError where Self.endsOnlyItsMessage(error) {
                    unanswered = 0
                    if error == .notFound {
                        pass.gone += 1
                    } else {
                        pass.unreadable += 1
                    }
                } catch let error as MailBridgeError where Self.isSlow(error) {
                    slow[listing.messageID] = self.retry(after: error, previous: retry)
                    pass.slow += 1
                    pass.error = error
                    unanswered += 1
                    if unanswered >= Self.slowInARow {
                        // Mail gives nothing in time here now, as for an account that is
                        // offline. Mail not asked for yet ends the mailbox, and a message
                        // that waited before leaves the others that waited for later.
                        guard retry != nil else { throw error }
                        asksAgain = false
                    }
                }
            }
        } catch {
            // What was read before Mail quit or stopped answering is kept. Nothing is saved
            // after `stop()`, or once Projects is off. The error ends the mailbox, so the
            // next pass reads it back to the days again, also when this save fails.
            try? await keep(found, pass: &pass)
            throw error
        }
        try await keep(found, pass: &pass)
        if let oldest = listings.last?.dateReceived, oldest < cutoff {
            return true
        }
        return polls && knownBefore
    }

    /// Saves the new messages of a range and counts them. Throws when the store could not
    /// save them, which ends the pass.
    private func keep(_ found: [Message], pass: inout Pass) async throws {
        guard !found.isEmpty, !Task.isCancelled, isOn(), choice.isConfirmed else { return }
        do {
            try await save(found)
        } catch {
            throw Stop(reason: .storeFailed)
        }
        pass.saved += found.count
    }

    /// Reads one message: its source, or for a message that is too large its headers and
    /// its attachments' names and types.
    private func message(_ listing: MailListing, pass: inout Pass) async throws -> Message {
        if listing.size > Self.largestSource {
            let headers = try await bridge.headers(listing.message)
            let attachments = try await bridge.attachments(listing.message)
            pass.tooLarge += 1
            return await Self.parsed(headers: headers, attachments: attachments, listing: listing)
        }
        let source = try await bridge.source(listing.message)
        // Mail may give no source for a message whose body it has not downloaded yet
        // (unverified). Saved, it would stay known with no text.
        guard !source.isEmpty else { throw MailBridgeError.unexpectedReply }
        pass.read += 1
        await waitWhileDictating()
        return await Self.parsed(source: source, listing: listing) { [weak self] in
            await self?.waitWhileDictating()
        }
    }

    /// Returns once no dictation runs, or once the pass is cancelled.
    private func waitWhileDictating() async {
        while isDictating() && !Task.isCancelled {
            try? await sleep(Self.dictationPoll)
        }
    }

    // MARK: Parsing

    /// Parses a source off the main actor, since a large message takes a while, and reads
    /// the text of its attachments from their parts, each once `waitWhileDictating` returns.
    @concurrent
    nonisolated static func parsed(
        source: String,
        listing: MailListing,
        waitWhileDictating: @Sendable () async -> Void = {}
    ) async -> Message {
        let mime = MIMEMessage(source: source, limits: MailAttachment.mimeLimits())
        let visible = VisibleText(mime)
        let date = mime.headers.date ?? listing.dateReceived ?? .distantPast
        let attachments = await MailAttachment.read(mime.attachments, modified: date, waitWhileDictating: waitWhileDictating)
        return message(listing, headers: mime.headers, attachments: attachments, visible: visible)
    }

    /// A message that is too large, from its headers and Mail's list of its attachments.
    @concurrent
    nonisolated static func parsed(headers: String, attachments: [MailAttachmentInfo], listing: MailListing) async -> Message {
        let named = attachments.filter { !$0.name.isEmpty }.map { attachment in
            MailAttachment(name: attachment.name, type: attachment.mimeType, size: attachment.size,
                           state: attachment.isDownloaded ? .emailTooLarge : .notDownloaded)
        }
        return message(listing, headers: MailHeaders(parsing: headers), attachments: named, visible: nil)
    }

    private nonisolated static func message(_ listing: MailListing, headers: MailHeaders, attachments: [MailAttachment], visible: VisibleText?) -> Message {
        func listed(_ addresses: [String]) -> [MailAddressHeader] {
            addresses.map { MailAddressHeader(name: "", address: $0) }
        }
        let from = headers.from
        let to = headers.to
        let cc = headers.cc
        let subject = listing.subject.isEmpty ? headers.subject ?? "" : listing.subject
        return Message(
            reference: listing.message,
            messageID: listing.messageID,
            date: headers.date ?? listing.dateReceived,
            dateReceived: listing.dateReceived,
            sender: listing.sender,
            from: from.isEmpty ? MailAddressHeader.list(listing.sender) : from,
            replyTo: headers.replyTo,
            to: to.isEmpty ? listed(listing.to) : to,
            cc: cc.isEmpty ? listed(listing.cc) : cc,
            subject: subject,
            inReplyTo: headers.inReplyTo,
            references: headers.references,
            list: ListMail(
                listID: headers["List-Id"].map(MailHeaders.decodedWords),
                listUnsubscribe: headers["List-Unsubscribe"],
                precedence: headers["Precedence"]
            ),
            attachments: attachments,
            size: listing.size,
            visible: visible,
            // The subject tells a forward that Outlook writes like a reply.
            history: visible.map { QuotedHistory(splitting: $0.text, subject: subject) }
        )
    }

    // MARK: Log

    private func log(_ pass: Pass, since started: ContinuousClock.Instant) {
        let milliseconds = Int(started.duration(to: .now) / .milliseconds(1))
        let counts = "\(pass.mailboxes) mailboxes, \(pass.read) read, \(pass.tooLarge) too large, \(pass.saved) saved, \(pass.known) known, \(pass.older) older, \(pass.withoutMessageID) without a Message-ID, \(pass.gone) gone, \(pass.unreadable) unreadable, \(pass.slow) slow, \(pass.waiting) waiting, in \(milliseconds) ms"
        if let skipped = pass.skipped {
            Logger.projectsMail.notice("Mail scan: \(counts, privacy: .public), stopped: \(String(describing: skipped), privacy: .public)")
        } else if let error = pass.error {
            Logger.projectsMail.notice("Mail scan: \(counts, privacy: .public), \(String(describing: error), privacy: .public)")
        } else if pass.saved > 0 {
            Logger.projectsMail.notice("Mail scan: \(counts, privacy: .public)")
        } else {
            Logger.projectsMail.debug("Mail scan: \(counts, privacy: .public)")
        }
    }
}
