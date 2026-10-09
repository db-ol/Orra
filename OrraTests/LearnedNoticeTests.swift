import AppKit
import Testing
@testable import Orra

@MainActor
struct LearnedNoticeTests {
    private let learned = CorrectionLearning.Learned(
        correction: Correction(heard: "S G Line Omni", corrected: "SGLang-Omni"),
        pairs: [Correction(heard: "S G Line Omni", corrected: "SGLang-Omni")],
        addedToVocabulary: true
    )

    @Test func theNoticeHidesAfterItsTime() async {
        let notice = LearnedNotice(sleep: { _ in await Task.yield() })
        var shown: [CorrectionLearning.Learned?] = []
        notice.onChange = { shown.append($0) }
        notice.show(learned)
        #expect(notice.learned == learned)
        for _ in 0..<50 where notice.learned != nil { await Task.yield() }
        #expect(notice.learned == nil)
        #expect(shown == [learned, nil])
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
    }
}
