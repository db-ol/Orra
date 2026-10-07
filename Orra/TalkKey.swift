import CoreGraphics
import Foundation

/// A key that starts a dictation while it is held on its own. The user picks one or more
/// in the menu or in Settings, and right Control is the default.
///
/// Only modifiers on the right hand and fn are offered. The left modifiers are part of so
/// many shortcuts that a dictation would start on every one of them, and Shift on its own
/// switches Chinese input methods between Chinese and English.
nonisolated enum TalkKey: String, CaseIterable, Identifiable, Sendable {
    case rightControl
    case rightOption
    case rightCommand
    case fn

    /// What a fresh install listens for. Right Control sits at the right end of the bottom
    /// row of most external keyboards, and the Fn key of many of those, such as the
    /// Logitech MX Keys, never reaches the Mac.
    static let defaultKeys: Set<TalkKey> = [.rightControl]

    var id: String { rawValue }

    /// The name on a switch in the menu or in Settings.
    var name: String {
        switch self {
        case .rightControl: String(localized: "Right Control")
        case .rightOption: String(localized: "Right Option")
        case .rightCommand: String(localized: "Right Command")
        case .fn: String(localized: "fn (Globe)")
        }
    }

    /// The name inside a sentence, such as "Hold right Control to talk".
    var nameInSentence: String {
        switch self {
        case .rightControl: String(localized: "right Control", comment: "A talk key inside a sentence")
        case .rightOption: String(localized: "right Option", comment: "A talk key inside a sentence")
        case .rightCommand: String(localized: "right Command", comment: "A talk key inside a sentence")
        case .fn: String(localized: "fn", comment: "A talk key inside a sentence")
        }
    }

    /// The virtual key code of the key's own flags changed events, from HIToolbox
    /// Events.h.
    var keyCode: Int64 {
        switch self {
        case .rightControl: 0x3E
        case .rightOption: 0x3D
        case .rightCommand: 0x36
        case .fn: 0x3F
        }
    }

    /// The flag that is set while this key is down. For the right hand modifiers it is the
    /// device dependent bit from IOKit's IOLLEvent.h, which tells the right key from the
    /// left one.
    var downFlag: CGEventFlags {
        switch self {
        case .rightControl: CGEventFlags(rawValue: 0x0000_2000)
        case .rightOption: CGEventFlags(rawValue: 0x0000_0040)
        case .rightCommand: CGEventFlags(rawValue: 0x0000_0010)
        case .fn: .maskSecondaryFn
        }
    }

    /// The flag that the left and the right key of a pair both set. Nil for fn.
    var sharedFlag: CGEventFlags? {
        switch self {
        case .rightControl: .maskControl
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .fn: nil
        }
    }

    /// The device dependent bit of the left key of the pair. Nil for fn.
    var leftKeyFlag: CGEventFlags? {
        switch self {
        case .rightControl: CGEventFlags(rawValue: 0x0000_0001)
        case .rightOption: CGEventFlags(rawValue: 0x0000_0020)
        case .rightCommand: CGEventFlags(rawValue: 0x0000_0008)
        case .fn: nil
        }
    }

    /// Fn's own events are swallowed, so the action set under "Press fn key to" in
    /// Keyboard settings, such as the emoji picker, does not also fire. The right hand
    /// modifiers have no system action of their own, unless Dictation or Siri is set to a
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
        if let leftKeyFlag {
            flags.insert(leftKeyFlag)
        }
        if self == .fn {
            flags.remove(.maskSecondaryFn)
        }
        return flags
    }

    /// Whether the flags of this key's own flags changed event say that it is now down.
    /// `wasDown` says whether the detector holds the key as down.
    func isDown(in flags: CGEventFlags, wasDown: Bool) -> Bool {
        guard let sharedFlag, let leftKeyFlag else {
            return flags.contains(downFlag)
        }
        if !flags.isDisjoint(with: downFlag.union(leftKeyFlag)) {
            return flags.contains(downFlag)
        }
        // A keyboard that sets no left or right bits. The shared flag cannot tell this key
        // from its left twin, so while the key is down, its own next event is its release.
        return wasDown ? false : flags.contains(sharedFlag)
    }

    /// On a keyboard that sets no left or right bits: whether the left twin is still down
    /// at this key's release. Then the hold was part of a shortcut that began with the left
    /// twin, which such a keyboard does not show at the press.
    func twinIsDown(atReleaseWith flags: CGEventFlags) -> Bool {
        guard let sharedFlag, let leftKeyFlag else { return false }
        return flags.isDisjoint(with: downFlag.union(leftKeyFlag)) && flags.contains(sharedFlag)
    }

    /// The hint in the menu, such as "Hold right Control or fn to talk". One sentence per
    /// number of keys, so each language can join the names its own way. There are four
    /// talk keys.
    static func holdHint(for keys: Set<TalkKey>) -> String {
        let names = allCases.filter(keys.contains).map(\.nameInSentence)
        switch names.count {
        case 0:
            return String(localized: "No talk key is set")
        case 1:
            return String(localized: "Hold \(names[0]) to talk")
        case 2:
            return String(localized: "Hold \(names[0]) or \(names[1]) to talk")
        case 3:
            return String(localized: "Hold \(names[0]), \(names[1]) or \(names[2]) to talk")
        default:
            return String(localized: "Hold \(names[0]), \(names[1]), \(names[2]) or \(names[3]) to talk")
        }
    }
}

/// Keeps the user's talk keys in UserDefaults.
nonisolated enum TalkKeyPreference {
    static let defaultsKey = "talkKeys"

    /// The saved keys, or the default when nothing usable is saved.
    static func load(from defaults: UserDefaults = .standard) -> Set<TalkKey> {
        let saved = Set((defaults.stringArray(forKey: defaultsKey) ?? []).compactMap(TalkKey.init(rawValue:)))
        return saved.isEmpty ? TalkKey.defaultKeys : saved
    }

    static func save(_ keys: Set<TalkKey>, to defaults: UserDefaults = .standard) {
        defaults.set(TalkKey.allCases.filter(keys.contains).map(\.rawValue), forKey: defaultsKey)
    }
}
