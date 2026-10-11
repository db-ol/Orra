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

    @Test func addingToAFullVocabularyShowsTheNoticeThatSaysSo() {
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let full = CorrectionLearning.Learned(correction: suggestion.pair, pairs: [], outcome: .vocabularyFull)
        var added: [String] = []
        var declined: [WordSuggestion] = []
        notice.onDecline = { declined.append($0) }
        // Adding tells that the vocabulary is full while the add runs, as CorrectionLearning does.
        notice.onAdd = { _, word in
            added.append(word)
            notice.show(full)
        }
        notice.suggest(suggestion)
        notice.draft = " 通义千问3 "
        notice.add()
        #expect(added == ["通义千问3"])
        #expect(notice.learned == full)
        #expect(declined.isEmpty)
    }

    @Test func undoClosesTheNoticeAndUndoesTheWord() {
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        var undone: [CorrectionLearning.Learned] = []
        notice.onUndo = { undone.append($0) }
        notice.show(learned)
        notice.undo()
        #expect(undone == [learned])
        #expect(notice.content == nil)
        // An empty field adds nothing.
        var added: [String] = []
        notice.onAdd = { added.append($1) }
        notice.suggest(suggestion)
        notice.draft = "  "
        notice.add()
        #expect(added.isEmpty)
        #expect(notice.suggestion == suggestion)
    }

    @Test func aNewOfferWaitsWhileTheUserEditsTheWord() {
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let other = WordSuggestion(
            change: Correction(heard: "经", corrected: "京"),
            pair: Correction(heard: "北经", corrected: "北京")
        )
        notice.suggest(suggestion)
        notice.setEditing(true)
        notice.draft = "通义"
        notice.suggest(other)
        #expect(notice.suggestion == suggestion)
        #expect(notice.draft == "通义")
        notice.setEditing(false)
        notice.add()
        #expect(notice.suggestion == other)
        #expect(notice.draft == "北京")
    }

    @Test func noticesThatComeTogetherShowInTurn() {
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let other = WordSuggestion(
            change: Correction(heard: "峰", corrected: "枫"),
            pair: Correction(heard: "林峰", corrected: "林枫")
        )
        let later = CorrectionLearning.Learned(
            correction: Correction(heard: "克劳德", corrected: "Claude"),
            pairs: [Correction(heard: "克劳德", corrected: "Claude")],
            outcome: .added
        )
        var declined: [WordSuggestion] = []
        notice.onDecline = { declined.append($0) }
        // Two offers and two learned words in one report, offers first.
        notice.suggest(suggestion)
        notice.suggest(other)
        notice.suggest(other)
        notice.show(learned)
        notice.show(later)
        #expect(notice.suggestion == suggestion)
        #expect(notice.waiting == [.suggestion(other), .learned(later)])
        notice.close()
        #expect(declined == [suggestion])
        #expect(notice.suggestion == other)
        #expect(notice.draft == "林枫")
        notice.close()
        #expect(notice.learned == later)
        // An offer waits behind a learned word, and a learned word replaces it.
        notice.suggest(suggestion)
        #expect(notice.learned == later)
        notice.show(learned)
        #expect(notice.learned == learned)
        #expect(notice.waiting == [.suggestion(suggestion)])
        notice.close()
        #expect(notice.suggestion == suggestion)
        #expect(declined == [suggestion, other])
    }

    @Test func thePanelsKeyStatusHoldsTheCountdown() {
        let start = Date(timeIntervalSince1970: 1_000)
        let notice = LearnedNotice(sleep: { _ in try await Task.sleep(for: .seconds(60)) }, now: { start })
        let owner = LearnedNoticePanel(notice: notice) { _ in }
        let panel = owner.makePanel()
        notice.onChange = nil
        notice.suggest(suggestion)
        // A click into the field makes the panel key: the user edits the word.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        #expect(notice.countdown == nil)
        // A click back into the user's app ends the editing, even when the field keeps its
        // focus inside the panel.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        #expect(notice.countdown == LearnedNotice.Countdown(hidesAt: start.addingTimeInterval(4), seconds: 4))
        withExtendedLifetime(owner) {}
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
