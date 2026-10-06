import AppKit
import Carbon.HIToolbox
import CoreGraphics
import IOKit

/// How putting text into the frontmost app went.
nonisolated enum InsertionResult: Equatable, Sendable {
    /// The text was pasted with Command V.
    case pasted
    /// Secure input is on, so the text was left on the pasteboard for the user to paste.
    case leftOnPasteboardForSecureInput
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
final class TextInserter {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: NSPasteboard
    private let postCommandShortcut: (CGKeyCode) -> Void
    private let isSecureInputOn: () -> Bool
    private let keyCodeForV: () -> CGKeyCode
    private let restoreDelay: Duration
    private var pendingSnapshot: PasteboardSnapshot?
    private var restoreTask: Task<Void, Never>?

    /// - Parameters:
    ///   - pasteboard: The pasteboard to use. The app passes `.general`, tests a private one.
    ///   - postCommandShortcut: Posts Command plus the given key. Tests pass a fake.
    ///   - isSecureInputOn: True while another app holds secure input.
    ///   - keyCodeForV: The key that types "v" while Command is held in the current
    ///     keyboard layout.
    ///   - restoreDelay: How long the target app gets to read the pasteboard.
    init(
        pasteboard: NSPasteboard,
        postCommandShortcut: @escaping (CGKeyCode) -> Void,
        isSecureInputOn: @escaping () -> Bool,
        keyCodeForV: @escaping () -> CGKeyCode,
        restoreDelay: Duration = .milliseconds(500)
    ) {
        self.pasteboard = pasteboard
        self.postCommandShortcut = postCommandShortcut
        self.isSecureInputOn = isSecureInputOn
        self.keyCodeForV = keyCodeForV
        self.restoreDelay = restoreDelay
    }

    static func live() -> TextInserter {
        TextInserter(
            pasteboard: .general,
            postCommandShortcut: KeyboardEvents.postCommandShortcut,
            isSecureInputOn: SecureInput.isOn,
            keyCodeForV: { KeyboardLayout.keyCode(for: "v", withCommand: true) ?? CGKeyCode(kVK_ANSI_V) }
        )
    }

    @discardableResult
    func insert(_ text: String) async -> InsertionResult {
        guard !text.isEmpty else { return .nothingToInsert }
        restoreTask?.cancel()
        // If the previous dictation is still waiting to restore, keep its snapshot. A new
        // one would only capture Orra's own text.
        var snapshot: PasteboardSnapshot
        if let pending = pendingSnapshot {
            snapshot = pending
        } else {
            snapshot = await PasteboardSnapshot.read(pasteboardNamed: pasteboard.name.rawValue)
            if snapshot.changeCount != pasteboard.changeCount {
                // Something was copied while reading. Read again so that copy comes back.
                snapshot = await PasteboardSnapshot.read(pasteboardNamed: pasteboard.name.rawValue)
            }
        }
        pendingSnapshot = nil

        pasteboard.declareTypes([.string, Self.concealedType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealedType)

        if isSecureInputOn() {
            return .leftOnPasteboardForSecureInput
        }
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

/// Whether any app holds secure event input, for example a focused password field or
/// Terminal's Secure Keyboard Entry. IsSecureEventInputEnabled is not declared in the SDK
/// headers. While secure input is on, the session dictionary has a nonzero
/// kCGSSessionSecureInputPID, which was checked on macOS 26.6.2.
nonisolated enum SecureInput {
    static func isOn() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? Int else {
            return false
        }
        return pid != 0
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
