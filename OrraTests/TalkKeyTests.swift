import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit
import Testing
@testable import Orra

struct TalkKeyTests {
    @Test func keyCodesAndFlagsMatchTheSystemHeaders() {
        #expect(TalkKey.rightControl.keyCode == Int64(kVK_RightControl))
        #expect(TalkKey.rightOption.keyCode == Int64(kVK_RightOption))
        #expect(TalkKey.rightCommand.keyCode == Int64(kVK_RightCommand))
        #expect(TalkKey.fn.keyCode == Int64(kVK_Function))
        #expect(TalkKey.rightControl.downFlag.rawValue == UInt64(NX_DEVICERCTLKEYMASK))
        #expect(TalkKey.rightOption.downFlag.rawValue == UInt64(NX_DEVICERALTKEYMASK))
        #expect(TalkKey.rightCommand.downFlag.rawValue == UInt64(NX_DEVICERCMDKEYMASK))
        #expect(TalkKey.fn.downFlag == .maskSecondaryFn)
        #expect(TalkKey.rightControl.twinFlag?.rawValue == UInt64(NX_DEVICELCTLKEYMASK))
        #expect(TalkKey.rightOption.twinFlag?.rawValue == UInt64(NX_DEVICELALTKEYMASK))
        #expect(TalkKey.rightCommand.twinFlag?.rawValue == UInt64(NX_DEVICELCMDKEYMASK))
        #expect(TalkKey.leftControl.keyCode == Int64(kVK_Control))
        #expect(TalkKey.leftOption.keyCode == Int64(kVK_Option))
        #expect(TalkKey.leftCommand.keyCode == Int64(kVK_Command))
        #expect(TalkKey.leftControl.downFlag.rawValue == UInt64(NX_DEVICELCTLKEYMASK))
        #expect(TalkKey.leftOption.downFlag.rawValue == UInt64(NX_DEVICELALTKEYMASK))
        #expect(TalkKey.leftCommand.downFlag.rawValue == UInt64(NX_DEVICELCMDKEYMASK))
        #expect(TalkKey.leftControl.twinFlag?.rawValue == UInt64(NX_DEVICERCTLKEYMASK))
        #expect(TalkKey.leftOption.twinFlag?.rawValue == UInt64(NX_DEVICERALTKEYMASK))
        #expect(TalkKey.leftCommand.twinFlag?.rawValue == UInt64(NX_DEVICERCMDKEYMASK))
        #expect(TalkKeyDetector.escapeKeyCode == Int64(kVK_Escape))
        #expect(KeyRecorder.shiftKeyCodes == [Int64(kVK_Shift), Int64(kVK_RightShift)])
        #expect(KeyRecorder.capsLockKeyCode == Int64(kVK_CapsLock))
    }

    @Test func savedRawValuesNeverChange() {
        // Saved choices of earlier versions must keep loading.
        #expect(TalkKey.allCases.map(\.rawValue) == ["rightControl", "rightOption", "rightCommand", "leftControl", "leftOption", "leftCommand", "fn"])
    }

    @Test func onlyTheLeftHandKeysWaitBeforeRecording() {
        #expect(TalkKey.allCases.filter(\.waitsBeforeRecording) == [.leftControl, .leftOption, .leftCommand])
    }

    @Test func leftControlIsToldFromRightControl() {
        let key = TalkKey.leftControl
        #expect(key.isDown(in: [.maskControl, key.downFlag], wasDown: false))
        #expect(!key.isDown(in: [.maskControl, TalkKey.rightControl.downFlag], wasDown: false))
        #expect(key.otherModifiers.contains(TalkKey.rightControl.downFlag))
        #expect(!key.otherModifiers.contains(.maskControl))
    }

    @Test func rightControlIsTheDefault() {
        #expect(TalkKey.defaultKey == .rightControl)
    }

    @Test func severalKeysKeepOneByAFixedOrder() {
        #expect(TalkKey.keepOrder.count == TalkKey.allCases.count)
        #expect(Set(TalkKey.keepOrder) == Set(TalkKey.allCases))
        #expect(TalkKey.kept(from: Set(TalkKey.allCases)) == .fn)
        #expect(TalkKey.kept(from: [.rightControl, .fn]) == .fn)
        #expect(TalkKey.kept(from: [.leftCommand, .rightControl, .rightOption]) == .rightControl)
        #expect(TalkKey.kept(from: [.leftOption, .rightCommand]) == .rightCommand)
        #expect(TalkKey.kept(from: [.leftCommand, .leftControl]) == .leftControl)
        #expect(TalkKey.kept(from: [.leftCommand]) == .leftCommand)
        #expect(TalkKey.kept(from: []) == nil)
    }

    @Test func otherModifiersForFnAreUnchanged() {
        #expect(TalkKey.fn.otherModifiers == [.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }

    @Test func otherModifiersForRightControlIncludeLeftControlAndFn() {
        let others = TalkKey.rightControl.otherModifiers
        #expect(others.contains(TalkKey.rightControl.twinFlag!))
        #expect(others.contains(.maskSecondaryFn))
        #expect(!others.contains(.maskControl))
        #expect(!others.contains(.maskAlphaShift))
    }

    @Test func isDownReadsTheRightBitAndFallsBackToTheSharedFlag() {
        let key = TalkKey.rightControl
        for wasDown in [false, true] {
            #expect(key.isDown(in: [.maskControl, key.downFlag], wasDown: wasDown))
            #expect(!key.isDown(in: [.maskControl, key.twinFlag!], wasDown: wasDown))
            #expect(!key.isDown(in: [], wasDown: wasDown))
        }
        // Without bits, the shared flag means down at a press, and the key's own event while
        // it is down is its release.
        #expect(key.isDown(in: .maskControl, wasDown: false))
        #expect(!key.isDown(in: .maskControl, wasDown: true))
        #expect(TalkKey.fn.isDown(in: .maskSecondaryFn, wasDown: false))
        #expect(!TalkKey.fn.isDown(in: .maskControl, wasDown: false))
    }

    @Test func theLeftTwinShowsOnlyWithoutBits() {
        let key = TalkKey.rightControl
        #expect(key.twinIsDown(atReleaseWith: .maskControl))
        #expect(!key.twinIsDown(atReleaseWith: []))
        #expect(!key.twinIsDown(atReleaseWith: [.maskControl, key.twinFlag!]))
        #expect(!TalkKey.fn.twinIsDown(atReleaseWith: .maskSecondaryFn))
    }

    @Test func everyModifierButFnModifiesClicks() {
        #expect(TalkKey.allCases.filter(\.modifiesClicks) == [.rightControl, .rightOption, .rightCommand, .leftControl, .leftOption, .leftCommand])
    }

    @Test func namesShowTheSymbolAndOtherKeyboardsLabels() {
        #expect(TalkKey.rightOption.title == "⌥ Right Option")
        #expect(TalkKey.rightOption.fullName == "⌥ Right Option (Alt)")
        #expect(TalkKey.leftCommand.fullName == "⌘ Left Command (Windows key)")
        #expect(TalkKey.rightControl.fullName == "⌃ Right Control")
        #expect(TalkKey.fn.title == "fn")
        #expect(TalkKey.fn.fullName == "fn (Globe 🌐)")
        #expect(TalkKey.leftOption.otherLabelInParentheses == "(Alt)")
        #expect(TalkKey.rightControl.otherLabelInParentheses == nil)
    }

    @Test func holdHintNamesTheKey() {
        #expect(TalkKey.rightControl.holdHint() == "Hold right Control to talk")
        #expect(TalkKey.leftCommand.holdHint() == "Hold left Command to talk")
        #expect(TalkKey.fn.holdHint() == "Hold fn to talk")
    }

    @Test func onlyFnSwallowsItsEvents() {
        #expect(TalkKey.allCases.filter(\.swallowsItsEvents) == [.fn])
    }

    @Test func finishHintNamesTheKey() {
        #expect(TalkKey.rightControl.finishHint() == "Press right Control to finish")
        #expect(TalkKey.fn.finishHint() == "Press fn to finish")
    }

    @Test func fnIsRecommendedOnlyForABuiltInKeyboard() {
        #expect(KeyboardKind.builtIn.recommendedKey == .fn)
        #expect(KeyboardKind.external.recommendedKey == .rightControl)
    }
}

/// Pressing a key to record the talk key.
struct KeyRecorderTests {
    private static func down(_ key: TalkKey) -> CGEventFlags {
        key.downFlag.union(key.sharedFlag ?? [])
    }

    @Test(arguments: TalkKey.allCases)
    func everyTalkKeyIsChosenAtItsReleaseOnItsOwn(_ key: TalkKey) {
        var recorder = KeyRecorder()
        #expect(recorder.handle(type: .flagsChanged, keyCode: key.keyCode, flags: Self.down(key)) == nil)
        #expect(recorder.handle(type: .flagsChanged, keyCode: key.keyCode, flags: []) == .chosen(key))
        // A release without its press means nothing.
        #expect(recorder.handle(type: .flagsChanged, keyCode: key.keyCode, flags: []) == nil)
    }

    @Test func aKeyboardWithoutLeftAndRightBitsStillTellsTheKeyByItsCode() {
        var recorder = KeyRecorder()
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.leftCommand.keyCode, flags: .maskCommand) == nil)
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.leftCommand.keyCode, flags: []) == .chosen(.leftCommand))
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.rightCommand.keyCode, flags: .maskCommand) == nil)
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.rightCommand.keyCode, flags: .maskCommand) == .chosen(.rightCommand))
    }

    @Test func shortcutsAreCombinations() {
        var recorder = KeyRecorder()
        // Command+C.
        _ = recorder.handle(type: .flagsChanged, keyCode: TalkKey.leftCommand.keyCode, flags: Self.down(.leftCommand))
        #expect(recorder.handle(type: .keyDown, keyCode: 0x08, flags: Self.down(.leftCommand)) == .rejected(.combination(modifiers: "⌘", keyCode: 0x08)))
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.leftCommand.keyCode, flags: []) == nil)
        // Right Option pressed while Command is held.
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: Self.down(.rightOption).union(.maskCommand)) == .rejected(.combination(modifiers: "⌥ ⌘", keyCode: nil)))
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: .maskCommand) == nil)
        // Right Control, then left Control.
        _ = recorder.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.down(.rightControl))
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.leftControl.keyCode, flags: Self.down(.rightControl).union(TalkKey.leftControl.downFlag)) == .rejected(.combination(modifiers: "⌃", keyCode: nil)))
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: Self.down(.leftControl)) == nil)
        // fn, then Shift.
        _ = recorder.handle(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: .maskSecondaryFn)
        #expect(recorder.handle(type: .flagsChanged, keyCode: 0x38, flags: [.maskSecondaryFn, .maskShift]) == .rejected(.combination(modifiers: "fn ⇧", keyCode: nil)))
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: .maskShift) == nil)
        // A letter with Control held, where Control went down before the recording.
        #expect(recorder.handle(type: .keyDown, keyCode: 0x00, flags: .maskControl) == .rejected(.combination(modifiers: "⌃", keyCode: 0x00)))
    }

    @Test func shiftCapsLockAndOtherKeysAreTurnedDown() {
        var recorder = KeyRecorder()
        #expect(recorder.handle(type: .flagsChanged, keyCode: 0x38, flags: .maskShift) == .rejected(.shift))
        #expect(recorder.handle(type: .flagsChanged, keyCode: 0x38, flags: []) == nil)
        #expect(recorder.handle(type: .flagsChanged, keyCode: 0x3C, flags: .maskShift) == .rejected(.shift))
        #expect(recorder.handle(type: .flagsChanged, keyCode: 0x39, flags: .maskAlphaShift) == .rejected(.capsLock))
        #expect(recorder.handle(type: .keyDown, keyCode: 0x00, flags: []) == .rejected(.key(keyCode: 0x00)))
        // A capital letter is the letter's key, not a combination.
        #expect(recorder.handle(type: .keyDown, keyCode: 0x00, flags: .maskShift) == .rejected(.key(keyCode: 0x00)))
        // Arrow keys carry the Fn flag on their own.
        #expect(recorder.handle(type: .keyDown, keyCode: 0x7B, flags: .maskSecondaryFn) == .rejected(.key(keyCode: 0x7B)))
        #expect(recorder.handle(type: .keyDown, keyCode: TalkKeyDetector.escapeKeyCode, flags: []) == .cancelled)
        #expect(recorder.handle(type: .keyDown, keyCode: TalkKeyDetector.globeKeyCode, flags: []) == nil)
        #expect(recorder.handle(type: .keyUp, keyCode: 0x00, flags: []) == nil)
    }

    @Test func aTurnedDownKeyStopsAPendingChoice() {
        var recorder = KeyRecorder()
        _ = recorder.handle(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: .maskSecondaryFn)
        #expect(recorder.handle(type: .keyDown, keyCode: 0x7E, flags: .maskSecondaryFn) == .rejected(.combination(modifiers: "fn", keyCode: 0x7E)))
        #expect(recorder.handle(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: []) == nil)
        #expect(recorder.candidate == nil)
    }

    @Test @MainActor func rejectionsSayWhy() {
        #expect(KeyRecorder.Rejection.shift.message == "Shift can't be the talk key. On its own, it switches input methods between Chinese and English.")
        #expect(KeyRecorder.Rejection.capsLock.message == "Caps Lock can't be the talk key. It turns capitals or the input method on and off.")
        #expect(KeyRecorder.Rejection.combination(modifiers: "⌘", keyCode: Int64(kVK_Return)).message == "⌘ Return is a key combination and can't be the talk key. Press one key on its own.")
        #expect(KeyRecorder.Rejection.combination(modifiers: "⌥ ⌘", keyCode: nil).message == "⌥ ⌘ is a key combination and can't be the talk key. Press one key on its own.")
        #expect(KeyRecorder.Rejection.combination(modifiers: "fn", keyCode: Int64(kVK_UpArrow)).message == "fn Up Arrow is a key combination and can't be the talk key. Press one key on its own.")
        // Right and left Control together show one symbol, so the note names no keys.
        #expect(KeyRecorder.Rejection.combination(modifiers: "⌃", keyCode: nil).message == "A key combination can't be the talk key. Press one key on its own.")
        #expect(KeyRecorder.Rejection.key(keyCode: Int64(kVK_Space)).message == "The Space key can't be the talk key. Holding it would type or do something in the app in front.")
        #expect(KeyRecorder.Rejection.key(keyCode: Int64(kVK_F5)).message == "The F5 key can't be the talk key. Holding it would type or do something in the app in front.")
    }
}

@MainActor
struct KeyNameTests {
    @Test func keysWithoutACharacterHaveNames() {
        #expect(KeyName.name(forKeyCode: Int64(kVK_Return)) == "Return")
        #expect(KeyName.name(forKeyCode: Int64(kVK_Tab)) == "Tab")
        #expect(KeyName.name(forKeyCode: Int64(kVK_LeftArrow)) == "Left Arrow")
        #expect(KeyName.name(forKeyCode: Int64(kVK_ForwardDelete)) == "Forward Delete")
        #expect(KeyName.name(forKeyCode: Int64(kVK_F1)) == "F1")
        #expect(KeyName.name(forKeyCode: Int64(kVK_F20)) == "F20")
    }

    @Test func aLetterKeyIsNamedByTheCharacterItTypes() throws {
        // The letter depends on the keyboard layout, A on ABC and Q on AZERTY.
        let name = try #require(KeyName.name(forKeyCode: Int64(kVK_ANSI_A)))
        #expect(name.count == 1)
        #expect(name == name.uppercased())
    }
}

/// Uses UserDefaults suites of its own, never Orra's real settings. Each test has a fixed
/// suite name, so reruns reuse one empty file per test instead of leaving a new one in
/// ~/Library/Preferences every time, and tests running in parallel never share one.
struct TalkKeyPreferenceTests {
    private func withDefaults(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "io.github.db-ol.OrraTests.TalkKeyPreference.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func nothingSavedMeansTheDefault() {
        withDefaults("nothingSaved") { defaults in
            #expect(TalkKeyPreference.load(from: defaults) == TalkKey.defaultKey)
        }
    }

    @Test func theSavedKeyComesBack() {
        withDefaults("saved") { defaults in
            TalkKeyPreference.save(.rightOption, to: defaults)
            #expect(TalkKeyPreference.load(from: defaults) == .rightOption)
            // Saved as a list of one, the way Orra 0.1.0 reads it.
            #expect(defaults.stringArray(forKey: TalkKeyPreference.defaultsKey) == ["rightOption"])
        }
    }

    @Test func severalSavedKeysKeepOne() {
        withDefaults("several") { defaults in
            // As Orra 0.1.0 saved them, with several keys on.
            defaults.set(["rightControl", "rightOption", "rightCommand", "fn"], forKey: TalkKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.load(from: defaults) == .fn)
            defaults.set(["rightControl", "rightCommand"], forKey: TalkKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.load(from: defaults) == .rightControl)
            defaults.set(["rightOption", "leftControl", "leftCommand"], forKey: TalkKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.load(from: defaults) == .rightOption)
            defaults.set(["leftOption", "leftCommand"], forKey: TalkKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.load(from: defaults) == .leftOption)
        }
    }

    @Test func unknownKeysAreIgnored() {
        withDefaults("unknown") { defaults in
            defaults.set(["leftShift", "leftOption"], forKey: TalkKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.load(from: defaults) == .leftOption)
            defaults.set(["leftShift"], forKey: TalkKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.load(from: defaults) == TalkKey.defaultKey)
            defaults.set([String](), forKey: TalkKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.load(from: defaults) == TalkKey.defaultKey)
        }
    }
}

struct HandsFreePreferenceTests {
    @Test func onUntilTurnedOff() {
        let suite = "io.github.db-ol.OrraTests.HandsFreePreference.onUntilTurnedOff"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(HandsFreePreference.load(from: defaults))
        HandsFreePreference.save(false, to: defaults)
        #expect(HandsFreePreference.load(from: defaults) == false)
        #expect(TalkKeyPreference.isSaved(in: defaults) == false)
        TalkKeyPreference.save(.fn, to: defaults)
        #expect(TalkKeyPreference.isSaved(in: defaults))
    }
}
