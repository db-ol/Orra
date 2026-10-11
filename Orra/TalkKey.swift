import CoreGraphics
import Foundation

/// A key that starts a dictation while it is held on its own. The user picks one or more
/// in the menu or in Settings, and right Control is the default.
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
    /// Logitech MX Keys, never reaches the Mac.
    static let defaultKeys: Set<TalkKey> = [.rightControl]

    var id: String { rawValue }

    /// The name on a switch in the menu or in Settings.
    var name: String {
        switch self {
        case .rightControl: String(localized: "Right Control")
        case .rightOption: String(localized: "Right Option")
        case .rightCommand: String(localized: "Right Command")
        case .leftControl: String(localized: "Left Control")
        case .leftOption: String(localized: "Left Option")
        case .leftCommand: String(localized: "Left Command")
        case .fn: String(localized: "fn (Globe)")
        }
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

    /// The hint in the menu, such as "Hold right Control or fn to talk". One sentence per
    /// number of keys up to four, so each language can join the names its own way. Five
    /// or more keys use the sentence for two, with all but the last name joined by the
    /// list separator of the language.
    static func holdHint(for keys: Set<TalkKey>, bundle: Bundle = .main) -> String {
        let names = allCases.filter(keys.contains).map { $0.sentenceName(in: bundle) }
        switch names.count {
        case 0:
            return String(localized: "No talk key is set", bundle: bundle)
        case 1:
            return String(localized: "Hold \(names[0]) to talk", bundle: bundle)
        case 2:
            return String(localized: "Hold \(names[0]) or \(names[1]) to talk", bundle: bundle)
        case 3:
            return String(localized: "Hold \(names[0]), \(names[1]) or \(names[2]) to talk", bundle: bundle)
        case 4:
            return String(localized: "Hold \(names[0]), \(names[1]), \(names[2]) or \(names[3]) to talk", bundle: bundle)
        default:
            let first = names.dropLast().dropFirst().reduce(names[0]) { list, name in
                String(localized: "\(list), \(name)", bundle: bundle, comment: "Talk key names in a list")
            }
            return String(localized: "Hold \(first) or \(names[names.count - 1]) to talk", bundle: bundle)
        }
    }

    /// What the indicator says during a hands free dictation, such as "Press right Control
    /// to finish".
    func finishHint(bundle: Bundle = .main) -> String {
        String(localized: "Press \(sentenceName(in: bundle)) to finish", bundle: bundle)
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
