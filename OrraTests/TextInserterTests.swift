import AppKit
import Testing
@testable import Orra

/// Every test uses its own named pasteboard, so the user's clipboard is never touched,
/// and a fake shortcut poster, so no real keyboard event is ever posted.
@MainActor
final class InserterFixture {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.db-ol.Orra.tests.\(UUID().uuidString)"))
    /// The process that holds secure input, nil while none does.
    var secureInputHolder: pid_t?
    /// The app in front.
    let frontmost: pid_t = 100
    var field: FocusedField.Kind = .plainText
    /// Runs each time the inserter reads the old pasteboard contents.
    var whileReading: () -> Void = {}
    private(set) var postedKeyCodes: [CGKeyCode] = []
    /// How often the inserter asked about the focused field.
    private(set) var fieldChecks = 0

    func makeInserter(restoreDelay: Duration = .milliseconds(50)) -> TextInserter {
        TextInserter(
            pasteboard: pasteboard,
            postCommandShortcut: { self.postedKeyCodes.append($0) },
            secureInputHolder: { self.secureInputHolder },
            frontmostApp: { self.frontmost },
            focusedField: { _ in
                self.fieldChecks += 1
                return self.field
            },
            readSnapshot: { name in
                self.whileReading()
                return await PasteboardSnapshot.read(pasteboardNamed: name)
            },
            keyCodeForV: { 9 },
            restoreDelay: restoreDelay
        )
    }

    func put(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Removes the test pasteboard from the pasteboard server.
    func release() {
        pasteboard.releaseGlobally()
    }
}

@MainActor
struct TextInserterTests {
    @Test func pastesWithCommandV() async {
        let fixture = InserterFixture()
        defer { fixture.release() }
        let inserter = fixture.makeInserter()
        #expect(await inserter.insert("这个 PR 先 merge 一下") == .pasted)
        #expect(fixture.pasteboard.string(forType: .string) == "这个 PR 先 merge 一下")
        #expect(fixture.pasteboard.types?.contains(TextInserter.concealedType) == true)
        #expect(fixture.postedKeyCodes == [9])
    }

    @Test func restoresThePreviousPasteboard() async throws {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        let inserter = fixture.makeInserter()
        await inserter.insert("new")
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.pasteboard.string(forType: .string) == "old")
        #expect(fixture.pasteboard.types?.contains(TextInserter.concealedType) == false)
    }

    @Test func keepsWhatTheUserCopiedAfterwards() async throws {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        let inserter = fixture.makeInserter()
        await inserter.insert("new")
        fixture.put("copied by the user")
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.pasteboard.string(forType: .string) == "copied by the user")
    }

    @Test func secureInputHeldInTheBackgroundStillPastesAndRestores() async throws {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        // Another process holds secure input, and the field in front cannot be described.
        fixture.secureInputHolder = 200
        fixture.field = .unknown
        let inserter = fixture.makeInserter()
        #expect(await inserter.insert("new") == .pasted)
        #expect(fixture.postedKeyCodes == [9])
        #expect(fixture.fieldChecks == 1)
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.pasteboard.string(forType: .string) == "old")
    }

    @Test func aPasswordFieldGetsNothingAndThePasteboardStays() async throws {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        let changeCount = fixture.pasteboard.changeCount
        fixture.secureInputHolder = fixture.frontmost
        fixture.field = .password
        let inserter = fixture.makeInserter()
        #expect(await inserter.insert("new") == .skippedPasswordField)
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.postedKeyCodes.isEmpty)
        #expect(fixture.pasteboard.string(forType: .string) == "old")
        #expect(fixture.pasteboard.changeCount == changeCount)
    }

    @Test func anUnreadableFieldInTheAppHoldingSecureInputGetsNothing() async {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        // A web password field in a browser that has not built its accessibility tree.
        fixture.secureInputHolder = fixture.frontmost
        fixture.field = .unknown
        let inserter = fixture.makeInserter()
        #expect(await inserter.insert("new") == .skippedPasswordField)
        #expect(fixture.postedKeyCodes.isEmpty)
        #expect(fixture.pasteboard.string(forType: .string) == "old")
    }

    @Test func plainTextInTheAppHoldingSecureInputGetsThePaste() async {
        let fixture = InserterFixture()
        defer { fixture.release() }
        // Terminal with Secure Keyboard Entry, whose text area Accessibility describes.
        fixture.secureInputHolder = fixture.frontmost
        fixture.field = .plainText
        let inserter = fixture.makeInserter()
        #expect(await inserter.insert("new") == .pasted)
        #expect(fixture.postedKeyCodes == [9])
    }

    @Test func withoutSecureInputNothingAsksAboutTheField() async {
        let fixture = InserterFixture()
        defer { fixture.release() }
        // No secure input means no focused password field, so the answer is never needed.
        fixture.field = .password
        let inserter = fixture.makeInserter()
        #expect(await inserter.insert("new") == .pasted)
        #expect(fixture.fieldChecks == 0)
        #expect(fixture.postedKeyCodes == [9])
    }

    @Test func focusThatMovesIntoAPasswordFieldWhileTheOldContentsAreReadIsCaught() async {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        fixture.field = .password
        // Secure input comes on while the old contents are read, as when Tab moves into a
        // password field.
        fixture.whileReading = { fixture.secureInputHolder = fixture.frontmost }
        let inserter = fixture.makeInserter()
        #expect(await inserter.insert("new") == .skippedPasswordField)
        #expect(fixture.postedKeyCodes.isEmpty)
        #expect(fixture.pasteboard.string(forType: .string) == "old")
    }

    @Test func aSkippedPasswordFieldLetsAnEarlierRestoreFinish() async throws {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        let inserter = fixture.makeInserter(restoreDelay: .milliseconds(100))
        #expect(await inserter.insert("first") == .pasted)
        fixture.secureInputHolder = fixture.frontmost
        fixture.field = .password
        #expect(await inserter.insert("second") == .skippedPasswordField)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.pasteboard.string(forType: .string) == "old")
    }

    @Test func copyLastDictationIsConcealedAndStays() async throws {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        TextInserter.copy("什么都可以", to: fixture.pasteboard)
        #expect(fixture.pasteboard.string(forType: .string) == "什么都可以")
        #expect(fixture.pasteboard.types?.contains(TextInserter.concealedType) == true)
        // Nothing puts the old contents back.
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.pasteboard.string(forType: .string) == "什么都可以")
    }

    @Test func emptyTextChangesNothing() async {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        let inserter = fixture.makeInserter()
        #expect(await inserter.insert("") == .nothingToInsert)
        #expect(fixture.postedKeyCodes.isEmpty)
        #expect(fixture.pasteboard.string(forType: .string) == "old")
    }

    @Test func secondDictationBeforeTheRestoreKeepsTheOriginalPasteboard() async throws {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        let inserter = fixture.makeInserter()
        await inserter.insert("one")
        await inserter.insert("two")
        #expect(fixture.pasteboard.string(forType: .string) == "two")
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.pasteboard.string(forType: .string) == "old")
        #expect(fixture.postedKeyCodes == [9, 9])
    }

    @Test func restoresEveryTypeOfEveryItem() async throws {
        let fixture = InserterFixture()
        defer { fixture.release() }
        let custom = NSPasteboard.PasteboardType("io.github.db-ol.Orra.tests.custom")
        let first = NSPasteboardItem()
        first.setString("rich text stand in", forType: .string)
        first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem()
        second.setString("second item", forType: .string)
        fixture.pasteboard.clearContents()
        fixture.pasteboard.writeObjects([first, second])
        let inserter = fixture.makeInserter()
        await inserter.insert("new")
        try await Task.sleep(for: .milliseconds(250))
        let items = fixture.pasteboard.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "rich text stand in")
        #expect(items.first?.data(forType: custom) == Data([1, 2, 3]))
        #expect(items.last?.string(forType: .string) == "second item")
    }

    @Test func currentLayoutHasAKeyForV() throws {
        // Reads the real keyboard layout but posts nothing.
        let code = try #require(KeyboardLayout.keyCode(for: "v"))
        #expect(KeyboardLayout.character(for: code) == "v")
    }

    @Test func currentLayoutHasAKeyForVWhileCommandIsHeld() throws {
        // The key Command V uses. Layouts such as Dvorak QWERTY Command change it.
        let code = try #require(KeyboardLayout.keyCode(for: "v", withCommand: true))
        #expect(KeyboardLayout.character(for: code, withCommand: true) == "v")
    }

    @Test func snapshotReadsEveryItemAndTheChangeCount() async {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        let snapshot = await PasteboardSnapshot.read(pasteboardNamed: fixture.pasteboard.name.rawValue)
        #expect(snapshot.changeCount == fixture.pasteboard.changeCount)
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items.first?.contains { $0.type == NSPasteboard.PasteboardType.string.rawValue } == true)
    }
}

struct FocusedFieldTests {
    @Test func fieldsAreToldApartByRoleAndSubrole() {
        #expect(FocusedField.kind(role: "AXTextField", subrole: "AXSecureTextField") == .password)
        #expect(FocusedField.kind(role: "AXSecureTextField", subrole: nil) == .password)
        #expect(FocusedField.kind(role: "AXTextField", subrole: nil) == .plainText)
        #expect(FocusedField.kind(role: "AXTextField", subrole: "AXSearchField") == .plainText)
        #expect(FocusedField.kind(role: "AXTextArea", subrole: nil) == .plainText)
        #expect(FocusedField.kind(role: "AXComboBox", subrole: nil) == .plainText)
        #expect(FocusedField.kind(role: "AXGroup", subrole: nil) == .unknown)
        #expect(FocusedField.kind(role: "AXWebArea", subrole: nil) == .unknown)
        #expect(FocusedField.kind(role: nil, subrole: nil) == .unknown)
    }

    @Test func onlyTheAppHoldingSecureInputGetsNothingForAnUnreadableField() {
        #expect(FocusedField.skipsPaste(field: .password, secureInputHolder: 200, frontmostApp: 100))
        #expect(FocusedField.skipsPaste(field: .password, secureInputHolder: 100, frontmostApp: 100))
        #expect(FocusedField.skipsPaste(field: .unknown, secureInputHolder: 100, frontmostApp: 100))
        #expect(!FocusedField.skipsPaste(field: .unknown, secureInputHolder: 200, frontmostApp: 100))
        #expect(!FocusedField.skipsPaste(field: .plainText, secureInputHolder: 100, frontmostApp: 100))
    }

    @Test func anAppThatCannotBeAskedIsUnknown() async {
        // No process has this ID, so Accessibility cannot answer.
        #expect(await FocusedField.kind(inApp: Int32.max) == .unknown)
    }
}
