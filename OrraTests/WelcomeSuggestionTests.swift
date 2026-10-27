import Foundation
import Testing
@testable import Orra

/// What the welcome window suggests once Orra is ready: when it shows, the three rows in
/// English and Chinese, Projects as a fourth where it can be turned on, and the button or On
/// for each.
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
        let rows = WelcomeSuggestion.all(cleanupOn: false, cleanupModelInstalled: false, translationOn: false, locale: english)
        #expect(rows.map(\.kind) == [.cleanup, .translation, .meeting])
        #expect(rows.map(\.title) == ["Cleanup", "Translation", "Meeting interpretation"])
        #expect(rows.map(\.line) == [
            "Removes fillers and fixes what you correct while speaking.",
            "Press right Option to translate, and again to finish. Chinese becomes English, and English becomes Chinese.",
            "Read what others say in your language, and let them hear you in theirs, even in your own voice.",
        ])
        #expect(rows.map(\.button) == ["Turn On in Settings…", "Turn On in Settings…", "Set Up in Settings…"])
        #expect(rows.map(\.note) == [nil, nil, "Live Captions and Speak Translations to Others are under Meeting Interpretation, in Settings and in the Orra menu. Speaking translations needs Translation on."])
        #expect(rows.allSatisfy { !$0.isOn })
        #expect(Set(rows.map(\.symbol)).count == 3)
        #expect(WelcomeSuggestion.heading(locale: english) == "Try next")
    }

    @Test func aFeatureThatIsOnShowsOnWithoutAButton() {
        let rows = WelcomeSuggestion.all(cleanupOn: true, cleanupModelInstalled: true, translationOn: false, locale: english)
        #expect(rows[0].isOn)
        #expect(rows[0].button == nil)
        #expect(rows[1].button == "Turn On in Settings…")
        #expect(WelcomeSuggestion.onLabel(locale: english) == "On")
        let off = WelcomeSuggestion.all(cleanupOn: false, cleanupModelInstalled: true, translationOn: false, locale: english)
        #expect(!off[0].isOn)
        #expect(off[0].button == "Turn On in Settings…")
        let both = WelcomeSuggestion.all(cleanupOn: true, cleanupModelInstalled: true, translationOn: true, locale: english)
        #expect(both.map(\.button) == [nil, nil, "Set Up in Settings…"])
    }

    /// Cleanup is set up on Dictation, translation on Translation, meeting interpretation
    /// on Meeting Interpretation, and Projects on Projects.
    @MainActor @Test func eachButtonOpensThePageOfItsFeature() {
        #expect(WelcomeSuggestion.Kind.allCases.map(\.settingsTab) == [.dictation, .translation, .meeting, .projects])
    }

    /// Projects is the last row on a Mac where it can be turned on: a build that shows it,
    /// with the memory it needs. It says that it is a preview that needs the Mail app, and
    /// shows On while it is on. Elsewhere the three rows stay.
    @Test func projectsShowsOnlyWhereItCanBeTurnedOn() {
        #expect(WelcomeSuggestion.all(cleanupOn: false, cleanupModelInstalled: false, translationOn: false, projectsAvailable: false, locale: english).map(\.kind) == [.cleanup, .translation, .meeting])
        let rows = WelcomeSuggestion.all(cleanupOn: false, cleanupModelInstalled: false, translationOn: false, projectsAvailable: true, locale: english)
        #expect(rows.map(\.kind) == [.cleanup, .translation, .meeting, .projects])
        let projects = rows[3]
        #expect(projects.title == "Projects")
        #expect(projects.line == "Sorts your mail into projects and explains each email with the files of your projects.")
        #expect(projects.note == "A preview. It works with the Mail app on this Mac.")
        #expect(projects.button == "Set Up in Settings…")
        #expect(!projects.isOn)
        #expect(projects.symbol == "briefcase")
        #expect(Set(rows.map(\.symbol)).count == 4)
        let on = WelcomeSuggestion.all(cleanupOn: false, cleanupModelInstalled: false, translationOn: false, projectsAvailable: true, projectsOn: true, locale: english)[3]
        #expect(on.isOn)
        #expect(on.button == nil)
        let inChinese = WelcomeSuggestion.all(cleanupOn: false, cleanupModelInstalled: false, translationOn: false, projectsAvailable: true, locale: chinese)[3]
        #expect(inChinese.title == "项目")
        #expect(inChinese.line == "把你的邮件分到各个项目里，并结合你各个项目里的文件解释每封邮件。")
        #expect(inChinese.note == "预览版，适用于这台 Mac 上的“邮件” App。")
        #expect(inChinese.button == "前往设置…")
    }

    /// Step 1 offers the cleanup model's download then, so the row neither says On nor
    /// offers Settings.
    @Test func cleanupOnWithoutItsModelShowsNeitherOnNorAButton() {
        let rows = WelcomeSuggestion.all(cleanupOn: true, cleanupModelInstalled: false, translationOn: false, locale: english)
        #expect(!rows[0].isOn)
        #expect(rows[0].button == nil)
        #expect(rows[1].button == "Turn On in Settings…")
        #expect(rows[2].button == "Set Up in Settings…")
    }

    @Test func inChinese() {
        let rows = WelcomeSuggestion.all(cleanupOn: false, cleanupModelInstalled: false, translationOn: false, locale: chinese)
        #expect(WelcomeSuggestion.heading(locale: chinese) == "还可以试试")
        #expect(rows.map(\.title) == ["整理", "翻译", "会议同传"])
        #expect(rows.map(\.line) == [
            "说完自动去掉语气词，并按你的改口改好。",
            "按右侧 Option 键翻译，再按一下结束。中文变成英文，英文变成中文。",
            "对方说的话，你看到自己语言的字幕。你说自己的语言，对方听到他们的语言，还可以是你的音色。",
        ])
        #expect(rows.map(\.button) == ["在设置中打开…", "在设置中打开…", "前往设置…"])
        #expect(rows[2].note == "实时字幕和为对方朗读译文都在“会议同传”里，设置和 Orra 菜单中都有。朗读译文需要先打开翻译。")
        let on = WelcomeSuggestion.all(cleanupOn: true, cleanupModelInstalled: true, translationOn: false, locale: chinese)
        #expect(on[0].button == nil)
        #expect(WelcomeSuggestion.onLabel(locale: chinese) == "已打开")
    }

    /// The translation line names the dictation language, which translation goes between
    /// with English.
    @Test func theTranslationLineNamesTheDictationLanguage() {
        let line = { (language: DictationLanguage, locale: Locale) in
            WelcomeSuggestion.all(cleanupOn: false, cleanupModelInstalled: false, translationOn: false, language: language, locale: locale)[1].line
        }
        #expect(line(.chinese, english) == "Press right Option to translate, and again to finish. Chinese becomes English, and English becomes Chinese.")
        #expect(line(.japanese, english) == "Press right Option to translate, and again to finish. Japanese becomes English, and English becomes Japanese.")
        #expect(line(.spanish, english) == "Press right Option to translate, and again to finish. Spanish becomes English, and English becomes Spanish.")
        #expect(line(.japanese, Locale(identifier: "ja")) == "右Optionキーを押して翻訳し、もう一度押して終了。日本語は英語に、英語は日本語になります。")
        #expect(line(.spanish, Locale(identifier: "es-419")) == "Presiona la tecla Opción derecha para traducir y otra vez para terminar. El español pasa a inglés y el inglés, a español.")
        #expect(line(.spanish, chinese) == "按右侧 Option 键翻译，再按一下结束。西班牙文变成英文，英文变成西班牙文。")
    }

    /// The translation line says how to use the user's translation key in its mode, as the
    /// Orra menu does, so a user who kept Hold reads Hold.
    @Test func theTranslationLineFollowsTheKeyAndItsMode() {
        let line = { (key: Hotkey, mode: TriggerMode, locale: Locale) in
            WelcomeSuggestion.all(cleanupOn: false, cleanupModelInstalled: false, translationOn: false, translationKey: key, translationMode: mode, locale: locale)[1].line
        }
        #expect(line(.rightOption, .hold, english) == "Hold right Option to translate. Chinese becomes English, and English becomes Chinese.")
        #expect(line(.rightControl, .doubleTap, english) == "Press right Control twice to translate, and once more to finish. Chinese becomes English, and English becomes Chinese.")
        #expect(line(.rightOption, .hold, chinese) == "按住右侧 Option 键翻译。中文变成英文，英文变成中文。")
        for mode in TriggerMode.allCases {
            #expect(line(.rightOption, mode, english).hasPrefix(Hotkey.rightOption.translateHint(mode: mode, in: english)))
        }
    }
}
