import CoreServices
import Foundation
import Testing
@testable import Orra

/// The events of the Mail bridge, built for this test process and never sent, as the Mail
/// spike's self check did. Each must be one of MailEvent's three, with every value a typed
/// parameter, get and count without interaction, and a reply that opens its window.
struct MailEventsTests {
    private typealias Code = MailEvents.Code
    private typealias Specifier = MailEvents.Specifier
    private typealias Value = MailEvents.Value

    /// This test process. Building an event for it sends nothing.
    private let target = NSAppleEventDescriptor(processIdentifier: getpid())

    private static let account = Specifier.textID(Code.account, "7A31-account", of: .application)
    private static let mailbox = Specifier.name(Code.mailbox, "Archive/2026", of: account)
    private static let message = Specifier.id(Code.message, 4217, of: mailbox)

    @Test func onlyGetCountAndReplyWithMailsCodes() {
        #expect(MailEvent.allCases == [.get, .count, .reply])
        #expect(MailEvent.allCases.map { Self.letters($0.eventClass) + Self.letters($0.eventID) } == ["coregetd", "corecnte", "emalrpms"])
        #expect(MailEvent.get.eventClass == 0x636F_7265)
        #expect(MailEvent.get.eventID == 0x6765_7464)
        #expect(MailEvents.code("ID  ") == 0x4944_2020)
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
        #expect(request.timeout == 10)
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

    @Test func listsDeeperThanProjectsAsksAreOther() {
        var deepest = NSAppleEventDescriptor.list()
        for _ in 0..<5 {
            let outer = NSAppleEventDescriptor.list()
            outer.insert(deepest, at: 1)
            deepest = outer
        }
        #expect(Value(deepest) == .list([.list([.list([.list([.other])])])]))
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
