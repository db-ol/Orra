import Foundation
import Testing
@testable import Orra

/// What the welcome window suggests once Orra is ready: when it shows, the three rows in
/// English and Chinese, and the button or On for each.
struct WelcomeSuggestionTests {
    private let english = Locale(identifier: "en")
    private let chinese = Locale(identifier: "zh-Hans")
    private let folder = URL(fileURLWithPath: "/tmp/model")

    private func checklist(model: ModelInstaller.State, modelState: PushToTalkController.ModelState = .ready, microphone: MicrophoneAccess = .authorized, hotkeyActive: Bool = true) -> SetupChecklist {
        SetupChecklist(installer: model, modelState: modelState, microphone: microphone, hotkeyActive: hotkeyActive)
    }

    @Test func showsOnlyOnceOrraIsReady() {
        #expect(WelcomeSuggestion.shows(checklist: checklist(model: .installed(folder))))
        #expect(!WelcomeSuggestion.shows(checklist: checklist(model: .missing(bytesPresent: 0))))
        #expect(!WelcomeSuggestion.shows(checklist: checklist(model: .downloading(bytes: 1, source: nil))))
        #expect(!WelcomeSuggestion.shows(checklist: checklist(model: .installed(folder), modelState: .loading)))
        #expect(!WelcomeSuggestion.shows(checklist: checklist(model: .installed(folder), microphone: .notDetermined)))
        #expect(!WelcomeSuggestion.shows(checklist: checklist(model: .installed(folder), hotkeyActive: false)))
    }

    @Test func cleanupOffOffersSettings() {
        let rows = WelcomeSuggestion.all(cleanupOn: false, translationOn: false, locale: english)
        #expect(rows.map(\.kind) == [.cleanup, .translation, .meeting])
        #expect(rows.map(\.title) == ["Cleanup", "Translation", "Meeting interpretation"])
        #expect(rows.map(\.line) == [
            "Removes fillers and fixes what you correct while speaking.",
            "Hold the translation key and speak. Chinese becomes English, and English becomes Chinese.",
            "Read what others say in your language, and let them hear you in theirs, even in your own voice.",
        ])
        #expect(rows.map(\.button) == ["Turn On in Settings…", "Turn On in Settings…", "Set Up in Settings…"])
        #expect(rows.allSatisfy { !$0.isOn })
        #expect(Set(rows.map(\.symbol)).count == 3)
        #expect(WelcomeSuggestion.heading(locale: english) == "Try next")
    }

    @Test func aFeatureThatIsOnShowsOnWithoutAButton() {
        let rows = WelcomeSuggestion.all(cleanupOn: true, translationOn: false, locale: english)
        #expect(rows[0].isOn)
        #expect(rows[0].button == nil)
        #expect(rows[1].button == "Turn On in Settings…")
        #expect(WelcomeSuggestion.onLabel(locale: english) == "On")
        let both = WelcomeSuggestion.all(cleanupOn: true, translationOn: true, locale: english)
        #expect(both.map(\.button) == [nil, nil, "Set Up in Settings…"])
    }

    @Test func inChinese() {
        let rows = WelcomeSuggestion.all(cleanupOn: false, translationOn: false, locale: chinese)
        #expect(WelcomeSuggestion.heading(locale: chinese) == "还可以试试")
        #expect(rows.map(\.title) == ["整理", "翻译", "会议同传"])
        #expect(rows.map(\.line) == [
            "说完自动去掉语气词，并按你的改口改好。",
            "按住翻译键说话，中文变成英文，英文变成中文。",
            "对方说的话，你看到自己语言的字幕。你说自己的语言，对方听到他们的语言，还可以是你的音色。",
        ])
        #expect(rows.map(\.button) == ["在设置中打开…", "在设置中打开…", "前往设置…"])
        let on = WelcomeSuggestion.all(cleanupOn: true, translationOn: false, locale: chinese)
        #expect(on[0].button == nil)
        #expect(WelcomeSuggestion.onLabel(locale: chinese) == "已打开")
    }
}
