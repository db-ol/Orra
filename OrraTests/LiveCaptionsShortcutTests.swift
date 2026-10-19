import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Orra

/// Stands in for the hot key API behind GlobalShortcut. It notes each registration and
/// never registers a real shortcut.
@MainActor
final class FakeShortcutSystem {
    /// "register" or "unregister" with the keys, in order.
    private(set) var log: [String] = []
    /// The shortcut registered now, nil while none is.
    private(set) var registered: KeyCombination?
    /// Presses the registered shortcut.
    private(set) var press: (@MainActor () -> Void)?
    /// Whether the system refuses the next registrations.
    var refuses = false

    func register(_ combination: KeyCombination, pressed: @escaping @MainActor () -> Void) -> GlobalShortcut.Unregister? {
        log.append("register \(combination.title())")
        guard !refuses else { return nil }
        registered = combination
        press = pressed
        return { [self] in
            log.append("unregister \(combination.title())")
            registered = nil
            press = nil
        }
    }
}

/// The Live Captions shortcut: which combinations it can be, how it is recorded and saved,
/// the default at the update, the refusals between it and Orra's keys, and that it is off
/// while any key is recorded. Key codes of function keys and named keys keep the notes the
/// same on every keyboard layout.
@MainActor
struct LiveCaptionsShortcutTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()
    let tapSystem = FakeTapSystem()
    let shortcuts = FakeShortcutSystem()

    static let hyper: ModifierSet = [.control, .option, .command]
    static let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    /// ⌃ ⌥ ⌘ C, as the default is on a US layout.
    static let controlOptionCommandC = LiveCaptionsShortcut.defaultShortcut(keyCodeForC: CGKeyCode(kVK_ANSI_C))
    /// ⌃ ⌥ ⌘ F13, which reads the same on every layout.
    static let controlOptionCommandF13 = KeyCombination(modifiers: hyper, keyCode: Int64(kVK_F13))
    static let controlOption = Hotkey.combination(KeyCombination(modifiers: [.control, .option]))

    private func controller(
        talkKey: Hotkey = .rightControl,
        translationKey: Hotkey? = nil,
        shortcut: KeyCombination? = controlOptionCommandF13,
        saved: @escaping (KeyCombination?) -> Void = { _ in }
    ) -> PushToTalkController {
        PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            isTrusted: tapSystem.isTrusted,
            installTap: tapSystem.install,
            talkKey: talkKey,
            translationKey: translationKey,
            liveCaptionsShortcut: shortcut,
            saveLiveCaptionsShortcut: saved,
            registerShortcut: shortcuts.register
        )
    }

    // MARK: Which combinations

    @Test func aShortcutNeedsControlOrCommandOrAFunctionKey() {
        func valid(_ modifiers: ModifierSet, _ keyCode: Int) -> Bool {
            KeyCombination(modifiers: modifiers, keyCode: Int64(keyCode)).isValidShortcut
        }
        #expect(valid(Self.hyper, kVK_ANSI_C))
        #expect(valid([.control], kVK_ANSI_K))
        #expect(valid([.shift, .command], kVK_ANSI_D))
        #expect(valid([.option, .command], kVK_ANSI_C))
        // A function key, alone or with modifiers, as remapped keys and Stream Deck send.
        #expect(valid([], kVK_F13))
        #expect(valid([.shift], kVK_F19))
        #expect(valid([.command], kVK_F5))
        // Keys that type, Option alone or with Shift, which macOS 15 refuses as hot keys.
        #expect(!valid([], kVK_ANSI_C))
        #expect(!valid([.shift], kVK_ANSI_C))
        #expect(!valid([.option], kVK_ANSI_C))
        #expect(!valid([.option, .shift], kVK_ANSI_C))
        #expect(!valid([.option], kVK_F13))
        // Shortcuts of macOS and Escape.
        #expect(!valid([.command], kVK_ANSI_C))
        #expect(!valid([.control], kVK_Space))
        #expect(!valid([.control, .command], kVK_Escape))
        // Modifiers alone.
        #expect(!KeyCombination(modifiers: Self.hyper).isValidShortcut)
    }

    @Test func theRecorderChoosesAtTheKeyDownAndSaysWhyItRefuses() {
        func outcome(_ type: CGEventType, _ keyCode: Int, _ flags: CGEventFlags, keys: [Hotkey] = [.rightControl, .rightOption]) -> LiveCaptionsShortcut.Outcome? {
            LiveCaptionsShortcut.outcome(type: type, keyCode: Int64(keyCode), flags: flags, orraKeys: keys)
        }
        // Modifiers going down decide nothing.
        #expect(outcome(.flagsChanged, kVK_RightControl, .maskControl) == nil)
        #expect(outcome(.keyDown, kVK_F13, Self.hyperFlags) == .chosen(Self.controlOptionCommandF13))
        // The Fn flag that function keys carry on their own is no modifier.
        #expect(outcome(.keyDown, kVK_F13, .maskSecondaryFn) == .chosen(KeyCombination(modifiers: [], keyCode: Int64(kVK_F13))))
        #expect(outcome(.keyDown, kVK_Escape, Self.hyperFlags) == .cancelled)

        let space = outcome(.keyDown, kVK_Space, .maskCommand)
        #expect(space == .rejected(.systemShortcut(KeyCombination(modifiers: .command, keyCode: Int64(kVK_Space)))))
        if case .rejected(let rejection) = space {
            #expect(rejection.message(in: Locale(identifier: "en")) == "⌘ Space is a shortcut of macOS or most apps and can't be the Live Captions shortcut. It would stop working everywhere while Orra runs.")
        }
        let returnKey = outcome(.keyDown, kVK_Return, .maskAlternate)
        #expect(returnKey == .rejected(.notAShortcut))
        #expect(LiveCaptionsShortcut.Rejection.notAShortcut.message(in: Locale(identifier: "en")) == "Use a key with Control or Command, or a function key such as F13.")
        // A function key alone would do, so the note names Option, which macOS refuses.
        #expect(outcome(.keyDown, kVK_F13, .maskAlternate) == .rejected(.onlyOption))
        #expect(outcome(.keyDown, kVK_F5, [.maskAlternate, .maskShift]) == .rejected(.onlyOption))
        #expect(outcome(.keyDown, kVK_ANSI_C, [.maskAlternate, .maskShift]) == .rejected(.notAShortcut))
        #expect(LiveCaptionsShortcut.Rejection.onlyOption.message(in: Locale(identifier: "en")) == "macOS refuses shortcuts with only Option, or Option and Shift. Add Control or Command, or leave Option out.")

        // One of Orra's keys, never swapped.
        let talkKey = Hotkey.combination(Self.controlOptionCommandF13)
        let clash = outcome(.keyDown, kVK_F13, Self.hyperFlags, keys: [talkKey, .rightOption])
        #expect(clash == .rejected(.orraKey(Self.controlOptionCommandF13)))
        if case .rejected(let rejection) = clash {
            #expect(rejection.message(in: Locale(identifier: "en")) == "⌃ ⌥ ⌘ F13 is already one of Orra's keys.")
            #expect(rejection.message(in: Locale(identifier: "zh-Hans")) == "⌃ ⌥ ⌘ F13 已经是 Orra 的按键了。")
        }
    }

    // MARK: Storage and the default

    @Test func theDefaultTypesCOnTheLayoutInUse() {
        let us = LiveCaptionsShortcut.defaultShortcut(keyCodeForC: CGKeyCode(kVK_ANSI_C))
        #expect(us.modifiers == Self.hyper)
        #expect(us.keyCode == Int64(kVK_ANSI_C))
        #expect(us.title() == "⌃ ⌥ ⌘ C")
        // On Dvorak, C is where a US keyboard has I.
        let dvorak = LiveCaptionsShortcut.defaultShortcut(keyCodeForC: CGKeyCode(kVK_ANSI_I))
        #expect(dvorak.keyCode == Int64(kVK_ANSI_I))
        #expect(dvorak.title() == "⌃ ⌥ ⌘ C")
        // A layout without C falls back to the C of a US keyboard.
        #expect(LiveCaptionsShortcut.defaultShortcut(keyCodeForC: nil).keyCode == Int64(kVK_ANSI_C))
        #expect(us.isValidShortcut)
    }

    @Test func theShortcutIsSavedAndNoneIsSavedAsNone() throws {
        try withTestDefaults("LiveCaptionsShortcut.saved") { defaults in
            let fallback = Self.controlOptionCommandC
            #expect(LiveCaptionsShortcutPreference.load(defaultShortcut: fallback, from: defaults) == fallback)
            LiveCaptionsShortcutPreference.save(nil, to: defaults)
            #expect(defaults.string(forKey: "liveCaptionsShortcut") == "none")
            #expect(LiveCaptionsShortcutPreference.load(defaultShortcut: fallback, from: defaults) == nil)
            // F13 alone could never be a talk key, but it can be the shortcut.
            let f13 = KeyCombination(modifiers: [], keyCode: Int64(kVK_F13))
            LiveCaptionsShortcutPreference.save(f13, to: defaults)
            #expect(LiveCaptionsShortcutPreference.load(defaultShortcut: fallback, from: defaults) == f13)
            LiveCaptionsShortcutPreference.save(Self.controlOptionCommandC, to: defaults)
            #expect(defaults.string(forKey: "liveCaptionsShortcut") == "control+option+command|8|C")
            #expect(LiveCaptionsShortcutPreference.load(defaultShortcut: f13, from: defaults)?.title() == "⌃ ⌥ ⌘ C")
            // Something Orra never saves loads as the default.
            defaults.set("option|8|C", forKey: "liveCaptionsShortcut")
            #expect(LiveCaptionsShortcutPreference.load(defaultShortcut: fallback, from: defaults) == fallback)
        }
    }

    @Test func theUpdateGivesEveryoneTheDefaultUnlessAKeyClashes() throws {
        let shortcut = Self.controlOptionCommandC
        func kept(_ keys: [Hotkey]) throws -> (KeyCombination?, String?) {
            var result: (KeyCombination?, String?) = (nil, nil)
            try withTestDefaults("LiveCaptionsShortcut.keep") { defaults in
                let kept = LiveCaptionsShortcutPreference.keep(shortcut, beside: keys, in: defaults)
                result = (kept, defaults.string(forKey: "liveCaptionsShortcut"))
            }
            return result
        }
        #expect(try kept([.rightControl, .rightOption]) == (shortcut, "control+option+command|8|C"))
        #expect(try kept([.fn, .leftCommand]) == (shortcut, "control+option+command|8|C"))
        // A key that is the shortcut, whose C the keyboard tap swallows.
        #expect(try kept([.combination(shortcut), .rightOption]) == (nil, "none"))
        // A key of modifiers only, all in the shortcut, starts a dictation at its press.
        #expect(try kept([Self.controlOption, .rightOption]) == (nil, "none"))
        #expect(try kept([.rightControl, .combination(KeyCombination(modifiers: Self.hyper))]) == (nil, "none"))
        // Modifiers it does not have, or a regular key, leave it alone.
        #expect(try kept([.combination(KeyCombination(modifiers: [.control, .shift])), .rightOption]) == (shortcut, "control+option+command|8|C"))
        #expect(try kept([.combination(KeyCombination(modifiers: [.control, .option], keyCode: Int64(kVK_ANSI_D))), .rightOption]) == (shortcut, "control+option+command|8|C"))
    }

    @Test func theUpdateStepRunsOnceAndKeepsWhatIsSaved() throws {
        try withTestDefaults("LiveCaptionsShortcut.once") { defaults in
            let shortcut = Self.controlOptionCommandC
            #expect(LiveCaptionsShortcutPreference.keep(shortcut, beside: [.rightControl], in: defaults) == shortcut)
            // A key picked later warns in Settings, and never clears the shortcut.
            #expect(LiveCaptionsShortcutPreference.keep(shortcut, beside: [Self.controlOption], in: defaults) == shortcut)
            #expect(defaults.string(forKey: "liveCaptionsShortcut") == "control+option+command|8|C")
            // None stays none.
            LiveCaptionsShortcutPreference.save(nil, to: defaults)
            #expect(LiveCaptionsShortcutPreference.keep(nil, beside: [.rightControl], in: defaults) == nil)
            #expect(defaults.string(forKey: "liveCaptionsShortcut") == "none")
        }
    }

    /// A talk key recorded as ⌃ ⌥ ⌘ C in a version without the shortcut, after it was saved,
    /// keeps working, and the shortcut turns into None.
    @Test func aSavedShortcutThatIsAKeyTurnsIntoNone() throws {
        try withTestDefaults("LiveCaptionsShortcut.savedKey") { defaults in
            let shortcut = Self.controlOptionCommandC
            LiveCaptionsShortcutPreference.save(shortcut, to: defaults)
            // The same keys typed as another character are the same key.
            let talkKey = Hotkey.combination(KeyCombination(modifiers: Self.hyper, keyCode: Int64(kVK_ANSI_C), character: "J"))
            #expect(LiveCaptionsShortcutPreference.keep(shortcut, beside: [talkKey, .rightOption], in: defaults) == nil)
            #expect(defaults.string(forKey: "liveCaptionsShortcut") == "none")
        }
        try withTestDefaults("LiveCaptionsShortcut.savedKey") { defaults in
            // A saved value Orra cannot read loads as the default, which the key then is.
            defaults.set("option|8|C", forKey: "liveCaptionsShortcut")
            let loaded = LiveCaptionsShortcutPreference.load(defaultShortcut: Self.controlOptionCommandC, from: defaults)
            #expect(LiveCaptionsShortcutPreference.keep(loaded, beside: [.combination(Self.controlOptionCommandC)], in: defaults) == nil)
            #expect(defaults.string(forKey: "liveCaptionsShortcut") == "none")
        }
    }

    @Test func launchMigrationsClearTheShortcutBesideAClashingKey() throws {
        try withTestDefaults("LiveCaptionsShortcut.launch") { defaults in
            var saved: [KeyCombination?] = []
            let controller = controller(talkKey: Self.controlOption, shortcut: Self.controlOptionCommandC) { saved.append($0) }
            LaunchMigrations.run(controller, in: defaults)
            #expect(controller.liveCaptionsShortcut == nil)
            #expect(saved == [nil])
            #expect(defaults.string(forKey: "liveCaptionsShortcut") == "none")
        }
        try withTestDefaults("LiveCaptionsShortcut.launch") { defaults in
            let controller = controller(shortcut: Self.controlOptionCommandC)
            LaunchMigrations.run(controller, in: defaults)
            #expect(controller.liveCaptionsShortcut == Self.controlOptionCommandC)
            #expect(defaults.string(forKey: "liveCaptionsShortcut") == "control+option+command|8|C")
        }
    }

    // MARK: Recording

    @Test func pressingAShortcutMakesItTheShortcut() {
        var saved: [KeyCombination?] = []
        let controller = controller(shortcut: nil) { saved.append($0) }
        controller.startChoosingLiveCaptionsShortcut()
        #expect(controller.isChoosingLiveCaptionsShortcut)
        #expect(controller.choosingKeySlot == nil)
        controller.keyChoice(type: .keyDown, keyCode: Int64(kVK_Return), flags: .maskAlternate)
        #expect(controller.shortcutChoiceRejection == .notAShortcut)
        // Modifiers going down keep the note and decide nothing.
        controller.keyChoice(type: .flagsChanged, keyCode: Int64(kVK_Control), flags: .maskControl)
        #expect(controller.shortcutChoiceRejection == .notAShortcut)
        controller.keyChoice(type: .keyDown, keyCode: Int64(kVK_F13), flags: Self.hyperFlags)
        #expect(controller.isChoosingLiveCaptionsShortcut == false)
        #expect(controller.shortcutChoiceRejection == nil)
        #expect(controller.liveCaptionsShortcut == Self.controlOptionCommandF13)
        #expect(saved == [Self.controlOptionCommandF13])
        // None turns it off.
        controller.setLiveCaptionsShortcut(nil)
        #expect(controller.liveCaptionsShortcut == nil)
        #expect(saved == [Self.controlOptionCommandF13, nil])
    }

    @Test func escapeStopsRecordingTheShortcutWithoutAChange() {
        let controller = controller()
        controller.startChoosingLiveCaptionsShortcut()
        controller.keyChoice(type: .keyDown, keyCode: Int64(kVK_Escape), flags: [])
        #expect(controller.isChoosingLiveCaptionsShortcut == false)
        #expect(controller.liveCaptionsShortcut == Self.controlOptionCommandF13)
    }

    @Test func recordingAKeyStopsRecordingTheShortcut() {
        let controller = controller()
        controller.startChoosingLiveCaptionsShortcut()
        controller.keyChoice(type: .keyDown, keyCode: Int64(kVK_Return), flags: [])
        controller.startChoosingKey(for: .talk)
        #expect(controller.isChoosingLiveCaptionsShortcut == false)
        #expect(controller.shortcutChoiceRejection == nil)
        #expect(controller.isChoosingTalkKey)
        controller.startChoosingLiveCaptionsShortcut()
        #expect(controller.choosingKeySlot == nil)
        controller.stopChoosingKey()
        #expect(controller.choosing == nil)
    }

    /// Neither the shortcut nor a key takes the other's combination, and nothing swaps.
    @Test func theShortcutAndTheKeysRefuseEachOther() {
        let talkCombination = KeyCombination(modifiers: [.control, .option], keyCode: Int64(kVK_F14))
        let controller = controller(talkKey: .combination(talkCombination))
        controller.startChoosingLiveCaptionsShortcut()
        controller.keyChoice(type: .keyDown, keyCode: Int64(kVK_F14), flags: [.maskControl, .maskAlternate])
        #expect(controller.shortcutChoiceRejection == .orraKey(talkCombination))
        #expect(controller.isChoosingLiveCaptionsShortcut)
        #expect(controller.liveCaptionsShortcut == Self.controlOptionCommandF13)
        controller.stopChoosingKey()

        for slot in [KeySlot.talk, .translation] {
            controller.startChoosingKey(for: slot)
            controller.keyChoice(type: .keyDown, keyCode: Int64(kVK_F13), flags: Self.hyperFlags)
            #expect(controller.keyChoiceRejection == .liveCaptionsShortcut(Self.controlOptionCommandF13))
            #expect(controller.keyChoiceRejection?.message(in: Locale(identifier: "en"), for: slot) == "⌃ ⌥ ⌘ F13 is the Live Captions shortcut.")
            #expect(controller.choosingKeySlot == slot)
            controller.stopChoosingKey()
        }
        #expect(controller.talkKey == .combination(talkCombination))
        #expect(controller.translationKey == .rightOption)
        #expect(controller.keySwap == nil)
        // Another combination is fine.
        controller.startChoosingKey(for: .talk)
        controller.keyChoice(type: .keyDown, keyCode: Int64(kVK_F15), flags: Self.hyperFlags)
        #expect(controller.talkKey == .combination(KeyCombination(modifiers: Self.hyper, keyCode: Int64(kVK_F15))))
    }

    @Test func settingsWarnsWhenAKeyOfModifiersOnlyIsInTheShortcut() {
        #expect(controller(talkKey: Self.controlOption).liveCaptionsShortcutMayStartDictation)
        // The recorder of the key that is the reason warns too, such as in the welcome window.
        #expect(controller(talkKey: Self.controlOption).liveCaptionsShortcutMayStartDictation(with: .talk))
        #expect(!controller(talkKey: Self.controlOption).liveCaptionsShortcutMayStartDictation(with: .translation))
        #expect(!controller(talkKey: .rightControl).liveCaptionsShortcutMayStartDictation)
        #expect(!controller(talkKey: .combination(KeyCombination(modifiers: [.control, .shift]))).liveCaptionsShortcutMayStartDictation)
        #expect(!controller(talkKey: Self.controlOption, shortcut: nil).liveCaptionsShortcutMayStartDictation)
        // The translation key counts while it is watched.
        let translator = controller(talkKey: .fn, translationKey: .combination(KeyCombination(modifiers: [.option, .command])))
        #expect(!translator.liveCaptionsShortcutMayStartDictation)
        #expect(!translator.liveCaptionsShortcutMayStartDictation(with: .translation))
        translator.setTranslationKeyOn(true)
        #expect(translator.liveCaptionsShortcutMayStartDictation)
        #expect(translator.liveCaptionsShortcutMayStartDictation(with: .translation))
        #expect(!translator.liveCaptionsShortcutMayStartDictation(with: .talk))
        #expect(String(localized: LocalizedStringResource("Pressing \(Self.controlOptionCommandF13.title()) may start a dictation for a moment.", locale: Locale(identifier: "en"))) == "Pressing ⌃ ⌥ ⌘ F13 may start a dictation for a moment.")
    }

    // MARK: The hot key

    @Test func theShortcutIsRegisteredFromTheStartAndPressingItTellsTheApp() {
        let controller = controller()
        var presses = 0
        controller.onLiveCaptionsShortcut = { presses += 1 }
        #expect(shortcuts.log.isEmpty)
        controller.start()
        #expect(shortcuts.log == ["register ⌃ ⌥ ⌘ F13"])
        shortcuts.press?()
        shortcuts.press?()
        #expect(presses == 2)
        controller.setLiveCaptionsShortcut(nil)
        #expect(shortcuts.log == ["register ⌃ ⌥ ⌘ F13", "unregister ⌃ ⌥ ⌘ F13"])
        #expect(shortcuts.registered == nil)
    }

    @Test func theShortcutIsOffWhileAnyKeyIsRecorded() {
        let controller = controller()
        controller.start()
        controller.startChoosingKey(for: .talk)
        #expect(shortcuts.registered == nil)
        // Switching to another recording keeps it off.
        controller.startChoosingKey(for: .translation)
        controller.stopChoosingKey()
        #expect(shortcuts.log == ["register ⌃ ⌥ ⌘ F13", "unregister ⌃ ⌥ ⌘ F13", "register ⌃ ⌥ ⌘ F13"])
        // Recording the shortcut itself, so its press reaches the recorder.
        controller.startChoosingLiveCaptionsShortcut()
        #expect(shortcuts.registered == nil)
        controller.keyChoice(type: .keyDown, keyCode: Int64(kVK_F16), flags: [.maskControl])
        #expect(shortcuts.registered == KeyCombination(modifiers: .control, keyCode: Int64(kVK_F16)))
        #expect(shortcuts.log.suffix(2) == ["unregister ⌃ ⌥ ⌘ F13", "register ⌃ F16"])
        // Recording the same shortcut again registers it again.
        controller.startChoosingLiveCaptionsShortcut()
        controller.keyChoice(type: .keyDown, keyCode: Int64(kVK_F16), flags: [.maskControl])
        #expect(shortcuts.log.suffix(2) == ["unregister ⌃ F16", "register ⌃ F16"])
        // A choice of a talk key brings it back too.
        controller.startChoosingKey(for: .talk)
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: .maskSecondaryFn)
        controller.keyChoice(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: [])
        #expect(controller.talkKey == .fn)
        #expect(shortcuts.registered == KeyCombination(modifiers: .control, keyCode: Int64(kVK_F16)))
    }

    @Test func aShortcutTheSystemRefusedIsTriedAgainAtTheNextChange() {
        shortcuts.refuses = true
        let controller = controller()
        #expect(!controller.liveCaptionsShortcutRefused)
        controller.start()
        #expect(shortcuts.registered == nil)
        // Settings and the Problem Report say so.
        #expect(controller.liveCaptionsShortcutRefused)
        #expect(String(localized: LocalizedStringResource("macOS refused \(Self.controlOptionCommandF13.title()). Another app may already use it.", locale: Locale(identifier: "en"))) == "macOS refused ⌃ ⌥ ⌘ F13. Another app may already use it.")
        shortcuts.refuses = false
        controller.startChoosingKey(for: .talk)
        controller.stopChoosingKey()
        #expect(shortcuts.registered == Self.controlOptionCommandF13)
        #expect(!controller.liveCaptionsShortcutRefused)
        // None is never refused.
        shortcuts.refuses = true
        controller.startChoosingKey(for: .talk)
        controller.stopChoosingKey()
        #expect(controller.liveCaptionsShortcutRefused)
        controller.setLiveCaptionsShortcut(nil)
        #expect(!controller.liveCaptionsShortcutRefused)
    }

    @Test func aHeldShortcutCountsOncePerPress() {
        var presses = ShortcutPresses()
        let start = ContinuousClock.now
        func counts(after elapsed: Duration) -> Bool {
            presses.press(at: start + elapsed)
        }
        #expect(counts(after: .zero))
        // Repeats while it is held.
        #expect(!counts(after: .milliseconds(500)))
        #expect(!counts(after: .milliseconds(530)))
        presses.release()
        #expect(counts(after: .milliseconds(800)))
        // A release that never came is not waited for forever.
        #expect(counts(after: .milliseconds(800) + ShortcutPresses.missedRelease))
    }

    /// Registered right after it was recorded, the shortcut is still held, and presses of
    /// that hold do not turn captions on.
    @Test func aShortcutRegisteredWhileHeldWaitsForItsRelease() {
        let start = ContinuousClock.now
        var presses = ShortcutPresses.held(since: start)
        func counts(after elapsed: Duration) -> Bool {
            presses.press(at: start + elapsed)
        }
        #expect(presses.isDown)
        #expect(!counts(after: .milliseconds(300)))
        #expect(!counts(after: .milliseconds(2000)))
        presses.release()
        #expect(counts(after: .milliseconds(2100)))
    }

    @Test func theHotKeyGetsTheModifiersAsCarbonNamesThem() {
        #expect(GlobalShortcut.carbonModifiers(Self.hyper) == 0x1900)
        #expect(GlobalShortcut.carbonModifiers([.shift]) == 0x0200)
        #expect(GlobalShortcut.carbonModifiers([]) == 0)
    }

    @Test func voiceOverHearsWhetherCaptionsTurnedOnOrOff() {
        #expect(LiveCaptionsShortcut.announcement(captionsOn: true, in: Locale(identifier: "en")) == "Live Captions on")
        #expect(LiveCaptionsShortcut.announcement(captionsOn: false, in: Locale(identifier: "zh-Hans")) == "实时字幕已关闭")
    }
}
