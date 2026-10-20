import Foundation
import os

/// Reads new mail from the Mail mailboxes the user chose, and from those linked to a
/// project, while Mail runs and Projects is on.
///
/// - Nothing is read before the user confirmed the mailbox choice once, see MailChoice.
///   Then only the chosen and the linked mailboxes are read, and in them only mail Mail
///   received within the chosen days. Mail is never opened, and nothing is read while it
///   does not run.
/// - A mailbox is read in ranges of 200 positions, never with `whose`. The spike found the
///   Inbox newest first. The order of other mailboxes is unverified, so a mailbox whose
///   first range shows its dates oldest first is read from its end.
/// - The first pass over a mailbox while the scan runs reads back to the days, and skips
///   the messages already known without reading them again. A pass that stopped midway,
///   such as when Mail quit, so finishes later. Once a pass reached the days, the next
///   ones stop at the first known Message-ID, and start with the newest 20.
/// - For each new message it reads the raw source and parses it off the main actor with
///   MIMEMessage, VisibleText and QuotedHistory. Mail's `content` is never read. A message
///   over `largestSource` bytes by the listing's size is too large: only its headers and
///   its attachments' names and types are read. Of attachments only names and types are
///   kept (decision 14).
/// - It saves the new messages of each range through a closure, and asks which messages
///   are known through another, so it never waits for the store and tests pass fakes.
/// - It polls every minute. When Mail does not answer (-600 while it runs) or times out
///   (-1712), the pass ends and the scan waits twice as long each time, up to 30 minutes.
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
        /// Why a pass asked Mail nothing.
        nonisolated enum Skip: Sendable, Equatable {
            case off
            case notConfirmed
            case mailNotRunning
            /// Another pass is under way, which reads the same new mail.
            case busy
        }

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
        /// The error that ended the pass, or else the last one that ended a mailbox.
        var error: MailBridgeError?
    }

    /// The positions a range covers (plan section 5).
    nonisolated static let rangeSize = 200
    /// The positions the first range of a poll covers, since new mail is usually little.
    nonisolated static let pollRangeSize = 20
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
        /// The days of the last pass that reached them or the end of the mailbox, nil
        /// before one did.
        var readDays: Int?
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
    /// Whether a pass is under way. Two passes at once would read the same mail twice.
    private var isScanning = false

    /// - Parameters:
    ///   - save: saves the new messages of a range, newest first.
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
    /// does not answer. Call `stop()` when Projects turns off, before letting the scan go.
    func start() {
        guard loop == nil else { return }
        loop = Task { await self.poll() }
        Logger.projectsMail.notice("Mail scan: started")
    }

    /// Stops polling and the pass under way, which saves nothing more, and forgets what
    /// the scan learned about the mailboxes and the user.
    func stop() {
        loop?.cancel()
        loop = nil
        progress = [:]
        accountsOwner = nil
        Logger.projectsMail.notice("Mail scan: stopped")
    }

    private func poll() async {
        var wait = Self.pollInterval
        while !Task.isCancelled {
            let pass = await scan()
            wait = Self.wait(after: pass.error, previous: wait)
            do {
                try await sleep(wait)
            } catch {
                return
            }
        }
    }

    /// The wait before the next pass. After Mail did not answer or timed out, twice the
    /// last wait, at least two poll intervals and at most `longestWait`. Otherwise one poll
    /// interval.
    nonisolated static func wait(after error: MailBridgeError?, previous: Duration) -> Duration {
        switch error {
        case .notAnswered?, .timedOut?:
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

    /// Reads the new mail of every chosen and linked mailbox once. The loop of `start()`
    /// calls it, and so may a click that should not wait for the next poll. While another
    /// pass is under way it returns at once.
    @discardableResult
    func scan() async -> Pass {
        var pass = Pass()
        guard !isScanning else {
            pass.skipped = .busy
            return pass
        }
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
        isScanning = true
        defer { isScanning = false }
        let started = ContinuousClock.now
        var unique = Set<MailMailbox>()
        let mailboxes = (choice.mailboxes + (await lookups.linkedMailboxes())).filter { unique.insert($0).inserted }
        let days = choice.days
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        var seen = Set<String>()
        for mailbox in mailboxes {
            guard !Task.isCancelled else { break }
            pass.mailboxes += 1
            do {
                try await read(mailbox, cutoff: cutoff, days: days, seen: &seen, pass: &pass)
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

    /// Whether an error ends only the mailbox it came from, not the pass.
    private nonisolated static func endsOnlyItsMailbox(_ error: MailBridgeError) -> Bool {
        switch error {
        case .notFound, .changedWhileReading, .unexpectedReply, .failed: true
        case .mailNotRunning, .notAnswered, .timedOut, .denied, .notAsked: false
        }
    }

    /// Reads one mailbox, range by range from its newest message, until the days, the end,
    /// or, once a pass reached the days, the first known message.
    private func read(_ mailbox: MailMailbox, cutoff: Date, days: Int, seen: inout Set<String>, pass: inout Pass) async throws {
        let total = try await bridge.count(mailbox)
        var state = progress[mailbox] ?? Progress()
        let polls = (state.readDays ?? 0) >= days
        var done = 0
        var size = polls ? Self.pollRangeSize : Self.rangeSize
        while done < total {
            try Task.checkCancellation()
            let length = min(size, total - done)
            let fromEnd = state.order == .oldestFirst
            let positions = fromEnd ? (total - done - length + 1)...(total - done) : (done + 1)...(done + length)
            var listings = try await bridge.listing(mailbox, positions)
            if fromEnd {
                listings.reverse()
            }
            if state.order == nil, let order = Self.order(of: listings) {
                state.order = order
                progress[mailbox] = state
                if order == .oldestFirst {
                    // Read it again from the end, so the newest come first.
                    if length < total {
                        continue
                    }
                    listings.reverse()
                }
            }
            done += length
            size = Self.rangeSize
            if try await take(listings, cutoff: cutoff, stopsAtKnown: polls, seen: &seen, pass: &pass) {
                break
            }
        }
        try Task.checkCancellation()
        state.readDays = max(state.readDays ?? 0, days)
        progress[mailbox] = state
    }

    /// The order of a mailbox from the dates of a range, read in the order of its
    /// positions: oldest first when the first date is older than the last, else newest
    /// first. Nil with fewer than two dates.
    nonisolated static func order(of listings: [MailListing]) -> Order? {
        let dates = listings.compactMap(\.dateReceived)
        guard dates.count >= 2, let first = dates.first, let last = dates.last else { return nil }
        return first < last ? .oldestFirst : .newestFirst
    }

    /// Reads and saves the new messages of a range, newest first. True when the mailbox is
    /// done: at a known message while it polls, or when the oldest message of the range
    /// came before the days.
    private func take(_ listings: [MailListing], cutoff: Date, stopsAtKnown: Bool, seen: inout Set<String>, pass: inout Pass) async throws -> Bool {
        let ids = listings.map(\.messageID).filter { !$0.isEmpty }
        let known = ids.isEmpty ? [] : await lookups.known(ids)
        var found: [Message] = []
        var done = false
        do {
            for listing in listings {
                if let date = listing.dateReceived, date < cutoff {
                    pass.older += 1
                    continue
                }
                guard !listing.messageID.isEmpty else {
                    pass.withoutMessageID += 1
                    continue
                }
                if known.contains(listing.messageID) || seen.contains(listing.messageID) {
                    pass.known += 1
                    if stopsAtKnown {
                        done = true
                        break
                    }
                    continue
                }
                try Task.checkCancellation()
                do {
                    found.append(try await message(listing, pass: &pass))
                    seen.insert(listing.messageID)
                } catch MailBridgeError.notFound {
                    pass.gone += 1
                }
            }
        } catch {
            // What was read before Mail quit or stopped answering is kept. Nothing is saved
            // after `stop()`.
            if !(error is CancellationError) {
                await keep(found, pass: &pass)
            }
            throw error
        }
        await keep(found, pass: &pass)
        if let oldest = listings.last?.dateReceived, oldest < cutoff {
            done = true
        }
        return done
    }

    private func keep(_ found: [Message], pass: inout Pass) async {
        guard !found.isEmpty, !Task.isCancelled else { return }
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
        let counts = "\(pass.mailboxes) mailboxes, \(pass.read) read, \(pass.tooLarge) too large, \(pass.saved) saved, \(pass.known) known, \(pass.older) older, \(pass.withoutMessageID) without a Message-ID, \(pass.gone) gone, in \(milliseconds) ms"
        if let error = pass.error {
            Logger.projectsMail.notice("Mail scan: \(counts, privacy: .public), \(String(describing: error), privacy: .public)")
        } else if pass.saved > 0 {
            Logger.projectsMail.notice("Mail scan: \(counts, privacy: .public)")
        } else {
            Logger.projectsMail.debug("Mail scan: \(counts, privacy: .public)")
        }
    }
}
