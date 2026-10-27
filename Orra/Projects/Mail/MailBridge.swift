import Foundation
import Synchronization

/// Mail, as Projects reads it: a struct of closures, so tests pass fakes and never send an
/// Apple Event, see AGENTS.md. `live` sends MailEvents' four events to the running Mail.
///
/// Every call but `reply` and `attach` only reads. `reply` makes a reply and always opens
/// its window, where the user decides what to send. `attach` adds a file the user ticked to
/// the reply `reply` just made, and only while the Mail that made it runs. There is no call
/// for a message's `content`: the model reads only text that Projects parses out of
/// `source` itself.
///
/// The calls run their events on MailEvents' send thread, one at a time, so none blocks the
/// caller's thread. They throw MailBridgeError. A call never launches Mail. While Mail does
/// not run, each throws `mailNotRunning` without asking it anything.
nonisolated struct MailBridge: Sendable {
    /// Whether Mail runs.
    var isRunning: @Sendable () -> Bool
    /// Asks macOS whether Orra may send Apple Events to Mail. With `ask` true macOS may show
    /// its prompt, which only the user's click in Settings may lead to. An answer that does
    /// not come in time is `unknown`. Remembered for `lastPermission`.
    var permission: @Sendable (_ ask: Bool) async -> MailPermission
    /// What the last real request told about the permission: a permission check, or an
    /// event that Mail answered or that macOS refused. Nil before the first one. Never asks
    /// macOS, so Settings and Report a Problem read this and not `permission`.
    var lastPermission: @Sendable () -> MailPermission?
    /// The user's accounts in Mail, with their addresses and full name.
    var accounts: @Sendable () async throws -> [MailAccountInfo]
    /// Every mailbox, for the picker in Settings: the inbox and the sent mailbox of all
    /// accounts first, then each account's mailboxes, then those On My Mac.
    var mailboxes: @Sendable () async throws -> [MailMailbox]
    /// How many messages a mailbox holds.
    var count: @Sendable (MailMailbox) async throws -> Int
    /// The list fields of the messages at these positions in a mailbox, the first being 1.
    /// Mail lists the inbox newest first. A range past the last message may fail with
    /// `notFound`, so read `count` first.
    var listing: @Sendable (MailMailbox, ClosedRange<Int>) async throws -> [MailListing]
    /// All the headers of a message, as Mail gives them.
    var headers: @Sendable (MailMessageRef) async throws -> String
    /// The raw source of a message, headers and every MIME part. It all comes into memory,
    /// so callers check the listing's `size` against their cap first.
    var source: @Sendable (MailMessageRef) async throws -> String
    /// The names, types and sizes of a message's attachments. Never their content.
    var attachments: @Sendable (MailMessageRef) async throws -> [MailAttachmentInfo]
    /// The mailbox a message is filed in, which for a message in the inbox of all accounts
    /// is the inbox of its account. So it never equals `MailMailbox.inbox` or `.sent`.
    var mailbox: @Sendable (MailMessageRef) async throws -> MailMailbox
    /// The messages selected in Mail. Read only on the user's click.
    var selection: @Sendable () async throws -> [MailMessageRef]
    /// Makes a reply to a message, to its sender or to all, and opens its window in Mail.
    /// Mail never sends it by itself. Gives the reply Mail made, or nil when Mail's answer
    /// named no outgoing message, or a Mail that started again meanwhile made it.
    var reply: @Sendable (MailMessageRef, _ all: Bool) async throws -> MailReplyRef?
    /// Adds a file at the end of a reply that `reply` made, as an attachment Mail reads from
    /// the file itself. Only for a file the user ticked, on the user's click. Throws
    /// `mailNotRunning` without asking Mail anything once the Mail that made the reply quit,
    /// also when another Mail runs now.
    var attach: @Sendable (URL, MailReplyRef) async throws -> Void
}

/// Whether Orra may send Apple Events to Mail, as macOS answers it.
nonisolated enum MailPermission: Sendable {
    /// 0: allowed.
    case allowed
    /// -1743: the user said no, or turned Orra off for Mail under Privacy & Security,
    /// Automation.
    case denied
    /// -1744: macOS has not asked the user yet.
    case notAsked
    /// -600: Mail is not running, so macOS cannot tell.
    case mailNotRunning
    /// No answer within the time limit, or any other code.
    case unknown

    init(status: Int) {
        self = switch status {
        case 0: .allowed
        case -1743: .denied
        case -1744: .notAsked
        case -600: .mailNotRunning
        default: .unknown
        }
    }
}

/// Why a call of MailBridge failed. Its description holds no mail data, so the log may
/// show it.
nonisolated enum MailBridgeError: Error, Equatable, Sendable {
    /// Mail is not running. Orra never opens it.
    case mailNotRunning
    /// Mail runs but did not take the event: -600 or -609 while its process is still there,
    /// which Mail on macOS 26 gives now and then.
    case notAnswered(code: Int)
    /// -1712: Mail did not answer in time.
    case timedOut
    /// -1743: the user does not allow Orra to control Mail.
    case denied
    /// -1744: macOS has not asked the user yet, and no event lets it ask.
    case notAsked
    /// -1728: the message or mailbox is no longer there.
    case notFound
    /// The messages at the positions of a listing changed while it was read, twice.
    case changedWhileReading
    /// Mail answered with something other than what was asked for.
    case unexpectedReply
    /// Any other error code of the system or of Mail.
    case failed(code: Int)

    /// What an error code of a request means, given whether Mail still runs.
    init(code: Int, mailRunning: Bool) {
        self = switch code {
        case -600, -609: mailRunning ? .notAnswered(code: code) : .mailNotRunning
        case -1712: .timedOut
        case -1743: .denied
        case -1744: .notAsked
        case -1728: .notFound
        default: .failed(code: code)
        }
    }
}

/// A mailbox in Mail. Two are the same when Mail names them the same way, whatever their
/// names for the picker.
nonisolated struct MailMailbox: Sendable, Hashable, Codable {
    nonisolated enum Kind: String, Sendable, Codable {
        /// The inbox of all accounts.
        case inbox
        /// The sent mailbox of all accounts.
        case sent
        /// Any other mailbox, of an account or On My Mac.
        case mailbox
    }

    let kind: Kind
    /// How Mail names it, such as mailbox "Archive/2026" of an account.
    let reference: MailEvents.Specifier
    /// Its name and the names of the mailboxes it sits in, such as "Archive/2026", for the
    /// picker. Empty for the inbox and the sent mailbox, which Settings names in the user's
    /// language, and for a mailbox from `mailbox(of:)` or `selection`, which only compare.
    let name: String
    /// The name of its account, nil On My Mac, for the two mailboxes of all accounts and for
    /// a mailbox from `mailbox(of:)` or `selection`.
    let account: String?

    static let inbox = MailMailbox(kind: .inbox, reference: .property(MailEvents.Code.inbox, of: .application), name: "", account: nil)
    static let sent = MailMailbox(kind: .sent, reference: .property(MailEvents.Code.sentMailbox, of: .application), name: "", account: nil)

    static func == (first: Self, second: Self) -> Bool {
        first.reference == second.reference
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(reference)
    }
}

/// A reply Mail made through `reply`, by its outgoing message's id, with the Mail session
/// that made it. The id holds in that session only.
nonisolated struct MailReplyRef: Sendable, Hashable {
    let id: Int
    let session: MailEvents.Session
}

/// A message in a mailbox. Mail's id holds for one Mail session only, so Projects keys mail
/// by its Message-ID and keeps this only to read the message again soon.
nonisolated struct MailMessageRef: Sendable, Hashable {
    let id: Int
    let mailbox: MailMailbox

    var reference: MailEvents.Specifier {
        .id(MailEvents.Code.message, id, of: mailbox.reference)
    }
}

/// The fields of a message in a mailbox's list, from one listing.
nonisolated struct MailListing: Sendable, Equatable {
    let message: MailMessageRef
    /// The Message-ID header without its angle brackets, empty when Mail has none.
    let messageID: String
    let dateReceived: Date?
    /// The sender as Mail gives it, such as "Mei Tan <mei@harbor.example>".
    let sender: String
    let subject: String
    /// The To and Cc addresses, each as ProjectsAddress.normalized gives it. Text that is not
    /// one address is left out.
    let to: [String]
    let cc: [String]
    /// The size in bytes, as Mail counts it.
    let size: Int
}

/// An attachment of a message, as Mail lists it.
nonisolated struct MailAttachmentInfo: Sendable, Equatable {
    let name: String
    /// The type and subtype in lowercase, such as application/pdf, without parameters.
    let mimeType: String
    /// The size in bytes as Mail estimates it, nil when Mail does not say.
    let size: Int?
    /// Whether Mail has downloaded it.
    let isDownloaded: Bool
}

/// An account in Mail.
nonisolated struct MailAccountInfo: Sendable, Equatable {
    /// The account's name in Mail.
    let name: String
    /// Its addresses, each as ProjectsAddress.normalized gives it.
    let addresses: [String]
    /// The full name it sends with, empty when it has none.
    let fullName: String
}

private typealias Specifier = MailEvents.Specifier
private typealias Code = MailEvents.Code
private typealias Value = MailEvents.Value

nonisolated extension MailBridge {
    /// The real Mail. Tests never use it.
    static let live = MailBridge(events: .live)

    /// How long a permission check may take before it counts as unknown. One that asks waits
    /// for the user to read the prompt.
    static func permissionLimit(ask: Bool) -> Duration {
        ask ? .seconds(120) : .seconds(5)
    }

    /// The bridge over a sender of Mail's events. `permissionLimit` gives the time limit of
    /// a permission check, by whether it asks.
    init(events: MailEvents, permissionLimit: @escaping @Sendable (Bool) -> Duration = Self.permissionLimit(ask:)) {
        let reader = Reader(events: events, remembered: Remembered())
        self.init(
            isRunning: events.isRunning,
            permission: { ask in await reader.permission(ask: ask, within: permissionLimit(ask)) },
            lastPermission: { reader.remembered.permission },
            accounts: { try await reader.accounts() },
            mailboxes: { try await reader.mailboxes() },
            count: { mailbox in try await reader.integer(.count(Code.message, in: mailbox.reference)) },
            listing: { mailbox, positions in try await reader.listing(mailbox, positions) },
            headers: { message in try await reader.text(.get(.property(Code.allHeaders, of: message.reference))) },
            source: { message in try await reader.text(.get(.property(Code.source, of: message.reference))) },
            attachments: { message in try await reader.attachments(message) },
            mailbox: { message in try await reader.mailbox(of: message) },
            selection: { try await reader.selection() },
            reply: { message, all in try await reader.reply(to: message, all: all) },
            attach: { file, reply in try await reader.attach(file, to: reply) }
        )
    }

    /// The answer of the last real request.
    private nonisolated final class Remembered: Sendable {
        private let last = Mutex<MailPermission?>(nil)

        var permission: MailPermission? {
            last.withLock { $0 }
        }

        func remember(_ permission: MailPermission) {
            last.withLock { $0 = permission }
        }
    }

    /// The requests behind the closures, and how their answers become values.
    private nonisolated struct Reader: Sendable {
        let events: MailEvents
        let remembered: Remembered

        /// The most mailboxes the picker lists, and how deep it looks.
        static let mostMailboxes = 1_000
        static let deepestMailbox = 8

        func permission(ask: Bool, within limit: Duration) async -> MailPermission {
            let (result, timedOut) = await TimedCall.run(within: limit) { await events.permission(ask) }
            let permission: MailPermission
            switch result {
            case .success(let status):
                permission = MailPermission(status: status)
            case .failure where timedOut:
                permission = .unknown
            case .failure:
                // The caller went away. That tells nothing about the permission.
                return .unknown
            }
            remembered.remember(permission)
            return permission
        }

        /// Sends a request and remembers what it tells about the permission.
        func value(_ request: MailEvents.Request) async throws -> Value {
            do {
                let value = try await events.send(request)
                remembered.remember(.allowed)
                return value
            } catch let failure as MailEvents.Failure {
                let error = MailBridgeError(code: failure.code, mailRunning: events.isRunning())
                switch error {
                case .denied: remembered.remember(.denied)
                case .notAsked: remembered.remember(.notAsked)
                default: break
                }
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MailBridgeError.failed(code: (error as NSError).code)
            }
        }

        // MARK: Shapes

        func text(_ request: MailEvents.Request) async throws -> String {
            try Self.text(await value(request))
        }

        func integer(_ request: MailEvents.Request) async throws -> Int {
            guard case .integer(let number) = try await value(request) else { throw MailBridgeError.unexpectedReply }
            return number
        }

        /// The values of a request over many objects, which must be `count` when given.
        func items(_ request: MailEvents.Request, count: Int? = nil) async throws -> [Value] {
            let items = Self.items(try await value(request), count: count)
            if let count, items.count != count { throw MailBridgeError.unexpectedReply }
            return items
        }

        func texts(_ request: MailEvents.Request, count: Int? = nil) async throws -> [String] {
            try await items(request, count: count).map(Self.text)
        }

        func integers(_ request: MailEvents.Request, count: Int? = nil) async throws -> [Int] {
            try await items(request, count: count).map {
                guard case .integer(let number) = $0 else { throw MailBridgeError.unexpectedReply }
                return number
            }
        }

        /// Lists of text per object, such as the addresses of each message's To recipients.
        func textLists(_ request: MailEvents.Request, count: Int) async throws -> [[String]] {
            let reply = try await value(request)
            var lists = Self.items(reply, count: count)
            // A request over one object may come back as that object's list alone.
            if count == 1, lists.count != 1, case .list = reply {
                lists = [reply]
            }
            guard lists.count == count else { throw MailBridgeError.unexpectedReply }
            return try lists.map { try Self.items($0, count: nil).map(Self.text) }
        }

        /// The items of a reply. A single value is a list of one, and no value an empty list.
        static func items(_ value: Value, count: Int?) -> [Value] {
            switch value {
            case .list(let items): items
            case .missing where count != 1: []
            default: [value]
            }
        }

        static func text(_ value: Value) throws -> String {
            switch value {
            case .text(let text): text
            case .missing: ""
            default: throw MailBridgeError.unexpectedReply
            }
        }

        // MARK: Calls

        func accounts() async throws -> [MailAccountInfo] {
            let every = Specifier.every(Code.account, of: .application)
            let names = try await texts(.get(.property(Code.name, of: every)))
            let addresses = try await textLists(.get(.property(Code.emailAddresses, of: every)), count: names.count)
            let fullNames = try await texts(.get(.property(Code.fullName, of: every)), count: names.count)
            return names.indices.map { index in
                MailAccountInfo(
                    name: names[index],
                    addresses: addresses[index].compactMap(ProjectsAddress.normalized),
                    fullName: fullNames[index]
                )
            }
        }

        func mailboxes() async throws -> [MailMailbox] {
            var found: [MailMailbox] = [.inbox, .sent]
            let every = Specifier.every(Code.account, of: .application)
            let accounts = try await items(.get(every))
            let names = try await texts(.get(.property(Code.name, of: every)), count: accounts.count)
            for (account, name) in zip(accounts, names) {
                guard case .reference(let reference) = account else { throw MailBridgeError.unexpectedReply }
                found += try await mailboxes(in: reference, account: name, room: Self.mostMailboxes - found.count)
            }
            found += try await mailboxes(in: .application, account: nil, room: Self.mostMailboxes - found.count)
            return found
        }

        /// The mailboxes in an account or On My Mac, level by level, each with the names of
        /// the mailboxes it sits in. Mail may list a mailbox both in its account and in its
        /// parent. It is listed once, under its parent.
        private func mailboxes(in container: Specifier, account: String?, room: Int) async throws -> [MailMailbox] {
            var order: [Specifier] = []
            var ownNames: [Specifier: String] = [:]
            var parentOf: [Specifier: Specifier] = [:]
            var parents = [container]
            for _ in 0..<Self.deepestMailbox where !parents.isEmpty && order.count < room {
                var children: [Specifier] = []
                for parent in parents where order.count < room {
                    let every = Specifier.every(Code.mailbox, of: parent)
                    let references = try await items(.get(every))
                    guard !references.isEmpty else { continue }
                    let names = try await texts(.get(.property(Code.name, of: every)), count: references.count)
                    for (item, name) in zip(references, names) {
                        guard case .reference(let reference) = item else { throw MailBridgeError.unexpectedReply }
                        if parent != container { parentOf[reference] = parent }
                        guard ownNames[reference] == nil else { continue }
                        guard order.count < room else { break }
                        order.append(reference)
                        ownNames[reference] = name
                        children.append(reference)
                    }
                }
                parents = children
            }
            // Each name with the names of its parents, built once every level is known.
            func path(_ reference: Specifier) -> String {
                var names = [ownNames[reference] ?? ""]
                var seen: Set = [reference]
                var current = reference
                while let parent = parentOf[current], seen.insert(parent).inserted {
                    names.append(ownNames[parent] ?? "")
                    current = parent
                }
                return names.reversed().joined(separator: "/")
            }
            return order.map { MailMailbox(kind: .mailbox, reference: $0, name: path($0), account: account) }
        }

        func listing(_ mailbox: MailMailbox, _ positions: ClosedRange<Int>) async throws -> [MailListing] {
            guard positions.lowerBound >= 1 else { throw MailBridgeError.unexpectedReply }
            let messages = Specifier.range(Code.message, positions.lowerBound, positions.upperBound, of: mailbox.reference)
            for _ in 1...2 {
                let ids = try await integers(.get(.property(Code.id, of: messages)))
                let count = ids.count
                let messageIDs = try await texts(.get(.property(Code.messageID, of: messages)), count: count)
                let dates = try await items(.get(.property(Code.dateReceived, of: messages)), count: count)
                let senders = try await texts(.get(.property(Code.sender, of: messages)), count: count)
                let subjects = try await texts(.get(.property(Code.subject, of: messages)), count: count)
                let to = try await textLists(.get(.property(Code.address, of: .every(Code.toRecipient, of: messages))), count: count)
                let cc = try await textLists(.get(.property(Code.address, of: .every(Code.ccRecipient, of: messages))), count: count)
                let sizes = try await integers(.get(.property(Code.messageSize, of: messages)), count: count)
                // New mail moves the positions of the older messages. The same ids at the end
                // mean every field above belongs to the same messages.
                guard try await integers(.get(.property(Code.id, of: messages)), count: count) == ids else { continue }
                return ids.indices.map { index in
                    var dateReceived: Date?
                    if case .date(let date) = dates[index] { dateReceived = date }
                    return MailListing(
                        message: MailMessageRef(id: ids[index], mailbox: mailbox),
                        messageID: Self.bare(messageIDs[index]),
                        dateReceived: dateReceived,
                        sender: senders[index],
                        subject: subjects[index],
                        to: to[index].compactMap(ProjectsAddress.normalized),
                        cc: cc[index].compactMap(ProjectsAddress.normalized),
                        size: sizes[index]
                    )
                }
            }
            throw MailBridgeError.changedWhileReading
        }

        /// A Message-ID without white space and angle brackets.
        static func bare(_ messageID: String) -> String {
            var id = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.hasPrefix("<"), id.hasSuffix(">"), id.count >= 2 {
                id = String(id.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            return id
        }

        func attachments(_ message: MailMessageRef) async throws -> [MailAttachmentInfo] {
            let every = Specifier.every(Code.attachment, of: message.reference)
            let names = try await texts(.get(.property(Code.name, of: every)))
            guard !names.isEmpty else { return [] }
            let types = try await texts(.get(.property(Code.mimeType, of: every)), count: names.count)
            let sizes = try await items(.get(.property(Code.fileSize, of: every)), count: names.count)
            let downloaded = try await items(.get(.property(Code.downloaded, of: every)), count: names.count)
            return names.indices.map { index in
                var size: Int?
                if case .integer(let bytes) = sizes[index] { size = bytes }
                var isDownloaded = false
                if case .boolean(let flag) = downloaded[index] { isDownloaded = flag }
                return MailAttachmentInfo(name: names[index], mimeType: Self.baseType(types[index]), size: size, isDownloaded: isDownloaded)
            }
        }

        /// The type and subtype of a MIME type, in lowercase and without parameters.
        static func baseType(_ type: String) -> String {
            let base = type.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return base.trimmingCharacters(in: .whitespaces).lowercased()
        }

        func mailbox(of message: MailMessageRef) async throws -> MailMailbox {
            guard case .reference(let reference) = try await value(.get(.property(Code.mailbox, of: message.reference))) else {
                throw MailBridgeError.unexpectedReply
            }
            return MailMailbox(kind: .mailbox, reference: reference, name: "", account: nil)
        }

        /// The selected messages. Anything else Mail names there is left out.
        func selection() async throws -> [MailMessageRef] {
            try await items(.get(.property(Code.selection, of: .application))).compactMap { item in
                guard case .reference(.id(Code.message, let id, of: let mailbox)) = item else { return nil }
                return MailMessageRef(id: id, mailbox: MailMailbox(kind: .mailbox, reference: mailbox, name: "", account: nil))
            }
        }

        /// Asks Mail for a reply window and gives the reply Mail made, as Mail names it:
        /// outgoing message id N of the application. The same Mail session must run before
        /// the request and after Mail answered, so the id belongs to the Mail that made the
        /// reply: a session that ended never comes back.
        func reply(to message: MailMessageRef, all: Bool) async throws -> MailReplyRef? {
            let session = events.session()
            let answer = try await value(.reply(to: message.reference, all: all))
            guard let session, events.session() == session,
                  case .reference(.id(Code.outgoingMessage, let id, of: .application)) = answer else { return nil }
            return MailReplyRef(id: id, session: session)
        }

        /// Adds the file at the end of the reply, only while the Mail that made the reply
        /// runs. Once it quit, the reply's id may name another message of the Mail that runs
        /// now, so nothing is sent. MailEvents checks the session again when the event's turn
        /// comes on the send thread, and fails as if Mail did not run.
        func attach(_ file: URL, to reply: MailReplyRef) async throws {
            guard events.session() == reply.session else {
                throw MailBridgeError.mailNotRunning
            }
            do {
                _ = try await value(.attach(file, toReply: reply.id, in: reply.session))
            } catch MailBridgeError.notAnswered where events.session() != reply.session {
                throw MailBridgeError.mailNotRunning
            }
        }
    }
}
