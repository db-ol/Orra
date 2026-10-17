import CoreGraphics
import Foundation

/// How a key starts and ends a dictation. Each of Orra's two keys has its own.
///
/// The raw values are saved in UserDefaults. Never change one, or a saved choice is lost.
nonisolated enum TriggerMode: String, CaseIterable, Identifiable, Sendable {
    /// Hold the key while speaking and let go to paste. With Double press for hands free
    /// on, a quick double press records hands free, see TalkKeyDetector.
    case hold
    /// Press the key once to start, and once more to paste. The recording goes on after
    /// the first release.
    case toggle
    /// Press the key twice quickly to start, and once more to paste. A single press or a
    /// hold does nothing.
    case doubleTap

    static let defaultMode: TriggerMode = .hold

    var id: String { rawValue }

    /// The name in the picker, such as "Hold".
    func title(in locale: Locale = .interface) -> String {
        switch self {
        case .hold: String(localized: LocalizedStringResource("Hold", locale: locale, comment: "A trigger mode: hold the key while speaking"))
        case .toggle: String(localized: LocalizedStringResource("Press to start and stop", locale: locale, comment: "A trigger mode: press once to start and once more to stop"))
        case .doubleTap: String(localized: LocalizedStringResource("Double press", locale: locale, comment: "A trigger mode: press twice quickly to start"))
        }
    }
}

/// The modifiers of a key combination, without left and right, as Mac menus show them.
nonisolated struct ModifierSet: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    static let control = ModifierSet(rawValue: 1 << 0)
    static let option = ModifierSet(rawValue: 1 << 1)
    static let shift = ModifierSet(rawValue: 1 << 2)
    static let command = ModifierSet(rawValue: 1 << 3)
    static let fn = ModifierSet(rawValue: 1 << 4)

    /// The modifiers a combination with a regular key needs at least one of. Shift alone
    /// with a letter types a capital, and fn alone with an arrow is Home or Page Up.
    static let commandLike: ModifierSet = [.control, .option, .command]

    /// The order Mac menus show them in, with fn first, the saved name and the symbol.
    static let ordered: [(ModifierSet, String, String)] = [
        (.fn, "fn", "fn"), (.control, "control", "⌃"), (.option, "option", "⌥"),
        (.shift, "shift", "⇧"), (.command, "command", "⌘"),
    ]

    /// The modifiers that are down in `flags`. fn counts only when `includingFn` is true,
    /// because the system also sets the Fn flag on arrow and function key events.
    init(flags: CGEventFlags, includingFn: Bool) {
        var set: ModifierSet = []
        if flags.contains(.maskControl) { set.insert(.control) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskCommand) { set.insert(.command) }
        if includingFn, flags.contains(.maskSecondaryFn) { set.insert(.fn) }
        self = set
    }

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    var count: Int {
        rawValue.nonzeroBitCount
    }

    /// The symbols in menu order, such as ["⌃", "⌥"].
    var symbols: [String] {
        Self.ordered.filter { contains($0.0) }.map(\.2)
    }
}

/// A combination the user picked as a key: two or more modifiers held together, such as
/// Control and Option, or modifiers with a regular key, such as Shift, Command and D.
/// Left and right count the same.
nonisolated struct KeyCombination: Hashable, Sendable {
    let modifiers: ModifierSet
    /// The virtual key code of the regular key, or nil for modifiers only.
    let keyCode: Int64?
    /// The character the regular key typed on the keyboard layout in use when it was
    /// picked, for its name on screen. Not part of what the combination is.
    let character: String?

    init(modifiers: ModifierSet, keyCode: Int64? = nil, character: String? = nil) {
        self.modifiers = keyCode == nil ? modifiers : modifiers.subtracting(.fn)
        self.keyCode = keyCode
        self.character = character
    }

    static func == (lhs: KeyCombination, rhs: KeyCombination) -> Bool {
        lhs.modifiers == rhs.modifiers && lhs.keyCode == rhs.keyCode
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(modifiers)
        hasher.combine(keyCode)
    }

    /// Whether this can be a key: two modifiers or more, or a regular key with Control,
    /// Option or Command that is no shortcut of the system. Escape stays the key that
    /// cancels.
    var isValid: Bool {
        guard let keyCode else { return modifiers.count >= 2 }
        return !modifiers.isDisjoint(with: ModifierSet.commandLike) && keyCode != TalkKeyDetector.escapeKeyCode && !isSystemShortcut
    }

    /// Whether this is a shortcut of macOS or of nearly every app: Command with any key but
    /// F1 to F20, such as ⌘ C, ⌘ V, ⌘ Tab or ⌘ Space, and Control with Space, which
    /// switches input sources. Orra swallows its key, so as a key it would stop working in
    /// every app while Orra runs.
    var isSystemShortcut: Bool {
        guard let keyCode else { return false }
        if modifiers == .command {
            return !KeyName.isFunctionKey(keyCode)
        }
        return modifiers == .control && keyCode == KeyName.spaceKeyCode
    }

    /// The keys as Mac menus show them, such as "⌃ ⌥" or "⇧ ⌘ D".
    func title(in locale: Locale = .interface) -> String {
        var parts = modifiers.symbols
        if let keyCode {
            parts.append(KeyName.namedKey(keyCode, locale: locale) ?? character ?? "#\(keyCode)")
        }
        return parts.joined(separator: " ")
    }

    /// How it is saved, such as "control+option" or "shift+command|2|D". The key code and
    /// the character follow the modifiers.
    var savedValue: String {
        let names = ModifierSet.ordered.filter { modifiers.contains($0.0) }.map(\.1).joined(separator: "+")
        guard let keyCode else { return names }
        return [names, String(keyCode), character ?? ""].joined(separator: "|")
    }

    /// Reads a saved combination. Nil for anything that is not a valid one.
    init?(saved: String) {
        let parts = saved.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        var modifiers: ModifierSet = []
        for name in parts[0].split(separator: "+") {
            guard let entry = ModifierSet.ordered.first(where: { $0.1 == name }) else { return nil }
            modifiers.insert(entry.0)
        }
        var keyCode: Int64?
        var character: String?
        if parts.count > 1 {
            guard let code = Int64(parts[1]) else { return nil }
            keyCode = code
            character = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        }
        self.init(modifiers: modifiers, keyCode: keyCode, character: character)
        guard isValid else { return nil }
    }

    /// Which way one event moves this combination, see `Hotkey.signal`.
    func signal(type: CGEventType, keyCode eventKeyCode: Int64, flags: CGEventFlags, isDown: Bool) -> Hotkey.Signal {
        switch type {
        case .flagsChanged:
            let held = ModifierSet(flags: flags, includingFn: keyCode == nil)
            if isDown {
                if held == modifiers { return .ignore }
                // Another modifier joined, which makes it another shortcut, or one of its
                // own went up, which ends the press.
                return modifiers.isSubset(of: held) ? .other : .up
            }
            if keyCode == nil, held == modifiers { return .down }
            // Its modifiers going down one by one, or up after a press, are not other input.
            return held.isSubset(of: modifiers) ? .ignore : .other
        case .keyDown:
            guard let keyCode, eventKeyCode == keyCode else { return .other }
            // A repeat while it is down, or a press with exactly its modifiers.
            if isDown || ModifierSet(flags: flags, includingFn: false) == modifiers { return .down }
            return .other
        case .keyUp:
            return isDown && eventKeyCode == keyCode ? .up : .ignore
        default:
            return .ignore
        }
    }
}

/// One of Orra's two keys: a single modifier, as before, or a combination.
nonisolated enum Hotkey: Hashable, Sendable {
    case key(TalkKey)
    case combination(KeyCombination)

    /// What one event means for a hotkey.
    nonisolated enum Signal: Equatable, Sendable {
        /// It went down, or a regular key of it repeats while it is down.
        case down
        /// It went up.
        case up
        /// Another key or modifier, which makes a press a shortcut.
        case other
        /// Nothing that matters, such as a key coming up, or the modifiers of a
        /// combination going down one by one.
        case ignore
    }

    // The single keys by their names, so a single key reads as before, such as
    // `.rightControl` where a Hotkey is expected.
    static let rightControl = Hotkey.key(.rightControl)
    static let rightOption = Hotkey.key(.rightOption)
    static let rightCommand = Hotkey.key(.rightCommand)
    static let leftControl = Hotkey.key(.leftControl)
    static let leftOption = Hotkey.key(.leftOption)
    static let leftCommand = Hotkey.key(.leftCommand)
    static let fn = Hotkey.key(.fn)

    static let defaultKey = Hotkey.key(TalkKey.defaultKey)

    /// The single key, or nil for a combination.
    var single: TalkKey? {
        if case .key(let key) = self { key } else { nil }
    }

    /// The combination, or nil for a single key.
    var combination: KeyCombination? {
        if case .combination(let combination) = self { combination } else { nil }
    }

    /// Whether this is a combination with a regular key, whose key events are hidden from
    /// the app in front while it matches.
    var hasRegularKey: Bool {
        combination?.keyCode != nil
    }

    /// Whether the tap hides an event of this key of `type` from the system and other
    /// apps: fn's own events, see `TalkKey.swallowsItsEvents`, and the regular key of a
    /// combination. The modifiers of a combination always pass through.
    func swallows(_ type: CGEventType) -> Bool {
        switch self {
        case .key(let key): key.swallowsItsEvents
        case .combination(let combination): combination.keyCode != nil && type != .flagsChanged
        }
    }

    /// Whether holding it changes what a click does, see `TalkKey.modifiesClicks`.
    var modifiesClicks: Bool {
        switch self {
        case .key(let key): key.modifiesClicks
        case .combination(let combination): !combination.modifiers.subtracting(.fn).isEmpty
        }
    }

    /// Whether a press waits for `TalkKeyDetector.leftKeyDelay` before it records. A
    /// combination is a deliberate choice and does not, unless it is among the detector's
    /// delayed keys.
    var waitsBeforeRecording: Bool {
        single?.waitsBeforeRecording ?? false
    }

    /// The modifiers it uses, without left and right. One for a single key.
    var modifiers: ModifierSet {
        switch self {
        case .key(let key):
            switch key {
            case .rightControl, .leftControl: .control
            case .rightOption, .leftOption: .option
            case .rightCommand, .leftCommand: .command
            case .fn: .fn
            }
        case .combination(let combination): combination.modifiers
        }
    }

    /// What one event means for this hotkey. `isDown` says whether the detector holds it
    /// as down.
    func signal(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isDown: Bool) -> Signal {
        switch self {
        case .key(let key):
            switch type {
            case .flagsChanged where keyCode == key.keyCode:
                return key.isDown(in: flags, wasDown: isDown) ? .down : .up
            case .flagsChanged, .keyDown:
                return .other
            default:
                return .ignore
            }
        case .combination(let combination):
            return combination.signal(type: type, keyCode: keyCode, flags: flags, isDown: isDown)
        }
    }

    /// Whether `flags` show another modifier at a press, which makes it a shortcut. A
    /// combination matches its modifiers exactly, so it is always alone.
    func isAlone(with flags: CGEventFlags) -> Bool {
        single.map { flags.isDisjoint(with: $0.otherModifiers) } ?? true
    }

    /// See `TalkKey.twinIsDown(atReleaseWith:)`. Never for a combination.
    func twinIsDown(atReleaseWith flags: CGEventFlags) -> Bool {
        single?.twinIsDown(atReleaseWith: flags) ?? false
    }

    /// The symbol and the name, such as "⌥ Right Option", or the keys of a combination.
    func title(in locale: Locale = .interface) -> String {
        switch self {
        case .key(let key): key.title(in: locale)
        case .combination(let combination): combination.title(in: locale)
        }
    }

    /// The other label in parentheses, such as "(Alt)". Nil for a combination.
    func otherLabelInParentheses(in locale: Locale = .interface) -> String? {
        single?.otherLabelInParentheses(in: locale)
    }

    /// The title with the other label, as in the menu.
    func fullName(in locale: Locale = .interface) -> String {
        single?.fullName(in: locale) ?? title(in: locale)
    }

    /// The name inside a sentence, such as "right Control" or "⌃ ⌥".
    func sentenceName(in locale: Locale = .interface) -> String {
        single?.sentenceName(in: locale) ?? title(in: locale)
    }

    /// The hint in the menu and the idle bar, such as "Hold right Control to talk", or
    /// "Hold fn or right Control to talk" with a second talk key.
    func talkHint(mode: TriggerMode, secondKey: TalkKey? = nil, in locale: Locale = .interface) -> String {
        let name = sentenceName(orSecond: secondKey, in: locale)
        return switch mode {
        case .hold: String(localized: LocalizedStringResource("Hold \(name) to talk", locale: locale))
        case .toggle: String(localized: LocalizedStringResource("Press \(name) to talk, and again to finish", locale: locale))
        case .doubleTap: String(localized: LocalizedStringResource("Press \(name) twice to talk, and once more to finish", locale: locale))
        }
    }

    /// The name inside a sentence, followed by the second talk key's when there is one, such
    /// as "fn or right Control".
    func sentenceName(orSecond secondKey: TalkKey?, in locale: Locale = .interface) -> String {
        let name = sentenceName(in: locale)
        guard let secondKey else { return name }
        let second = secondKey.sentenceName(in: locale)
        return String(localized: LocalizedStringResource("\(name) or \(second)", locale: locale, comment: "The talk key and the second talk key inside a sentence, such as fn or right Control"))
    }

    /// The hint in the menu while translation is on, such as "Hold right Option to
    /// translate".
    func translateHint(mode: TriggerMode, in locale: Locale = .interface) -> String {
        let name = sentenceName(in: locale)
        return switch mode {
        case .hold: String(localized: LocalizedStringResource("Hold \(name) to translate", locale: locale))
        case .toggle: String(localized: LocalizedStringResource("Press \(name) to translate, and again to finish", locale: locale))
        case .doubleTap: String(localized: LocalizedStringResource("Press \(name) twice to translate, and once more to finish", locale: locale))
        }
    }

    /// What the indicator says during a hands free dictation, such as "Press right Control
    /// to finish".
    func finishHint(in locale: Locale = .interface) -> String {
        String(localized: LocalizedStringResource("Press \(sentenceName(in: locale)) to finish", locale: locale))
    }

    /// The key as a problem report names it: the saved name of a single key, or the saved
    /// combination, which holds key codes only.
    var reportName: String {
        switch self {
        case .key(let key): key.rawValue
        case .combination(let combination): "combination \(combination.modifiers.symbols.joined()) \(combination.keyCode.map(String.init) ?? "")"
        }
    }

    /// The translation key Orra uses until the user picks one, see
    /// `TalkKey.defaultTranslationKey(talkKey:)`. Right Option beside a combination.
    static func defaultTranslationKey(talkKey: Hotkey) -> Hotkey {
        .key(TalkKey.defaultTranslationKey(talkKey: talkKey.single ?? .rightControl))
    }
}

/// Keeps how each key starts a dictation in UserDefaults. Hold until the user picks
/// another.
nonisolated enum TriggerModePreference {
    static func defaultsKey(for slot: KeySlot) -> String {
        slot == .talk ? "talkKeyMode" : "translationKeyMode"
    }

    static func load(for slot: KeySlot, from defaults: UserDefaults = .standard) -> TriggerMode {
        defaults.string(forKey: defaultsKey(for: slot)).flatMap(TriggerMode.init(rawValue:)) ?? .defaultMode
    }

    static func save(_ mode: TriggerMode, for slot: KeySlot, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultsKey(for: slot))
    }
}
