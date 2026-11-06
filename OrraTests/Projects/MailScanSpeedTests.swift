import Foundation
import Synchronization
import Testing
@testable import Orra

/// How fast the Mail scan gets through a slow Mail. SlowMail plays Mail at the level of its
/// events, so every event MailBridge builds is counted. Each takes as long as Mail might on
/// a busy Mac, tens to hundreds of milliseconds, on a clock of SlowMail's own that no test
/// waits for. An Exchange account that drops fails as Mail does then: with -1712 once the
/// event's timeout passed, or with -609 at once. It never sends an Apple Event. The
/// accounts, people and mail are made up, at .example addresses.
///
/// With TEST_RUNNER_ORRA_MAIL_SPEED_OUT set to a file, the measurements add their numbers
/// to it, and with TEST_RUNNER_ORRA_MAIL_SPEED_TRACE set too, the numbers of every run. A
/// flaky account is run for 5 of the 25 events it may fail first, and for all 25 with
/// TEST_RUNNER_ORRA_MAIL_SPEED_ALL_PHASES set, as for the numbers of a pull request:
///
///     TEST_RUNNER_ORRA_MAIL_SPEED_ALL_PHASES=1 TEST_RUNNER_ORRA_MAIL_SPEED_OUT=<file> xcodebuild … -only-testing:OrraTests/MailScanSpeedTests test
@MainActor
struct MailScanSpeedTests {
    nonisolated static let start = Date(timeIntervalSince1970: 1_792_300_000)
    nonisolated static let hour: TimeInterval = 3_600
    nonisolated static let day: TimeInterval = 86_400

    /// The Exchange account and its four mailboxes, as a user may choose them.
    nonisolated static let exchange = MailEvents.Specifier.textID(MailEvents.Code.account, "E7-exchange", of: .application)
    nonisolated static let inbox = exchangeMailbox("Inbox")
    nonisolated static let outbox = exchangeMailbox("Outbox")
    nonisolated static let drafts = exchangeMailbox("Drafts")
    nonisolated static let sentItems = exchangeMailbox("Sent Items")

    nonisolated static func exchangeMailbox(_ name: String) -> MailMailbox {
        MailMailbox(kind: .mailbox, reference: .name(MailEvents.Code.mailbox, name, of: exchange), name: name, account: "Exchange")
    }

    let suite: TestDefaults
    let defaults: UserDefaults

    init() throws {
        suite = try TestDefaults("mail-scan-speed")
        defaults = suite.defaults
    }

    private func cleanUp() {
        suite.remove()
    }

    // MARK: The events of a pass

    /// The events of a pass over a small mailbox of the Exchange account, in order: the
    /// count, the nine gets of the listing, then one source per message, newest first, with
    /// the three gets of the accounts before the first save of ten. Mail does not give one
    /// source in time, which waits and costs no other event. The next pass asks for the
    /// known mail nothing but its listing, and for the message that waited its source, last.
    @Test func aPassSendsOneEventPerNewMessageInThisOrder() async throws {
        defer { cleanUp() }
        let mail = SlowMail()
        mail.addAccount(id: "E7-exchange", name: "Exchange", addresses: ["ana.li@northfield.example"], fullName: "Ana Li")
        var messages = SlowMail.messages(12, from: 1, newest: Self.hour, apart: Self.day, account: "E7-exchange", domain: "northfield.example")
            + SlowMail.messages(3, from: 101, newest: 120 * Self.day, apart: Self.day, account: "E7-exchange", domain: "northfield.example")
        messages[3].hangs = true
        mail.put(messages, in: Self.inbox, account: "E7-exchange")
        let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: false)
        choice.choose([Self.inbox])
        choice.confirm()
        let saved = Saved()
        let scan = MailScan(
            bridge: MailBridge(events: mail.events, pause: { mail.advance(by: $0) }),
            choice: choice,
            lookups: MailScan.Lookups(known: { ids in Set(ids).intersection(saved.ids) }, linkedMailboxes: { [] }),
            save: { messages, _ in
                saved.ids += messages.map(\.messageID)
                saved.batches.append(messages.count)
            },
            isOn: { true },
            now: { Self.start.addingTimeInterval(mail.elapsedSeconds) }
        )
        let first = await scan.scan()
        typealias Kind = SlowMail.Event.Kind
        let listing = Array(repeating: Kind.listing("Inbox", 1...15), count: 9)
        let accounts = Array(repeating: Kind.accounts, count: 3)
        #expect(mail.log.map(\.kind) == [.count("Inbox")] + listing + (1...11).map { Kind.source($0) } + accounts + [.source(12)])
        #expect(mail.log.map(\.code) == Array(repeating: 0, count: 13) + [-1712] + Array(repeating: 0, count: 11))
        #expect(saved.batches == [10, 1])
        #expect(first.read == 11)
        #expect(first.slow == 1)
        #expect(first.older == 3)
        #expect(first.error == .timedOut)

        let before = mail.log.count
        let second = await scan.scan()
        #expect(mail.log.dropFirst(before).map(\.kind) == [.count("Inbox")] + listing + [.source(4)])
        #expect(second.known == 11)
        #expect(second.saved == 0)
    }

    /// What the store saved in `aPassSendsOneEventPerNewMessageInThisOrder`.
    @MainActor
    final class Saved {
        var ids: [String] = []
        var batches: [Int] = []
    }

    // MARK: Measurements

    /// The four mailboxes the user chose.
    nonisolated static let chosen = [inbox, outbox, drafts, sentItems]

    /// The events a flaky account may fail first, of the 25: five, or all of them with
    /// TEST_RUNNER_ORRA_MAIL_SPEED_ALL_PHASES set.
    static var phases: [Int] {
        ProcessInfo.processInfo.environment["ORRA_MAIL_SPEED_ALL_PHASES"] != nil ? Array(0..<25) : [0, 5, 10, 15, 20]
    }

    /// The same Mail answering every event, with an Exchange account that fails one event
    /// in 25, and with two messages besides whose body never comes. A flaky account is run
    /// once for each of `phases`, since which events fail matters. Notes the events per
    /// message, the time until the first ten emails were saved and until all were, on
    /// SlowMail's clock, the median and the worst of the runs.
    @Test(.timeLimit(.minutes(5)), arguments: SlowMail.Trouble.allCases)
    func theScanOfAnExchangeAccount(trouble: SlowMail.Trouble) async throws {
        defer { cleanUp() }
        var runs: [Run] = []
        for phase in trouble == .none ? [0] : Self.phases {
            let mail = SlowMail.exchangeUser(trouble: trouble, phase: phase)
            runs.append(await run(mail, Self.chosen, expecting: mail.readable(days: 90, in: Self.chosen)))
            if ProcessInfo.processInfo.environment["ORRA_MAIL_SPEED_TRACE"] != nil {
                Self.note("\(trouble) phase \(phase): \(runs[runs.count - 1].summary)")
            }
        }
        let summary = Summary(runs)
        Self.note("\(trouble): \(summary)")
        // Bounds well above what the scan takes now, so a change that slows it down shows.
        // A scan that waits for every mailbox after each failure, or stops at a message
        // that never comes, saves only part of the mail in 12 hours.
        #expect(summary.finished == runs.count)
        #expect(runs.allSatisfy { ($0.firstTen ?? .seconds(Int.max)) <= .seconds(60) })
        #expect(runs.allSatisfy { ($0.allSaved ?? .seconds(Int.max)) <= (trouble == .none ? .seconds(20) : .seconds(15 * 60)) })
        #expect(runs.allSatisfy { $0.eventsPerMessage <= (trouble == .none ? 1.4 : 3) })
        if trouble == .none {
            #expect(runs.allSatisfy { ($0.firstTen ?? .seconds(Int.max)) <= .seconds(5) })
        }
    }

    /// The median and the worst of runs.
    struct Summary: CustomStringConvertible {
        var runs: [Run]

        init(_ runs: [Run]) {
            self.runs = runs
        }

        /// The median and the largest, with nil as never, which counts as the largest.
        static func spread(_ values: [Duration?]) -> (median: Duration?, worst: Duration?) {
            let sorted = values.sorted { ($0 ?? .seconds(Int.max)) < ($1 ?? .seconds(Int.max)) }
            return (sorted[sorted.count / 2], sorted.last ?? nil)
        }

        var finished: Int {
            runs.filter { $0.allSaved != nil }.count
        }

        var description: String {
            let first = Self.spread(runs.map(\.firstTen))
            let all = Self.spread(runs.map(\.allSaved))
            let perMessage = runs.map(\.eventsPerMessage).sorted()
            let saved = runs.map(\.saved).sorted()
            let polls = runs.compactMap(\.pollEvents).sorted()
            return "\(runs.count) runs, \(finished) saved all within 12 h, saved median \(saved[saved.count / 2]) of \(runs[0].goal), "
                + "events per message median \(String(format: "%.2f", perMessage[perMessage.count / 2])) worst \(String(format: "%.2f", perMessage.last ?? 0)), "
                + "first ten median \(Run.seconds(first.median)) worst \(Run.seconds(first.worst)), "
                + "all median \(Run.seconds(all.median)) worst \(Run.seconds(all.worst)), "
                + "poll events median \(polls.isEmpty ? "none" : String(polls[polls.count / 2]))"
        }
    }

    /// Adds a line to the file that TEST_RUNNER_ORRA_MAIL_SPEED_OUT names, if any, for the
    /// numbers of a pull request.
    static func note(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["ORRA_MAIL_SPEED_OUT"], !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: Running the scan

    /// What one run of the scan's loop took, on SlowMail's clock.
    struct Run: CustomStringConvertible {
        var goal = 0
        var saved = 0
        var passes = 0
        var firstTen: Duration?
        var allSaved: Duration?
        /// The events sent until all mail was saved, or until the run ended.
        var events = 0
        var timeouts = 0
        var refusals = 0
        var kinds: [String: Int] = [:]
        /// The events of the first pass after all mail was saved, which only polls.
        var pollEvents: Int?
        var end: Duration = .zero

        var eventsPerMessage: Double {
            saved == 0 ? .infinity : Double(events) / Double(saved)
        }

        static func seconds(_ duration: Duration?) -> String {
            guard let duration else { return "never" }
            return String(format: "%.1f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        }

        var summary: String {
            let kinds = kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            return "saved \(saved) of \(goal), \(events) events (\(String(format: "%.2f", eventsPerMessage)) per message: \(kinds)), "
                + "\(timeouts) timeouts, \(refusals) refusals, \(passes) passes, first ten \(Self.seconds(firstTen)), "
                + "all \(Self.seconds(allSaved)), poll \(pollEvents.map(String.init) ?? "none") events, ended at \(Self.seconds(end))"
        }

        var description: String {
            summary
        }
    }

    /// Runs the scan's loop over SlowMail until it saved `goal` emails and polled once
    /// more, or until `limit` passed on SlowMail's clock.
    func run(_ mail: SlowMail, _ mailboxes: [MailMailbox], days: Int = 90, expecting goal: Int, limit: Duration = .seconds(12 * 3_600)) async -> Run {
        let choice = MailChoice(defaults: defaults, suggestsInboxAndSent: false)
        choice.choose(mailboxes)
        choice.choose(days: days)
        choice.confirm()
        let driver = Driver(goal: goal, limit: limit, mail: mail)
        let scan = MailScan(
            bridge: MailBridge(events: mail.events, pause: { mail.advance(by: $0) }),
            choice: choice,
            lookups: MailScan.Lookups(known: { ids in driver.known(ids) }, linkedMailboxes: { [] }),
            save: { messages, _ in driver.save(messages) },
            report: { driver.reported($0) },
            isOn: { true },
            now: { Self.start.addingTimeInterval(mail.elapsedSeconds) },
            sleep: { try await driver.sleep($0) }
        )
        await withCheckedContinuation { continuation in
            driver.finished = continuation
            scan.start()
        }
        scan.stop()
        return driver.run
    }

    /// Plays the store and the loop's waits for `run`, on SlowMail's clock.
    @MainActor
    final class Driver {
        let mail: SlowMail
        let limit: Duration
        var finished: CheckedContinuation<Void, Never>?
        var run = Run()
        private var savedIDs: Set<String> = []
        private var goalPass: Int?
        private var passStart = 0

        init(goal: Int, limit: Duration, mail: SlowMail) {
            self.mail = mail
            self.limit = limit
            run.goal = goal
        }

        func known(_ ids: [String]) -> Set<String> {
            Set(ids).intersection(savedIDs)
        }

        func save(_ messages: [MailScan.Message]) {
            for message in messages where savedIDs.insert(message.messageID).inserted {
                run.saved += 1
            }
            if run.firstTen == nil, run.saved >= min(10, run.goal) {
                run.firstTen = mail.elapsed
            }
            if run.allSaved == nil, run.saved >= run.goal {
                run.allSaved = mail.elapsed
                goalPass = run.passes
                note()
            }
        }

        func reported(_ report: MailScan.Report) {
            switch report {
            case .began:
                run.passes += 1
                passStart = mail.log.count
            case .ended:
                if let goalPass, run.passes == goalPass + 1 {
                    run.pollEvents = mail.log.count - passStart
                }
            }
        }

        func sleep(_ duration: Duration) async throws {
            mail.advance(by: duration)
            if run.pollEvents != nil || mail.elapsed >= limit {
                if run.allSaved == nil {
                    note()
                }
                run.end = mail.elapsed
                finished?.resume()
                finished = nil
                throw CancellationError()
            }
        }

        /// Notes the events so far.
        private func note() {
            let log = mail.log
            run.events = log.count
            run.timeouts = log.filter { $0.code == -1712 }.count
            run.refusals = log.filter { $0.code == -609 || $0.code == -600 }.count
            run.kinds = Dictionary(grouping: log, by: \.kind.name).mapValues(\.count)
        }
    }
}

/// Mail on a busy Mac, at the level of its events: mailboxes in memory, answered as Mail
/// answers MailBridge's gets and counts, one event at a time on a clock of its own.
nonisolated final class SlowMail: Sendable {
    /// What goes wrong with the Exchange account.
    enum Trouble: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Nothing: every event is answered.
        case none
        /// One event in 25 to the account fails, the first such with -1712 after the
        /// event's timeout, the next with -609 at once, and so on.
        case flaky
        /// As flaky, and the source of two messages never comes in time, as for a body
        /// that is still on the server of an account that is offline.
        case flakyWithHangingMessages

        var testDescription: String {
            rawValue
        }
    }

    nonisolated struct Message: Sendable {
        let id: Int
        let messageID: String
        let received: Date
        let sender: String
        let subject: String
        let to: [String]
        let source: String
        let account: String
        /// Mail never gives its source in time.
        var hangs = false
    }

    nonisolated struct Event: Sendable {
        nonisolated enum Kind: Sendable, Equatable {
            case count(String)
            case listing(String, ClosedRange<Int>)
            case source(Int)
            case headers(Int)
            case attachments(Int)
            case accounts
            case other

            var name: String {
                switch self {
                case .count: "count"
                case .listing: "listing"
                case .source: "source"
                case .headers: "headers"
                case .attachments: "attachments"
                case .accounts: "accounts"
                case .other: "other"
                }
            }
        }

        let kind: Kind
        let at: Duration
        let took: Duration
        let code: Int
    }

    private nonisolated struct Box {
        let name: String
        let account: String?
        var messages: [Message]
    }

    private nonisolated struct Account {
        let id: String
        let name: String
        let addresses: [String]
        let fullName: String
    }

    private nonisolated struct State {
        var boxes: [MailEvents.Specifier: Box] = [:]
        var accounts: [Account] = []
        var clock: Duration = .zero
        var log: [Event] = []
        /// Events sent to each account, by its id, counted from the phase of its failures.
        var sent: [String: Int] = [:]
        /// One event in this many to an account fails, by its id.
        var failsOneIn: [String: Int] = [:]
    }

    private let state = Mutex(State())

    // MARK: Building a Mail

    /// Adds an account, which fails one event in `failsOneIn` sent to it, the first after
    /// `failsOneIn - phase` events.
    func addAccount(id: String, name: String, addresses: [String], fullName: String = "", failsOneIn: Int? = nil, phase: Int = 0) {
        state.withLock { state in
            state.accounts.append(Account(id: id, name: name, addresses: addresses, fullName: fullName))
            state.failsOneIn[id] = failsOneIn
            state.sent[id] = phase
        }
    }

    func put(_ messages: [Message], in mailbox: MailMailbox, account: String?) {
        state.withLock { state in
            state.boxes[mailbox.reference] = Box(name: mailbox.name.isEmpty ? "\(mailbox.kind)" : mailbox.name, account: account, messages: messages)
        }
    }

    /// The messages of these mailboxes within the days that Mail can give.
    func readable(days: Int, in mailboxes: [MailMailbox]) -> Int {
        let cutoff = MailScanSpeedTests.start.addingTimeInterval(-Double(days) * MailScanSpeedTests.day)
        return state.withLock { state in
            Set(mailboxes.flatMap { state.boxes[$0.reference]?.messages ?? [] }.filter { $0.received >= cutoff && !$0.hangs }.map(\.messageID)).count
        }
    }

    /// Messages received `apart` seconds after each other, the newest `newest` seconds
    /// before the start, numbered from `first`.
    static func messages(_ count: Int, from first: Int, newest: TimeInterval, apart: TimeInterval, account: String, domain: String) -> [Message] {
        (0..<count).map { offset in
            let number = first + offset
            let messageID = "n\(number)@\(domain)"
            let subject = "Course update \(number)"
            let line = "Notes for week \(number % 14 + 1): the reading list, the lab slots and the room changes are below."
            let body = Array(repeating: line, count: (number % 7 + 1) * 12).joined(separator: "\r\n")
            let source = [
                "Message-ID: <\(messageID)>",
                "Date: Mon, 12 Oct 2026 09:\(String(format: "%02d", number % 60)):00 +0800",
                "From: Wen Ko <wen.ko@\(domain)>",
                "To: Ana Li <ana.li@northfield.example>",
                "Subject: \(subject)",
                "Content-Type: text/plain; charset=utf-8",
                "",
                body,
                "",
            ].joined(separator: "\r\n")
            return Message(
                id: number, messageID: messageID,
                received: MailScanSpeedTests.start.addingTimeInterval(-newest - Double(offset) * apart),
                sender: "Wen Ko <wen.ko@\(domain)>", subject: subject, to: ["ana.li@northfield.example"], source: source, account: account)
        }
    }

    /// A user with nine accounts who chose four mailboxes of the Exchange one, with about
    /// a hundred emails in 90 days.
    static func exchangeUser(trouble: Trouble, phase: Int = 0) -> SlowMail {
        let mail = SlowMail()
        let others = ["Home", "Family", "News", "Shop", "Club", "Lab", "Old School", "Studio"]
        for (index, name) in others.enumerated() {
            mail.addAccount(id: "A\(index)-\(name)", name: name, addresses: ["ana.li.\(index)@mail\(index).example"], fullName: "Ana Li")
        }
        mail.addAccount(id: "E7-exchange", name: "Exchange", addresses: ["ana.li@northfield.example"], fullName: "Ana Li",
                        failsOneIn: trouble == .none ? nil : 25, phase: phase)
        var inbox = messages(70, from: 1, newest: 2 * hour, apart: 30 * hour, account: "E7-exchange", domain: "northfield.example")
            + messages(130, from: 1_001, newest: 91 * day, apart: day, account: "E7-exchange", domain: "northfield.example")
        if trouble == .flakyWithHangingMessages {
            inbox[14].hangs = true
            inbox[39].hangs = true
        }
        mail.put(inbox, in: MailScanSpeedTests.inbox, account: "E7-exchange")
        mail.put([], in: MailScanSpeedTests.outbox, account: "E7-exchange")
        mail.put(messages(4, from: 3_001, newest: 5 * hour, apart: 2 * day, account: "E7-exchange", domain: "northfield.example"),
                 in: MailScanSpeedTests.drafts, account: "E7-exchange")
        mail.put(messages(25, from: 4_001, newest: 3 * hour, apart: 84 * hour, account: "E7-exchange", domain: "northfield.example")
                    + messages(75, from: 5_001, newest: 92 * day, apart: day, account: "E7-exchange", domain: "northfield.example"),
                 in: MailScanSpeedTests.sentItems, account: "E7-exchange")
        return mail
    }

    private static let hour = MailScanSpeedTests.hour
    private static let day = MailScanSpeedTests.day

    // MARK: The clock

    var elapsed: Duration {
        state.withLock { $0.clock }
    }

    var elapsedSeconds: TimeInterval {
        let elapsed = elapsed
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    func advance(by duration: Duration) {
        state.withLock { $0.clock += duration }
    }

    var log: [Event] {
        state.withLock { $0.log }
    }

    // MARK: Answering

    var events: MailEvents {
        MailEvents(
            isRunning: { true },
            send: { request in try self.answer(request) },
            permission: { _ in 0 }
        )
    }

    private typealias Code = MailEvents.Code
    private typealias Specifier = MailEvents.Specifier
    private typealias Value = MailEvents.Value

    private func answer(_ request: MailEvents.Request) throws -> Value {
        try state.withLock { state in
            var kind = Event.Kind.other
            var account: String?
            var took = Duration.milliseconds(20)
            var hangs = false
            var answer: () throws -> Value = { throw MailEvents.Failure(code: -1708) }
            switch request {
            case .count(let element, in: let reference) where element == Code.message:
                let box = state.boxes[reference]
                kind = .count(box?.name ?? "?")
                account = box?.account
                took = .milliseconds(40)
                answer = {
                    guard let box else { throw MailEvents.Failure(code: -1728) }
                    return .integer(box.messages.count)
                }
            case .get(.property(let property, of: .range(_, let first, let last, of: let reference))):
                let box = state.boxes[reference]
                kind = .listing(box?.name ?? "?", first...max(first, last))
                account = box?.account
                took = .milliseconds(30 + max(0, last - first + 1))
                answer = { try Self.listing(property, box: box, first: first, last: last) }
            case .get(.property(let property, of: .every(let recipients, of: .range(_, let first, let last, of: let reference)))):
                let box = state.boxes[reference]
                kind = .listing(box?.name ?? "?", first...max(first, last))
                account = box?.account
                took = .milliseconds(30 + 2 * max(0, last - first + 1))
                answer = {
                    guard property == Code.address, let box, first >= 1, last <= box.messages.count else { throw MailEvents.Failure(code: -1728) }
                    return .list(box.messages[(first - 1)..<last].map { message in
                        .list(recipients == Code.toRecipient ? message.to.map { .text($0) } : [])
                    })
                }
            case .get(.property(let property, of: .id(_, let id, of: let reference))):
                let message = state.boxes[reference]?.messages.first { $0.id == id }
                account = message?.account ?? state.boxes[reference]?.account
                switch property {
                case Code.source:
                    kind = .source(id)
                    took = .milliseconds(80 + 3 * (message?.source.utf8.count ?? 0) / 1_024)
                    hangs = message?.hangs == true
                    answer = {
                        guard let message else { throw MailEvents.Failure(code: -1728) }
                        return .text(message.source)
                    }
                case Code.allHeaders:
                    kind = .headers(id)
                    took = .milliseconds(50)
                    answer = {
                        guard let message else { throw MailEvents.Failure(code: -1728) }
                        return .text(String(message.source.prefix { $0 != "\n" }))
                    }
                default:
                    break
                }
            case .get(.property(_, of: .every(let element, of: .id(_, let id, of: let reference)))) where element == Code.attachment:
                kind = .attachments(id)
                account = state.boxes[reference]?.account
                took = .milliseconds(40)
                answer = { .list([]) }
            case .get(.property(let property, of: .every(let element, of: .application))) where element == Code.account:
                kind = .accounts
                took = .milliseconds(60)
                let accounts = state.accounts
                answer = {
                    switch property {
                    case Code.name: .list(accounts.map { .text($0.name) })
                    case Code.emailAddresses: .list(accounts.map { .list($0.addresses.map { .text($0) }) })
                    case Code.fullName: .list(accounts.map { .text($0.fullName) })
                    default: throw MailEvents.Failure(code: -1708)
                    }
                }
            default:
                break
            }
            var code = 0
            if hangs {
                code = -1712
            } else if let account, let oneIn = state.failsOneIn[account] {
                let sent = state.sent[account, default: 0] + 1
                state.sent[account] = sent
                if sent % oneIn == 0 {
                    code = (sent / oneIn) % 2 == 1 ? -1712 : -609
                }
            }
            switch code {
            case -1712: took = .milliseconds(Int(request.timeout * 1_000))
            case 0: break
            default: took = .milliseconds(20)
            }
            state.log.append(Event(kind: kind, at: state.clock, took: took, code: code))
            state.clock += took
            if code != 0 {
                throw MailEvents.Failure(code: code)
            }
            return try answer()
        }
    }

    private static func listing(_ property: FourCharCode, box: Box?, first: Int, last: Int) throws -> Value {
        guard let box, first >= 1, last <= box.messages.count, first <= last else { throw MailEvents.Failure(code: -1728) }
        let messages = box.messages[(first - 1)..<last]
        switch property {
        case Code.id: return .list(messages.map { .integer($0.id) })
        case Code.messageID: return .list(messages.map { .text("<\($0.messageID)>") })
        case Code.dateReceived: return .list(messages.map { .date($0.received) })
        case Code.sender: return .list(messages.map { .text($0.sender) })
        case Code.subject: return .list(messages.map { .text($0.subject) })
        case Code.messageSize: return .list(messages.map { .integer($0.source.utf8.count) })
        default: throw MailEvents.Failure(code: -1708)
        }
    }
}
