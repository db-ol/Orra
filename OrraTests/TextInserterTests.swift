import AppKit
import Testing
@testable import Orra

/// Every test uses its own named pasteboard, so the user's clipboard is never touched,
/// and a fake shortcut poster, so no real keyboard event is ever posted.
@MainActor
final class InserterFixture {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.db-ol.Orra.tests.\(UUID().uuidString)"))
    var secureInput = false
    private(set) var postedKeyCodes: [CGKeyCode] = []

    func makeInserter(restoreDelay: Duration = .milliseconds(50)) -> TextInserter {
        TextInserter(
            pasteboard: pasteboard,
            postCommandShortcut: { self.postedKeyCodes.append($0) },
            isSecureInputOn: { self.secureInput },
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

    @Test func secureInputLeavesTheTextOnThePasteboard() async throws {
        let fixture = InserterFixture()
        defer { fixture.release() }
        fixture.put("old")
        fixture.secureInput = true
        let inserter = fixture.makeInserter()
        #expect(await inserter.insert("new") == .leftOnPasteboardForSecureInput)
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.postedKeyCodes.isEmpty)
        #expect(fixture.pasteboard.string(forType: .string) == "new")
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
