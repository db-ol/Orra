import CoreServices
import Foundation
import Synchronization
import Testing
@testable import Orra

/// The events of the Mail bridge, built for this test process and never sent, as the Mail
/// spike's self check did. Each must be one of MailEvent's four, with every value a typed
/// parameter, none that lets macOS show its prompt, get, count and attach without
/// interaction, a reply that opens its window, and an attachment with only its file at the
/// end of a reply's content.
struct MailEventsTests {
    private typealias Code = MailEvents.Code
    private typealias Specifier = MailEvents.Specifier
    private typealias Value = MailEvents.Value

    /// This test process. Building an event for it sends nothing.
    private let target = NSAppleEventDescriptor(processIdentifier: getpid())

    private static let account = Specifier.textID(Code.account, "7A31-account", of: .application)
    private static let mailbox = Specifier.name(Code.mailbox, "Archive/2026", of: account)
    private static let message = Specifier.id(Code.message, 4217, of: mailbox)
    private static let file = URL(fileURLWithPath: "/Users/someone/Projects/Harbor lobby/Drawings/floor-plan-v3.pdf")
    private static let session = MailEvents.Session(processIdentifier: 811, launched: Date(timeIntervalSince1970: 1_761_400_000))

    @Test func onlyGetCountReplyAndAttachWithMailsCodes() {
        #expect(MailEvent.allCases == [.get, .count, .reply, .attach])
        #expect(MailEvent.allCases.map { Self.letters($0.eventClass) + Self.letters($0.eventID) } == ["coregetd", "corecnte", "emalrpms", "corecrel"])
        #expect(MailEvent.get.eventClass == 0x636F_7265)
        #expect(MailEvent.get.eventID == 0x6765_7464)
        #expect(MailEvents.code("ID  ") == 0x4944_2020)
        #expect(MailEvents.Request.neverPrompt.rawValue == 0x0002_0000)
    }

    @Test func getReadsAPropertyOfAMessageWithoutInteraction() throws {
        let request = MailEvents.Request.get(.property(Code.source, of: Self.message))
        let event = try request.appleEvent(target: target)
        #expect(Self.letters(event.eventClass) == "core")
        #expect(Self.letters(event.eventID) == "getd")
        #expect(event.paramDescriptor(forKeyword: AEKeyword(keyAERequestedType)) == nil)

        let source = try #require(event.paramDescriptor(forKeyword: keyDirectObject))
        #expect(Self.shape(source) == ["prop", "prop"])
        let property = try #require(Self.data(source))
        #expect(Self.letters(property.typeCodeValue) == "raso")

        let message = try #require(Self.container(source))
        #expect(Self.shape(message) == ["mssg", "ID  "])
        #expect(Self.data(message)?.descriptorType == typeSInt32)
        #expect(Self.data(message)?.int32Value == 4217)

        let mailbox = try #require(Self.container(message))
        #expect(Self.shape(mailbox) == ["mbxp", "name"])
        #expect(Self.data(mailbox)?.stringValue == "Archive/2026")

        let account = try #require(Self.container(mailbox))
        #expect(Self.shape(account) == ["mact", "ID  "])
        #expect(Self.data(account)?.stringValue == "7A31-account")
        #expect(Self.container(account)?.descriptorType == typeNull)

        #expect(request.event == .get)
        #expect(request.sendOptions.contains(.waitForReply))
        #expect(request.sendOptions.contains(.neverInteract))
        #expect(request.sendOptions.contains(MailEvents.Request.neverPrompt))
        #expect(!request.sendOptions.contains(.canInteract))
        #expect(request.timeout == 10)
    }

    @Test func aRangeOfMessagesTakesTheRangeForm() throws {
        let request = MailEvents.Request.get(.property(Code.dateReceived, of: .range(Code.message, 1, 200, of: MailMailbox.inbox.reference)))
        let event = try request.appleEvent(target: target)
        let dates = try #require(event.paramDescriptor(forKeyword: keyDirectObject))
        let property = try #require(Self.data(dates))
        #expect(Self.letters(property.typeCodeValue) == "rdrc")

        let messages = try #require(Self.container(dates))
        #expect(Self.shape(messages) == ["mssg", "rang"])
        let range = try #require(Self.data(messages))
        #expect(range.descriptorType == typeRangeDescriptor)
        for (keyword, position) in [(keyAERangeStart, 1), (keyAERangeStop, 200)] {
            let end = try #require(range.forKeyword(keyword))
            #expect(Self.shape(end) == ["mssg", "indx"])
            #expect(Self.data(end)?.int32Value == Int32(position))
            #expect(Self.container(end)?.descriptorType == typeCurrentContainer)
        }

        let inbox = try #require(Self.container(messages))
        #expect(Self.shape(inbox) == ["prop", "prop"])
        let inboxProperty = try #require(Self.data(inbox))
        #expect(Self.letters(inboxProperty.typeCodeValue) == "inmb")
        #expect(Self.container(inbox)?.descriptorType == typeNull)

        #expect(request.sendOptions.contains(.neverInteract))
        #expect(request.sendOptions.contains(MailEvents.Request.neverPrompt))
        #expect(request.timeout == 30)
    }

    @Test func everyTakesTheOrdinalAll() throws {
        let request = MailEvents.Request.get(.property(Code.address, of: .every(Code.toRecipient, of: Self.message)))
        let event = try request.appleEvent(target: target)
        let addresses = try #require(event.paramDescriptor(forKeyword: keyDirectObject))
        let recipients = try #require(Self.container(addresses))
        #expect(Self.shape(recipients) == ["trcp", "indx"])
        let all = try #require(Self.data(recipients))
        #expect(all.descriptorType == typeAbsoluteOrdinal)
        // The same bytes as a type descriptor of 'all ' holds.
        #expect(all.data == NSAppleEventDescriptor(typeCode: 0x616C_6C20).data)
        #expect(request.timeout == 30)
    }

    @Test func countNamesTheClassOfItsElements() throws {
        let request = MailEvents.Request.count(Code.message, in: MailMailbox.inbox.reference)
        let event = try request.appleEvent(target: target)
        #expect(Self.letters(event.eventClass) == "core")
        #expect(Self.letters(event.eventID) == "cnte")
        let inbox = try #require(event.paramDescriptor(forKeyword: keyDirectObject))
        #expect(Self.shape(inbox) == ["prop", "prop"])
        let elementClass = try #require(event.paramDescriptor(forKeyword: keyAEObjectClass))
        #expect(Self.letters(elementClass.typeCodeValue) == "mssg")
        #expect(request.sendOptions.contains(.neverInteract))
        #expect(request.sendOptions.contains(MailEvents.Request.neverPrompt))
        #expect(request.timeout == 30)
    }

    @Test(arguments: [false, true])
    func aReplyAlwaysOpensItsWindow(all: Bool) throws {
        let request = MailEvents.Request.reply(to: Self.message, all: all)
        let event = try request.appleEvent(target: target)
        #expect(Self.letters(event.eventClass) == "emal")
        #expect(Self.letters(event.eventID) == "rpms")
        let message = try #require(event.paramDescriptor(forKeyword: keyDirectObject))
        #expect(Self.shape(message) == ["mssg", "ID  "])
        let openingWindow = try #require(event.paramDescriptor(forKeyword: 0x726F_7077))
        #expect(openingWindow.booleanValue)
        #expect(event.paramDescriptor(forKeyword: 0x7270_616C)?.booleanValue == all)
        #expect(request.event == .reply)
        #expect(request.sendOptions.contains(.waitForReply))
        #expect(!request.sendOptions.contains(.neverInteract))
        #expect(request.sendOptions.contains(MailEvents.Request.neverPrompt))
        #expect(request.timeout == 10)
    }

    /// The attach event of AppleScript's `make new attachment with properties {file name:f}
    /// at end of content of outgoing message id 77`: the class of the new object is the
    /// attachment, and its place is the end of the content of that reply, of the
    /// application, as Mail names a reply it made.
    @Test func anAttachmentGoesAtTheEndOfTheContentOfTheReply() throws {
        let request = MailEvents.Request.attach(Self.file, toReply: 77, in: Self.session)
        let event = try request.appleEvent(target: target)
        #expect(Self.letters(event.eventClass) == "core")
        #expect(Self.letters(event.eventID) == "crel")
        #expect(request.event == .attach)
        #expect(event.paramDescriptor(forKeyword: keyDirectObject) == nil)

        let objectClass = try #require(event.paramDescriptor(forKeyword: keyAEObjectClass))
        #expect(objectClass.descriptorType == typeType)
        #expect(Self.letters(objectClass.typeCodeValue) == "atts")

        let place = try #require(event.paramDescriptor(forKeyword: keyAEInsertHere))
        #expect(Self.letters(place.descriptorType) == "insl")
        let position = try #require(place.forKeyword(keyAEPosition))
        #expect(position.descriptorType == typeEnumerated)
        #expect(Self.letters(position.enumCodeValue) == "end ")

        let content = try #require(place.forKeyword(keyAEObject))
        #expect(Self.shape(content) == ["prop", "prop"])
        #expect(Self.letters(try #require(Self.data(content)).typeCodeValue) == "ctnt")
        let reply = try #require(Self.container(content))
        #expect(Self.shape(reply) == ["bcke", "ID  "])
        #expect(Self.data(reply)?.descriptorType == typeSInt32)
        #expect(Self.data(reply)?.int32Value == 77)
        #expect(Self.container(reply)?.descriptorType == typeNull)
    }

    /// The new attachment's properties are a record with the one key of its file, a file
    /// URL, so Mail reads the file itself. A URL that is not a file URL builds no event.
    @Test func theAttachmentHoldsOnlyItsFileAsAFileURL() throws {
        let event = try MailEvents.Request.attach(Self.file, toReply: 77, in: Self.session).appleEvent(target: target)
        let properties = try #require(event.paramDescriptor(forKeyword: keyAEPropData))
        #expect(properties.descriptorType == typeAERecord)
        #expect(properties.numberOfItems == 1)
        #expect(Self.letters(properties.keywordForDescriptor(at: 1)) == "atfn")
        let file = try #require(properties.forKeyword(MailEvents.code("atfn")))
        #expect(Self.letters(file.descriptorType) == "furl")
        #expect(file.fileURLValue == Self.file)
        #expect(file.fileURLValue?.path == "/Users/someone/Projects/Harbor lobby/Drawings/floor-plan-v3.pdf")

        let web = try #require(URL(string: "https://harbor.example/floor-plan-v3.pdf"))
        #expect(throws: MailEvents.Failure.self) {
            try MailEvents.Request.attach(web, toReply: 77, in: Self.session).appleEvent(target: target)
        }
    }

    @Test func attachNeverInteractsOrPromptsAndWaits30Seconds() {
        let request = MailEvents.Request.attach(Self.file, toReply: 77, in: Self.session)
        #expect(request.sendOptions.contains(.waitForReply))
        #expect(request.sendOptions.contains(.neverInteract))
        #expect(request.sendOptions.contains(MailEvents.Request.neverPrompt))
        #expect(!request.sendOptions.contains(.canInteract))
        #expect(request.timeout == 30)
    }

    /// Only an attachment is bound to the Mail session that made its reply. The others go
    /// to whichever Mail runs.
    @Test func onlyAnAttachmentNamesItsSession() {
        #expect(MailEvents.Request.attach(Self.file, toReply: 77, in: Self.session).session == Self.session)
        #expect(MailEvents.Request.reply(to: Self.message, all: false).session == nil)
        #expect(MailEvents.Request.get(.property(Code.source, of: Self.message)).session == nil)
        #expect(MailEvents.Request.count(Code.message, in: Self.mailbox).session == nil)
        #expect(Self.session != MailEvents.Session(processIdentifier: 812, launched: Date(timeIntervalSince1970: 1_761_400_000)))
        #expect(Self.session != MailEvents.Session(processIdentifier: 811, launched: Date(timeIntervalSince1970: 1_761_500_000)))
    }

    /// Mail names the reply it made as outgoing message id N of the application, which a
    /// specifier reads back as it came.
    @Test func theReplyComesBackAsAnOutgoingMessage() throws {
        let reply = Specifier.id(Code.outgoingMessage, 77, of: .application)
        let descriptor = try reply.descriptor()
        #expect(Self.shape(descriptor) == ["bcke", "ID  "])
        #expect(Value(descriptor) == .reference(reply))
    }

    /// Mail names accounts, mailboxes and messages in its replies the way Projects builds them,
    /// so a reference read from a reply goes back to Mail unchanged.
    @Test func specifiersComeBackFromTheirDescriptors() throws {
        let specifiers: [Specifier] = [
            Self.account,
            Self.mailbox,
            Self.message,
            .name(Code.mailbox, "Imported", of: .application),
            .property(Code.inbox, of: .application),
            .every(Code.mailbox, of: Self.account),
            .index(Code.message, -1, of: Self.mailbox),
        ]
        for specifier in specifiers {
            let descriptor = try specifier.descriptor()
            #expect(Value(descriptor) == .reference(specifier))
        }
        // Projects never reads a range back from Mail.
        let range = try Specifier.range(Code.message, 1, 2, of: Self.mailbox).descriptor()
        #expect(Value(range) == .other)
    }

    @Test func aSpecifierSurvivesJSON() throws {
        let saved = try JSONEncoder().encode(Self.message)
        let loaded = try JSONDecoder().decode(Specifier.self, from: saved)
        #expect(loaded == Self.message)
    }

    @Test func repliesBecomeValues() throws {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(Value(NSAppleEventDescriptor(string: "Quarterly figures")) == .text("Quarterly figures"))
        #expect(Value(NSAppleEventDescriptor(int32: 42)) == .integer(42))
        #expect(Value(NSAppleEventDescriptor(boolean: true)) == .boolean(true))
        #expect(Value(NSAppleEventDescriptor(boolean: false)) == .boolean(false))
        #expect(Value(NSAppleEventDescriptor(date: date)) == .date(date))
        #expect(Value(nil) == .missing)
        #expect(Value(NSAppleEventDescriptor.null()) == .missing)
        #expect(Value(NSAppleEventDescriptor(typeCode: 0x6D73_6E67)) == .missing)
        #expect(Value(NSAppleEventDescriptor(typeCode: 0x6162_6364)) == .other)

        var big: Int64 = 5_000_000_000
        #expect(Value(NSAppleEventDescriptor(descriptorType: typeSInt64, bytes: &big, length: 8)) == .integer(5_000_000_000))
        var size: UInt32 = 3_000_000_000
        #expect(Value(NSAppleEventDescriptor(descriptorType: typeUInt32, bytes: &size, length: 4)) == .integer(3_000_000_000))
        #expect(Value(NSAppleEventDescriptor(double: 12.0)) == .integer(12))

        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(string: "a@harbor.example"), at: 1)
        list.insert(NSAppleEventDescriptor.list(), at: 2)
        list.insert(NSAppleEventDescriptor(int32: 7), at: 3)
        #expect(Value(list) == .list([.text("a@harbor.example"), .list([]), .integer(7)]))
    }

    /// The key data of a specifier from Mail is a type, a number or text. A specifier there is
    /// never read, so a reply never nests deeper than the limit.
    @Test func aSpecifierAsKeyDataIsOther() throws {
        var data = try Self.message.descriptor()
        for form in [formName, formUniqueID, formAbsolutePosition, formPropertyID] {
            let object = try #require(NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier))
            object.setDescriptor(NSAppleEventDescriptor(typeCode: Code.mailbox), forKeyword: AEKeyword(keyAEDesiredClass))
            object.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
            object.setDescriptor(NSAppleEventDescriptor(enumCode: DescType(form)), forKeyword: AEKeyword(keyAEKeyForm))
            object.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
            #expect(Value(object) == .other)
            data = object
        }
    }

    @Test func listsDeeperThanProjectsAsksAreOther() {
        var deepest = NSAppleEventDescriptor.list()
        for _ in 0..<5 {
            let outer = NSAppleEventDescriptor.list()
            outer.insert(deepest, at: 1)
            deepest = outer
        }
        #expect(Value(deepest) == .list([.list([.list([.list([.other])])])]))
    }

    // MARK: The send thread

    /// A caller cancelled while an earlier request holds the thread gets CancellationError
    /// at once, and its work never runs. The work here sends nothing. A thread that made the
    /// caller wait for its turn would hang, and the time limit stops it.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledRequestNeverRuns() async throws {
        let thread = MailEvents.SendThread()
        let (started, starting) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let ran = Ran()
        let first = Task {
            try await thread.run {
                starting.yield()
                release.wait()
                return 1
            }
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()

        let second = Task {
            try await thread.run {
                ran.mark()
                return 2
            }
        }
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }

        release.signal()
        #expect(try await first.value == 1)
        // The thread runs its work in order, so the second would have run before this.
        #expect(try await thread.run { 3 } == 3)
        #expect(!ran.happened)
    }

    /// Whether a piece of work ran, from any thread.
    private final class Ran: Sendable {
        private let value = Mutex(false)

        var happened: Bool {
            value.withLock { $0 }
        }

        func mark() {
            value.withLock { $0 = true }
        }
    }

    // MARK: Reading descriptors

    private static func letters(_ code: FourCharCode) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
    }

    /// The class an object specifier wants and its key form, as four letters each.
    private static func shape(_ object: NSAppleEventDescriptor) -> [String] {
        guard object.descriptorType == typeObjectSpecifier else { return ["not an object specifier"] }
        return [
            letters(object.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue ?? 0),
            letters(object.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue ?? 0),
        ]
    }

    private static func data(_ object: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        object.forKeyword(AEKeyword(keyAEKeyData))
    }

    private static func container(_ object: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        object.forKeyword(AEKeyword(keyAEContainer))
    }
}
