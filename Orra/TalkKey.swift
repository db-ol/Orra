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
    var name: String {
        switch self {
        case .rightControl: String(localized: "Right Control")
        case .rightOption: String(localized: "Right Option")
        case .rightCommand: String(localized: "Right Command")
        case .leftControl: String(localized: "Left Control")
        case .leftOption: String(localized: "Left Option")
        case .leftCommand: String(localized: "Left Command")
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
    var title: String {
        symbol.map { "\($0) \(name)" } ?? name
    }

    /// What the key is called on other keycaps, shown as a small hint next to its name.
    /// A keyboard with a Windows layout prints Alt on the key the Mac uses as Option, and
    /// a Windows logo on the key it uses as Command. The fn key of recent Macs shows a
    /// globe. Control is Ctrl everywhere, so it needs none.
    var otherLabel: String? {
        switch self {
        case .rightControl, .leftControl: nil
        case .rightOption, .leftOption: String(localized: "Alt", comment: "The label of the Option key on a keyboard with a Windows layout")
        case .rightCommand, .leftCommand: String(localized: "Windows key", comment: "The key a keyboard with a Windows layout has in place of Command")
        case .fn: String(localized: "Globe 🌐", comment: "The fn key of recent Macs, which shows a globe")
        }
    }

    /// The other label in parentheses, such as "(Alt)", or nil.
    var otherLabelInParentheses: String? {
        otherLabel.map { String(localized: "(\($0))", comment: "A talk key's label on other keyboards, such as (Alt)") }
    }

    /// The title with the other label, such as "⌥ Right Option (Alt)", where the key is
    /// shown in one line of text, as in the menu.
    var fullName: String {
        otherLabel.map { String(localized: "\(title) (\($0))", comment: "A talk key with its label on other keyboards, such as ⌥ Right Option (Alt)") } ?? title
    }

    /// The name inside a sentence, such as "Hold right Control to talk".
    var nameInSentence: String {
        sentenceName(in: .main)
    }

    /// The name inside a sentence, from the strings in `bundle`. Tests pass the Chinese
    /// strings.
    func sentenceName(in bundle: Bundle) -> String {
        switch self {
        case .rightControl: String(localized: "right Control", bundle: bundle, comment: "A talk key inside a sentence")
        case .rightOption: String(localized: "right Option", bundle: bundle, comment: "A talk key inside a sentence")
        case .rightCommand: String(localized: "right Command", bundle: bundle, comment: "A talk key inside a sentence")
        case .leftControl: String(localized: "left Control", bundle: bundle, comment: "A talk key inside a sentence")
        case .leftOption: String(localized: "left Option", bundle: bundle, comment: "A talk key inside a sentence")
        case .leftCommand: String(localized: "left Command", bundle: bundle, comment: "A talk key inside a sentence")
        case .fn: String(localized: "fn", bundle: bundle, comment: "A talk key inside a sentence")
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

    /// The hint in the menu, such as "Hold right Control to talk".
    func holdHint(bundle: Bundle = .main) -> String {
        String(localized: "Hold \(sentenceName(in: bundle)) to talk", bundle: bundle)
    }

    /// What the indicator says during a hands free dictation, such as "Press right Control
    /// to finish".
    func finishHint(bundle: Bundle = .main) -> String {
        String(localized: "Press \(sentenceName(in: bundle)) to finish", bundle: bundle)
    }
}

/// Records the talk key the user presses, like the shortcut recorders of Mac apps. A key
/// that can be a talk key counts when it goes down on its own and comes up again with
/// nothing else pressed in between, so a shortcut such as Command+C is never taken for
/// Command. Anything else is turned down with the reason, and the recorder keeps
/// listening. Escape cancels.
///
/// Pure logic. `HotkeyTap`, or a local event monitor while Orra has no tap, feeds it the
/// key down and flags changed events.
nonisolated struct KeyRecorder: Equatable, Sendable {
    nonisolated enum Outcome: Equatable, Sendable {
        /// The key went down and up on its own. It becomes the talk key.
        case chosen(TalkKey)
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
        /// Two keys together, such as Command+C or right Control with Shift held.
        case combination
        /// A key that types or acts on its own, such as a letter, Return or an arrow key.
        case key(keyCode: Int64)
    }

    static let shiftKeyCodes: Set<Int64> = [0x38, 0x3C]
    static let capsLockKeyCode: Int64 = 0x39

    /// A key that can be a talk key, down on its own with nothing pressed since.
    private(set) var candidate: TalkKey?

    /// What one key down or flags changed event means, or nil for one that decides nothing
    /// yet, such as a talk key going down.
    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Outcome? {
        switch type {
        case .flagsChanged:
            if let key = TalkKey.allCases.first(where: { $0.keyCode == keyCode }) {
                if key.isDown(in: flags, wasDown: candidate == key) {
                    // A second modifier, or one pressed while another is held.
                    guard candidate == nil, flags.isDisjoint(with: key.otherModifiers) else {
                        candidate = nil
                        return .rejected(.combination)
                    }
                    candidate = key
                    return nil
                }
                guard candidate == key else { return nil }
                candidate = nil
                return .chosen(key)
            }
            if Self.shiftKeyCodes.contains(keyCode) {
                guard flags.contains(.maskShift) else { return nil }
                let combined = candidate != nil
                candidate = nil
                return .rejected(combined ? .combination : .shift)
            }
            if keyCode == Self.capsLockKeyCode {
                candidate = nil
                return .rejected(.capsLock)
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
            let combined = candidate != nil || !flags.isDisjoint(with: [.maskControl, .maskAlternate, .maskCommand])
            candidate = nil
            return .rejected(combined ? .combination : .key(keyCode: keyCode))
        default:
            return nil
        }
    }
}

extension KeyRecorder.Rejection {
    /// What the recorder says about the press, such as "Shift can't be the talk key" with
    /// the reason.
    @MainActor var message: String {
        switch self {
        case .shift:
            String(localized: "Shift can't be the talk key. On its own, it switches input methods between Chinese and English.")
        case .capsLock:
            String(localized: "Caps Lock can't be the talk key. It turns capitals or the input method on and off.")
        case .combination:
            String(localized: "A key combination can't be the talk key. Press one key on its own.")
        case .key(let keyCode):
            if let name = KeyName.name(forKeyCode: keyCode) {
                String(localized: "The \(name) key can't be the talk key. Holding it would type or do something in the app in front.")
            } else {
                String(localized: "This key can't be the talk key. Holding it would type or do something in the app in front.")
            }
        }
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
        defaults.object(forKey: defaultsKey) as? Bool ?? true
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
        defaults.object(forKey: defaultsKey) != nil
    }
}
