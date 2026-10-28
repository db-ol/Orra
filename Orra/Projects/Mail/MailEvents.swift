import AppKit
import CoreServices
import Foundation
import os
import Synchronization

extension Logger {
    /// The Apple Events Projects sends to Mail: which of the four events, how long it took
    /// and its error code, and the answers of the permission check. Never what was asked for
    /// or what came back.
    nonisolated static let projectsMail = Logger(subsystem: ProblemReport.subsystem, category: "projects-mail")
}

/// The only Apple Events Orra sends, all to Mail. Each raw value is the event class and the
/// event ID, as Mail.sdef writes them. Get and count only read. Reply makes a reply to a
/// message in a window of its own, which Mail never sends by itself. Attach makes only an
/// attachment, at the end of the content of a reply Mail just made, with a file the user
/// ticked for it.
///
/// Tools/ci/check_rules.py reads this enum. It must hold these four and no other, and every
/// event MailEvents builds takes its codes from here.
nonisolated enum MailEvent: String, CaseIterable, Sendable {
    /// get, in the standard suite: reads a property or the elements of an object.
    case get = "coregetd"
    /// count, in the standard suite: counts the elements of an object.
    case count = "corecnte"
    /// reply, in Mail's suite: makes a reply to a message and opens its window.
    case reply = "emalrpms"
    /// make, in the standard suite, as attach: makes an attachment at the end of the content
    /// of a reply Mail just made, and nothing else.
    case attach = "corecrel"

    var eventClass: AEEventClass {
        MailEvents.code(rawValue.prefix(4))
    }

    var eventID: AEEventID {
        MailEvents.code(rawValue.suffix(4))
    }
}

/// Mail's scripting, through the four events of MailEvent. The only code in Orra that
/// builds or sends an Apple Event. Projects reaches it through MailBridge, and tests pass
/// fakes of these closures, since tests never send an Apple Event.
///
/// A request is a value. The live sender builds its event on a thread of its own, sends it
/// to Mail's process id and turns the reply into a `Value` on that thread, so no descriptor
/// leaves it. It finds Mail with NSRunningApplication, so it never launches Mail. Every
/// value goes into the event as a typed parameter, never as script text.
nonisolated struct MailEvents: Sendable {
    /// Whether Mail runs and has finished launching.
    var isRunning: @Sendable () -> Bool
    /// Sends a request to the running Mail and gives the direct result of its reply. Throws
    /// `Failure` with the error code of the system or of Mail's reply, -600 without sending
    /// anything when Mail does not run.
    var send: @Sendable (Request) async throws -> Value
    /// Whether Orra may send Apple Events to Mail, from AEDeterminePermissionToAutomateTarget:
    /// 0 allowed, -1743 denied, -1744 not asked yet, -600 Mail not running. With `ask` true,
    /// macOS may show its prompt and the answer waits for the user.
    var permission: @Sendable (_ ask: Bool) async -> Int
    /// The session of the Mail that runs now, nil when none runs or macOS does not say when
    /// it launched.
    var session: @Sendable () -> Session?
}

nonisolated extension MailEvents {
    /// A failed request, with the error code of the system or of Mail's reply.
    nonisolated struct Failure: Error, Equatable, Sendable {
        let code: Int
    }

    /// A four character code, such as "core", from its four ASCII letters.
    static func code(_ text: some StringProtocol) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// One run of Mail, from its launch until it quits: its process id and when it launched.
    /// Mail's ids of the replies it makes hold only in the session that made them, and a Mail
    /// that starts again may give the same id to another message.
    nonisolated struct Session: Sendable, Hashable {
        let processIdentifier: pid_t
        let launched: Date

        init(processIdentifier: pid_t, launched: Date) {
            self.processIdentifier = processIdentifier
            self.launched = launched
        }

        /// The session of a running Mail, nil when macOS does not say when it launched, as
        /// for a Mail started without Launch Services. A process id alone could name a later
        /// process, so such a Mail gets no session, and no reply of it gets a file.
        init?(_ mail: NSRunningApplication) {
            guard let launched = mail.launchDate else { return nil }
            self.init(processIdentifier: mail.processIdentifier, launched: launched)
        }
    }

    /// The codes of Mail.sdef that Projects reads (Mail 16.0 on macOS 26.6). There is no
    /// code for `content` here: the model reads only text that Projects parses out of
    /// `source` itself. The one place that names content, as where a new attachment goes,
    /// is `Request.endOfContent(ofReply:)`.
    nonisolated enum Code {
        // Mail's own properties.
        static let selection = MailEvents.code("slct")
        static let inbox = MailEvents.code("inmb")
        static let sentMailbox = MailEvents.code("stmb")
        // Classes. A message's mailbox property has the code of the class.
        static let account = MailEvents.code("mact")
        static let mailbox = MailEvents.code("mbxp")
        static let message = MailEvents.code("mssg")
        static let toRecipient = MailEvents.code("trcp")
        static let ccRecipient = MailEvents.code("crcp")
        static let attachment = MailEvents.code("attc")
        /// The reply that `reply` gives back, in Mail's own suite.
        static let outgoingMessage = MailEvents.code("bcke")
        // Properties.
        static let name = MailEvents.code("pnam")
        static let id = MailEvents.code("ID  ")
        static let emailAddresses = MailEvents.code("emad")
        static let fullName = MailEvents.code("flln")
        static let messageID = MailEvents.code("meid")
        static let dateReceived = MailEvents.code("rdrc")
        static let sender = MailEvents.code("sndr")
        static let subject = MailEvents.code("subj")
        static let address = MailEvents.code("radd")
        static let messageSize = MailEvents.code("msze")
        static let allHeaders = MailEvents.code("alhe")
        static let source = MailEvents.code("raso")
        static let mimeType = MailEvents.code("attp")
        static let fileSize = MailEvents.code("atsz")
        static let downloaded = MailEvents.code("atdn")
        // The value AppleScript calls missing value.
        static let missingValue = MailEvents.code("msng")
    }

    /// An object in Mail, as AppleScript names it, such as message id 7 of mailbox "INBOX"
    /// of account id "…". Built by Projects, or read from Mail's replies, which name
    /// accounts, mailboxes and messages this way.
    nonisolated indirect enum Specifier: Sendable, Hashable, Codable {
        /// Mail itself.
        case application
        /// A property of an object, by its code.
        case property(FourCharCode, of: Specifier)
        /// Every element of a class.
        case every(FourCharCode, of: Specifier)
        /// The element of a class at a position, 1 being the first and -1 the last.
        case index(FourCharCode, Int, of: Specifier)
        /// The elements of a class from one position to another.
        case range(FourCharCode, Int, Int, of: Specifier)
        /// The element of a class with an id that is a number, such as a message.
        case id(FourCharCode, Int, of: Specifier)
        /// The element of a class with an id that is text, such as an account.
        case textID(FourCharCode, String, of: Specifier)
        /// The element of a class with a name, such as a mailbox.
        case name(FourCharCode, String, of: Specifier)
    }

    /// What Mail answered, without its descriptor.
    nonisolated enum Value: Sendable, Equatable {
        /// No value, or the value AppleScript calls missing value.
        case missing
        case text(String)
        case integer(Int)
        case boolean(Bool)
        case date(Date)
        case list([Value])
        case reference(Specifier)
        /// A value of another type, which Projects never asks for.
        case other
    }

    /// One request to Mail. Each builds one event of MailEvent.
    nonisolated enum Request: Sendable, Hashable {
        /// Reads what the specifier names.
        case get(Specifier)
        /// Counts the elements of a class in an object.
        case count(FourCharCode, in: Specifier)
        /// Makes a reply to a message, to its sender or to all, and always opens its window.
        case reply(to: Specifier, all: Bool)
        /// Adds a file as an attachment at the end of the content of the reply with this id,
        /// which `reply` made in the Mail session given. Mail reads the file itself. Sent only
        /// to the Mail of that session, never to a Mail that started since.
        case attach(URL, toReply: Int, in: Session)

        var event: MailEvent {
            switch self {
            case .get: .get
            case .count: .count
            case .reply: .reply
            case .attach: .attach
            }
        }

        /// The Mail session the request must go to, nil when any running Mail may take it.
        var session: Session? {
            switch self {
            case .attach(_, _, let session): session
            case .get, .count, .reply: nil
            }
        }

        /// No event lets macOS show its Automation prompt. Before the user allows Orra, each
        /// fails with -1744 instead, so only a permission check that asks, from the user's
        /// click in Settings, shows it. Get, count and attach also never let Mail interact
        /// with the user. A reply opens a window.
        var sendOptions: NSAppleEventDescriptor.SendOptions {
            switch self {
            case .get, .count, .attach: [.waitForReply, .neverInteract, Self.neverPrompt]
            case .reply: [.waitForReply, .canInteract, Self.neverPrompt]
            }
        }

        /// kAEDoNotPromptForUserConsent. SendOptions has no name for it, and sendEvent passes
        /// its options to AESendMessage as they are.
        static let neverPrompt = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent))

        /// How long Mail may take, in seconds: 30 for a request over many elements and for an
        /// attachment, which Mail may read in full first, 10 for one value.
        var timeout: TimeInterval {
            switch self {
            case .get(let specifier): specifier.isMany ? 30 : 10
            case .count: 30
            case .reply: 10
            case .attach: 30
            }
        }

        /// The event, built for a target and never sent here. Tests build it with a target
        /// of their own process.
        func appleEvent(target: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor.appleEvent(
                withEventClass: self.event.eventClass,
                eventID: self.event.eventID,
                targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            switch self {
            case .get(let specifier):
                event.setParam(try specifier.descriptor(), forKeyword: keyDirectObject)
            case .count(let elementClass, let container):
                event.setParam(try container.descriptor(), forKeyword: keyDirectObject)
                event.setParam(NSAppleEventDescriptor(typeCode: elementClass), forKeyword: keyAEObjectClass)
            case .reply(let message, let all):
                event.setParam(try message.descriptor(), forKeyword: keyDirectObject)
                event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: MailEvents.code("ropw"))
                event.setParam(NSAppleEventDescriptor(boolean: all), forKeyword: MailEvents.code("rpal"))
            case .attach(let file, let reply, _):
                event.setParam(NSAppleEventDescriptor(typeCode: MailEvents.code("atts")), forKeyword: keyAEObjectClass)
                event.setParam(try Self.endOfContent(ofReply: reply), forKeyword: keyAEInsertHere)
                event.setParam(try Self.fileProperties(file), forKeyword: keyAEPropData)
            }
            return event
        }
    }
}

nonisolated extension MailEvents.Request {
    /// Where a new attachment goes: the end of the content of the outgoing message with this
    /// id, an insertion location as AppleScript builds `at end of content of outgoing message
    /// id 7`. The only place in Orra that names a message's content, and only as where a new
    /// attachment goes. Nothing reads it.
    private static func endOfContent(ofReply reply: Int) throws -> NSAppleEventDescriptor {
        let content = MailEvents.Specifier.property(MailEvents.code("ctnt"), of: .id(MailEvents.Code.outgoingMessage, reply, of: .application))
        guard let location = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeInsertionLoc) else {
            throw MailEvents.Failure(code: errAECoercionFail)
        }
        location.setDescriptor(try content.descriptor(), forKeyword: keyAEObject)
        location.setDescriptor(NSAppleEventDescriptor(enumCode: kAEEnd), forKeyword: keyAEPosition)
        return location
    }

    /// The properties of a new attachment: its file and nothing else, as a file URL, so
    /// Mail reads the file itself and Orra sends only where it is. A URL that is not a
    /// file URL builds nothing.
    private static func fileProperties(_ file: URL) throws -> NSAppleEventDescriptor {
        guard file.isFileURL else {
            throw MailEvents.Failure(code: errAECoercionFail)
        }
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(NSAppleEventDescriptor(fileURL: file), forKeyword: MailEvents.code("atfn"))
        return properties
    }
}

// MARK: Descriptors

nonisolated extension MailEvents.Specifier {
    /// Whether it names many objects, so Mail may take longer to answer.
    var isMany: Bool {
        switch self {
        case .application: false
        case .every, .range: true
        case .property(_, let container), .index(_, _, let container), .id(_, _, let container),
             .textID(_, _, let container), .name(_, _, let container):
            container.isMany
        }
    }

    /// The object specifier, built the way AppleScript builds it.
    func descriptor() throws -> NSAppleEventDescriptor {
        switch self {
        case .application:
            return NSAppleEventDescriptor.null()
        case .property(let code, let container):
            return try Self.object(cProperty, in: container.descriptor(), form: Self.propertyForm, data: NSAppleEventDescriptor(typeCode: code))
        case .every(let elementClass, let container):
            var all = Self.all
            guard let ordinal = NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, bytes: &all, length: MemoryLayout.size(ofValue: all)) else {
                throw Self.cannotBuild
            }
            return try Self.object(elementClass, in: container.descriptor(), form: Self.positionForm, data: ordinal)
        case .index(let elementClass, let position, let container):
            return try Self.object(elementClass, in: container.descriptor(), form: Self.positionForm, data: NSAppleEventDescriptor(int32: Int32(clamping: position)))
        case .range(let elementClass, let first, let last, let container):
            guard let current = NSAppleEventDescriptor(descriptorType: typeCurrentContainer, data: nil),
                  let range = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeRangeDescriptor) else {
                throw Self.cannotBuild
            }
            let start = try Self.object(elementClass, in: current, form: Self.positionForm, data: NSAppleEventDescriptor(int32: Int32(clamping: first)))
            let stop = try Self.object(elementClass, in: current, form: Self.positionForm, data: NSAppleEventDescriptor(int32: Int32(clamping: last)))
            range.setDescriptor(start, forKeyword: keyAERangeStart)
            range.setDescriptor(stop, forKeyword: keyAERangeStop)
            return try Self.object(elementClass, in: container.descriptor(), form: Self.rangeForm, data: range)
        case .id(let elementClass, let id, let container):
            return try Self.object(elementClass, in: container.descriptor(), form: Self.idForm, data: NSAppleEventDescriptor(int32: Int32(clamping: id)))
        case .textID(let elementClass, let id, let container):
            return try Self.object(elementClass, in: container.descriptor(), form: Self.idForm, data: NSAppleEventDescriptor(string: id))
        case .name(let elementClass, let name, let container):
            return try Self.object(elementClass, in: container.descriptor(), form: Self.nameForm, data: NSAppleEventDescriptor(string: name))
        }
    }

    /// Reads a specifier from one of Mail's replies, or nil for a form Projects never uses.
    init?(_ descriptor: NSAppleEventDescriptor, depth: Int = 0) {
        guard depth < Self.deepest, descriptor.descriptorType == typeObjectSpecifier,
              let want = descriptor.forKeyword(Self.desiredClassKey), want.descriptorType == typeType,
              let form = descriptor.forKeyword(Self.formKey),
              let data = descriptor.forKeyword(Self.dataKey) else { return nil }
        let container: Self
        if let from = descriptor.forKeyword(Self.containerKey), from.descriptorType != typeNull {
            guard let outer = Self(from, depth: depth + 1) else { return nil }
            container = outer
        } else {
            container = .application
        }
        let elementClass = want.typeCodeValue
        // The key data is a type, a number or text. A specifier or a list there would nest
        // deeper than `deepest` allows, so it is never read.
        let nests = data.descriptorType == typeObjectSpecifier || data.descriptorType == typeAEList
        let value = nests ? MailEvents.Value.other : MailEvents.Value(data)
        switch form.enumCodeValue {
        case Self.propertyForm where data.descriptorType == typeType:
            self = .property(data.typeCodeValue, of: container)
        case Self.positionForm where data.descriptorType == typeAbsoluteOrdinal:
            guard data.data.count == MemoryLayout<OSType>.size,
                  data.data.withUnsafeBytes({ $0.loadUnaligned(as: OSType.self) }) == Self.all else { return nil }
            self = .every(elementClass, of: container)
        case Self.positionForm:
            guard case .integer(let position) = value else { return nil }
            self = .index(elementClass, position, of: container)
        case Self.idForm:
            switch value {
            case .integer(let id): self = .id(elementClass, id, of: container)
            case .text(let id): self = .textID(elementClass, id, of: container)
            default: return nil
            }
        case Self.nameForm:
            guard case .text(let name) = value else { return nil }
            self = .name(elementClass, name, of: container)
        default:
            return nil
        }
    }

    /// How many levels a specifier from Mail may have. A message in a mailbox in an account
    /// has three.
    private static let deepest = 12

    // The keys and forms of an object specifier, which the SDK gives as Int.
    private static let desiredClassKey = AEKeyword(keyAEDesiredClass)
    private static let containerKey = AEKeyword(keyAEContainer)
    private static let formKey = AEKeyword(keyAEKeyForm)
    private static let dataKey = AEKeyword(keyAEKeyData)
    private static let propertyForm = DescType(formPropertyID)
    private static let positionForm = DescType(formAbsolutePosition)
    private static let rangeForm = DescType(formRange)
    private static let idForm = DescType(formUniqueID)
    private static let nameForm = DescType(formName)
    private static let all = OSType(kAEAll)

    private static let cannotBuild = MailEvents.Failure(code: errAECoercionFail)

    private static func object(
        _ want: DescType,
        in container: NSAppleEventDescriptor,
        form: DescType,
        data: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        guard let object = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier) else {
            throw cannotBuild
        }
        object.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: desiredClassKey)
        object.setDescriptor(container, forKeyword: containerKey)
        object.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: formKey)
        object.setDescriptor(data, forKeyword: dataKey)
        return object
    }
}

nonisolated extension MailEvents.Value {
    /// Reads a value out of a reply. Lists deeper than a few levels, which Projects never
    /// asks for, count as other.
    init(_ descriptor: NSAppleEventDescriptor?, depth: Int = 0) {
        guard let descriptor else {
            self = .missing
            return
        }
        switch descriptor.descriptorType {
        case typeNull:
            self = .missing
        case typeType where descriptor.typeCodeValue == MailEvents.Code.missingValue:
            self = .missing
        case typeAEList:
            guard depth < Self.deepestList else {
                self = .other
                return
            }
            let count = descriptor.numberOfItems
            self = .list(count > 0 ? (1...count).map { Self(descriptor.atIndex($0), depth: depth + 1) } : [])
        case typeObjectSpecifier:
            self = MailEvents.Specifier(descriptor).map { .reference($0) } ?? .other
        case typeUnicodeText, typeUTF8Text, typeChar, typeUTF16ExternalRepresentation:
            self = descriptor.stringValue.map { .text($0) } ?? .other
        case typeTrue:
            self = .boolean(true)
        case typeFalse:
            self = .boolean(false)
        case typeBoolean:
            self = .boolean(descriptor.booleanValue)
        case typeSInt16, typeSInt32:
            self = .integer(Int(descriptor.int32Value))
        case typeSInt64:
            self = Self.number(descriptor.data, as: Int64.self).map { .integer(Int($0)) } ?? .other
        case typeUInt32:
            self = Self.number(descriptor.data, as: UInt32.self).map { .integer(Int($0)) } ?? .other
        case typeIEEE64BitFloatingPoint:
            self = Self.number(descriptor.data, as: Double.self).flatMap { Int(exactly: $0.rounded()) }.map { .integer($0) } ?? .other
        case typeLongDateTime:
            self = descriptor.dateValue.map { .date($0) } ?? .missing
        default:
            self = .other
        }
    }

    /// Lists of lists of lists, as `address of every to recipient of messages 1 thru 200`
    /// gives, are as deep as Projects asks.
    private static let deepestList = 4

    private static func number<Number: BitwiseCopyable>(_ data: Data, as type: Number.Type) -> Number? {
        guard data.count == MemoryLayout<Number>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Number.self) }
    }
}

// MARK: Sending

nonisolated extension MailEvents {
    /// The events and the permission check of the real Mail. Tests never use it.
    static let live = MailEvents(
        isRunning: { runningMail() != nil },
        send: { request in try await sendThread.run { try sendNow(request) } },
        permission: { ask in await permissionOnItsOwnThread(ask: ask) },
        session: { runningMail().flatMap(Session.init) }
    )

    private static let mailIdentifier = "com.apple.mail"
    private static let sendThread = SendThread()
    /// procNotFound, which a send to a process that is gone gives too.
    private static let notRunning = procNotFound

    /// Mail, when it runs and has finished launching. Never launches it. ReplyHandoff
    /// brings this process to the front.
    static func runningMail() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: mailIdentifier)
            .first { !$0.isTerminated && $0.isFinishedLaunching && $0.processIdentifier > 0 }
    }

    /// On the send thread: builds the event, sends it to Mail's process id and reads the
    /// reply. A process id target fails with -600 when Mail is gone and never launches it. A
    /// request bound to a Mail session goes only to that session's Mail, and fails with -600
    /// as well when another Mail runs now.
    private static func sendNow(_ request: Request) throws -> Value {
        guard let mail = runningMail() else {
            Logger.projectsMail.info("Mail is not running, \(String(describing: request.event), privacy: .public) not sent")
            throw Failure(code: notRunning)
        }
        if let code = refusal(of: request, by: Session(mail)) {
            Logger.projectsMail.info("Mail started again since the reply, \(String(describing: request.event), privacy: .public) not sent")
            throw Failure(code: code)
        }
        let target = NSAppleEventDescriptor(processIdentifier: mail.processIdentifier)
        let event = try request.appleEvent(target: target)
        let started = ContinuousClock.now
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: request.sendOptions, timeout: request.timeout)
        } catch {
            let code = (error as NSError).code
            log(request, since: started, code: code)
            throw Failure(code: code)
        }
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber), number.int32Value != 0 {
            let code = Int(number.int32Value)
            log(request, since: started, code: code)
            throw Failure(code: code)
        }
        log(request, since: started, code: 0)
        return Value(reply.paramDescriptor(forKeyword: keyDirectObject))
    }

    /// The code with which the send thread refuses a request before it builds the event, nil
    /// when it may go. A request bound to a Mail session goes only to that session's Mail, so
    /// another Mail refuses it with -600, as a Mail that is gone does. The event then goes to
    /// the process id of the Mail checked here, which a later Mail cannot have taken in the
    /// moment between.
    static func refusal(of request: Request, by running: Session?) -> Int? {
        guard let session = request.session else { return nil }
        return running == session ? nil : notRunning
    }

    private static func log(_ request: Request, since started: ContinuousClock.Instant, code: Int) {
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        if code == 0 {
            Logger.projectsMail.debug("\(String(describing: request.event), privacy: .public) took \(milliseconds) ms")
        } else {
            Logger.projectsMail.info("\(String(describing: request.event), privacy: .public) failed with \(code) after \(milliseconds) ms")
        }
    }

    /// AEDeterminePermissionToAutomateTarget on a thread of its own, so a check that hangs,
    /// or waits for the user at the prompt, never holds up the send thread. MailBridge puts
    /// a time limit on the wait.
    private static func permissionOnItsOwnThread(ask: Bool) async -> Int {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: permissionNow(ask: ask))
            }
            thread.name = "Orra Mail permission"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private static func permissionNow(ask: Bool) -> Int {
        guard let mail = runningMail() else {
            Logger.projectsMail.info("Permission check, Mail is not running")
            return notRunning
        }
        let target = NSAppleEventDescriptor(processIdentifier: mail.processIdentifier)
        let started = ContinuousClock.now
        // aeDesc points into target, so target must live until the check returns.
        let status = withExtendedLifetime(target) {
            target.aeDesc.map { Int(AEDeterminePermissionToAutomateTarget($0, typeWildCard, typeWildCard, ask)) } ?? notRunning
        }
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        Logger.projectsMail.info("Permission check, asked \(ask), answered \(status) after \(milliseconds) ms")
        return status
    }

    /// One thread that sends Mail's events one at a time, in the order they came. A send
    /// blocks it until Mail answers or the event's timeout passes. A caller cancelled before
    /// its turn gets CancellationError at once, and its event is never sent. Tests build one
    /// with work that sends nothing.
    nonisolated final class SendThread: Sendable {
        private let jobs = Mutex<[@Sendable () -> Void]>([])
        private let waiting = DispatchSemaphore(value: 0)

        init() {
            let thread = Thread { [self] in
                while true {
                    waiting.wait()
                    let job = jobs.withLock { $0.removeFirst() }
                    job()
                }
            }
            thread.name = "Orra Mail events"
            thread.qualityOfService = .utility
            thread.start()
        }

        func run<Answer: Sendable>(_ work: @escaping @Sendable () throws -> Answer) async throws -> Answer {
            let caller = Caller<Answer>()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard caller.wait(continuation) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    jobs.withLock {
                        $0.append {
                            // Nil when the caller was cancelled first, and then nothing runs.
                            guard let continuation = caller.take() else { return }
                            continuation.resume(with: Result { try work() })
                        }
                    }
                    waiting.signal()
                }
            } onCancel: {
                caller.take()?.resume(throwing: CancellationError())
            }
        }

        /// A caller's continuation, until its job starts or the caller is cancelled. Only the
        /// first of the two takes it.
        private nonisolated final class Caller<Answer: Sendable>: Sendable {
            private nonisolated enum State {
                case new
                case waiting(CheckedContinuation<Answer, any Error>)
                case taken
            }

            private let state = Mutex(State.new)

            /// Keeps the continuation. False when the caller was cancelled before.
            func wait(_ continuation: CheckedContinuation<Answer, any Error>) -> Bool {
                state.withLock { state in
                    guard case .new = state else { return false }
                    state = .waiting(continuation)
                    return true
                }
            }

            func take() -> CheckedContinuation<Answer, any Error>? {
                state.withLock { state in
                    defer { state = .taken }
                    guard case .waiting(let continuation) = state else { return nil }
                    return continuation
                }
            }
        }
    }
}
