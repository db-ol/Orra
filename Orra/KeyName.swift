import Carbon.HIToolbox
import Foundation

/// The name of a key that cannot be the talk key, for the note in the talk key recorder,
/// such as "Return" or "A". Shown on screen only, never logged.
enum KeyName {
    /// The name of the key with this virtual key code: its name for a key that types no
    /// character, and otherwise the character it types on the current keyboard layout, as
    /// a capital. Nil when neither is known.
    static func name(forKeyCode keyCode: Int64, locale: Locale = .interface) -> String? {
        if let name = namedKey(keyCode, locale: locale) {
            return name
        }
        return character(forKeyCode: keyCode)
    }

    /// Keys whose keycap shows a word or an arrow, by their codes in HIToolbox Events.h.
    /// The names are looked up in the language of `locale`.
    nonisolated static func namedKey(_ keyCode: Int64, locale: Locale = .interface) -> String? {
        switch Int(keyCode) {
        case kVK_Return: String(localized: LocalizedStringResource("Return", locale: locale, comment: "A key name"))
        case kVK_ANSI_KeypadEnter: String(localized: LocalizedStringResource("Enter", locale: locale, comment: "A key name"))
        case kVK_Tab: String(localized: LocalizedStringResource("Tab", locale: locale, comment: "A key name"))
        case kVK_Space: String(localized: LocalizedStringResource("Space", locale: locale, comment: "A key name"))
        case kVK_Delete: String(localized: LocalizedStringResource("Delete", locale: locale, comment: "A key name"))
        case kVK_ForwardDelete: String(localized: LocalizedStringResource("Forward Delete", locale: locale, comment: "A key name"))
        case kVK_Home: String(localized: LocalizedStringResource("Home", locale: locale, comment: "A key name"))
        case kVK_End: String(localized: LocalizedStringResource("End", locale: locale, comment: "A key name"))
        case kVK_PageUp: String(localized: LocalizedStringResource("Page Up", locale: locale, comment: "A key name"))
        case kVK_PageDown: String(localized: LocalizedStringResource("Page Down", locale: locale, comment: "A key name"))
        case kVK_LeftArrow: String(localized: LocalizedStringResource("Left Arrow", locale: locale, comment: "A key name"))
        case kVK_RightArrow: String(localized: LocalizedStringResource("Right Arrow", locale: locale, comment: "A key name"))
        case kVK_UpArrow: String(localized: LocalizedStringResource("Up Arrow", locale: locale, comment: "A key name"))
        case kVK_DownArrow: String(localized: LocalizedStringResource("Down Arrow", locale: locale, comment: "A key name"))
        case kVK_Help: String(localized: LocalizedStringResource("Help", locale: locale, comment: "A key name"))
        case kVK_ANSI_KeypadClear: String(localized: LocalizedStringResource("Clear", locale: locale, comment: "A key name"))
        default: functionKeys[Int(keyCode)].map { "F\($0)" }
        }
    }

    /// Whether the key is one of F1 to F20.
    nonisolated static func isFunctionKey(_ keyCode: Int64) -> Bool {
        functionKeys[Int(keyCode)] != nil
    }

    nonisolated static let spaceKeyCode = Int64(kVK_Space)

    /// F1 to F20 by key code.
    nonisolated private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7,
        kVK_F8: 8, kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13,
        kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19,
        kVK_F20: 20,
    ]

    /// The character the key types without modifiers on the current keyboard layout that
    /// can type Latin letters, such as ABC under a Chinese input method. Reads the layout
    /// only, which needs no permission.
    static func character(forKeyCode keyCode: Int64) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let keyboard = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                keyboard,
                UInt16(truncatingIfNeeded: keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return text.isEmpty ? nil : text.uppercased()
    }
}
