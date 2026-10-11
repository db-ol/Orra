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
        #expect(KeyChoice.shiftKeyCodes == [Int64(kVK_Shift), Int64(kVK_RightShift)])
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
        #expect(TalkKey.defaultKeys == [.rightControl])
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

    @Test func holdHintNamesTheKeysInMenuOrder() {
        #expect(TalkKey.holdHint(for: [.rightControl]) == "Hold right Control to talk")
        #expect(TalkKey.holdHint(for: [.fn, .rightControl]) == "Hold right Control or fn to talk")
        #expect(TalkKey.holdHint(for: [.fn, .rightOption, .rightControl]) == "Hold right Control, right Option or fn to talk")
        #expect(TalkKey.holdHint(for: [.fn, .rightOption, .rightCommand, .rightControl]) == "Hold right Control, right Option, right Command or fn to talk")
        #expect(TalkKey.holdHint(for: [.fn, .leftCommand, .rightOption, .rightCommand, .rightControl]) == "Hold right Control, right Option, right Command, left Command or fn to talk")
        #expect(TalkKey.holdHint(for: Set(TalkKey.allCases)) == "Hold right Control, right Option, right Command, left Control, left Option, left Command or fn to talk")
        #expect(TalkKey.holdHint(for: []) == "No talk key is set")
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

/// Pressing a key to choose the talk key.
struct KeyChoiceTests {
    @Test(arguments: TalkKey.allCases)
    func everyTalkKeyIsRecognizedWhenItGoesDown(_ key: TalkKey) {
        let flags = key.downFlag.union(key.sharedFlag ?? [])
        #expect(KeyChoice.press(type: .flagsChanged, keyCode: key.keyCode, flags: flags) == .talkKey(key))
        // Its release means nothing.
        #expect(KeyChoice.press(type: .flagsChanged, keyCode: key.keyCode, flags: []) == nil)
    }

    @Test func aKeyboardWithoutLeftAndRightBitsStillTellsTheKeyByItsCode() {
        #expect(KeyChoice.press(type: .flagsChanged, keyCode: TalkKey.leftCommand.keyCode, flags: .maskCommand) == .talkKey(.leftCommand))
        #expect(KeyChoice.press(type: .flagsChanged, keyCode: TalkKey.rightCommand.keyCode, flags: .maskCommand) == .talkKey(.rightCommand))
    }

    @Test func shiftEscapeAndOtherKeysAreNotTalkKeys() {
        #expect(KeyChoice.press(type: .flagsChanged, keyCode: 0x38, flags: .maskShift) == .shift)
        #expect(KeyChoice.press(type: .flagsChanged, keyCode: 0x3C, flags: .maskShift) == .shift)
        #expect(KeyChoice.press(type: .flagsChanged, keyCode: 0x38, flags: []) == nil)
        #expect(KeyChoice.press(type: .keyDown, keyCode: TalkKeyDetector.escapeKeyCode, flags: []) == .escape)
        #expect(KeyChoice.press(type: .keyDown, keyCode: 0x00, flags: []) == .otherKey)
        // Caps Lock is not offered and means nothing.
        #expect(KeyChoice.press(type: .flagsChanged, keyCode: 0x39, flags: .maskAlphaShift) == nil)
        #expect(KeyChoice.press(type: .keyUp, keyCode: 0x00, flags: []) == nil)
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
            #expect(TalkKeyPreference.load(from: defaults) == TalkKey.defaultKeys)
        }
    }

    @Test func savedKeysComeBack() {
        withDefaults("saved") { defaults in
            TalkKeyPreference.save([.fn, .rightOption], to: defaults)
            #expect(TalkKeyPreference.load(from: defaults) == [.fn, .rightOption])
            #expect(defaults.stringArray(forKey: TalkKeyPreference.defaultsKey) == ["rightOption", "fn"])
        }
    }

    @Test func unknownKeysAreIgnored() {
        withDefaults("unknown") { defaults in
            defaults.set(["leftShift", "fn"], forKey: TalkKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.load(from: defaults) == [.fn])
            defaults.set(["leftShift"], forKey: TalkKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.load(from: defaults) == TalkKey.defaultKeys)
            defaults.set([String](), forKey: TalkKeyPreference.defaultsKey)
            #expect(TalkKeyPreference.load(from: defaults) == TalkKey.defaultKeys)
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
        TalkKeyPreference.save([.fn], to: defaults)
        #expect(TalkKeyPreference.isSaved(in: defaults))
    }
}
