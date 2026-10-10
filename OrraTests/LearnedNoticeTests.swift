import AppKit
import Foundation
import Testing
@testable import Orra

@MainActor
struct LearnedNoticeTests {
    private let learned = CorrectionLearning.Learned(
        correction: Correction(heard: "S G Line Omni", corrected: "SGLang-Omni"),
        pairs: [Correction(heard: "S G Line Omni", corrected: "SGLang-Omni")],
        outcome: .added
    )

    @Test func theNoticeHidesAfterItsTime() async {
        let notice = LearnedNotice(sleep: { _ in await Task.yield() })
        var shown: [LearnedNotice.Content?] = []
        notice.onChange = { shown.append($0) }
        notice.show(learned)
        #expect(notice.learned == learned)
        for _ in 0..<50 where notice.learned != nil { await Task.yield() }
        #expect(notice.learned == nil)
        #expect(shown == [.learned(learned), nil])
    }

    @Test func theNoticeStaysWhileThePointerIsOverIt() async {
        let notice = LearnedNotice(sleep: { _ in await Task.yield() })
        notice.show(learned)
        notice.hold()
        for _ in 0..<50 { await Task.yield() }
        #expect(notice.learned == learned)
        notice.release()
        for _ in 0..<50 where notice.learned != nil { await Task.yield() }
        #expect(notice.learned == nil)
    }

    @Test func theCountdownShowsWhenTheNoticeGoes() {
        let start = Date(timeIntervalSince1970: 1_000)
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) }, now: { start })
        notice.show(learned)
        #expect(notice.countdown == LearnedNotice.Countdown(hidesAt: start.addingTimeInterval(10), seconds: 10))
        notice.hold()
        #expect(notice.countdown == nil)
        notice.release()
        #expect(notice.countdown == LearnedNotice.Countdown(hidesAt: start.addingTimeInterval(4), seconds: 4))
        notice.close()
        #expect(notice.countdown == nil)
    }

    @Test func closingHidesItAtOnce() {
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        notice.show(learned)
        notice.close()
        #expect(notice.learned == nil)
    }

    @Test func thePanelTakesClicksButNeverTheFocus() {
        let panel = LearnedNoticePanel(notice: LearnedNotice()) { _ in }.makePanel()
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.ignoresMouseEvents)
        // While it offers a word, only a click into the field makes it key.
        panel.acceptsKeyboard = true
        #expect(panel.canBecomeKey)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.canBecomeMain)
    }

    private let suggestion = WordSuggestion(
        change: Correction(heard: "一", corrected: "义"),
        pair: Correction(heard: "通一千问", corrected: "通义千问")
    )

    @Test func anOfferedWordThatRunsOutIsDeclined() async {
        let notice = LearnedNotice(sleep: { _ in await Task.yield() })
        var declined: [WordSuggestion] = []
        notice.onDecline = { declined.append($0) }
        notice.suggest(suggestion)
        #expect(notice.suggestion == suggestion)
        #expect(notice.draft == "通义千问")
        for _ in 0..<50 where notice.content != nil { await Task.yield() }
        #expect(notice.content == nil)
        #expect(declined == [suggestion])
    }

    @Test func closingAnOfferedWordDeclinesItAndAddingDoesNot() {
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        var declined: [WordSuggestion] = []
        notice.onDecline = { declined.append($0) }
        notice.suggest(suggestion)
        notice.finish()
        #expect(declined.isEmpty)
        notice.suggest(suggestion)
        notice.close()
        #expect(declined == [suggestion])
        notice.show(learned)
        notice.close()
        #expect(declined == [suggestion])
    }

    @Test func editingTheWordHoldsTheNotice() {
        let start = Date(timeIntervalSince1970: 1_000)
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) }, now: { start })
        notice.suggest(suggestion)
        #expect(notice.countdown == LearnedNotice.Countdown(hidesAt: start.addingTimeInterval(15), seconds: 15))
        notice.setEditing(true)
        #expect(notice.countdown == nil)
        // The pointer leaving while the user types does not start the countdown.
        notice.hold()
        notice.release()
        #expect(notice.countdown == nil)
        notice.setEditing(false)
        #expect(notice.countdown == LearnedNotice.Countdown(hidesAt: start.addingTimeInterval(4), seconds: 4))
    }
}
