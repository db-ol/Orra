import AppKit
import ApplicationServices
import Synchronization

/// The focused element of an app, as ScreenReader reads it through the Accessibility API.
/// Closures, so tests can pass fakes. The live ones ask the app and may wait for it, up to
/// `ScreenReader.callTimeout` each.
nonisolated struct ScreenField: Sendable {
    /// What the element is, from its role and subrole. Nothing else is asked unless it is
    /// a plain text field.
    var kind: FocusedField.Kind
    /// The selected range in UTF-16 units, the cursor when it is empty. Nil when the field
    /// does not say.
    var selection: @Sendable () -> NSRange?
    /// The text in a range of UTF-16 units, nil when the field does not give it.
    var text: @Sendable (NSRange) -> String?
    /// The length of the text, nil when the field does not say.
    var length: @Sendable () -> Int?
    /// The whole text, nil when the field does not give it.
    var value: @Sendable () -> String?
    /// The title of the app's focused window, nil when it has none.
    var windowTitle: @Sendable () -> String?
}

/// Where ScreenReader reads. Closures, so tests can pass fakes.
nonisolated struct ScreenSource: Sendable {
    /// The process that holds secure input, or nil while none does.
    var secureInputHolder: @Sendable () -> pid_t?
    /// The focused element of the app, or nil when there is none or it did not answer.
    var focusedField: @Sendable (pid_t) -> ScreenField?
}

/// Reads the text before the cursor in the focused field of the app in front, and the title
/// of its window, for Use names on screen, see ScreenNames. Only a plain text field is read,
/// never a password field and never an app that holds secure input. At most
/// `maximumBeforeCursor` characters. Reading stops at a deadline, and each call to the app
/// waits at most `callTimeout`, so an app that does not answer costs little, and the
/// dictation never waits for the reading, see PushToTalkController. Nothing read is logged
/// or saved.
nonisolated enum ScreenReader {
    /// The experiment measured contexts of up to 825 characters before the cursor.
    static let maximumBeforeCursor = 1_000
    /// A field longer than this is read only through a range of its text, so a big
    /// document is never copied whole, as with FieldReader.
    static let maximumFieldLength = FieldReader.maximumLength
    /// How long one call to the app may wait.
    static let callTimeout: Float = 0.2
    /// How long the reading may go on after the press of the key. No call starts later.
    static let timeLimit: Duration = .milliseconds(500)

    /// What the focused field of the app shows before its cursor, and its window title. Nil
    /// for an app that holds secure input, a focused element that is not a plain text
    /// field, Orra itself, or when nothing could be read before `deadline`.
    static func read(
        inApp pid: pid_t,
        from source: ScreenSource,
        deadline: ContinuousClock.Instant,
        now: () -> ContinuousClock.Instant = { .now }
    ) -> ScreenText? {
        func inTime() -> Bool { now() < deadline }
        guard pid != getpid(), source.secureInputHolder() != pid, inTime(),
              let field = source.focusedField(pid), field.kind == .plainText, inTime() else { return nil }
        var before = ""
        if let selection = field.selection(), selection.location != NSNotFound, inTime() {
            let cursor = max(0, selection.location)
            // Twice as many UTF-16 units as characters, for characters outside the BMP.
            let start = max(0, cursor - 2 * maximumBeforeCursor)
            if cursor > 0, let text = field.text(NSRange(location: start, length: cursor - start)) {
                before = lastCharacters(of: text)
            } else if cursor > 0, inTime(), let whole = wholeText(of: field, inTime: inTime) {
                before = lastCharacters(of: String(decoding: whole.utf16.prefix(cursor), as: UTF16.self))
            }
        } else if inTime(), let whole = wholeText(of: field, inTime: inTime) {
            // A field that does not say where its cursor is: most dictations go at the end.
            before = lastCharacters(of: whole)
        }
        let title = inTime() ? field.windowTitle().map { String($0.prefix(200)) } : nil
        guard !before.isEmpty || title?.isEmpty == false else { return nil }
        return ScreenText(beforeCursor: before, windowTitle: title)
    }

    /// The field's whole text, when it is no longer than `maximumFieldLength`.
    private static func wholeText(of field: ScreenField, inTime: () -> Bool) -> String? {
        guard let length = field.length(), length <= maximumFieldLength, inTime(),
              let value = field.value(), value.utf16.count <= maximumFieldLength else { return nil }
        return value
    }

    /// The last `maximumBeforeCursor` characters, without a broken character at the start.
    static func lastCharacters(of text: String) -> String {
        String(text.suffix(maximumBeforeCursor).drop { $0 == "\u{FFFD}" })
    }
}

extension ScreenSource {
    /// The Accessibility API, which Orra already has for the talk key.
    nonisolated static let live = ScreenSource(
        secureInputHolder: { SecureInput.holder() },
        focusedField: { pid in
            guard let element = FocusedField.focusedElement(inApp: pid, timeout: ScreenReader.callTimeout) else { return nil }
            let field = FieldHandle(element)
            return ScreenField(
                kind: FocusedField.kind(of: element),
                selection: { AXText.range(of: field.element, kAXSelectedTextRangeAttribute) },
                text: { AXText.string(of: field.element, in: $0) },
                length: { AXText.attribute(of: field.element, kAXNumberOfCharactersAttribute) as? Int },
                value: { AXText.attribute(of: field.element, kAXValueAttribute) as? String },
                windowTitle: { AXText.windowTitle(inApp: pid) }
            )
        }
    )
}

/// The few Accessibility reads ScreenSource.live needs.
private nonisolated enum AXText {
    static func attribute(of element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func range(of element: AXUIElement, _ name: String) -> NSRange? {
        guard let value = attribute(of: element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // The type was checked above.
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func string(of element: AXUIElement, in range: NSRange) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func windowTitle(inApp pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, ScreenReader.callTimeout)
        guard let window = attribute(of: app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        // The type was checked above.
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, ScreenReader.callTimeout)
        return attribute(of: element, kAXTitleAttribute) as? String
    }
}

extension ScreenNames {
    /// The names of the app in front for the speech model: reads the screen, see
    /// ScreenReader, and takes the terms out of what it read. Off the main actor, since the
    /// app in front answers and may be slow, and the first use reads the common words.
    @concurrent
    static func read(inApp pid: pid_t) async -> [String] {
        let deadline = ContinuousClock.now + ScreenReader.timeLimit
        guard let screen = ScreenReader.read(inApp: pid, from: .live, deadline: deadline) else { return [] }
        return terms(in: screen, common: .installed)
    }
}

/// The reading of the screen for one dictation, which the press of the key starts while Use
/// names on screen is on, see PushToTalkController. The reading fills in the names when it
/// ends, and the dictation takes them only if it has ended by the time the speech model
/// starts, so the dictation never waits for it. In memory for that dictation only.
nonisolated final class ScreenNamesRead: Sendable {
    /// The app that was read, the one in front at the press.
    let app: pid_t
    private let started: ContinuousClock.Instant
    private let result = Mutex<(names: [String], took: Duration)?>(nil)

    init(app: pid_t, started: ContinuousClock.Instant = .now) {
        self.app = app
        self.started = started
    }

    func finish(_ names: [String]) {
        let took = started.duration(to: .now)
        result.withLock { $0 = (names, took) }
    }

    /// The names and how long the reading took, nil while it still runs.
    var finished: (names: [String], took: Duration)? {
        result.withLock { $0 }
    }
}
