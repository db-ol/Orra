import AppKit
import Carbon.HIToolbox
import CoreGraphics
import IOKit

/// How putting text into the frontmost app went.
nonisolated enum InsertionResult: Equatable, Sendable {
    /// The text was pasted with Command V.
    case pasted
    /// A password field had the focus, so nothing was pasted and the pasteboard was left
    /// alone.
    case skippedPasswordField
    /// There was nothing to insert.
    case nothingToInsert
}

/// Puts dictated text into the frontmost app: write it to the pasteboard, post Command V,
/// and put the old pasteboard back half a second later.
///
/// The text is marked with org.nspasteboard.ConcealedType so clipboard managers skip it.
/// The old contents come back only if nothing else changed the pasteboard meanwhile.
/// Reading the old contents can wait on the app that copied them, so it happens off the
/// main thread, where the keyboard tap runs.
///
/// Secure input does not stop the paste. It keeps other apps from reading keys, and
/// posting Command V is reported to still work. It is one flag for the whole session, and
/// a process that keeps it on in the background would otherwise stop every paste. A
/// focused password field turns it on too, so while it is on, Orra asks Accessibility
/// about the focused field just before the paste (see `FocusedField.skipsPaste`). A
/// password field gets nothing, and neither does a field Accessibility cannot describe in
/// the app that holds secure input itself. The pasteboard is then left alone, and the text
/// stays under Copy Last Dictation.
final class TextInserter {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: NSPasteboard
    private let postCommandShortcut: (CGKeyCode) -> Void
    private let secureInputHolder: () -> pid_t?
    private let frontmostApp: () -> pid_t?
    private let focusedField: (pid_t) async -> FocusedField.Kind
    private let readSnapshot: (String) async -> PasteboardSnapshot
    private let keyCodeForV: () -> CGKeyCode
    private let restoreDelay: Duration
    private var pendingSnapshot: PasteboardSnapshot?
    private var restoreTask: Task<Void, Never>?

    /// - Parameters:
    ///   - pasteboard: The pasteboard to use. The app passes `.general`, tests a private one.
    ///   - postCommandShortcut: Posts Command plus the given key. Tests pass a fake.
    ///   - secureInputHolder: The process that holds secure input, or nil while none does.
    ///   - frontmostApp: The process ID of the app in front.
    ///   - focusedField: What Accessibility says about the focused field of an app. Asked
    ///     only while secure input is on.
    ///   - readSnapshot: Reads everything on the named pasteboard. Tests wrap it.
    ///   - keyCodeForV: The key that types "v" while Command is held in the current
    ///     keyboard layout.
    ///   - restoreDelay: How long the target app gets to read the pasteboard.
    init(
        pasteboard: NSPasteboard,
        postCommandShortcut: @escaping (CGKeyCode) -> Void,
        secureInputHolder: @escaping () -> pid_t?,
        frontmostApp: @escaping () -> pid_t?,
        focusedField: @escaping (pid_t) async -> FocusedField.Kind,
        readSnapshot: @escaping (String) async -> PasteboardSnapshot = { await PasteboardSnapshot.read(pasteboardNamed: $0) },
        keyCodeForV: @escaping () -> CGKeyCode,
        restoreDelay: Duration = .milliseconds(500)
    ) {
        self.pasteboard = pasteboard
        self.postCommandShortcut = postCommandShortcut
        self.secureInputHolder = secureInputHolder
        self.frontmostApp = frontmostApp
        self.focusedField = focusedField
        self.readSnapshot = readSnapshot
        self.keyCodeForV = keyCodeForV
        self.restoreDelay = restoreDelay
    }

    static func live() -> TextInserter {
        TextInserter(
            pasteboard: .general,
            postCommandShortcut: KeyboardEvents.postCommandShortcut,
            secureInputHolder: SecureInput.holder,
            frontmostApp: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            focusedField: { await FocusedField.kind(inApp: $0) },
            keyCodeForV: { KeyboardLayout.keyCode(for: "v", withCommand: true) ?? CGKeyCode(kVK_ANSI_V) }
        )
    }

    /// Puts text on the pasteboard for the user to paste, as Copy Last Dictation does.
    /// Marked concealed, so clipboard managers skip it, and kept on this Mac, so Universal
    /// Clipboard does not offer it to other devices. Nothing restores the old contents.
    static func copy(_ text: String, to pasteboard: NSPasteboard) {
        // Not followed by declareTypes, which would clear the host only option again.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: concealedType)
        pasteboard.writeObjects([item])
    }

    @discardableResult
    func insert(_ text: String) async -> InsertionResult {
        guard !text.isEmpty else { return .nothingToInsert }
        // If the previous dictation is still waiting to restore, keep its snapshot. A new
        // one would only capture Orra's own text.
        let readsSnapshot = pendingSnapshot == nil
        var snapshot = if let pendingSnapshot { pendingSnapshot } else { await readPasteboard() }
        // Asked right before the paste, because reading the old contents can take a while
        // and the focus can move into a password field meanwhile. A skip leaves an earlier
        // dictation's restore alone.
        if await skipsPaste() {
            return .skippedPasswordField
        }
        if readsSnapshot, snapshot.changeCount != pasteboard.changeCount {
            // Something was copied while Orra asked about the field.
            snapshot = await readPasteboard()
        }
        restoreTask?.cancel()
        pendingSnapshot = nil

        pasteboard.declareTypes([.string, Self.concealedType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealedType)

        let writtenChangeCount = pasteboard.changeCount
        postCommandShortcut(keyCodeForV())
        pendingSnapshot = snapshot
        restoreTask = Task { [weak self, restoreDelay] in
            try? await Task.sleep(for: restoreDelay)
            guard !Task.isCancelled, let self else { return }
            if pasteboard.changeCount == writtenChangeCount {
                snapshot.restore(to: pasteboard)
            }
            pendingSnapshot = nil
        }
        return .pasted
    }

    private func readPasteboard() async -> PasteboardSnapshot {
        var snapshot = await readSnapshot(pasteboard.name.rawValue)
        if snapshot.changeCount != pasteboard.changeCount {
            // Something was copied while reading. Read again so that copy comes back.
            snapshot = await readSnapshot(pasteboard.name.rawValue)
        }
        return snapshot
    }

    /// Whether the text has to stay out of the focused field. Without secure input no
    /// password field has the focus, so nothing is asked.
    private func skipsPaste() async -> Bool {
        guard let holder = secureInputHolder(), let app = frontmostApp() else { return false }
        return FocusedField.skipsPaste(field: await focusedField(app), secureInputHolder: holder, frontmostApp: app)
    }
}

/// A copy of everything on a pasteboard, so it can be put back.
nonisolated struct PasteboardSnapshot: Sendable {
    nonisolated struct Entry: Sendable {
        var type: String
        var data: Data
    }

    /// The pasteboard's change count when reading began.
    let changeCount: Int
    let items: [[Entry]]

    /// Reads every type of every item. Asking for data the copying app has not provided
    /// yet waits for that app, so this runs off the main actor.
    @concurrent
    static func read(pasteboardNamed name: String) async -> PasteboardSnapshot {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        let changeCount = pasteboard.changeCount
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { Entry(type: type.rawValue, data: $0) }
            }
        }
        return PasteboardSnapshot(changeCount: changeCount, items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}

/// Synthesized keyboard shortcuts. Posting needs Accessibility access, which the keyboard
/// tap already requires.
nonisolated enum KeyboardEvents {
    static func postCommandShortcut(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        // The left Command device bit as well, because some clients, such as Microsoft
        // Remote Desktop in scancode mode, read the device bits and would type a plain v.
        let flags: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))]
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}

/// What the focused field of an app is, read through Accessibility, which Orra already
/// has for the talk key.
nonisolated enum FocusedField {
    nonisolated enum Kind: Equatable, Sendable {
        case password
        /// A text field, text area or combo box that is not a password field.
        case plainText
        /// Nothing could be read in time, or the element is something else.
        case unknown
    }

    /// How long one read may wait for a busy app. Two reads at most.
    static let timeout: Float = 0.5

    /// Whether dictated text has to stay out of the focused field while secure input is
    /// on. A password field gets nothing. So does a field Accessibility cannot describe in
    /// the app that holds secure input itself: some browsers show no elements of a web
    /// page until an assistive app asks for them, and still turn secure input on for their
    /// password fields (reported). A field nobody can describe while another process holds
    /// secure input in the background gets the paste.
    static func skipsPaste(field: Kind, secureInputHolder: pid_t, frontmostApp: pid_t) -> Bool {
        switch field {
        case .password: true
        case .plainText: false
        case .unknown: secureInputHolder == frontmostApp
        }
    }

    /// Reads off the main actor, because the app in front answers and may be slow.
    @concurrent
    static func kind(inApp pid: pid_t) async -> Kind {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        let field = focused as! AXUIElement
        // A timeout applies only to the element it was set on.
        AXUIElementSetMessagingTimeout(field, timeout)
        var values: CFArray?
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(field, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
              let read = values as? [Any], read.count == 2 else { return .unknown }
        // An attribute that cannot be read comes back as an error value, not a string.
        return kind(role: read[0] as? String, subrole: read[1] as? String)
    }

    /// AppKit's password fields have the subrole AXSecureTextField. How web password
    /// fields report themselves is not tried yet. Some apps put it in the role instead.
    static func kind(role: String?, subrole: String?) -> Kind {
        if subrole == kAXSecureTextFieldSubrole || role == kAXSecureTextFieldSubrole {
            return .password
        }
        if let role, [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
            return .plainText
        }
        return .unknown
    }
}

/// Which process holds secure event input, for example for a focused password field or
/// Terminal's Secure Keyboard Entry. IsSecureEventInputEnabled is not declared in the SDK
/// headers. While secure input is on, the session dictionary has a nonzero
/// kCGSSessionSecureInputPID, which was checked on macOS 26.6.2.
nonisolated enum SecureInput {
    /// The holder's process ID, or nil while no process holds secure input.
    static func holder() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? Int, pid != 0 else {
            return nil
        }
        return pid_t(pid)
    }
}

/// Reads the current keyboard layout, so Command V uses the key that types "v" there.
/// Text Input Sources must be used on the main thread, so this stays on the main actor.
enum KeyboardLayout {
    /// The modifier state for Command, as UCKeyTranslate expects it.
    private static let commandModifier = UInt32((cmdKey >> 8) & 0xFF)

    /// The key code that types `character` in the current layout, or nil. With
    /// `withCommand`, the lookup holds Command, because layouts such as Dvorak QWERTY
    /// Command switch to QWERTY while Command is down.
    static func keyCode(for character: Character, withCommand: Bool = false) -> CGKeyCode? {
        let modifiers = withCommand ? commandModifier : 0
        return withCurrentLayout { layout in
            (0..<128).map { CGKeyCode($0) }.first { translate($0, modifiers: modifiers, in: layout) == String(character) }
        } ?? nil
    }

    /// The character that `keyCode` types in the current layout, or nil.
    static func character(for keyCode: CGKeyCode, withCommand: Bool = false) -> String? {
        let modifiers = withCommand ? commandModifier : 0
        return withCurrentLayout { layout in translate(keyCode, modifiers: modifiers, in: layout) } ?? nil
    }

    private static func withCurrentLayout<Result>(_ body: (UnsafePointer<UCKeyboardLayout>) -> Result) -> Result? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              // The key is the value of kTISPropertyUnicodeKeyLayoutData. Swift 6 rejects
              // reading that C global because it is imported as a mutable variable.
              let property = TISGetInputSourceProperty(source, "TISPropertyUnicodeKeyLayoutData" as CFString) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            return body(base.assumingMemoryBound(to: UCKeyboardLayout.self))
        }
    }

    private static func translate(_ keyCode: CGKeyCode, modifiers: UInt32, in layout: UnsafePointer<UCKeyboardLayout>) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            modifiers,
            UInt32(LMGetKbdType()),
            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
