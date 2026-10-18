import Foundation
import Synchronization
import Testing
@testable import Orra

/// The reading of the screen with a scripted field, so no app is read.
struct ScreenReaderTests {
    /// What the reader asked the field, in order.
    final class Asked: Sendable {
        let list = Mutex<[String]>([])

        func add(_ question: String) {
            list.withLock { $0.append(question) }
        }

        var all: [String] {
            list.withLock { $0 }
        }
    }

    /// A field with `text` and the cursor at `cursor`, in UTF-16 units, or no cursor for
    /// nil. `rangeReads` says whether it gives a range of its text. `onAsk` runs before
    /// each answer.
    static func field(
        kind: FocusedField.Kind = .plainText,
        text: String,
        cursor: Int?,
        rangeReads: Bool = true,
        title: String? = "Notes",
        asked: Asked,
        onAsk: @escaping @Sendable () -> Void = {}
    ) -> ScreenField {
        let units = Array(text.utf16)
        return ScreenField(
            kind: kind,
            selection: {
                asked.add("selection")
                onAsk()
                return cursor.map { NSRange(location: $0, length: 0) }
            },
            text: { range in
                asked.add("text")
                onAsk()
                guard rangeReads, range.location >= 0, range.location + range.length <= units.count else { return nil }
                return String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
            },
            length: {
                asked.add("length")
                onAsk()
                return units.count
            },
            value: {
                asked.add("value")
                onAsk()
                return text
            },
            windowTitle: {
                asked.add("title")
                onAsk()
                return title
            }
        )
    }

    static func source(_ field: ScreenField?, secureInputHolder: pid_t? = nil, asked: Asked) -> ScreenSource {
        ScreenSource(
            secureInputHolder: { secureInputHolder },
            focusedField: { _ in
                asked.add("field")
                return field
            }
        )
    }

    private let app: pid_t = 4242
    private var later: ContinuousClock.Instant { .now + .seconds(60) }

    @Test func readsTheTextBeforeTheCursorAndTheWindowTitle() {
        let asked = Asked()
        let text = "Hi Dana, the Quorvia notes are attached. Bye"
        let field = Self.field(text: text, cursor: 41, asked: asked)
        let screen = ScreenReader.read(inApp: app, from: Self.source(field, asked: asked), deadline: later)
        #expect(screen == ScreenText(beforeCursor: "Hi Dana, the Quorvia notes are attached. ", windowTitle: "Notes"))
        #expect(asked.all == ["field", "selection", "text", "title"])
    }

    @Test func readsAtMostTheLastThousandCharacters() {
        let asked = Asked()
        let text = String(repeating: "早", count: 600) + String(repeating: "晚", count: 1_200)
        let field = Self.field(text: text, cursor: 1_800, asked: asked)
        let screen = ScreenReader.read(inApp: app, from: Self.source(field, asked: asked), deadline: later)
        #expect(screen?.beforeCursor == String(repeating: "晚", count: ScreenReader.maximumBeforeCursor))
        // Characters outside the BMP take two units each.
        let emoji = String(repeating: "😀", count: 1_500)
        let wide = ScreenReader.read(inApp: app, from: Self.source(Self.field(text: emoji, cursor: emoji.utf16.count, asked: asked), asked: asked), deadline: later)
        #expect(wide?.beforeCursor == String(repeating: "😀", count: ScreenReader.maximumBeforeCursor))
        // A character cut in half where the range starts is left out.
        #expect(ScreenReader.lastCharacters(of: "\u{FFFD}😀 Bram") == "😀 Bram")
    }

    @Test func aFieldWithoutRangesIsReadWholeAndCutAtTheCursor() {
        let asked = Asked()
        let field = Self.field(text: "林悦你好，青岚计划的排期在附件里。谢谢", cursor: 17, rangeReads: false, asked: asked)
        let screen = ScreenReader.read(inApp: app, from: Self.source(field, asked: asked), deadline: later)
        #expect(screen?.beforeCursor == "林悦你好，青岚计划的排期在附件里。")
        #expect(asked.all == ["field", "selection", "text", "length", "value", "title"])
    }

    @Test func aFieldWithoutACursorIsReadFromItsEnd() {
        let asked = Asked()
        let field = Self.field(text: "Ask Bram about Kelpstone.", cursor: nil, asked: asked)
        let screen = ScreenReader.read(inApp: app, from: Self.source(field, asked: asked), deadline: later)
        #expect(screen?.beforeCursor == "Ask Bram about Kelpstone.")
    }

    @Test func aLongFieldWithoutRangesIsNotCopied() {
        let asked = Asked()
        let text = String(repeating: "a", count: ScreenReader.maximumFieldLength + 1)
        let field = Self.field(text: text, cursor: 10, rangeReads: false, title: nil, asked: asked)
        let screen = ScreenReader.read(inApp: app, from: Self.source(field, asked: asked), deadline: later)
        #expect(screen == nil)
        #expect(!asked.all.contains("value"))
    }

    @Test func aPasswordFieldIsNeverRead() {
        let asked = Asked()
        let field = Self.field(kind: .password, text: "hunter2", cursor: 7, asked: asked)
        #expect(ScreenReader.read(inApp: app, from: Self.source(field, asked: asked), deadline: later) == nil)
        #expect(asked.all == ["field"])
    }

    @Test func anElementThatIsNoTextFieldIsNotRead() {
        let asked = Asked()
        let field = Self.field(kind: .unknown, text: "Kelpstone", cursor: 9, asked: asked)
        #expect(ScreenReader.read(inApp: app, from: Self.source(field, asked: asked), deadline: later) == nil)
        #expect(asked.all == ["field"])
    }

    @Test func anAppWithSecureInputIsNotAsked() {
        let asked = Asked()
        let field = Self.field(text: "Kelpstone", cursor: 9, asked: asked)
        #expect(ScreenReader.read(inApp: app, from: Self.source(field, secureInputHolder: app, asked: asked), deadline: later) == nil)
        #expect(asked.all.isEmpty)
        // Secure input held by another app leaves this one readable.
        let other = ScreenReader.read(inApp: app, from: Self.source(field, secureInputHolder: 1, asked: asked), deadline: later)
        #expect(other?.beforeCursor == "Kelpstone")
    }

    @Test func orraItselfIsNotRead() {
        let asked = Asked()
        let field = Self.field(text: "Kelpstone", cursor: 9, asked: asked)
        #expect(ScreenReader.read(inApp: getpid(), from: Self.source(field, asked: asked), deadline: later) == nil)
        #expect(asked.all.isEmpty)
    }

    @Test func nothingIsAskedAfterTheDeadline() {
        let asked = Asked()
        let clock = Mutex(ContinuousClock.now)
        let start = clock.withLock { $0 }
        // Each answer takes 250 ms, and the reading may take 500.
        let field = Self.field(text: "Ask Bram about Kelpstone.", cursor: 25, asked: asked) {
            clock.withLock { $0 += .milliseconds(250) }
        }
        let screen = ScreenReader.read(inApp: app, from: Self.source(field, asked: asked), deadline: start + .milliseconds(500)) {
            clock.withLock { $0 }
        }
        #expect(screen == ScreenText(beforeCursor: "Ask Bram about Kelpstone.", windowTitle: nil))
        #expect(asked.all == ["field", "selection", "text"])
        // An app that answers too slowly gives nothing at all.
        let slow = Asked()
        let slowField = Self.field(text: "Ask Bram about Kelpstone.", cursor: 25, asked: slow) {
            clock.withLock { $0 += .seconds(1) }
        }
        let late = clock.withLock { $0 }
        let nothing = ScreenReader.read(inApp: app, from: Self.source(slowField, asked: slow), deadline: late + .milliseconds(500)) {
            clock.withLock { $0 }
        }
        #expect(nothing == nil)
        #expect(slow.all == ["field", "selection"])
    }

    @Test func aLongWindowTitleIsCut() {
        let asked = Asked()
        let field = Self.field(text: "", cursor: 0, title: String(repeating: "x", count: 500), asked: asked)
        let screen = ScreenReader.read(inApp: app, from: Self.source(field, asked: asked), deadline: later)
        #expect(screen?.beforeCursor == "")
        #expect(screen?.windowTitle?.count == 200)
    }
}
