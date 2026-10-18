import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import Orra

/// The language picked in the welcome window: which localization it shows, that the window
/// switches to it while Orra runs in another, and when closing the window restarts Orra.
/// The tests run in English, so Chinese, Japanese and Spanish here are always a language
/// Orra did not start with.
@MainActor
struct WelcomeLanguageTests {
    private let available = ["zh-Hans", "ja", "es-419", "en"]
    private let chinese = Locale(identifier: "zh-Hans")
    private let japanese = Locale(identifier: "ja")
    private let spanish = Locale(identifier: "es-419")

    @Test func theMacsChoiceFollowsTheMacsLanguages() {
        #expect(AppLanguage.system.localization(macLanguages: ["en-US", "zh-Hans-US"], available: available) == "en")
        #expect(AppLanguage.system.localization(macLanguages: ["zh-Hans-CN", "en-US"], available: available) == "zh-Hans")
        // Traditional Chinese does not fall back to Simplified.
        #expect(AppLanguage.system.localization(macLanguages: ["zh-Hant-TW", "en-US"], available: available) == "en")
        // A language Orra does not have is passed over.
        #expect(AppLanguage.system.localization(macLanguages: ["fr-FR", "zh-Hans-CN"], available: available) == "zh-Hans")
        #expect(AppLanguage.system.localization(macLanguages: ["fr-FR"], available: available) == "en")
        #expect(AppLanguage.system.localization(macLanguages: [], available: available) == "en")
        #expect(AppLanguage.system.localization(macLanguages: ["ja-JP", "en-US"], available: available) == "ja")
        #expect(AppLanguage.system.localization(macLanguages: ["de-DE", "ja-JP"], available: available) == "ja")
        // Spain's Spanish falls back to the Latin American one.
        #expect(AppLanguage.system.localization(macLanguages: ["es-ES", "en-US"], available: available) == "es-419")
        #expect(AppLanguage.system.localization(macLanguages: ["es-MX"], available: available) == "es-419")
    }

    @Test func aLanguageOfOrrasOwnIgnoresTheMac() {
        #expect(AppLanguage.english.localization(macLanguages: ["zh-Hans-CN"], available: available) == "en")
        #expect(AppLanguage.chinese.localization(macLanguages: ["en-US"], available: available) == "zh-Hans")
        #expect(AppLanguage.chinese.localization() == "zh-Hans")
        #expect(AppLanguage.english.localization() == "en")
        #expect(AppLanguage.japanese.localization(macLanguages: ["zh-Hans-CN"], available: available) == "ja")
        #expect(AppLanguage.japanese.localization() == "ja")
        #expect(AppLanguage.spanish.localization(macLanguages: ["es-ES"], available: available) == "es-419")
        #expect(AppLanguage.spanish.localization() == "es-419")
    }

    @Test func orraStartedInTheTestLanguage() {
        #expect(AppLanguage.launchLocalization == "en")
        #expect(Locale.interface.identifier == "en")
    }

    /// Text built in code, looked up in a language other than the one Orra started with.
    @Test func textBuiltInCodeFollowsThePickedLanguage() {
        #expect(WelcomeWindow.title(in: "zh-Hans") == "欢迎使用 Orra")
        #expect(WelcomeWindow.title(in: "en") == "Welcome to Orra")
        #expect(WelcomeWindow.title(in: "ja") == "ようこそOrraへ")
        #expect(WelcomeWindow.title(in: "es-419") == "Te damos la bienvenida a Orra")
        #expect(TalkKey.rightOption.fullName(in: chinese) == "⌥ 右侧 Option 键（Alt）")
        #expect(TalkKey.rightOption.fullName() == "⌥ Right Option (Alt)")
        #expect(Hotkey.rightControl.talkHint(mode: .hold, in: chinese) == "按住右侧 Control 键说话")
        #expect(KeyName.namedKey(Int64(kVK_Space), locale: chinese) != KeyName.namedKey(Int64(kVK_Space)))
        #expect(KeyRecorder.Rejection.key(keyCode: Int64(kVK_Return)).message(in: chinese) == "“Return”键不能作为说话键。按住它会输入文字或在前台 App 中执行操作。")
        #expect(PushToTalkController.ModelProblem.missing.message(in: chinese) == "这台 Mac 上没有语音模型")
        #expect(ModelInstaller.State.checking.menuLines(total: 1, locale: chinese) == ["正在准备语音模型…"])
        #expect(ModelInstaller.State.downloading(bytes: 0, source: nil).buttonTitle(total: 1, locale: chinese) == "取消下载")
        #expect(ModelInstaller.State.downloading(bytes: 0, source: nil).buttonTitle(total: 1, locale: japanese) == "ダウンロードをキャンセル")
        #expect(ModelInstaller.State.downloading(bytes: 0, source: nil).buttonTitle(total: 1, locale: spanish) == "Cancelar descarga")
        #expect(PushToTalkController.ModelProblem.missing.message(in: japanese) == "このMacに音声認識モデルがありません")
        #expect(PushToTalkController.ModelProblem.missing.message(in: spanish) == "El modelo de transcripción no está en esta Mac")
    }

    /// SwiftUI looks up a text literal in the locale of the environment, not only formats
    /// with it: each view is drawn and compared with the text it should show.
    @Test func textLiteralsFollowTheLocaleOfTheEnvironment() {
        func image(_ view: some View) -> Data? {
            let renderer = ImageRenderer(content: view.padding().background(Color.white))
            renderer.scale = 1
            return renderer.nsImage?.tiffRepresentation
        }
        let done = image(Text("Done").environment(\.locale, chinese))
        #expect(done != nil)
        #expect(done == image(Text(verbatim: "完成")))
        #expect(done != image(Text(verbatim: "Done")))
        let button = image(Button("Not Now") {}.environment(\.locale, chinese))
        #expect(button == image(Button {} label: { Text(verbatim: "以后") }))
        #expect(image(Text("Done").environment(\.locale, Locale(identifier: "en"))) == image(Text(verbatim: "Done")))
        // Localized text carries its language, and macOS may draw Japanese text with and
        // without it in different fonts, so both sides name one.
        let hiragino = Font.custom("Hiragino Sans", size: 13)
        #expect(image(Text("Cancel").font(hiragino).environment(\.locale, japanese)) == image(Text(verbatim: "キャンセル").font(hiragino)))
        #expect(image(Text("Done").environment(\.locale, spanish)) == image(Text(verbatim: "Listo")))
    }

    @Test func closingRestartsOnlyWhenSetupIsCompleteAndTheLanguageWasPickedInTheWindow() {
        #expect(WelcomeWindow.restartsOnClose(setupComplete: true, dictating: false, downloading: false, pickedHere: true, otherWindowOpen: false, picked: "zh-Hans", launched: "en"))
        #expect(WelcomeWindow.restartsOnClose(setupComplete: true, dictating: false, downloading: false, pickedHere: true, otherWindowOpen: false, picked: "en", launched: "zh-Hans"))
        // Same as the Mac on a Mac in English, after Orra started in English.
        #expect(!WelcomeWindow.restartsOnClose(setupComplete: true, dictating: false, downloading: false, pickedHere: true, otherWindowOpen: false, picked: "en", launched: "en"))
        // Not Now, maybe during the download: the next launch shows the language.
        #expect(!WelcomeWindow.restartsOnClose(setupComplete: false, dictating: false, downloading: false, pickedHere: true, otherWindowOpen: false, picked: "zh-Hans", launched: "en"))
        #expect(!WelcomeWindow.restartsOnClose(setupComplete: true, dictating: true, downloading: false, pickedHere: true, otherWindowOpen: false, picked: "zh-Hans", launched: "en"))
        // Picked in Settings, which has its own Restart Orra button.
        #expect(!WelcomeWindow.restartsOnClose(setupComplete: true, dictating: false, downloading: false, pickedHere: false, otherWindowOpen: false, picked: "zh-Hans", launched: "en"))
        // The cleanup model is still downloading after the speech model.
        #expect(!WelcomeWindow.restartsOnClose(setupComplete: true, dictating: false, downloading: true, pickedHere: true, otherWindowOpen: false, picked: "zh-Hans", launched: "en"))
        // Settings or Report a Problem is open and may hold something unfinished.
        #expect(!WelcomeWindow.restartsOnClose(setupComplete: true, dictating: false, downloading: false, pickedHere: true, otherWindowOpen: true, picked: "zh-Hans", launched: "en"))
    }
}
