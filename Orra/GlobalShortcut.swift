import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

extension Logger {
    /// The Live Captions shortcut. States only, never which keys were pressed.
    nonisolated static let shortcut = Logger(subsystem: ProblemReport.subsystem, category: "shortcut")
}

/// The shortcut that turns Live Captions on and off from any app: ⌃ ⌥ ⌘ C, unless the user
/// picks another one or none in Settings, General, Keys. Everyone starts with it, new users
/// and users of an earlier version alike, unless one of their keys clashes with it, see
/// `LiveCaptionsShortcutPreference.keep`.
///
/// It is a hot key of the system, see GlobalShortcut, and not a key of the keyboard tap.
/// So it needs no Accessibility access, and a press of any other key waits for nothing new.
/// Orra's own keys are right hand modifiers, so the left hand presses it without starting a
/// dictation. A talk key that is a right hand key, such as right Control, pressed first,
/// starts a dictation, which the rest of the shortcut then cancels.
nonisolated enum LiveCaptionsShortcut {
    /// What one press means while the user records the shortcut.
    enum Outcome: Equatable, Sendable {
        /// The combination becomes the shortcut.
        case chosen(KeyCombination)
        /// The press cannot be the shortcut. The recorder keeps listening.
        case rejected(Rejection)
        /// Escape: the recorder stops without a change.
        case cancelled
    }

    /// Why a press cannot be the shortcut.
    enum Rejection: Equatable, Sendable {
        /// Neither Control nor Command and no function key, such as a letter alone, or
        /// Option with a letter, which types a character.
        case notAShortcut
        /// A function key with Option alone or with Shift, which macOS refuses as a hot key.
        case onlyOption
        /// A shortcut of macOS or of nearly every app, such as ⌘ C, see
        /// `KeyCombination.isSystemShortcut`. The shortcut would take its press in every app.
        case systemShortcut(KeyCombination)
        /// The talk key or the translation key. The shortcut never swaps with a key.
        case orraKey(KeyCombination)

        /// What the recorder says about the press, such as "⌘ Space is a shortcut of macOS
        /// or most apps and can't be the Live Captions shortcut" with the reason.
        func message(in locale: Locale = .interface) -> String {
            switch self {
            case .notAShortcut:
                String(localized: LocalizedStringResource("Use a key with Control or Command, or a function key such as F13.", locale: locale))
            case .onlyOption:
                String(localized: LocalizedStringResource("macOS refuses shortcuts with only Option, or Option and Shift. Add Control or Command, or leave Option out.", locale: locale))
            case .systemShortcut(let combination):
                String(localized: LocalizedStringResource("\(combination.title(in: locale)) is a shortcut of macOS or most apps and can't be the Live Captions shortcut. It would stop working everywhere while Orra runs.", locale: locale))
            case .orraKey(let combination):
                String(localized: LocalizedStringResource("\(combination.title(in: locale)) is already one of Orra's keys.", locale: locale))
            }
        }
    }

    /// The modifiers of the default shortcut.
    static let defaultModifiers: ModifierSet = [.control, .option, .command]

    /// ⌃ ⌥ ⌘ C, with the key that types C while Command is down on the keyboard layout in
    /// use, so it stays C on a Dvorak or AZERTY layout. `keyCodeForC` is nil when the layout
    /// types no C, and then the shortcut uses the C of a US keyboard.
    static func defaultShortcut(keyCodeForC: CGKeyCode?) -> KeyCombination {
        KeyCombination(modifiers: defaultModifiers, keyCode: Int64(keyCodeForC ?? CGKeyCode(kVK_ANSI_C)), character: "C")
    }

    /// What one key down or flags changed event means while the user records the shortcut,
    /// or nil for one that decides nothing, such as a modifier going down. The shortcut is
    /// chosen when its regular key goes down. `orraKeys` are the keys it must not be.
    static func outcome(type: CGEventType, keyCode: Int64, flags: CGEventFlags, orraKeys: [Hotkey]) -> Outcome? {
        // Reported to arrive with a press of the Globe key, see TalkKeyDetector.
        guard type == .keyDown, keyCode != TalkKeyDetector.globeKeyCode else { return nil }
        if keyCode == TalkKeyDetector.escapeKeyCode {
            return .cancelled
        }
        let combination = KeyCombination(modifiers: ModifierSet(flags: flags, includingFn: false), keyCode: keyCode)
        if combination.isSystemShortcut {
            return .rejected(.systemShortcut(combination))
        }
        guard combination.isValidShortcut else {
            // A function key alone would do, so the note names Option.
            if KeyName.isFunctionKey(keyCode), combination.hasOnlyOptionModifiers {
                return .rejected(.onlyOption)
            }
            return .rejected(.notAShortcut)
        }
        if orraKeys.contains(.combination(combination)) {
            return .rejected(.orraKey(combination))
        }
        return .chosen(combination)
    }

    /// Whether pressing `shortcut` may start a dictation of `key` for a moment: `key` is a
    /// combination of modifiers only, all of them in the shortcut, such as ⌃ ⌥ beside
    /// ⌃ ⌥ ⌘ C. It records as soon as its modifiers are down, and the rest of the shortcut
    /// cancels the dictation again. Settings warns about it.
    static func mayStartDictation(_ key: Hotkey, pressing shortcut: KeyCombination) -> Bool {
        guard let combination = key.combination, combination.keyCode == nil else { return false }
        return combination.modifiers.isSubset(of: shortcut.modifiers)
    }

    /// Whether `key` keeps `shortcut` from working well: the key is the shortcut, whose key
    /// the keyboard tap swallows, or pressing the shortcut may start a dictation of it.
    static func clashes(_ key: Hotkey, with shortcut: KeyCombination) -> Bool {
        key == .combination(shortcut) || mayStartDictation(key, pressing: shortcut)
    }

    /// What VoiceOver says after the shortcut turned Live Captions on or off. The change
    /// may come while another app is in front, where nothing else says it.
    static func announcement(captionsOn: Bool, in locale: Locale = .interface) -> String {
        captionsOn
            ? String(localized: LocalizedStringResource("Live Captions on", locale: locale))
            : String(localized: LocalizedStringResource("Live Captions off", locale: locale))
    }
}

/// Keeps the Live Captions shortcut in UserDefaults: the combination, see
/// `KeyCombination.savedValue`, or "none" once the user cleared it.
nonisolated enum LiveCaptionsShortcutPreference {
    static let defaultsKey = "liveCaptionsShortcut"
    static let noneValue = "none"

    /// The saved shortcut, nil for none, or `defaultShortcut` while nothing usable is saved.
    static func load(defaultShortcut: KeyCombination, from defaults: UserDefaults = .standard) -> KeyCombination? {
        guard let saved = defaults.string(forKey: defaultsKey) else { return defaultShortcut }
        if saved == noneValue {
            return nil
        }
        return KeyCombination(saved: saved, accepting: \.isValidShortcut) ?? defaultShortcut
    }

    /// Saves the shortcut, or "none" for nil.
    static func save(_ shortcut: KeyCombination?, to defaults: UserDefaults = .standard) {
        defaults.set(shortcut?.savedValue ?? noneValue, forKey: defaultsKey)
    }

    /// Saves the shortcut a user starts with, unless one is saved: `shortcut`, which is the
    /// default then, or none when one of `keys` clashes with it, see
    /// `LiveCaptionsShortcut.clashes`. So a user whose talk key is ⌃ ⌥ ⌘ C, or ⌃ ⌥, keeps
    /// their key working as before the update. Saved at once, so a key the user picks
    /// later never clears the shortcut. LaunchMigrations runs it at every launch. Returns
    /// the shortcut to use.
    ///
    /// A saved shortcut that one of `keys` is turns into none too. Settings never allows
    /// that, but a version without the shortcut does, or a saved value Orra cannot read
    /// loads as the default. The key keeps working, as it did when it was picked.
    static func keep(_ shortcut: KeyCombination?, beside keys: [Hotkey], in defaults: UserDefaults = .standard) -> KeyCombination? {
        if defaults.string(forKey: defaultsKey) != nil {
            guard let shortcut, keys.contains(.combination(shortcut)) else { return shortcut }
            save(nil, to: defaults)
            return nil
        }
        let kept = shortcut.flatMap { shortcut in
            keys.contains { LiveCaptionsShortcut.clashes($0, with: shortcut) } ? nil : shortcut
        }
        save(kept, to: defaults)
        return kept
    }
}

/// Tells a new press of a global shortcut from a repeat while its keys are held. The system
/// sends a press and a release for each registered shortcut, and may send more presses
/// while the key repeats. A press while the shortcut is down counts only when the last one
/// came so long ago that its release must have been missed.
nonisolated struct ShortcutPresses: Equatable, Sendable {
    /// Longer than the longest wait before a key repeats, and than the slowest repeat, that
    /// Keyboard settings offer, about 1.8 seconds each.
    static let missedRelease: Duration = .milliseconds(2500)

    private(set) var isDown = false
    private var lastPress: ContinuousClock.Instant?

    init() {}

    /// The presses of a shortcut whose keys are already down, as when it is registered
    /// right after the user recorded it. Presses during that hold do not count. The system
    /// sends no release for a press it never matched, so the owner calls `release()` once
    /// the key is up.
    static func held(since now: ContinuousClock.Instant) -> ShortcutPresses {
        var presses = ShortcutPresses()
        presses.isDown = true
        presses.lastPress = now
        return presses
    }

    /// A press arrived. True when it counts as a new press.
    mutating func press(at now: ContinuousClock.Instant) -> Bool {
        defer {
            isDown = true
            lastPress = now
        }
        guard isDown, let lastPress else { return true }
        return now - lastPress >= Self.missedRelease
    }

    /// The release arrived.
    mutating func release() {
        isDown = false
    }
}

/// A global shortcut through the hot key API of Carbon's HIToolbox, which the system
/// delivers to Orra whichever app is in front. It needs no permission, and it does not go
/// through the keyboard tap, whose callback every key press on the Mac waits for.
/// `RegisterEventHotKey` is not deprecated in the macOS 27 SDK and is not thread safe, so
/// everything here runs on the main thread.
///
/// Registered without `kEventHotKeyExclusive`, so another app that registered the same
/// combination gets its presses too.
enum GlobalShortcut {
    /// Registers `combination` with the system and calls `pressed` on the main thread at
    /// each press. Returns what unregisters it, or nil when the system refused it. A
    /// closure, so tests never register a real one. The app uses `registerLive`.
    typealias Register = @MainActor (_ combination: KeyCombination, _ pressed: @escaping @MainActor () -> Void) -> Unregister?
    typealias Unregister = @MainActor () -> Void

    /// 'Orra', the signature of Orra's hot keys.
    nonisolated fileprivate static let signature: OSType = 0x4F72_7261

    /// A registered shortcut: what its press calls, and whether it is down.
    private struct Entry {
        let pressed: @MainActor () -> Void
        var presses = ShortcutPresses()
    }

    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1
    private static var entries: [UInt32: Entry] = [:]

    /// The modifiers as `RegisterEventHotKey` takes them. fn is not one of them.
    nonisolated static func carbonModifiers(_ modifiers: ModifierSet) -> UInt32 {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }

    static func registerLive(_ combination: KeyCombination, pressed: @escaping @MainActor () -> Void) -> Unregister? {
        guard let keyCode = combination.keyCode, installHandler() else { return nil }
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(truncatingIfNeeded: keyCode),
            carbonModifiers(combination.modifiers),
            EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            Logger.shortcut.error("The system refused the shortcut, status \(status, privacy: .public)")
            return nil
        }
        // Right after the user recorded the shortcut, its key is still down. A press the
        // system may repeat during that hold must not turn captions on.
        let key = CGKeyCode(truncatingIfNeeded: keyCode)
        let held = CGEventSource.keyState(.hidSystemState, key: key)
        entries[id] = Entry(pressed: pressed, presses: held ? .held(since: .now) : ShortcutPresses())
        if held {
            releaseWhenUp(id: id, key: key)
        }
        Logger.shortcut.info("Shortcut registered, held: \(held, privacy: .public)")
        return {
            UnregisterEventHotKey(reference)
            entries[id] = nil
        }
    }

    /// Marks the shortcut with this ID released once its key is up. Checks every 50 ms, for
    /// 30 seconds at most, after which a press counts again anyway.
    private static func releaseWhenUp(id: UInt32, key: CGKeyCode) {
        Task {
            let deadline = ContinuousClock.now + .seconds(30)
            while CGEventSource.keyState(.hidSystemState, key: key), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            entries[id]?.presses.release()
        }
    }

    /// Installs the handler of Orra's hot key events once. True when it is in place.
    private static func installHandler() -> Bool {
        guard !handlerInstalled else { return true }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), receiveHotKeyEvent, types.count, &types, nil, nil)
        handlerInstalled = status == noErr
        if !handlerInstalled {
            Logger.shortcut.error("The shortcut handler could not be installed, status \(status, privacy: .public)")
        }
        return handlerInstalled
    }

    /// A press or a release of the shortcut with this ID.
    fileprivate static func receive(id: UInt32, isPress: Bool, at now: ContinuousClock.Instant) {
        guard var entry = entries[id] else { return }
        var counts = false
        if isPress {
            counts = entry.presses.press(at: now)
        } else {
            entry.presses.release()
        }
        entries[id] = entry
        if counts {
            entry.pressed()
        }
    }
}

/// The handler of Orra's hot key events, which the system calls on the main thread.
nonisolated private func receiveHotKeyEvent(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKey = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKey
    )
    guard status == noErr, hotKey.signature == GlobalShortcut.signature else { return OSStatus(eventNotHandledErr) }
    let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let id = hotKey.id
    let now = ContinuousClock.now
    MainActor.assumeIsolated {
        GlobalShortcut.receive(id: id, isPress: isPress, at: now)
    }
    return noErr
}
