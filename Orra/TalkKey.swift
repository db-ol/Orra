import CoreGraphics
import Foundation
import IOKit

/// The key that starts a dictation while it is held on its own. The user picks one by
/// pressing it, in Settings or in the welcome window, and right Control is the default.
///
/// The left and right Control, Option and Command keys and fn are offered. Shift is not,
/// because Shift on its own switches Chinese input methods between Chinese and English,
/// and Orra cannot hide that press from the input method. The left modifiers are part of
/// many shortcuts, so a hold of one starts recording only after it has been held alone for
/// a moment, see `TalkKeyDetector.leftKeyDelay`.
///
/// The raw values are saved in UserDefaults. Never change one, or a saved choice is lost.
nonisolated enum TalkKey: String, CaseIterable, Identifiable, Sendable {
    case rightControl
    case rightOption
    case rightCommand
    case leftControl
    case leftOption
    case leftCommand
    case fn

    /// What a fresh install listens for. Right Control sits at the right end of the bottom
    /// row of most external keyboards, and the Fn key of many of those, such as the
    /// Logitech MX Keys, never reaches the Mac. The welcome window recommends fn on a
    /// Mac's built in keyboard and lets the user press the key they want.
    static let defaultKey: TalkKey = .rightControl

    /// Which key stays the talk key when a saved choice holds several, as Orra 0.1.0 and
    /// earlier builds of this branch allowed. fn comes first, because right Control is the
    /// default and so a user who turned fn on chose it on purpose. Right Control follows,
    /// then the other right hand keys, then the left hand ones, which wait before they
    /// record.
    static let keepOrder: [TalkKey] = [.fn, .rightControl, .rightOption, .rightCommand, .leftControl, .leftOption, .leftCommand]

    /// The key to keep from several, by `keepOrder`. Nil when `keys` is empty.
    static func kept(from keys: Set<TalkKey>) -> TalkKey? {
        keepOrder.first(where: keys.contains)
    }

    var id: String { rawValue }

    /// The key's Mac name, such as "Right Option", as in Keyboard settings. Left and right
    /// are part of it. fn keeps its keycap label in every language.
    ///
    /// The text of a talk key is looked up in the language of `locale`, which is the
    /// language Orra started with unless the welcome window passes the one picked there.
    func name(in locale: Locale = .interface) -> String {
        switch self {
        case .rightControl: String(localized: LocalizedStringResource("Right Control", locale: locale))
        case .rightOption: String(localized: LocalizedStringResource("Right Option", locale: locale))
        case .rightCommand: String(localized: LocalizedStringResource("Right Command", locale: locale))
        case .leftControl: String(localized: LocalizedStringResource("Left Control", locale: locale))
        case .leftOption: String(localized: LocalizedStringResource("Left Option", locale: locale))
        case .leftCommand: String(localized: LocalizedStringResource("Left Command", locale: locale))
        case .fn: "fn"
        }
    }

    /// The symbol Mac menus show for the key, such as ⌥ for Option. Nil for fn, whose
    /// keycap shows the globe and which menus show as "fn" or the globe.
    var symbol: String? {
        switch self {
        case .rightControl, .leftControl: "⌃"
        case .rightOption, .leftOption: "⌥"
        case .rightCommand, .leftCommand: "⌘"
        case .fn: nil
        }
    }

    /// The symbol and the name, such as "⌥ Right Option".
    func title(in locale: Locale = .interface) -> String {
        symbol.map { "\($0) \(name(in: locale))" } ?? name(in: locale)
    }

    /// What the key is called on other keycaps, shown as a small hint next to its name.
    /// A keyboard with a Windows layout prints Alt on the key the Mac uses as Option, and
    /// a Windows logo on the key it uses as Command. The fn key of recent Macs shows a
    /// globe. Control is Ctrl everywhere, so it needs none.
    func otherLabel(in locale: Locale = .interface) -> String? {
        switch self {
        case .rightControl, .leftControl: nil
        case .rightOption, .leftOption: String(localized: LocalizedStringResource("Alt", locale: locale, comment: "The label of the Option key on a keyboard with a Windows layout"))
        case .rightCommand, .leftCommand: String(localized: LocalizedStringResource("Windows key", locale: locale, comment: "The key a keyboard with a Windows layout has in place of Command"))
        case .fn: String(localized: LocalizedStringResource("Globe 🌐", locale: locale, comment: "The fn key of recent Macs, which shows a globe"))
        }
    }

    /// The other label in parentheses, such as "(Alt)", or nil.
    func otherLabelInParentheses(in locale: Locale = .interface) -> String? {
        otherLabel(in: locale).map { String(localized: LocalizedStringResource("(\($0))", locale: locale, comment: "A talk key's label on other keyboards, such as (Alt)")) }
    }

    /// The title with the other label, such as "⌥ Right Option (Alt)", where the key is
    /// shown in one line of text, as in the menu.
    func fullName(in locale: Locale = .interface) -> String {
        let title = title(in: locale)
        return otherLabel(in: locale).map { String(localized: LocalizedStringResource("\(title) (\($0))", locale: locale, comment: "A talk key with its label on other keyboards, such as ⌥ Right Option (Alt)")) } ?? title
    }

    /// The name inside a sentence, such as "Hold right Control to talk".
    func sentenceName(in locale: Locale = .interface) -> String {
        switch self {
        case .rightControl: String(localized: LocalizedStringResource("right Control", locale: locale, comment: "A talk key inside a sentence"))
        case .rightOption: String(localized: LocalizedStringResource("right Option", locale: locale, comment: "A talk key inside a sentence"))
        case .rightCommand: String(localized: LocalizedStringResource("right Command", locale: locale, comment: "A talk key inside a sentence"))
        case .leftControl: String(localized: LocalizedStringResource("left Control", locale: locale, comment: "A talk key inside a sentence"))
        case .leftOption: String(localized: LocalizedStringResource("left Option", locale: locale, comment: "A talk key inside a sentence"))
        case .leftCommand: String(localized: LocalizedStringResource("left Command", locale: locale, comment: "A talk key inside a sentence"))
        case .fn: String(localized: LocalizedStringResource("fn", locale: locale, comment: "A talk key inside a sentence"))
        }
    }

    /// The virtual key code of the key's own flags changed events, from HIToolbox
    /// Events.h.
    var keyCode: Int64 {
        switch self {
        case .rightControl: 0x3E
        case .rightOption: 0x3D
        case .rightCommand: 0x36
        case .leftControl: 0x3B
        case .leftOption: 0x3A
        case .leftCommand: 0x37
        case .fn: 0x3F
        }
    }

    /// The flag that is set while this key is down. For Control, Option and Command it is
    /// the device dependent bit from IOKit's IOLLEvent.h, which tells the right key from
    /// the left one.
    var downFlag: CGEventFlags {
        switch self {
        case .rightControl: CGEventFlags(rawValue: 0x0000_2000)
        case .rightOption: CGEventFlags(rawValue: 0x0000_0040)
        case .rightCommand: CGEventFlags(rawValue: 0x0000_0010)
        case .leftControl: CGEventFlags(rawValue: 0x0000_0001)
        case .leftOption: CGEventFlags(rawValue: 0x0000_0020)
        case .leftCommand: CGEventFlags(rawValue: 0x0000_0008)
        case .fn: .maskSecondaryFn
        }
    }

    /// The flag that the left and the right key of a pair both set. Nil for fn.
    var sharedFlag: CGEventFlags? {
        switch self {
        case .rightControl, .leftControl: .maskControl
        case .rightOption, .leftOption: .maskAlternate
        case .rightCommand, .leftCommand: .maskCommand
        case .fn: nil
        }
    }

    /// The device dependent bit of the other key of the pair, such as left Control's for
    /// right Control. Nil for fn.
    var twinFlag: CGEventFlags? {
        switch self {
        case .rightControl: TalkKey.leftControl.downFlag
        case .rightOption: TalkKey.leftOption.downFlag
        case .rightCommand: TalkKey.leftCommand.downFlag
        case .leftControl: TalkKey.rightControl.downFlag
        case .leftOption: TalkKey.rightOption.downFlag
        case .leftCommand: TalkKey.rightCommand.downFlag
        case .fn: nil
        }
    }

    /// Whether this is a left hand modifier. Those are part of so many shortcuts that a
    /// hold starts recording only after the key was held alone for
    /// `TalkKeyDetector.leftKeyDelay`.
    var waitsBeforeRecording: Bool {
        switch self {
        case .leftControl, .leftOption, .leftCommand: true
        case .rightControl, .rightOption, .rightCommand, .fn: false
        }
    }

    /// Fn's own events are swallowed, so the action set under "Press fn key to" in
    /// Keyboard settings, such as the emoji picker, does not also fire. Control, Option and
    /// Command have no system action of their own, unless Dictation or Siri is set to a
    /// double press of that key, so their events pass through and apps keep an accurate
    /// picture of which modifiers are down.
    var swallowsItsEvents: Bool {
        self == .fn
    }

    /// Whether holding the key changes what a click does, such as Control click opening a
    /// context menu. A click during a hold of such a key ends the hold. Clicking into a
    /// field while holding fn is a plain click, so an fn hold goes on.
    var modifiesClicks: Bool {
        sharedFlag != nil
    }

    /// Flags that mean another modifier is down. A press of this key with one of them
    /// held belongs to a shortcut, not to a dictation. Caps Lock is a lock, not a held
    /// key, so it does not count.
    var otherModifiers: CGEventFlags {
        var flags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        if let sharedFlag {
            flags.remove(sharedFlag)
        }
        if let twinFlag {
            flags.insert(twinFlag)
        }
        if self == .fn {
            flags.remove(.maskSecondaryFn)
        }
        return flags
    }

    /// Whether the flags of this key's own flags changed event say that it is now down.
    /// `wasDown` says whether the detector holds the key as down.
    func isDown(in flags: CGEventFlags, wasDown: Bool) -> Bool {
        guard let sharedFlag, let twinFlag else {
            return flags.contains(downFlag)
        }
        if !flags.isDisjoint(with: downFlag.union(twinFlag)) {
            return flags.contains(downFlag)
        }
        // A keyboard that sets no left or right bits. The shared flag cannot tell this key
        // from its twin, so while the key is down, its own next event is its release.
        return wasDown ? false : flags.contains(sharedFlag)
    }

    /// On a keyboard that sets no left or right bits: whether the twin is still down at
    /// this key's release. Then the hold was part of a shortcut that began with the twin,
    /// which such a keyboard does not show at the press.
    func twinIsDown(atReleaseWith flags: CGEventFlags) -> Bool {
        guard let sharedFlag, let twinFlag else { return false }
        return flags.isDisjoint(with: downFlag.union(twinFlag)) && flags.contains(sharedFlag)
    }

    /// The translation key Orra uses until the user picks one: right Option, next to the
    /// default talk key, or right Command when the talk key is right Option. Either key is
    /// a right hand modifier, so the left hand keeps its shortcuts.
    static func defaultTranslationKey(talkKey: TalkKey) -> TalkKey {
        talkKey == .rightOption ? .rightCommand : .rightOption
    }
}

/// Orra's two keys: the talk key, which pastes what was said, and the translation key,
/// which pastes it translated. They are never the same key.
nonisolated enum KeySlot: Equatable, Sendable {
    case talk
    case translation
}

/// What the user records by pressing keys in Settings: one of Orra's two keys, or the Live
/// Captions shortcut.
nonisolated enum KeyChoiceTarget: Equatable, Sendable {
    case key(KeySlot)
    case liveCaptionsShortcut
}

/// What the user sees after picking for one slot the key of the other: the two keys
/// swapped, and this is where each one went.
nonisolated struct KeySwap: Equatable, Sendable {
    let talkKey: Hotkey
    let translationKey: Hotkey

    /// Such as "The two keys swapped. The talk key is now right Option and the translation
    /// key right Control."
    func message(in locale: Locale = .interface) -> String {
        let talk = talkKey.sentenceName(in: locale)
        let translation = translationKey.sentenceName(in: locale)
        return String(localized: LocalizedStringResource("The two keys swapped. The talk key is now \(talk) and the translation key \(translation).", locale: locale))
    }
}

/// Records the talk key the user presses, like the shortcut recorders of Mac apps. A key
/// that can be a talk key counts when it goes down on its own and comes up again with
/// nothing else pressed in between. Two or more modifiers held together, such as Control
/// and Option, count as a combination at the first release. Modifiers with a regular key,
/// such as Command and Shift with D, count when the regular key goes down. Anything else
/// is turned down with the reason, and the recorder keeps listening. Escape cancels.
///
/// Pure logic. `HotkeyTap`, or a local event monitor while Orra has no tap, feeds it the
/// key down and flags changed events.
nonisolated struct KeyRecorder: Equatable, Sendable {
    nonisolated enum Outcome: Equatable, Sendable {
        /// The key or the combination becomes the key.
        case chosen(Hotkey)
        /// The press cannot be the talk key. The recorder keeps listening.
        case rejected(Rejection)
        /// Escape: the recorder stops without a change.
        case cancelled
    }

    /// Why a press cannot be the talk key.
    nonisolated enum Rejection: Equatable, Sendable {
        /// Shift on its own switches Chinese input methods between Chinese and English, and
        /// Orra cannot hide that press from the input method.
        case shift
        /// Caps Lock is a lock, not a key that is held, and switches input methods too.
        case capsLock
        /// Keys together that cannot be a combination, such as fn with an arrow key, or
        /// right and left Control. The symbols of the modifiers held, such as "fn", and the
        /// key code of the other key when it is not a modifier, so the note can show
        /// "fn Up Arrow".
        case combination(modifiers: String, keyCode: Int64?)
        /// A key that types or acts on its own, such as a letter, Return or an arrow key.
        case key(keyCode: Int64)
        /// A shortcut of macOS or of nearly every app, such as ⌘ C, see
        /// `KeyCombination.isSystemShortcut`. The symbols of the modifiers and the key code.
        case shortcut(modifiers: String, keyCode: Int64)
        /// The Live Captions shortcut, which never swaps with a key. The controller refuses
        /// it, since the recorder does not know the shortcut.
        case liveCaptionsShortcut(KeyCombination)
    }

    static let shiftKeyCodes: Set<Int64> = [0x38, 0x3C]
    static let capsLockKeyCode: Int64 = 0x39

    /// A key that can be a talk key, down on its own with nothing pressed since.
    private(set) var candidate: TalkKey?
    /// Every modifier held since all were up, without left and right.
    private(set) var peak: ModifierSet = []
    /// The modifiers down now.
    private var held: ModifierSet = []
    /// True once a regular key was turned down during this press, so its modifiers are no
    /// combination when they come up.
    private var spoiled = false

    /// Whether a key or a combination that can be chosen is down, so a note about an
    /// earlier press no longer applies.
    var isPending: Bool {
        candidate != nil || (peak.count >= 2 && !spoiled)
    }

    /// What one key down or flags changed event means, or nil for one that decides nothing
    /// yet, such as a talk key going down.
    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Outcome? {
        switch type {
        case .flagsChanged:
            let now = ModifierSet(flags: flags, includingFn: true)
            let previous = held
            held = now
            if keyCode == Self.capsLockKeyCode {
                candidate = nil
                return .rejected(.capsLock)
            }
            defer {
                if held.isEmpty {
                    peak = []
                    spoiled = false
                }
            }
            // The first release of a combination of modifiers chooses it.
            if !previous.isSubset(of: now), peak.count >= 2, !spoiled {
                let combination = KeyCombination(modifiers: peak)
                candidate = nil
                spoiled = true
                return .chosen(.combination(combination))
            }
            if let key = TalkKey.allCases.first(where: { $0.keyCode == keyCode }) {
                if key.isDown(in: flags, wasDown: candidate == key) {
                    peak.formUnion(now)
                    // A second modifier, or one pressed while another is held.
                    guard candidate == nil, flags.isDisjoint(with: key.otherModifiers) else {
                        if peak.count >= 2, !spoiled {
                            // A combination, chosen at its first release.
                            candidate = nil
                            return nil
                        }
                        let rejection = combination(flags: flags, fnPressed: key == .fn, keyCode: nil)
                        candidate = nil
                        return .rejected(rejection)
                    }
                    candidate = key
                    peak = now
                    return nil
                }
                guard candidate == key else { return nil }
                candidate = nil
                return .chosen(.key(key))
            }
            if Self.shiftKeyCodes.contains(keyCode) {
                guard flags.contains(.maskShift) else { return nil }
                peak.formUnion(now)
                if peak.count >= 2, !spoiled {
                    candidate = nil
                    return nil
                }
                let rejection: Rejection = candidate != nil ? combination(flags: flags, fnPressed: false, keyCode: nil) : .shift
                candidate = nil
                return .rejected(rejection)
            }
            return nil
        case .keyDown:
            if keyCode == TalkKeyDetector.escapeKeyCode {
                candidate = nil
                return .cancelled
            }
            // Reported to arrive with a press of the Globe key, see TalkKeyDetector.
            if keyCode == TalkKeyDetector.globeKeyCode {
                return nil
            }
            let modifiers = ModifierSet(flags: flags, includingFn: false)
            let combination = KeyCombination(modifiers: modifiers, keyCode: keyCode)
            if candidate != .fn, combination.isSystemShortcut {
                candidate = nil
                spoiled = true
                return .rejected(.shortcut(modifiers: symbols(flags: flags, fnPressed: false), keyCode: keyCode))
            }
            if candidate != .fn, combination.isValid {
                candidate = nil
                spoiled = true
                return .chosen(.combination(combination))
            }
            let combined = candidate != nil || !flags.isDisjoint(with: [.maskControl, .maskAlternate, .maskCommand])
            let rejection: Rejection = combined ? self.combination(flags: flags, fnPressed: false, keyCode: keyCode) : .key(keyCode: keyCode)
            candidate = nil
            spoiled = true
            return .rejected(rejection)
        default:
            return nil
        }
    }

    /// The combination the user pressed, with the modifiers in the order Mac menus show
    /// them. fn counts only when it was pressed for the recording, because arrow and
    /// function keys carry the Fn flag on their own. Call it before clearing `candidate`.
    private func combination(flags: CGEventFlags, fnPressed: Bool, keyCode: Int64?) -> Rejection {
        .combination(modifiers: symbols(flags: flags, fnPressed: fnPressed), keyCode: keyCode)
    }

    /// The symbols of the modifiers held, such as "⇧ ⌘", in the order Mac menus show them.
    private func symbols(flags: CGEventFlags, fnPressed: Bool) -> String {
        var modifiers = ModifierSet(flags: flags, includingFn: false)
        if fnPressed || candidate == .fn {
            modifiers.insert(.fn)
        }
        return modifiers.symbols.joined(separator: " ")
    }
}

extension KeyRecorder.Rejection {
    /// What the recorder says about the press, such as "Shift can't be the talk key" with
    /// the reason. `slot` names the key being recorded.
    @MainActor func message(in locale: Locale = .interface, for slot: KeySlot = .talk) -> String {
        if slot == .translation {
            return translationKeyMessage(in: locale)
        }
        return switch self {
        case .shift:
            String(localized: LocalizedStringResource("Shift can't be the talk key. On its own, it switches input methods between Chinese and English.", locale: locale))
        case .capsLock:
            String(localized: LocalizedStringResource("Caps Lock can't be the talk key. It turns capitals or the input method on and off.", locale: locale))
        case .combination(let modifiers, let keyCode):
            if let keys = Self.keys(modifiers: modifiers, keyCode: keyCode, locale: locale) {
                String(localized: LocalizedStringResource("\(keys) is a key combination and can't be the talk key.", locale: locale))
            } else {
                String(localized: LocalizedStringResource("A key combination can't be the talk key.", locale: locale))
            }
        case .key(let keyCode):
            if let name = KeyName.name(forKeyCode: keyCode, locale: locale) {
                String(localized: LocalizedStringResource("The \(name) key can't be the talk key. Holding it would type or do something in the app in front.", locale: locale))
            } else {
                String(localized: LocalizedStringResource("This key can't be the talk key. Holding it would type or do something in the app in front.", locale: locale))
            }
        case .shortcut(let modifiers, let keyCode):
            if let keys = Self.keys(modifiers: modifiers, keyCode: keyCode, locale: locale) {
                String(localized: LocalizedStringResource("\(keys) is a shortcut of macOS or most apps and can't be the talk key. It would stop working everywhere while Orra runs.", locale: locale))
            } else {
                String(localized: LocalizedStringResource("A shortcut of macOS or most apps can't be the talk key. It would stop working everywhere while Orra runs.", locale: locale))
            }
        case .liveCaptionsShortcut(let shortcut):
            Self.shortcutMessage(shortcut, in: locale)
        }
    }

    /// The same notes while the user records the translation key.
    @MainActor private func translationKeyMessage(in locale: Locale) -> String {
        switch self {
        case .shift:
            String(localized: LocalizedStringResource("Shift can't be the translation key. On its own, it switches input methods between Chinese and English.", locale: locale))
        case .capsLock:
            String(localized: LocalizedStringResource("Caps Lock can't be the translation key. It turns capitals or the input method on and off.", locale: locale))
        case .combination(let modifiers, let keyCode):
            if let keys = Self.keys(modifiers: modifiers, keyCode: keyCode, locale: locale) {
                String(localized: LocalizedStringResource("\(keys) is a key combination and can't be the translation key.", locale: locale))
            } else {
                String(localized: LocalizedStringResource("A key combination can't be the translation key.", locale: locale))
            }
        case .key(let keyCode):
            if let name = KeyName.name(forKeyCode: keyCode, locale: locale) {
                String(localized: LocalizedStringResource("The \(name) key can't be the translation key. Holding it would type or do something in the app in front.", locale: locale))
            } else {
                String(localized: LocalizedStringResource("This key can't be the translation key. Holding it would type or do something in the app in front.", locale: locale))
            }
        case .shortcut(let modifiers, let keyCode):
            if let keys = Self.keys(modifiers: modifiers, keyCode: keyCode, locale: locale) {
                String(localized: LocalizedStringResource("\(keys) is a shortcut of macOS or most apps and can't be the translation key. It would stop working everywhere while Orra runs.", locale: locale))
            } else {
                String(localized: LocalizedStringResource("A shortcut of macOS or most apps can't be the translation key. It would stop working everywhere while Orra runs.", locale: locale))
            }
        case .liveCaptionsShortcut(let shortcut):
            Self.shortcutMessage(shortcut, in: locale)
        }
    }

    /// The same note for either key: the press is the Live Captions shortcut.
    private static func shortcutMessage(_ shortcut: KeyCombination, in locale: Locale) -> String {
        String(localized: LocalizedStringResource("\(shortcut.title(in: locale)) is the Live Captions shortcut.", locale: locale))
    }
}

extension KeyRecorder.Rejection {
    /// The keys of a combination as the note shows them, such as "⌘ C" or "⌥ ⌘", or nil
    /// when fewer than two keys are known, for example right and left Option together.
    @MainActor static func keys(modifiers: String, keyCode: Int64?, locale: Locale = .interface) -> String? {
        var parts = modifiers.isEmpty ? [] : modifiers.split(separator: " ").map(String.init)
        if let keyCode {
            guard let name = KeyName.name(forKeyCode: keyCode, locale: locale) else { return nil }
            parts.append(name)
        }
        return parts.count >= 2 ? parts.joined(separator: " ") : nil
    }
}

/// Which talk key the welcome window recommends: fn when the Mac has a built in keyboard
/// in use, and right Control otherwise, because some external keyboards, such as the
/// Logitech MX Keys, never send fn.
nonisolated enum KeyboardKind: Equatable, Sendable {
    case builtIn
    case external

    var recommendedKey: TalkKey {
        self == .builtIn ? .fn : .rightControl
    }

    /// Whether this Mac has a built in keyboard that can be typed on now: a HID device in
    /// the IOKit registry marked Built-In with a keyboard usage, as `ioreg` showed on a
    /// MacBook on 2026-10-10, and the lid open. Reading the registry needs no permission,
    /// unlike opening the device. Not a documented interface, so the welcome window names
    /// both recommendations.
    static func current() -> KeyboardKind {
        hasBuiltInKeyboard() && !Lid.isClosed() ? .builtIn : .external
    }

    private static func hasBuiltInKeyboard() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard !found else { continue }
            let builtIn = IORegistryEntryCreateCFProperty(service, "Built-In" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool ?? false
            guard builtIn else { continue }
            let pairs = IORegistryEntryCreateCFProperty(service, "DeviceUsagePairs" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]] ?? []
            // Generic Desktop page 1, Keyboard usage 6.
            found = pairs.contains { ($0["DeviceUsagePage"] as? Int) == 1 && ($0["DeviceUsage"] as? Int) == 6 }
        }
        return found
    }
}

/// Keeps whether a double press of the talk key starts a hands free dictation. On until the
/// user turns it off.
nonisolated enum HandsFreePreference {
    static let defaultsKey = "handsFreeDoublePress"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey, default: true)
    }

    static func save(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }
}

/// Keeps the user's talk key in UserDefaults.
///
/// Orra 0.1.0 saved a list of keys under `defaultsKey`, and several could be on. The key is
/// still saved there, as a list of one, so a saved choice of 0.1.0 loads and a downgrade
/// keeps the key. A list of several keeps one, see `TalkKey.kept(from:)`.
nonisolated enum TalkKeyPreference {
    static let defaultsKey = "talkKeys"

    /// The saved key, or the default when nothing usable is saved.
    static func load(from defaults: UserDefaults = .standard) -> TalkKey {
        let saved = Set((defaults.stringArray(forKey: defaultsKey) ?? []).compactMap(TalkKey.init(rawValue:)))
        return TalkKey.kept(from: saved) ?? TalkKey.defaultKey
    }

    static func save(_ key: TalkKey, to defaults: UserDefaults = .standard) {
        defaults.set([key.rawValue], forKey: defaultsKey)
    }

    /// Whether the user has chosen a key before, so the welcome window can mark its step as
    /// done.
    static func isSaved(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) != nil || defaults.object(forKey: combinationKey) != nil
    }

    /// Where a combination is saved, see `KeyCombination.savedValue`. A single key removes
    /// it. The list under `defaultsKey` stays as it was, so an older Orra keeps the last
    /// single key.
    static let combinationKey = "talkKeyCombination"

    /// The saved key or combination, or the default when nothing usable is saved.
    static func loadHotkey(from defaults: UserDefaults = .standard) -> Hotkey {
        if let combination = defaults.string(forKey: combinationKey).flatMap(KeyCombination.init(saved:)) {
            return .combination(combination)
        }
        return .key(load(from: defaults))
    }

    static func saveHotkey(_ hotkey: Hotkey, to defaults: UserDefaults = .standard) {
        switch hotkey {
        case .key(let key):
            save(key, to: defaults)
            defaults.removeObject(forKey: combinationKey)
        case .combination(let combination):
            defaults.set(combination.savedValue, forKey: combinationKey)
        }
    }
}

/// The optional second talk key: a single key that starts a dictation just as the talk key
/// does, in the talk key's mode. Handy for someone who switches between a Mac's built in
/// keyboard and an external one whose fn never reaches the Mac, such as the Logitech MX
/// Keys: fn on the one, right Control on the other, with nothing to switch.
///
/// It is never the talk key and never the translation key, so a press always belongs to
/// one slot. A combination as the talk key may share a modifier with it, such as ⌃ ⌥ and
/// right Control. Then a press of right Control counts only after a moment, so the
/// combination can take over, as with the translation key. It records from its key down
/// meanwhile, see `TalkKeyDetector.capturesEarly(_:)`.
nonisolated enum SecondTalkKey {
    /// Whether `key` can be the second key beside these two keys.
    static func isAllowed(_ key: TalkKey, talkKey: Hotkey, translationKey: Hotkey) -> Bool {
        Hotkey.key(key) != talkKey && Hotkey.key(key) != translationKey
    }

    /// The keys the picker offers, in the order of `TalkKey.allCases`.
    static func choices(talkKey: Hotkey, translationKey: Hotkey) -> [TalkKey] {
        TalkKey.allCases.filter { isAllowed($0, talkKey: talkKey, translationKey: translationKey) }
    }

    /// The second key that suits an external keyboard whose fn never reaches the Mac: right
    /// Control, or right Option or right Command when right Control is taken or is one of
    /// the modifiers of either key. Nil when none of them is free.
    static func suggested(talkKey: Hotkey, translationKey: Hotkey) -> TalkKey? {
        [TalkKey.rightControl, .rightOption, .rightCommand].first { key in
            isAllowed(key, talkKey: talkKey, translationKey: translationKey)
                && [talkKey, translationKey].allSatisfy { $0.combination?.modifiers.isDisjoint(with: Hotkey.key(key).modifiers) ?? true }
        }
    }
}

/// Keeps the second talk key in UserDefaults under its own key. It is not added to the list
/// under `TalkKeyPreference.defaultsKey`, because an older Orra keeps one key of a list by
/// its own order, see `TalkKey.kept(from:)`, and could lose the talk key. An older Orra
/// ignores this key and keeps the talk key alone.
nonisolated enum SecondTalkKeyPreference {
    static let defaultsKey = "secondTalkKey"

    /// The saved key, or nil when none is saved or the saved one is no longer allowed beside
    /// these keys, which Orra never saves itself.
    static func load(talkKey: Hotkey, translationKey: Hotkey, from defaults: UserDefaults = .standard) -> TalkKey? {
        guard let key = defaults.string(forKey: defaultsKey).flatMap(TalkKey.init(rawValue:)),
              SecondTalkKey.isAllowed(key, talkKey: talkKey, translationKey: translationKey) else { return nil }
        return key
    }

    /// Saves the key, or removes it for none.
    static func save(_ key: TalkKey?, to defaults: UserDefaults = .standard) {
        if let key {
            defaults.set(key.rawValue, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}

/// Keeps the user's translation key in UserDefaults. Until the user picks one, or picks
/// the talk key's key for it and the keys swap, nothing is saved and the key follows the
/// talk key, see `TalkKey.defaultTranslationKey(talkKey:)`.
nonisolated enum TranslationKeyPreference {
    static let defaultsKey = "translationKey"

    static func save(_ key: TalkKey, to defaults: UserDefaults = .standard) {
        defaults.set(key.rawValue, forKey: defaultsKey)
    }

    /// Where a combination is saved, as for the talk key.
    static let combinationKey = "translationKeyCombination"

    /// The saved key or combination, or the default for this talk key when nothing usable
    /// is saved or the saved one is the talk key.
    static func loadHotkey(talkKey: Hotkey, from defaults: UserDefaults = .standard) -> Hotkey {
        if let combination = defaults.string(forKey: combinationKey).flatMap(KeyCombination.init(saved:)),
           Hotkey.combination(combination) != talkKey {
            return .combination(combination)
        }
        if let saved = defaults.string(forKey: defaultsKey).flatMap(TalkKey.init(rawValue:)), Hotkey.key(saved) != talkKey {
            return .key(saved)
        }
        return Hotkey.defaultTranslationKey(talkKey: talkKey)
    }

    static func saveHotkey(_ hotkey: Hotkey, to defaults: UserDefaults = .standard) {
        switch hotkey {
        case .key(let key):
            save(key, to: defaults)
            defaults.removeObject(forKey: combinationKey)
        case .combination(let combination):
            defaults.set(combination.savedValue, forKey: combinationKey)
        }
    }
}
