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
        #expect(TalkKey.rightControl.leftKeyFlag?.rawValue == UInt64(NX_DEVICELCTLKEYMASK))
        #expect(TalkKey.rightOption.leftKeyFlag?.rawValue == UInt64(NX_DEVICELALTKEYMASK))
        #expect(TalkKey.rightCommand.leftKeyFlag?.rawValue == UInt64(NX_DEVICELCMDKEYMASK))
    }

    @Test func rightControlIsTheDefault() {
        #expect(TalkKey.defaultKeys == [.rightControl])
    }

    @Test func otherModifiersForFnAreUnchanged() {
        #expect(TalkKey.fn.otherModifiers == [.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }

    @Test func otherModifiersForRightControlIncludeLeftControlAndFn() {
        let others = TalkKey.rightControl.otherModifiers
        #expect(others.contains(TalkKey.rightControl.leftKeyFlag!))
        #expect(others.contains(.maskSecondaryFn))
        #expect(!others.contains(.maskControl))
        #expect(!others.contains(.maskAlphaShift))
    }

    @Test func isDownReadsTheRightBitAndFallsBackToTheSharedFlag() {
        let key = TalkKey.rightControl
        for wasDown in [false, true] {
            #expect(key.isDown(in: [.maskControl, key.downFlag], wasDown: wasDown))
            #expect(!key.isDown(in: [.maskControl, key.leftKeyFlag!], wasDown: wasDown))
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
        #expect(!key.twinIsDown(atReleaseWith: [.maskControl, key.leftKeyFlag!]))
        #expect(!TalkKey.fn.twinIsDown(atReleaseWith: .maskSecondaryFn))
    }

    @Test func onlyTheRightHandModifiersModifyClicks() {
        #expect(TalkKey.allCases.filter(\.modifiesClicks) == [.rightControl, .rightOption, .rightCommand])
    }

    @Test func holdHintNamesTheKeysInMenuOrder() {
        #expect(TalkKey.holdHint(for: [.rightControl]) == "Hold right Control to talk")
        #expect(TalkKey.holdHint(for: [.fn, .rightControl]) == "Hold right Control or fn to talk")
        #expect(TalkKey.holdHint(for: [.fn, .rightOption, .rightControl]) == "Hold right Control, right Option or fn to talk")
        #expect(TalkKey.holdHint(for: []) == "No talk key is set")
    }

    @Test func onlyFnSwallowsItsEvents() {
        #expect(TalkKey.allCases.filter(\.swallowsItsEvents) == [.fn])
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
