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
/// - For each new message it reads the raw source and parses it off the main actor with
///   MIMEMessage, VisibleText and QuotedHistory. Mail's `content` is never read. A message
///   over `largestSource` bytes by the listing's size is too large: only its headers and
///   its attachments' names and types are read. Of attachments only names and types are
///   kept (decision 14). A message Mail cannot give, or gives with no source, is not saved,
///   and a later pass reads it again.
/// - It saves the new messages of each range through a closure, and asks which messages
///   are known through another, so it never waits for the store and tests pass fakes.
/// - It polls every minute. When Mail does not answer (-600 while it runs), times out
///   (-1712), or Orra may not control it, the pass ends and the scan waits twice as long
///   each time, up to 30 minutes.
///
/// The user's own addresses and name come from Mail's accounts, or from the override that
/// a Debug build passes in, with which the scan never asks Mail for the accounts.
///
/// Logs counts, times and error codes only.
final class MailScan {
    /// An attachment as the scan keeps it: its name and type, never its content.
    nonisolated struct Attachment: Sendable, Equatable {
        var name: String
        /// The MIME type in lowercase, such as application/pdf.
        var mimeType: String
    }

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
        /// The attachments that have a file name, in the order of their parts.
        var attachments: [Attachment]
        /// The size in bytes, as Mail counts it.
        var size: Int
        /// The text a reader sees and the text the email hides. Nil for a message over
        /// `largestSource`, whose source is never read.
        var visible: VisibleText?
        /// The visible text split into the email's own text, its quoted history and its
        /// signature. Nil when `visible` is.
        var history: QuotedHistory?

        var isTooLarge: Bool {
            visible == nil
        }
    }

    /// What the scan reads from the store. Closures, so it never waits for the store and
    /// tests pass fakes.
    struct Lookups {
        /// Which of these Message-IDs are saved already.
        var known: ([String]) async -> Set<String>
        /// The mailboxes linked to a project, read along with the chosen ones.
        var linkedMailboxes: () async -> [MailMailbox]
    }

    /// What one pass did, for the log and the tests.
    nonisolated struct Pass: Sendable, Equatable {
        /// Why a pass asked Mail nothing, or nothing more.
        nonisolated enum Skip: Sendable, Equatable {
            case off
            case notConfirmed
            case mailNotRunning
            /// Another pass is under way, which reads the same new mail.
            case busy
        }

        /// Why the pass asked Mail nothing, or why it stopped asking once it had started:
        /// Projects went off or the confirm was forgotten.
        var skipped: Skip?
        var mailboxes = 0
        /// Messages whose source was read.
        var read = 0
        /// Messages over `largestSource`, of which only the headers were read.
        var tooLarge = 0
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
        /// The error that ended the pass, or else the last one that ended a mailbox.
        var error: MailBridgeError?
    }

    /// The positions a range covers (plan section 5).
    nonisolated static let rangeSize = 200
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
    }

    /// Why a pass reads nothing more.
    private struct Stop: Error {
        var reason: Pass.Skip
    }

    private let bridge: MailBridge
    private let choice: MailChoice
    private let lookups: Lookups
    private let save: ([Message]) async -> Void
    private let ownerOverride: SortingService.Owner?
    private let isOn: () -> Bool
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var progress: [MailMailbox: Progress] = [:]
    /// The user as Mail's accounts gave it, read once while the scan runs.
    private var accountsOwner: SortingService.Owner?
    private var loop: Task<Void, Never>?
    /// The pass under way. Two passes at once would read the same mail twice.
    private var current: Task<Pass, Never>?

    /// - Parameters:
    ///   - save: saves the new messages of a range, newest first. Each later call of a pass
    ///     holds older mail than the one before, so a caller that sorts the mail should do
    ///     so after the pass, oldest first, such as with `SortingService.sortWaiting()`.
    ///   - ownerOverride: the user's addresses and name in a Debug build that sets them, so
    ///     Mail's accounts are never read.
    ///   - isOn: whether Projects is on.
    ///   - now: the time, which the days count back from.
    ///   - sleep: waits between passes, Task.sleep in the app.
    init(
        bridge: MailBridge,
        choice: MailChoice,
        lookups: Lookups,
        save: @escaping ([Message]) async -> Void,
        ownerOverride: SortingService.Owner? = nil,
        isOn: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.bridge = bridge
        self.choice = choice
        self.lookups = lookups
        self.save = save
        self.ownerOverride = ownerOverride
        self.isOn = isOn
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
        loop = Task { [weak self] in
            var wait = MailScan.pollInterval
            while !Task.isCancelled, let pass = await self?.scan() {
                wait = MailScan.wait(after: pass.error, previous: wait)
                do {
                    try await sleep(wait)
                } catch {
                    return
                }
            }
        }
        Logger.projectsMail.notice("Mail scan: started")
    }

    /// Stops polling and the pass under way, which reads and saves nothing more, and
    /// forgets what the scan learned about the mailboxes and the user.
    func stop() {
        loop?.cancel()
        loop = nil
        current?.cancel()
        progress = [:]
        accountsOwner = nil
        Logger.projectsMail.notice("Mail scan: stopped")
    }

    /// The wait before the next pass. After Mail did not answer, timed out, or refused
    /// Orra, twice the last wait, at least two poll intervals and at most `longestWait`.
    /// Otherwise one poll interval.
    nonisolated static func wait(after error: MailBridgeError?, previous: Duration) -> Duration {
        switch error {
        case .notAnswered?, .timedOut?, .denied?, .notAsked?:
            min(max(previous * 2, pollInterval * 2), longestWait)
        default:
            pollInterval
        }
    }

    // MARK: The user

    /// The user's own addresses and name: the override of a Debug build, else Mail's
    /// accounts, read once while the scan runs. Nil while Projects is off, before the user
    /// confirmed the mailbox choice, while Mail does not run, or when Mail does not answer.
    func owner() async -> SortingService.Owner? {
        if let ownerOverride {
            return ownerOverride
        }
        if let accountsOwner {
            return accountsOwner
        }
        guard isOn(), choice.isConfirmed, bridge.isRunning() else { return nil }
        do {
            let accounts = try await bridge.accounts()
            var seen = Set<String>()
            let addresses = accounts.flatMap(\.addresses).filter { seen.insert($0).inserted }
            let owner = SortingService.Owner(addresses: addresses, name: accounts.map(\.fullName).first { !$0.isEmpty })
            accountsOwner = owner
            Logger.projectsMail.notice("Mail scan: \(accounts.count, privacy: .public) accounts with \(addresses.count, privacy: .public) addresses")
            return owner
        } catch {
            Logger.projectsMail.error("Mail scan: reading the accounts failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: A pass

    /// Reads the new mail of every chosen and linked mailbox once, as the loop of `start()`
    /// does. While another pass is under way it returns at once. That covers a `start()`
    /// right after `stop()`, while the stopped pass still waits for Mail's answer.
    @discardableResult
    func scan() async -> Pass {
        guard current == nil else {
            return Pass(skipped: .busy)
        }
        let task = Task { await self.readMailboxes() }
        current = task
        let pass = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        current = nil
        return pass
    }

    private func readMailboxes() async -> Pass {
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
        let mailboxes = ((await lookups.linkedMailboxes()) + choice.mailboxes).filter { unique.insert($0).inserted }
        let days = choice.days
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        var seen = Set<String>()
        for mailbox in mailboxes {
            do {
                try checkMayRead()
                pass.mailboxes += 1
                try await read(mailbox, cutoff: cutoff, days: days, seen: &seen, pass: &pass)
            } catch let stop as Stop {
                pass.skipped = stop.reason
                break
            } catch let error as MailBridgeError {
                pass.error = error
                // Mail quit, does not answer, or Orra may not read it: the pass ends. A
                // mailbox that is gone or changed only skips that mailbox.
                if !Self.endsOnlyItsMailbox(error) {
                    break
                }
            } catch {
                break
            }
        }
        log(pass, since: started)
        return pass
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
    /// after the first range that holds a message known before the pass.
    private func read(_ mailbox: MailMailbox, cutoff: Date, days: Int, seen: inout Set<String>, pass: inout Pass) async throws {
        var total = try await bridge.count(mailbox)
        try checkMayRead()
        var state = progress[mailbox] ?? Progress(order: mailbox.kind == .inbox ? .newestFirst : nil)
        let readBefore = state.readDays
        let polls = (readBefore ?? 0) >= days
        // Until this pass is done, the next one reads back to the days, so a pass that ends
        // midway misses nothing.
        state.readDays = nil
        progress[mailbox] = state
        let unreadable = pass.unreadable
        var complete = true
        // Mail's ids of the messages this pass listed in this mailbox.
        var listed = Set<Int>()
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
            if try await take(listings, cutoff: cutoff, polls: polls, listed: &listed, seen: &seen, pass: &pass) {
                break
            }
        }
        try checkMayRead()
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
    /// known before the pass.
    private func take(
        _ listings: [MailListing],
        cutoff: Date,
        polls: Bool,
        listed: inout Set<Int>,
        seen: inout Set<String>,
        pass: inout Pass
    ) async throws -> Bool {
        let fresh = listings.filter { listed.insert($0.message.id).inserted }
        let ids = fresh.map(\.messageID).filter { !$0.isEmpty }
        let known = ids.isEmpty ? [] : await lookups.known(ids)
        var found: [Message] = []
        var knownBefore = false
        do {
            for listing in fresh {
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
                try checkMayRead()
                do {
                    found.append(try await message(listing, pass: &pass))
                    seen.insert(listing.messageID)
                } catch let error as MailBridgeError where Self.endsOnlyItsMessage(error) {
                    if error == .notFound {
                        pass.gone += 1
                    } else {
                        pass.unreadable += 1
                    }
                }
            }
        } catch {
            // What was read before Mail quit or stopped answering is kept. Nothing is saved
            // after `stop()`, or once Projects is off.
            await keep(found, pass: &pass)
            throw error
        }
        await keep(found, pass: &pass)
        if let oldest = listings.last?.dateReceived, oldest < cutoff {
            return true
        }
        return polls && knownBefore
    }

    private func keep(_ found: [Message], pass: inout Pass) async {
        guard !found.isEmpty, !Task.isCancelled, isOn(), choice.isConfirmed else { return }
        await save(found)
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
        return await Self.parsed(source: source, listing: listing)
    }

    // MARK: Parsing

    /// Parses a source off the main actor, since a large message takes a while.
    @concurrent
    nonisolated static func parsed(source: String, listing: MailListing) async -> Message {
        let mime = MIMEMessage(source: source)
        let visible = VisibleText(mime)
        let attachments = mime.attachments.compactMap { part -> Attachment? in
            guard let name = part.name, !name.isEmpty else { return nil }
            return Attachment(name: name, mimeType: part.mimeType)
        }
        return message(listing, headers: mime.headers, attachments: attachments, visible: visible)
    }

    /// A message that is too large, from its headers and Mail's list of its attachments.
    @concurrent
    nonisolated static func parsed(headers: String, attachments: [MailAttachmentInfo], listing: MailListing) async -> Message {
        let named = attachments.filter { !$0.name.isEmpty }.map { Attachment(name: $0.name, mimeType: $0.mimeType) }
        return message(listing, headers: MailHeaders(parsing: headers), attachments: named, visible: nil)
    }

    private nonisolated static func message(_ listing: MailListing, headers: MailHeaders, attachments: [Attachment], visible: VisibleText?) -> Message {
        func listed(_ addresses: [String]) -> [MailAddressHeader] {
            addresses.map { MailAddressHeader(name: "", address: $0) }
        }
        let from = headers.from
        let to = headers.to
        let cc = headers.cc
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
            subject: listing.subject.isEmpty ? headers.subject ?? "" : listing.subject,
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
            history: visible.map { QuotedHistory(splitting: $0.text) }
        )
    }

    // MARK: Log

    private func log(_ pass: Pass, since started: ContinuousClock.Instant) {
        let milliseconds = Int(started.duration(to: .now) / .milliseconds(1))
        let counts = "\(pass.mailboxes) mailboxes, \(pass.read) read, \(pass.tooLarge) too large, \(pass.saved) saved, \(pass.known) known, \(pass.older) older, \(pass.withoutMessageID) without a Message-ID, \(pass.gone) gone, \(pass.unreadable) unreadable, in \(milliseconds) ms"
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
