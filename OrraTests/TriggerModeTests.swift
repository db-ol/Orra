import CoreGraphics
import Foundation
import Testing
@testable import Orra

/// The trigger modes of a key, press to start and stop and double press, and combinations
/// such as Control and Option or Shift, Command and D, with an explicit clock.
struct TriggerModeTests {
    typealias Decision = TalkKeyDetector.Decision
    typealias Event = PushToTalkStateMachine.Event

    static let c: Int64 = 8
    static let d: Int64 = 2
    static let shift: Int64 = 56
    static let controlOption = Hotkey.combination(KeyCombination(modifiers: [.control, .option]))
    static let shiftCommandD = Hotkey.combination(KeyCombination(modifiers: [.shift, .command], keyCode: 2, character: "D"))
    static let leftControlFlags = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x01)
    static let leftOptionBit = CGEventFlags(rawValue: 0x20)
    static let leftCommandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)

    var now = ContinuousClock.now

    private mutating func advance(_ milliseconds: Int) {
        now = now.advanced(by: .milliseconds(milliseconds))
    }

    private func down(_ key: TalkKey, _ detector: inout TalkKeyDetector, with modifiers: CGEventFlags = []) -> Decision {
        detector.handle(type: .flagsChanged, keyCode: key.keyCode, flags: key.downFlag.union(key.sharedFlag ?? []).union(modifiers), at: now)
    }

    private func up(_ key: TalkKey, _ detector: inout TalkKeyDetector, with modifiers: CGEventFlags = []) -> Decision {
        detector.handle(type: .flagsChanged, keyCode: key.keyCode, flags: modifiers, at: now)
    }

    private func event(_ type: CGEventType, _ keyCode: Int64, _ flags: CGEventFlags, _ detector: inout TalkKeyDetector) -> Decision {
        detector.handle(type: type, keyCode: keyCode, flags: flags, at: now)
    }

    // MARK: Press to start and stop

    @Test mutating func aPressStartsAndTheNextPressFinishes() {
        var detector = TalkKeyDetector(keys: [.rightControl], modes: [.rightControl: .toggle])
        #expect(down(.rightControl, &detector) == Decision(event: .pressed(isRepeat: false), swallow: false))
        advance(80)
        // The recording goes on after the release.
        #expect(up(.rightControl, &detector) == Decision(event: .doublePressed, swallow: false))
        #expect(detector.phase == .handsFree(.rightControl))
        #expect(detector.timer == nil)
        advance(3_000)
        #expect(down(.rightControl, &detector).event == nil)
        #expect(up(.rightControl, &detector) == Decision(event: .released, swallow: false))
        #expect(detector.phase == .up)
    }

    @Test mutating func aLongFirstPressAlsoKeepsRecording() {
        var detector = TalkKeyDetector(keys: [.fn], modes: [.fn: .toggle], handsFreeEnabled: false)
        #expect(down(.fn, &detector) == Decision(event: .pressed(isRepeat: false), swallow: true))
        advance(2_000)
        #expect(up(.fn, &detector) == Decision(event: .doublePressed, swallow: true))
        #expect(detector.phase.isHandsFree)
    }

    @Test mutating func aShortcutWithTheKeyStillCancels() {
        var detector = TalkKeyDetector(keys: [.rightControl], modes: [.rightControl: .toggle])
        #expect(down(.rightControl, &detector).event == .pressed(isRepeat: false))
        #expect(event(.keyDown, Self.c, .maskControl, &detector) == Decision(event: .cancelled, swallow: false))
        #expect(up(.rightControl, &detector).event == nil)
        #expect(detector.phase == .up)
    }

    @Test mutating func aLeftKeyTappedStartsAtItsRelease() {
        var detector = TalkKeyDetector(keys: [.leftCommand], modes: [.leftCommand: .toggle])
        #expect(down(.leftCommand, &detector).event == nil)
        #expect(detector.timer == .leftKeyDelay)
        advance(100)
        #expect(up(.leftCommand, &detector).event == .doublePressed)
        // Command+C stays a shortcut.
        var other = TalkKeyDetector(keys: [.leftCommand], modes: [.leftCommand: .toggle])
        _ = down(.leftCommand, &other)
        #expect(event(.keyDown, Self.c, Self.leftCommandFlags, &other) == .passThrough)
        #expect(up(.leftCommand, &other).event == nil)
        #expect(other.phase == .up)
    }

    @Test mutating func escapeCancelsAndTheModeIsPerKey() {
        var detector = TalkKeyDetector(keys: [.rightControl, .rightOption], modes: [.rightControl: .toggle], handsFreeEnabled: false)
        _ = down(.rightControl, &detector)
        _ = up(.rightControl, &detector)
        #expect(event(.keyDown, TalkKeyDetector.escapeKeyCode, [], &detector) == Decision(event: .cancelled, swallow: true))
        // Its key up stays hidden too.
        #expect(event(.keyUp, TalkKeyDetector.escapeKeyCode, [], &detector).swallow)
        // Right Option has no mode, so it holds.
        #expect(down(.rightOption, &detector).event == .pressed(isRepeat: false))
        advance(500)
        #expect(up(.rightOption, &detector).event == .released)
    }

    // MARK: Double press

    @Test mutating func aDoublePressStartsAndAPressFinishes() {
        var detector = TalkKeyDetector(keys: [.rightControl], modes: [.rightControl: .doubleTap], handsFreeEnabled: false)
        #expect(down(.rightControl, &detector) == Decision(event: nil, swallow: false))
        #expect(detector.timer == .tapLimit)
        advance(80)
        #expect(up(.rightControl, &detector).event == nil)
        #expect(detector.phase == .tapped(.rightControl, recording: false))
        advance(150)
        #expect(down(.rightControl, &detector).event == nil)
        advance(80)
        #expect(up(.rightControl, &detector).event == .doublePressed)
        #expect(detector.phase == .handsFree(.rightControl))
        _ = down(.rightControl, &detector)
        #expect(up(.rightControl, &detector).event == .released)
    }

    @Test mutating func aHoldOrASinglePressDoesNothing() {
        var detector = TalkKeyDetector(keys: [.rightControl], modes: [.rightControl: .doubleTap])
        _ = down(.rightControl, &detector)
        #expect(detector.timerFired(generation: detector.generation) == nil)
        #expect(detector.phase == .cancelled(.rightControl))
        advance(2_000)
        #expect(up(.rightControl, &detector).event == nil)
        #expect(detector.phase == .up)
        // A single tap whose window ends.
        _ = down(.rightControl, &detector)
        _ = up(.rightControl, &detector)
        #expect(detector.timer == .doublePressWindow)
        #expect(detector.timerFired(generation: detector.generation) == nil)
        #expect(detector.phase == .up)
    }

    @Test mutating func turningHandsFreeOffLeavesADoublePressKeyAlone() {
        var detector = TalkKeyDetector(keys: [.rightControl], modes: [.rightControl: .doubleTap])
        _ = down(.rightControl, &detector)
        _ = up(.rightControl, &detector)
        #expect(detector.setHandsFreeEnabled(false) == nil)
        #expect(detector.phase == .tapped(.rightControl, recording: false))
        _ = down(.rightControl, &detector)
        #expect(up(.rightControl, &detector).event == .doublePressed)
    }

    @Test mutating func holdModeKeepsHandsFreeAsBefore() {
        var detector = TalkKeyDetector(keys: [.rightControl], modes: [.rightControl: .hold])
        #expect(down(.rightControl, &detector).event == .pressed(isRepeat: false))
        advance(100)
        #expect(up(.rightControl, &detector).event == .tapped)
        advance(100)
        #expect(down(.rightControl, &detector).event == .pressed(isRepeat: false))
        advance(100)
        #expect(up(.rightControl, &detector).event == .doublePressed)
    }

    // MARK: Combinations of modifiers

    @Test mutating func controlAndOptionHoldLikeAModifier() {
        var detector = TalkKeyDetector(keys: [Self.controlOption], handsFreeEnabled: false)
        // Control alone is not the combination yet.
        #expect(event(.flagsChanged, 59, Self.leftControlFlags, &detector) == .passThrough)
        #expect(detector.phase == .up)
        let both = Self.leftControlFlags.union(.maskAlternate).union(Self.leftOptionBit)
        #expect(event(.flagsChanged, 58, both, &detector) == Decision(event: .pressed(isRepeat: false), swallow: false))
        #expect(detector.phase == .holding(Self.controlOption))
        advance(1_000)
        // Letting go of either ends it. The other one's release passes through.
        #expect(event(.flagsChanged, 58, Self.leftControlFlags, &detector) == Decision(event: .released, swallow: false))
        #expect(event(.flagsChanged, 59, [], &detector) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test mutating func anotherKeyMakesTheCombinationAShortcut() {
        var detector = TalkKeyDetector(keys: [Self.controlOption], handsFreeEnabled: false)
        let both = Self.leftControlFlags.union(.maskAlternate).union(Self.leftOptionBit)
        _ = event(.flagsChanged, 59, Self.leftControlFlags, &detector)
        _ = event(.flagsChanged, 58, both, &detector)
        // Control, Option and Space.
        #expect(event(.keyDown, 49, both, &detector) == Decision(event: .cancelled, swallow: false))
        // Shift as well is another shortcut, so it never starts.
        var other = TalkKeyDetector(keys: [Self.controlOption], handsFreeEnabled: false)
        _ = event(.flagsChanged, Self.shift, .maskShift, &other)
        _ = event(.flagsChanged, 59, Self.leftControlFlags.union(.maskShift), &other)
        #expect(event(.flagsChanged, 58, both.union(.maskShift), &other) == .passThrough)
        #expect(other.phase == .up)
    }

    @Test mutating func aCombinationTakesOverFromOneOfItsModifiersThatWaits() {
        var detector = TalkKeyDetector(keys: [.rightControl, Self.controlOption], delayedKeys: [.rightControl, Self.controlOption])
        let rightControl = TalkKey.rightControl.downFlag.union(.maskControl)
        #expect(event(.flagsChanged, TalkKey.rightControl.keyCode, rightControl, &detector).event == nil)
        #expect(detector.phase == .arming(.rightControl))
        advance(100)
        #expect(event(.flagsChanged, 58, rightControl.union(.maskAlternate).union(Self.leftOptionBit), &detector).event == nil)
        #expect(detector.phase == .arming(Self.controlOption))
        #expect(detector.timerFired(generation: detector.generation) == .pressed(isRepeat: false))
        advance(900)
        #expect(event(.flagsChanged, TalkKey.rightControl.keyCode, Self.leftOptionBit.union(.maskAlternate), &detector).event == .released)
    }

    // MARK: Combinations with a regular key

    @Test mutating func shiftCommandDIsHiddenFromTheAppWhileItMatches() {
        var detector = TalkKeyDetector(keys: [Self.shiftCommandD], handsFreeEnabled: false)
        let flags = Self.leftCommandFlags.union(.maskShift)
        #expect(event(.flagsChanged, 55, Self.leftCommandFlags, &detector) == .passThrough)
        #expect(event(.flagsChanged, Self.shift, flags, &detector) == .passThrough)
        #expect(event(.keyDown, Self.d, flags, &detector) == Decision(event: .pressed(isRepeat: false), swallow: true))
        // Repeats of D stay hidden.
        #expect(event(.keyDown, Self.d, flags, &detector) == Decision(event: nil, swallow: true))
        advance(800)
        #expect(event(.keyUp, Self.d, flags, &detector) == Decision(event: .released, swallow: true))
        // The modifiers always pass through.
        #expect(event(.flagsChanged, Self.shift, Self.leftCommandFlags, &detector) == .passThrough)
        #expect(event(.flagsChanged, 55, [], &detector) == .passThrough)
        // D with Command only, or alone, types as usual.
        #expect(event(.keyDown, Self.d, Self.leftCommandFlags, &detector) == .passThrough)
        #expect(event(.keyUp, Self.d, Self.leftCommandFlags, &detector) == .passThrough)
        #expect(event(.keyDown, Self.d, [], &detector) == .passThrough)
        #expect(detector.phase == .up)
    }

    @Test mutating func lettingGoOfAModifierFirstEndsItAndDsKeyUpStaysHidden() {
        var detector = TalkKeyDetector(keys: [Self.shiftCommandD], handsFreeEnabled: false)
        let flags = Self.leftCommandFlags.union(.maskShift)
        _ = event(.keyDown, Self.d, flags, &detector)
        advance(800)
        #expect(event(.flagsChanged, Self.shift, Self.leftCommandFlags, &detector) == Decision(event: .released, swallow: false))
        #expect(event(.keyUp, Self.d, Self.leftCommandFlags, &detector) == Decision(event: nil, swallow: true))
        #expect(detector.phase == .up)
    }

    @Test mutating func shiftCommandDTogglesAndAnotherModifierCancels() {
        var detector = TalkKeyDetector(keys: [Self.shiftCommandD], modes: [Self.shiftCommandD: .toggle])
        let flags = Self.leftCommandFlags.union(.maskShift)
        #expect(event(.keyDown, Self.d, flags, &detector).event == .pressed(isRepeat: false))
        #expect(event(.keyUp, Self.d, flags, &detector) == Decision(event: .doublePressed, swallow: true))
        // Typing goes on while the dictation runs.
        #expect(event(.keyDown, Self.c, [], &detector) == .passThrough)
        #expect(event(.keyDown, Self.d, flags, &detector) == Decision(event: nil, swallow: true))
        #expect(event(.keyUp, Self.d, flags, &detector) == Decision(event: .released, swallow: true))
        // Option joining during a hold makes it a shortcut.
        var other = TalkKeyDetector(keys: [Self.shiftCommandD], handsFreeEnabled: false)
        _ = event(.keyDown, Self.d, flags, &other)
        #expect(event(.flagsChanged, 58, flags.union(.maskAlternate), &other) == Decision(event: .cancelled, swallow: false))
        #expect(event(.keyUp, Self.d, flags.union(.maskAlternate), &other) == Decision(event: nil, swallow: true))
    }

    @Test mutating func aCombinationIsHiddenWhileAnotherKeyRecords() {
        var detector = TalkKeyDetector(keys: [.rightControl, Self.shiftCommandD], modes: [.rightControl: .toggle])
        _ = down(.rightControl, &detector)
        _ = up(.rightControl, &detector)
        #expect(detector.phase == .handsFree(.rightControl))
        let flags = Self.leftCommandFlags.union(.maskShift)
        #expect(event(.keyDown, Self.d, flags, &detector) == Decision(event: nil, swallow: true))
        #expect(event(.keyUp, Self.d, flags, &detector) == Decision(event: nil, swallow: true))
        #expect(detector.phase == .handsFree(.rightControl))
    }

    // MARK: The types

    @Test func combinationsAreSavedAndReadBack() {
        #expect(KeyCombination(modifiers: [.option, .control]).savedValue == "control+option")
        #expect(KeyCombination(modifiers: [.command, .shift], keyCode: 2, character: "D").savedValue == "shift+command|2|D")
        #expect(KeyCombination(saved: "shift+command|2|D") == KeyCombination(modifiers: [.shift, .command], keyCode: 2))
        #expect(KeyCombination(saved: "shift+command|2|D")?.character == "D")
        #expect(KeyCombination(saved: "fn+control") == KeyCombination(modifiers: [.fn, .control]))
        // Not combinations: one modifier, Shift with a letter, Escape, unknown names.
        #expect(KeyCombination(saved: "control") == nil)
        #expect(KeyCombination(saved: "shift|2|D") == nil)
        #expect(KeyCombination(saved: "command|53|") == nil)
        #expect(KeyCombination(saved: "hyper+control") == nil)
        #expect(KeyCombination(saved: "") == nil)
        // fn never counts with a regular key, because arrows carry its flag.
        #expect(KeyCombination(modifiers: [.fn, .command], keyCode: 2).modifiers == .command)
    }

    @Test func titlesAndHintsNameTheKeys() {
        #expect(Self.controlOption.title() == "⌃ ⌥")
        #expect(Self.shiftCommandD.title() == "⇧ ⌘ D")
        #expect(Hotkey.combination(KeyCombination(modifiers: .command, keyCode: 0x24)).title() == "⌘ Return")
        #expect(Hotkey.rightControl.talkHint(mode: .hold) == "Hold right Control to talk")
        #expect(Hotkey.rightControl.talkHint(mode: .toggle) == "Press right Control to talk, and again to finish")
        #expect(Hotkey.fn.talkHint(mode: .doubleTap) == "Press fn twice to talk, and once more to finish")
        #expect(Self.controlOption.translateHint(mode: .hold) == "Hold ⌃ ⌥ to translate")
        #expect(Hotkey.rightOption.translateHint(mode: .toggle) == "Press right Option to translate, and again to finish")
        #expect(Self.shiftCommandD.finishHint() == "Press ⇧ ⌘ D to finish")
        #expect(TriggerMode.allCases.map { $0.title() } == ["Hold", "Press to start and stop", "Double press"])
    }

    @Test func onlyTheRegularKeyOfACombinationIsSwallowed() {
        #expect(Self.shiftCommandD.swallows(.keyDown))
        #expect(Self.shiftCommandD.swallows(.keyUp))
        #expect(!Self.shiftCommandD.swallows(.flagsChanged))
        #expect(!Self.controlOption.swallows(.flagsChanged))
        #expect(Hotkey.fn.swallows(.flagsChanged))
        #expect(!Hotkey.rightControl.swallows(.flagsChanged))
    }

    @Test func savedModeRawValuesNeverChange() {
        #expect(TriggerMode.allCases.map(\.rawValue) == ["hold", "toggle", "doubleTap"])
        #expect(TriggerMode.defaultMode == .hold)
    }
}

/// Uses UserDefaults suites of its own, never Orra's real settings, as
/// TalkKeyPreferenceTests does.
struct HotkeyPreferenceTests {
    private func withDefaults(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "io.github.db-ol.OrraTests.HotkeyPreference.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func aSavedSingleKeyLoadsAsBefore() {
        withDefaults("single") { defaults in
            #expect(TalkKeyPreference.loadHotkey(from: defaults) == .rightControl)
            // As every earlier Orra saved it.
            defaults.set(["fn"], forKey: TalkKeyPreference.defaultsKey)
            defaults.set("leftOption", forKey: TranslationKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.loadHotkey(from: defaults) == .fn)
            #expect(TranslationKeyPreference.loadHotkey(talkKey: .fn, from: defaults) == .leftOption)
            #expect(TranslationKeyPreference.loadHotkey(talkKey: .leftOption, from: defaults) == .rightOption)
        }
    }

    @Test func aCombinationKeepsTheSingleKeyForAnOlderOrra() {
        withDefaults("combination") { defaults in
            TalkKeyPreference.saveHotkey(.fn, to: defaults)
            let combination = Hotkey.combination(KeyCombination(modifiers: [.shift, .command], keyCode: 2, character: "D"))
            TalkKeyPreference.saveHotkey(combination, to: defaults)
            #expect(TalkKeyPreference.loadHotkey(from: defaults) == combination)
            #expect(TalkKeyPreference.isSaved(in: defaults))
            #expect(defaults.stringArray(forKey: TalkKeyPreference.defaultsKey) == ["fn"])
            // A single key again removes the combination.
            TalkKeyPreference.saveHotkey(.rightOption, to: defaults)
            #expect(TalkKeyPreference.loadHotkey(from: defaults) == .rightOption)
            #expect(defaults.object(forKey: TalkKeyPreference.combinationKey) == nil)
        }
    }

    @Test func aTranslationCombinationComesBack() {
        withDefaults("translation") { defaults in
            let combination = Hotkey.combination(KeyCombination(modifiers: [.control, .option]))
            TranslationKeyPreference.saveHotkey(combination, to: defaults)
            #expect(TranslationKeyPreference.loadHotkey(talkKey: .rightControl, from: defaults) == combination)
            // Never the talk key.
            #expect(TranslationKeyPreference.loadHotkey(talkKey: combination, from: defaults) == .rightOption)
            TranslationKeyPreference.saveHotkey(.leftCommand, to: defaults)
            #expect(TranslationKeyPreference.loadHotkey(talkKey: .rightControl, from: defaults) == .leftCommand)
        }
    }

    @Test func modesAreSavedPerKey() {
        withDefaults("modes") { defaults in
            #expect(TriggerModePreference.load(for: .talk, from: defaults) == .hold)
            TriggerModePreference.save(.toggle, for: .talk, to: defaults)
            TriggerModePreference.save(.doubleTap, for: .translation, to: defaults)
            #expect(TriggerModePreference.load(for: .talk, from: defaults) == .toggle)
            #expect(TriggerModePreference.load(for: .translation, from: defaults) == .doubleTap)
            defaults.set("sometimes", forKey: TriggerModePreference.defaultsKey(for: .talk))
            #expect(TriggerModePreference.load(for: .talk, from: defaults) == .hold)
        }
    }
}
