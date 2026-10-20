import AppKit
import Testing
@testable import Orra

/// Every test uses its own named pasteboard, so the user's clipboard is never touched. A
/// pasteboard does not tell whether it is kept on this Mac, so TextInserterTests checks that
/// part through the restore of a concealed copy.
@MainActor
struct ConcealedClipboardTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.db-ol.Orra.tests.\(UUID().uuidString)"))

    @Test func aCopyIsConcealedAndStays() async throws {
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        #expect(ConcealedClipboard.copy("什么都可以", to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "什么都可以")
        #expect(pasteboard.types?.contains(ConcealedClipboard.concealedType) == true)
        // Nothing puts the old contents back.
        try await Task.sleep(for: .milliseconds(150))
        #expect(pasteboard.string(forType: .string) == "什么都可以")
    }

    @Test func aCopyTakesThePlaceOfEveryEarlierItem() {
        defer { pasteboard.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("io.github.db-ol.Orra.tests.custom")
        let first = NSPasteboardItem()
        first.setString("rich text stand in", forType: .string)
        first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem()
        second.setString("second item", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([first, second])
        let before = pasteboard.changeCount

        #expect(ConcealedClipboard.copy("Dear Mei,\n\nThe samples ship on Friday.", to: pasteboard))
        #expect(pasteboard.changeCount != before)
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 1)
        #expect(Set(items.first?.types ?? []) == [.string, ConcealedClipboard.concealedType])
        #expect(items.first?.string(forType: .string) == "Dear Mei,\n\nThe samples ship on Friday.")
        #expect(pasteboard.data(forType: custom) == nil)
    }
}
