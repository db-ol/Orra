import CoreGraphics
import Foundation
import Testing
@testable import Orra

/// The second talk key: how it is saved, which keys it can be, that either talk key starts
/// a dictation, and the hints that name both.
@MainActor
struct SecondTalkKeyTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()
    let tapSystem = FakeTapSystem()

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "io.github.db-ol.OrraTests.second-key-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: Storage

    @Test func theSecondKeyIsSavedUnderItsOwnKeyAndLeavesTheTalkKeyAlone() throws {
        try withDefaults { defaults in
            TalkKeyPreference.saveHotkey(.fn, to: defaults)
            #expect(SecondTalkKeyPreference.load(talkKey: .fn, translationKey: .rightOption, from: defaults) == nil)
            SecondTalkKeyPreference.save(.rightControl, to: defaults)
            #expect(defaults.string(forKey: "secondTalkKey") == "rightControl")
            #expect(SecondTalkKeyPreference.load(talkKey: .fn, translationKey: .rightOption, from: defaults) == .rightControl)
            // An older Orra reads the list and keeps fn alone.
            #expect(defaults.stringArray(forKey: TalkKeyPreference.defaultsKey) == ["fn"])
            #expect(TalkKeyPreference.load(from: defaults) == .fn)
            SecondTalkKeyPreference.save(nil, to: defaults)
            #expect(defaults.object(forKey: "secondTalkKey") == nil)
            #expect(SecondTalkKeyPreference.load(talkKey: .fn, translationKey: .rightOption, from: defaults) == nil)
        }
    }

    @Test func aSavedSecondKeyThatClashesOrIsUnknownLoadsAsNone() throws {
        try withDefaults { defaults in
            defaults.set("rightControl", forKey: SecondTalkKeyPreference.defaultsKey)
            #expect(SecondTalkKeyPreference.load(talkKey: .rightControl, translationKey: .rightOption, from: defaults) == nil)
            #expect(SecondTalkKeyPreference.load(talkKey: .fn, translationKey: .rightControl, from: defaults) == nil)
            defaults.set("capsLock", forKey: SecondTalkKeyPreference.defaultsKey)
            #expect(SecondTalkKeyPreference.load(talkKey: .fn, translationKey: .rightOption, from: defaults) == nil)
        }
    }

    // MARK: Conflict rules

    @Test func theChoicesLeaveOutTheTalkKeyAndTheTranslationKey() {
        #expect(SecondTalkKey.choices(talkKey: .fn, translationKey: .rightOption) == [.rightControl, .rightCommand, .leftControl, .leftOption, .leftCommand])
        let combination = Hotkey.combination(KeyCombination(modifiers: [.fn, .control]))
        // A combination is no single key, so every single key but the translation key is left.
        #expect(SecondTalkKey.choices(talkKey: combination, translationKey: .rightOption).count == TalkKey.allCases.count - 1)
        #expect(!SecondTalkKey.isAllowed(.fn, talkKey: .fn, translationKey: .rightOption))
        #expect(!SecondTalkKey.isAllowed(.rightOption, talkKey: .fn, translationKey: .rightOption))
        #expect(SecondTalkKey.isAllowed(.rightControl, talkKey: .fn, translationKey: .rightOption))
    }

    @Test func theSuggestedKeyIsRightControlUnlessItIsTaken() {
        #expect(SecondTalkKey.suggested(talkKey: .fn, translationKey: .rightOption) == .rightControl)
        #expect(SecondTalkKey.suggested(talkKey: .fn, translationKey: .rightControl) == .rightOption)
        // fn and Control together: right Control would share a modifier with the talk key.
        let fnControl = Hotkey.combination(KeyCombination(modifiers: [.fn, .control]))
        #expect(SecondTalkKey.suggested(talkKey: fnControl, translationKey: .rightOption) == .rightCommand)
        let everything = Hotkey.combination(KeyCombination(modifiers: [.fn, .control, .option, .command]))
        #expect(SecondTalkKey.suggested(talkKey: everything, translationKey: .rightOption) == nil)
    }

    private func controller(talkKey: Hotkey = .fn, second: TalkKey? = .rightControl, saved: @escaping (TalkKey?) -> Void = { _ in }) -> PushToTalkController {
        PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            isTrusted: tapSystem.isTrusted,
            installTap: tapSystem.install,
            minimumHold: .zero,
            releaseTail: .zero,
            listeningCueDelay: .zero,
            talkKey: talkKey,
            secondTalkKey: second,
            saveSecondTalkKey: saved
        )
    }

    @Test func aSecondKeyEqualToAnotherKeyIsDroppedAtLaunch() {
        #expect(controller(talkKey: .rightControl, second: .rightControl).secondTalkKey == nil)
        // The translation key beside fn is right Option.
        #expect(controller(talkKey: .fn, second: .rightOption).secondTalkKey == nil)
        #expect(controller(talkKey: .fn, second: .rightControl).secondTalkKey == .rightControl)
    }

    @Test func settingTheSecondKeySavesItAndRefusesAClash() {
        var saved: [TalkKey?] = []
        let controller = controller(second: nil) { saved.append($0) }
        controller.setSecondTalkKey(.rightControl)
        controller.setSecondTalkKey(.fn)
        controller.setSecondTalkKey(.rightOption)
        #expect(controller.secondTalkKey == .rightControl)
        controller.setSecondTalkKey(nil)
        #expect(controller.secondTalkKey == nil)
        #expect(saved == [.rightControl, nil])
        #expect(!controller.secondTalkKeyChoices.contains(.fn))
        #expect(!controller.secondTalkKeyChoices.contains(.rightOption))
    }

    @Test func pickingTheSecondKeyAsTheTalkKeySwapsTheTwo() {
        var saved: [TalkKey?] = []
        let controller = controller { saved.append($0) }
        controller.chooseTalkKey(.rightControl)
        #expect(controller.talkKey == .rightControl)
        #expect(controller.secondTalkKey == .fn)
        // A combination cannot be the second key, so the second key goes.
        controller.chooseTalkKey(.combination(KeyCombination(modifiers: [.control, .option])))
        #expect(controller.secondTalkKey == .fn)
        controller.chooseTalkKey(.fn)
        #expect(controller.secondTalkKey == nil)
        #expect(saved == [.fn, nil])
    }

    @Test func pickingTheSecondKeyAsTheTranslationKeyRemovesIt() {
        let controller = controller()
        controller.chooseTranslationKey(.rightControl)
        #expect(controller.translationKey == .rightControl)
        #expect(controller.secondTalkKey == nil)
        #expect(controller.talkKey == .fn)
    }

    // MARK: Either key starts a dictation

    @Test func eitherTalkKeyStartsADictation() async throws {
        let controller = controller()
        controller.start()
        await controller.loadModel()
        let tap = try #require(tapSystem.installed)
        let controlDown = TalkKey.rightControl.downFlag.union(.maskControl)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: controlDown)
        #expect(tap.activeKey == .rightControl)
        #expect(controller.state == .listening)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: [])
        for _ in 0..<1_000 where controller.state != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.state == .idle)
        // fn still works, and its events are swallowed as before.
        #expect(tap.handle(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: .maskSecondaryFn))
        #expect(tap.activeKey == .fn)
        #expect(controller.state == .listening)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.fn.keyCode, flags: [])
    }

    @Test func theSecondKeyFollowsTheTalkKeysModeAndGoesWhenRemoved() async throws {
        let controller = controller()
        controller.setTriggerMode(.doubleTap, for: .talk)
        controller.start()
        await controller.loadModel()
        let tap = try #require(tapSystem.installed)
        let controlDown = TalkKey.rightControl.downFlag.union(.maskControl)
        // In double press mode a single press records nothing.
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: controlDown)
        #expect(controller.state == .idle)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: [])
        controller.setSecondTalkKey(nil)
        controller.setTriggerMode(.hold, for: .talk)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: controlDown)
        #expect(tap.activeKey == nil)
        #expect(controller.state == .idle)
    }

    @Test func aSecondKeyInsideTheTalkCombinationWaitsSoTheCombinationCanTakeOver() async throws {
        let combination = Hotkey.combination(KeyCombination(modifiers: [.control, .option]))
        let controller = controller(talkKey: combination)
        controller.start()
        await controller.loadModel()
        let tap = try #require(tapSystem.installed)
        let controlDown = TalkKey.rightControl.downFlag.union(.maskControl)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightControl.keyCode, flags: controlDown)
        #expect(tap.activeKey == .rightControl)
        // Right Control records silently while it waits.
        #expect(controller.state == .arming)
        _ = tap.handle(type: .flagsChanged, keyCode: TalkKey.rightOption.keyCode, flags: controlDown.union(TalkKey.rightOption.downFlag).union(.maskAlternate))
        #expect(tap.activeKey == combination)
        // The talk combination counts at once and keeps that recording.
        #expect(controller.state == .listening)
    }

    // MARK: Hints

    @Test func theHintsNameBothKeys() {
        let controller = controller()
        #expect(controller.talkHint() == "Hold fn or right Control to talk")
        controller.setTriggerMode(.toggle, for: .talk)
        #expect(controller.talkHint() == "Press fn or right Control to talk, and again to finish")
        controller.setSecondTalkKey(nil)
        #expect(controller.talkHint() == "Press fn to talk, and again to finish")
        let chinese = Locale(identifier: "zh-Hans")
        #expect(Hotkey.fn.talkHint(mode: .hold, secondKey: .rightControl, in: chinese) == "按住地球仪（fn）键或右侧 Control 键说话")
    }
}

/// Telling an external keyboard from the built in one by its registry properties, and the
/// tip that offers a second key.
@MainActor
struct ExternalKeyboardTests {
    @Test func keyboardsAreToldApartByTheirRegistryProperties() {
        let usb: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6, "Transport": "USB", "Product": "USB Keyboard"]
        let bluetooth: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6, "Transport": "Bluetooth Low Energy", "Product": "MX Keys"]
        let classic: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6, "Transport": "Bluetooth", "Product": "Magic Keyboard"]
        #expect(ExternalKeyboard.isExternalKeyboard(usb))
        #expect(ExternalKeyboard.isExternalKeyboard(bluetooth))
        #expect(ExternalKeyboard.isExternalKeyboard(classic))
        // As `ioreg` shows a MacBook's own keyboard on Apple silicon.
        let fifo: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6, "Transport": "FIFO", "Built-In": true, "Product": "Apple Internal Keyboard / Trackpad"]
        #expect(!ExternalKeyboard.isExternalKeyboard(fifo))
        let spi: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6, "Transport": "SPI", "Product": "Apple Internal Keyboard / Trackpad"]
        #expect(!ExternalKeyboard.isExternalKeyboard(spi))
        // An Intel MacBook's own keyboard on USB, with or without the Built-In mark.
        let intel: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6, "Transport": "USB", "Product": "Apple Internal Keyboard / Trackpad"]
        #expect(!ExternalKeyboard.isExternalKeyboard(intel))
        var marked = usb
        marked["Built-In"] = true
        #expect(!ExternalKeyboard.isExternalKeyboard(marked))
        // A mouse that also lists a keyboard usage has the mouse as its primary usage.
        let mouse: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 2, "Transport": "USB", "Product": "Gaming Mouse",
                                    "DeviceUsagePairs": [["DeviceUsagePage": 1, "DeviceUsage": 2], ["DeviceUsagePage": 1, "DeviceUsage": 6]]]
        #expect(!ExternalKeyboard.isExternalKeyboard(mouse))
        // A headset's buttons, and a virtual keyboard without a transport.
        let headset: [String: Any] = ["PrimaryUsagePage": 12, "PrimaryUsage": 1, "Transport": "Audio", "Product": "Headset"]
        #expect(!ExternalKeyboard.isExternalKeyboard(headset))
        let virtual: [String: Any] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6, "Product": "Virtual Keyboard"]
        #expect(!ExternalKeyboard.isExternalKeyboard(virtual))
        #expect(!ExternalKeyboard.isExternalKeyboard([:]))
    }

    private let learned = CorrectionLearning.Learned(
        correction: Correction(heard: "S G Line Omni", corrected: "SGLang-Omni"),
        pairs: [Correction(heard: "S G Line Omni", corrected: "SGLang-Omni")],
        outcome: .added
    )

    private let ready = ExternalKeyboardTip.Situation(
        talkKey: .fn,
        translationKey: .rightOption,
        secondTalkKey: nil,
        externalKeyboard: true,
        setupComplete: true,
        welcomeOpen: false
    )

    @Test func theTipShowsOnlyForAnFnTalkKeyAfterSetup() {
        #expect(ExternalKeyboardTip.key(for: ready) == .rightControl)
        var situation = ready
        situation.talkKey = .combination(KeyCombination(modifiers: [.fn, .option]))
        #expect(ExternalKeyboardTip.key(for: situation) == .rightControl)
        situation.talkKey = .rightControl
        situation.translationKey = .rightOption
        #expect(ExternalKeyboardTip.key(for: situation) == nil)
        situation = ready
        situation.secondTalkKey = .rightCommand
        #expect(ExternalKeyboardTip.key(for: situation) == nil)
        situation = ready
        situation.externalKeyboard = false
        #expect(ExternalKeyboardTip.key(for: situation) == nil)
        situation = ready
        situation.setupComplete = false
        #expect(ExternalKeyboardTip.key(for: situation) == nil)
        situation = ready
        situation.welcomeOpen = true
        #expect(ExternalKeyboardTip.key(for: situation) == nil)
        situation = ready
        situation.translationKey = .rightControl
        #expect(ExternalKeyboardTip.key(for: situation) == .rightOption)
    }

    @Test func theTipShowsOnceEver() throws {
        let suite = "io.github.db-ol.OrraTests.keyboard-tip-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var offered: [TalkKey] = []
        let tip = ExternalKeyboardTip(defaults: defaults) { offered.append($0) }
        var waiting = ready
        waiting.welcomeOpen = true
        tip.check(waiting)
        #expect(offered.isEmpty)
        tip.check(ready)
        tip.check(ready)
        #expect(offered == [.rightControl])
        tip.answer()
        // The next launch never offers it again.
        let next = ExternalKeyboardTip(defaults: defaults) { offered.append($0) }
        next.check(ready)
        #expect(offered == [.rightControl])
        #expect(next.answered)
    }

    @Test func theTipIsCheckedAgainBeforeItAdds() throws {
        let suite = "io.github.db-ol.OrraTests.keyboard-tip-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tip = ExternalKeyboardTip(defaults: defaults) { _ in }
        #expect(tip.stillOffers(.rightControl, in: ready))
        // The user picked a second key, or changed the talk key, while the tip waited.
        var situation = ready
        situation.secondTalkKey = .leftOption
        #expect(!tip.stillOffers(.rightControl, in: situation))
        situation = ready
        situation.talkKey = .rightCommand
        #expect(!tip.stillOffers(.rightControl, in: situation))
        situation = ready
        situation.externalKeyboard = false
        #expect(!tip.stillOffers(.rightControl, in: situation))
        // Right Control became the translation key, so the tip would now offer another key.
        situation = ready
        situation.translationKey = .rightControl
        #expect(!tip.stillOffers(.rightControl, in: situation))
        tip.answer()
        #expect(!tip.stillOffers(.rightControl, in: ready))
    }

    @Test func aWaitingTipThatNoLongerFitsIsDropped() {
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        var applies = true
        notice.keyboardTipApplies = { _ in applies }
        notice.show(learned)
        notice.offerKeyboardTip(.rightControl)
        #expect(notice.waiting == [.keyboardTip(.rightControl)])
        applies = false
        notice.close()
        #expect(notice.content == nil)
        #expect(notice.waiting.isEmpty)
        // One that still fits shows.
        applies = true
        notice.show(learned)
        notice.offerKeyboardTip(.rightControl)
        notice.close()
        #expect(notice.keyboardTip == .rightControl)
    }

    @Test func aFullQueueNeverPushesOutTheTip() {
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let first = WordSuggestion(change: Correction(heard: "一", corrected: "义"), pair: Correction(heard: "通一千问", corrected: "通义千问"))
        notice.suggest(first)
        notice.offerKeyboardTip(.rightControl)
        for index in 0..<LearnedNotice.maximumWaiting + 2 {
            let heard = "词\(index)"
            notice.suggest(WordSuggestion(change: Correction(heard: heard, corrected: "字"), pair: Correction(heard: heard, corrected: "字")))
        }
        #expect(notice.waiting.count == LearnedNotice.maximumWaiting)
        #expect(notice.waiting.first == .keyboardTip(.rightControl))
        notice.close()
        #expect(notice.keyboardTip == .rightControl)
    }

    @Test func theTipTextNamesTheKey() {
        let english = ExternalKeyboardTip.lines(for: .rightControl, in: Locale(identifier: "en"))
        #expect(english.reason == "Some external keyboards never send fn to the Mac.")
        #expect(english.question == "Talk with right Control too?")
        let chinese = ExternalKeyboardTip.lines(for: .rightControl, in: Locale(identifier: "zh-Hans"))
        #expect(chinese.reason == "有些外接键盘的 fn 键传不到 Mac。")
        #expect(chinese.question == "要同时用右侧 Control 键说话吗？")
    }

    @Test func theNoticeAddsTheKeyOrIsDismissed() {
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        var added: [TalkKey] = []
        var dismissed: [TalkKey] = []
        notice.onAddSecondKey = { added.append($0) }
        notice.onDismissTip = { dismissed.append($0) }
        notice.offerKeyboardTip(.rightControl)
        #expect(notice.keyboardTip == .rightControl)
        notice.addSecondKey()
        #expect(notice.content == nil)
        #expect(added == [.rightControl])
        notice.offerKeyboardTip(.rightOption)
        notice.close()
        #expect(dismissed == [.rightOption])
        #expect(added == [.rightControl])
    }

    @Test func aLearnedWordWaitsForTheTip() {
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        notice.offerKeyboardTip(.rightControl)
        notice.show(learned)
        #expect(notice.keyboardTip == .rightControl)
        notice.close()
        #expect(notice.learned == learned)
        // A tip that comes while a word shows waits too.
        notice.offerKeyboardTip(.rightControl)
        #expect(notice.learned == learned)
        notice.close()
        #expect(notice.keyboardTip == .rightControl)
    }
}
