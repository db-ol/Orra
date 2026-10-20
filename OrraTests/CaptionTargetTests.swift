import Foundation
import Testing
@testable import Orra

/// The language Live Captions translate into: its choices, its default from the user's own
/// language, what it acts as for the dictation language, how each sentence is read, and
/// the step that keeps an earlier user's captions in the language they had.
@MainActor
struct CaptionTargetTests {
    let temporary = TemporaryModelFolders()

    /// Cleanup and translation with a stand in model that never loads.
    private func cleanup(captionTarget: TranslationTarget? = nil, saveCaptionTarget: @escaping (TranslationTarget) -> Void = { _ in }, defaultCaptionTarget: @escaping () -> TranslationTarget) -> TextCleanup {
        TextCleanup(
            isOn: false,
            save: { _ in },
            captionTarget: captionTarget,
            saveCaptionTarget: saveCaptionTarget,
            defaultCaptionTarget: defaultCaptionTarget,
            models: ModelInstaller(
                manifest: temporary.manifest,
                folders: temporary.folders,
                environment: ModelDownload.Environment(fetch: FileFetch { _, _, _, _, _, _ in throw URLError(.notConnectedToInternet) }, freeSpace: { _ in nil }, sleep: { _ in })
            ),
            engine: CleanupEngine(load: { _ in }, unload: {}, complete: { $0 })
        )
    }

    /// The default for the language Orra shows and the Mac's languages.
    private func defaultTarget(interface: String, macLanguages: [String]) -> TranslationTarget {
        CaptionTargetPreference.defaultTarget(ownLanguage: OwnLanguage.find(interface: interface, macLanguages: macLanguages))
    }

    /// With nothing saved, captions translate into the user's own language, and into
    /// English without one.
    @Test func theDefaultIsYourOwnLanguageOrEnglish() {
        #expect(defaultTarget(interface: "zh-Hans", macLanguages: ["zh-Hans-CN", "en-US"]) == .chinese)
        #expect(defaultTarget(interface: "ja", macLanguages: ["ja-JP"]) == .japanese)
        #expect(defaultTarget(interface: "es-419", macLanguages: ["es-MX"]) == .spanish)
        // Orra in English on a Mac with Chinese second reads an English meeting in Chinese.
        #expect(defaultTarget(interface: "en", macLanguages: ["en-US", "zh-Hans-CN"]) == .chinese)
        #expect(defaultTarget(interface: "en", macLanguages: ["en-US", "ja-JP"]) == .japanese)
        // English picked for Orra on a Spanish Mac.
        #expect(defaultTarget(interface: "en", macLanguages: ["es-ES", "en-US"]) == .spanish)
        // None of the three.
        #expect(defaultTarget(interface: "en", macLanguages: ["en-US"]) == .english)
        #expect(defaultTarget(interface: "en", macLanguages: ["fr-FR", "de-DE"]) == .english)
        // Orra follows the Mac, which shows it in English with English first.
        #expect(CaptionTargetPreference.defaultTarget(ownLanguage: OwnLanguage.current(appLanguage: .system, macLanguages: ["en-US", "zh-Hans-CN"])) == .chinese)
    }

    /// Until the user picks one, the target follows their own language, read each time,
    /// so a language picked for Orra in the welcome window counts at once. A pick stays.
    @Test func theDefaultFollowsYourOwnLanguageUntilAPick() {
        var own: DictationLanguage? = .chinese
        let cleanup = cleanup { CaptionTargetPreference.defaultTarget(ownLanguage: own) }
        #expect(cleanup.captionTarget == .chinese)
        own = .japanese
        #expect(cleanup.captionTarget == .japanese)
        own = nil
        #expect(cleanup.captionTarget == .english)
        #expect(cleanup.pickedCaptionTarget == nil)
        cleanup.setCaptionTarget(.chinese)
        own = .spanish
        #expect(cleanup.captionTarget == .chinese)
        #expect(cleanup.pickedCaptionTarget == .chinese)
    }

    /// Captions offer English and the dictation language, English first. A target saved
    /// for another dictation language acts and shows as the dictation language, stays
    /// saved, and comes back with its language.
    @Test func aTargetForAnotherLanguageActsAsTheDictationLanguage() {
        #expect(CaptionTarget.choices(for: .chinese) == [.english, .chinese])
        #expect(CaptionTarget.choices(for: .japanese) == [.english, .japanese])
        #expect(CaptionTarget.choices(for: .spanish) == [.english, .spanish])
        for language in DictationLanguage.allCases {
            #expect(CaptionTarget.effective(.english, for: language) == .english)
            #expect(CaptionTarget.effective(language.translationLanguage, for: language) == language.translationLanguage)
            for target in TranslationTarget.allCases {
                #expect(CaptionTarget.choices(for: language).contains(CaptionTarget.effective(target, for: language)))
                #expect(language.translationRoutes.contains(CaptionTarget.route(target, in: language)))
            }
        }
        #expect(CaptionTarget.effective(.japanese, for: .chinese) == .chinese)
        #expect(CaptionTarget.effective(.chinese, for: .spanish) == .spanish)
        // Picked while dictating in Japanese, then the dictation language changes.
        let cleanup = cleanup(captionTarget: .japanese) { .english }
        cleanup.setDictationLanguage(.chinese)
        #expect(cleanup.captionTarget == .japanese)
        #expect(cleanup.effectiveCaptionTarget == .chinese)
        cleanup.setDictationLanguage(.japanese)
        #expect(cleanup.effectiveCaptionTarget == .japanese)
    }

    /// Choosing the target the window or Settings shows already changes nothing: a target
    /// saved for another dictation language stays, and a default does not become a pick.
    @Test func choosingTheShownTargetKeepsWhatIsSaved() {
        var saved: [TranslationTarget] = []
        let picked = cleanup(captionTarget: .japanese, saveCaptionTarget: { saved.append($0) }) { .english }
        picked.setDictationLanguage(.chinese)
        #expect(picked.effectiveCaptionTarget == .chinese)
        picked.pickCaptionTarget(.chinese)
        #expect(picked.pickedCaptionTarget == .japanese)
        #expect(saved.isEmpty)
        picked.pickCaptionTarget(.english)
        #expect(picked.pickedCaptionTarget == .english)
        #expect(saved == [.english])

        let unpicked = cleanup { .chinese }
        unpicked.setDictationLanguage(.chinese)
        unpicked.pickCaptionTarget(.chinese)
        #expect(unpicked.pickedCaptionTarget == nil)
        unpicked.pickCaptionTarget(.english)
        #expect(unpicked.pickedCaptionTarget == .english)
    }

    /// Each sentence is read with the rule of the dictation language, except that kana make
    /// a sentence the Chinese rule reads as Chinese, or finds nothing to translate in,
    /// Japanese, and that Han characters without kana make a sentence the Japanese rule
    /// reads as Japanese not Japanese.
    @Test func captionsTellJapaneseAndChineseApart() {
        #expect(CaptionTarget.source(of: "我们开始吧。", in: .chinese) == .partner)
        #expect(CaptionTarget.source(of: "今日はありがとうございました。", in: .chinese) == .other)
        #expect(CaptionTarget.source(of: "明日の会議は十時からです。", in: .chinese) == .other)
        #expect(CaptionTarget.source(of: "Hello everyone.", in: .chinese) == .english)
        // Kana only, which the Chinese rule finds nothing to translate in, is Japanese too.
        #expect(CaptionTarget.source(of: "ありがとう", in: .chinese) == .other)
        #expect(CaptionTarget.source(of: "そうですね。", in: .chinese) == .other)
        // Read as English, which kana do not change, and nothing to translate stays so.
        #expect(CaptionTarget.source(of: "Let's meet at the カフェ.", in: .chinese) == .english)
        #expect(CaptionTarget.source(of: "2026", in: .chinese) == nil)
        #expect(CaptionTarget.source(of: "！？", in: .chinese) == nil)
        #expect(TranslationDirection.source(of: "ありがとう", in: .chinese) == nil)
        // The rule of the translation key is unchanged.
        #expect(TranslationDirection.source(of: "今日はありがとうございました。", in: .chinese) == .partner)

        #expect(CaptionTarget.source(of: "今日はありがとうございました。", in: .japanese) == .partner)
        #expect(CaptionTarget.source(of: "ありがとう", in: .japanese) == .partner)
        #expect(CaptionTarget.source(of: "我们开始吧。", in: .japanese) == .other)
        // Japanese said without any kana goes into English too.
        #expect(CaptionTarget.source(of: "会議室", in: .japanese) == .other)
        #expect(CaptionTarget.source(of: "Hello everyone.", in: .japanese) == .english)
        #expect(TranslationDirection.source(of: "我们开始吧。", in: .japanese) == .partner)

        #expect(CaptionTarget.source(of: "Gracias a todos.", in: .spanish) == .partner)
        #expect(CaptionTarget.source(of: "我们开始吧。", in: .spanish) == .other)
    }

    /// A sentence in the target already needs no translation, on every route. Every other
    /// sentence goes into the target as it acts for the dictation language, and one in
    /// neither language into English.
    @Test func eachSentenceGoesIntoTheTargetUnlessItIsInItAlready() async {
        #expect(CaptionTarget.target(source: .english, into: .chinese, in: .chinese) == .chinese)
        #expect(CaptionTarget.target(source: .english, into: .english, in: .chinese) == nil)
        #expect(CaptionTarget.target(source: .partner, into: .chinese, in: .chinese) == nil)
        #expect(CaptionTarget.target(source: .partner, into: .english, in: .chinese) == .english)
        #expect(CaptionTarget.target(source: .other, into: .chinese, in: .chinese) == .english)
        #expect(CaptionTarget.target(source: .other, into: .english, in: .japanese) == .english)
        #expect(CaptionTarget.target(source: nil, into: .chinese, in: .chinese) == nil)
        // A target saved for Japanese acts as Chinese for Chinese dictation.
        #expect(CaptionTarget.target(source: .english, into: .japanese, in: .chinese) == .chinese)
        #expect(CaptionTarget.target(source: .partner, into: .japanese, in: .chinese) == nil)

        let english = await CaptionTarget.plan(for: "Hello everyone.", into: .chinese, in: .chinese)
        #expect(english?.route == .chinese(.chinese))
        #expect(english?.source == .english)
        let japanese = await CaptionTarget.plan(for: "今日はありがとうございました。", into: .chinese, in: .chinese)
        #expect(japanese?.route == .chinese(.english))
        #expect(japanese?.source == .other)
        let kana = await CaptionTarget.plan(for: "そうですね。", into: .chinese, in: .chinese)
        #expect(kana?.route == .chinese(.english))
        #expect(await CaptionTarget.plan(for: "我们开始吧。", into: .chinese, in: .chinese) == nil)
        #expect(await CaptionTarget.plan(for: "Good morning, everyone.", into: .english, in: .spanish) == nil)
        let spanish = await CaptionTarget.plan(for: "Gracias a todos.", into: .english, in: .spanish)
        #expect(spanish?.route == TranslationRoute(.spanish, into: .english))
    }

    /// An earlier user's captions translated the way the translation key does. Their
    /// caption target is their fixed Translate into when it fits their dictation language,
    /// otherwise their own language when it is a choice, otherwise their dictation language.
    @Test func anEarlierUserKeepsTheLanguageTheirCaptionsHad() {
        // Orra in English, Chinese second, Automatic: an English meeting stays Chinese.
        #expect(CaptionTargetPreference.earlierTarget(direction: .automatic, language: .chinese, ownLanguage: .chinese) == .chinese)
        // A Mac in English only, which got 中文 + English: the dictation language.
        #expect(CaptionTargetPreference.earlierTarget(direction: .automatic, language: .chinese, ownLanguage: nil) == .chinese)
        #expect(CaptionTargetPreference.earlierTarget(direction: .english, language: .chinese, ownLanguage: .chinese) == .english)
        #expect(CaptionTargetPreference.earlierTarget(direction: .chinese, language: .chinese, ownLanguage: nil) == .chinese)
        // A choice saved for Japanese acted as Automatic for Chinese dictation, and
        // Japanese is no choice for captions then.
        #expect(CaptionTargetPreference.earlierTarget(direction: .japanese, language: .chinese, ownLanguage: .japanese) == .chinese)
        #expect(CaptionTargetPreference.earlierTarget(direction: .automatic, language: .japanese, ownLanguage: .japanese) == .japanese)
        #expect(CaptionTargetPreference.earlierTarget(direction: .english, language: .spanish, ownLanguage: .spanish) == .english)
        #expect(CaptionTargetPreference.earlierTarget(direction: .spanish, language: .spanish, ownLanguage: nil) == .spanish)
    }

    /// The step runs at the first launch of this version only. A new user is never taken
    /// for an earlier one, also at the second launch, when they look set up, and a saved
    /// target always stays.
    @Test func theStepRunsOnceAndOnlyForAnEarlierUser() throws {
        try withTestDefaults("CaptionTarget.newUser") { defaults in
            #expect(CaptionTargetPreference.migrate(setUpBefore: false, direction: .automatic, language: .chinese, ownLanguage: .chinese, in: defaults) == nil)
            #expect(CaptionTargetPreference.saved(in: defaults) == nil)
            #expect(defaults.bool(forKey: CaptionTargetPreference.migratedKey))
            #expect(CaptionTargetPreference.migrate(setUpBefore: true, direction: .automatic, language: .chinese, ownLanguage: .chinese, in: defaults) == nil)
            #expect(CaptionTargetPreference.saved(in: defaults) == nil)
        }
        try withTestDefaults("CaptionTarget.earlierUser") { defaults in
            #expect(CaptionTargetPreference.migrate(setUpBefore: true, direction: .english, language: .chinese, ownLanguage: .chinese, in: defaults) == .english)
            #expect(CaptionTargetPreference.saved(in: defaults) == .english)
            // A pick after that is never replaced.
            CaptionTargetPreference.save(.chinese, to: defaults)
            #expect(CaptionTargetPreference.migrate(setUpBefore: true, direction: .english, language: .chinese, ownLanguage: .chinese, in: defaults) == nil)
            #expect(CaptionTargetPreference.saved(in: defaults) == .chinese)
        }
        try withTestDefaults("CaptionTarget.saved") { defaults in
            CaptionTargetPreference.save(.english, to: defaults)
            #expect(CaptionTargetPreference.migrate(setUpBefore: true, direction: .automatic, language: .chinese, ownLanguage: .chinese, in: defaults) == nil)
            #expect(CaptionTargetPreference.saved(in: defaults) == .english)
        }
        try withTestDefaults("CaptionTarget.unknown") { defaults in
            defaults.set("ko", forKey: CaptionTargetPreference.defaultsKey)
            #expect(CaptionTargetPreference.saved(in: defaults) == nil)
        }
    }
}
