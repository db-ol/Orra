import AppKit
import CoreServices
import Foundation
import os
import Synchronization

extension Logger {
    /// The Apple Events Projects sends to Mail: which of the three events, how long it took
    /// and its error code, and the answers of the permission check. Never what was asked for
    /// or what came back.
    nonisolated static let projectsMail = Logger(subsystem: ProblemReport.subsystem, category: "projects-mail")
}

/// The only Apple Events Orra sends, all to Mail. Each raw value is the event class and the
/// event ID, as Mail.sdef writes them. Get and count only read. Reply makes a reply to a
/// message in a window of its own, which Mail never sends by itself.
///
/// Tools/ci/check_rules.py reads this enum. It must hold these three and no other, and every
/// event MailEvents builds takes its codes from here.
nonisolated enum MailEvent: String, CaseIterable, Sendable {
    /// get, in the standard suite: reads a property or the elements of an object.
    case get = "coregetd"
    /// count, in the standard suite: counts the elements of an object.
    case count = "corecnte"
    /// reply, in Mail's suite: makes a reply to a message and opens its window.
    case reply = "emalrpms"

    var eventClass: AEEventClass {
        MailEvents.code(rawValue.prefix(4))
    }

    var eventID: AEEventID {
        MailEvents.code(rawValue.suffix(4))
    }
}

/// Mail's scripting, through the three events of MailEvent. The only code in Orra that
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

    /// The codes of Mail.sdef that Projects reads (Mail 16.0 on macOS 26.6). There is no
    /// code for `content` here: the model reads only text that Projects parses out of
    /// `source` itself.
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

        var event: MailEvent {
            switch self {
            case .get: .get
            case .count: .count
            case .reply: .reply
            }
        }

        /// Get and count never let Mail interact with the user. A reply opens a window.
        var sendOptions: NSAppleEventDescriptor.SendOptions {
            switch self {
            case .get, .count: [.waitForReply, .neverInteract]
            case .reply: [.waitForReply, .canInteract]
            }
        }

        /// How long Mail may take, in seconds: 30 for a request over many elements, 10 for
        /// one value.
        var timeout: TimeInterval {
            switch self {
            case .get(let specifier): specifier.isMany ? 30 : 10
            case .count: 30
            case .reply: 10
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
            }
            return event
        }
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
        let value = MailEvents.Value(data, depth: Self.deepest)
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
        permission: { ask in await permissionOnItsOwnThread(ask: ask) }
    )

    private static let mailIdentifier = "com.apple.mail"
    private static let sendThread = SendThread()
    /// procNotFound, which a send to a process that is gone gives too.
    private static let notRunning = procNotFound

    /// Mail, when it runs and has finished launching. Never launches it.
    private static func runningMail() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: mailIdentifier)
            .first { !$0.isTerminated && $0.isFinishedLaunching && $0.processIdentifier > 0 }
    }

    /// On the send thread: builds the event, sends it to Mail's process id and reads the
    /// reply. A process id target fails with -600 when Mail is gone and never launches it.
    private static func sendNow(_ request: Request) throws -> Value {
        guard let mail = runningMail() else {
            Logger.projectsMail.info("Mail is not running, \(request.event.logName, privacy: .public) not sent")
            throw Failure(code: notRunning)
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

    private static func log(_ request: Request, since started: ContinuousClock.Instant, code: Int) {
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        if code == 0 {
            Logger.projectsMail.debug("\(request.event.logName, privacy: .public) took \(milliseconds) ms")
        } else {
            Logger.projectsMail.info("\(request.event.logName, privacy: .public) failed with \(code) after \(milliseconds) ms")
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
        guard let address = target.aeDesc else { return notRunning }
        let started = ContinuousClock.now
        let status = Int(AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, ask))
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        Logger.projectsMail.info("Permission check, asked \(ask), answered \(status) after \(milliseconds) ms")
        return status
    }

    /// One thread that sends Mail's events one at a time, in the order they came. A send
    /// blocks it until Mail answers or the event's timeout passes.
    private nonisolated final class SendThread: Sendable {
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
            try await withCheckedThrowingContinuation { continuation in
                jobs.withLock { $0.append { continuation.resume(with: Result { try work() }) } }
                waiting.signal()
            }
        }
    }
}

nonisolated extension MailEvent {
    /// The event's name for the log.
    var logName: String {
        switch self {
        case .get: "get"
        case .count: "count"
        case .reply: "reply"
        }
    }
}
