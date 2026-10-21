import Foundation
import Testing
@testable import Orra

/// The language Live Captions translate into: its choices, its default from the user's own
/// language, how each sentence is read, the routes into the target, the prefix caches
/// they keep, and the step that keeps an earlier user's captions in the language they had.
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

    /// Captions offer all four languages, English and the dictation language first, and the
    /// other two as a beta. A target saved while dictating in another language stays what
    /// it is after a change of the dictation language.
    @Test func captionsOfferAllFourLanguages() {
        #expect(CaptionTarget.choices(for: .chinese) == [.english, .chinese, .japanese, .spanish])
        #expect(CaptionTarget.choices(for: .japanese) == [.english, .japanese, .chinese, .spanish])
        #expect(CaptionTarget.choices(for: .spanish) == [.english, .spanish, .chinese, .japanese])
        for language in DictationLanguage.allCases {
            #expect(Set(CaptionTarget.choices(for: language)) == Set(TranslationTarget.allCases))
            #expect(CaptionTarget.choices(for: language).filter { CaptionTarget.isBeta($0, for: language) } == Array(CaptionTarget.choices(for: language).dropFirst(2)))
        }
        #expect(!CaptionTarget.isBeta(.english, for: .japanese))
        #expect(!CaptionTarget.isBeta(.japanese, for: .japanese))
        #expect(CaptionTarget.isBeta(.japanese, for: .chinese))
        #expect(CaptionTarget.isBeta(.chinese, for: .spanish))
        // Picked while dictating in Japanese, then the dictation language changes.
        let cleanup = cleanup(captionTarget: .japanese) { .english }
        cleanup.setDictationLanguage(.chinese)
        #expect(cleanup.captionTarget == .japanese)
        #expect(cleanup.pickedCaptionTarget == .japanese)
    }

    /// Choosing the target the window or Settings shows already changes nothing, so a
    /// default does not become a pick.
    @Test func choosingTheShownTargetKeepsWhatIsSaved() {
        var saved: [TranslationTarget] = []
        let picked = cleanup(captionTarget: .japanese, saveCaptionTarget: { saved.append($0) }) { .english }
        picked.setDictationLanguage(.chinese)
        picked.pickCaptionTarget(.japanese)
        #expect(picked.pickedCaptionTarget == .japanese)
        #expect(saved.isEmpty)
        picked.pickCaptionTarget(.spanish)
        #expect(picked.pickedCaptionTarget == .spanish)
        #expect(saved == [.spanish])

        let unpicked = cleanup { .chinese }
        unpicked.setDictationLanguage(.chinese)
        unpicked.pickCaptionTarget(.chinese)
        #expect(unpicked.pickedCaptionTarget == nil)
        unpicked.pickCaptionTarget(.english)
        #expect(unpicked.pickedCaptionTarget == .english)
    }

    /// Each sentence is read by its script, whatever the dictation language: kana by the
    /// Japanese rule, Han characters by the Chinese rule, Latin letters by the Spanish rule
    /// when the recognizer finds English or Spanish or the text is short, and anything
    /// else is shown as it was said.
    @Test func eachSentenceIsReadByItsScript() {
        // Kana make Japanese, also with kanji, which the Chinese rule took for Chinese.
        #expect(CaptionTarget.language(of: "今日はありがとうございました。") == .japanese)
        #expect(CaptionTarget.language(of: "明日の会議は十時からです。") == .japanese)
        #expect(CaptionTarget.language(of: "そうですね。") == .japanese)
        #expect(CaptionTarget.language(of: LanguageGuardTests.japanese) == .japanese)
        // English with a few kana stays English.
        #expect(CaptionTarget.language(of: "Let's meet at the カフェ.") == .english)
        // Han characters without kana make Chinese, which the Japanese rule took for
        // Japanese, and Cantonese and mixed Chinese too.
        #expect(CaptionTarget.language(of: "我们开始吧。") == .chinese)
        #expect(CaptionTarget.language(of: "我哋而家开始。") == .chinese)
        #expect(CaptionTarget.language(of: "这个 PR 你帮我 review 一下") == .chinese)
        #expect(CaptionTarget.language(of: LanguageGuardTests.chinese) == .chinese)
        // English with a name in Han characters.
        #expect(CaptionTarget.language(of: "Send it to 王小明.") == .english)
        // The known blind spot: Japanese in Han characters only reads as Chinese.
        #expect(CaptionTarget.language(of: "会議室") == .chinese)
        // Latin letters.
        #expect(CaptionTarget.language(of: "Hello everyone.") == .english)
        #expect(CaptionTarget.language(of: LanguageGuardTests.english) == .english)
        #expect(CaptionTarget.language(of: "Gracias a todos.") == .spanish)
        #expect(CaptionTarget.language(of: LanguageGuardTests.spanish) == .spanish)
        // English full of names or terms, which the recognizer gives to Indonesian with
        // English close behind, stays English, as the language check of captions keeps it.
        #expect(CaptionTarget.language(of: "Next item, Kafka consumer lag.") == .english)
        #expect(CaptionTarget.language(of: "Tokyo, Osaka, Nagoya, Fukuoka stores.") == .english)
        // Other languages in Latin letters, long enough for the recognizer, are shown as
        // they were said.
        #expect(CaptionTarget.language(of: "Nous allons commencer la réunion avec le budget de cette année.") == nil)
        #expect(CaptionTarget.language(of: "Vamos começar a reunião com o orçamento deste ano, está bem?") == nil)
        #expect(CaptionTarget.language(of: "Wir fangen mit dem Budget für dieses Jahr an.") == nil)
        #expect(CaptionTarget.language(of: "Iniziamo la riunione con il bilancio di quest'anno.") == nil)
        #expect(CaptionTarget.language(of: "We beginnen de vergadering met het budget van dit jaar.") == nil)
        #expect(CaptionTarget.language(of: LanguageGuardTests.swedish) == nil)
        // Other scripts.
        #expect(CaptionTarget.language(of: "회의를 시작하겠습니다.") == nil)
        #expect(CaptionTarget.language(of: "Давайте начнём.") == nil)
        // Nothing to translate.
        #expect(CaptionTarget.language(of: "2026") == nil)
        #expect(CaptionTarget.language(of: "！？") == nil)
        #expect(CaptionTarget.language(of: "") == nil)
    }

    /// Latin text too short for the recognizer, which it gives to languages such as Polish
    /// or Catalan, goes to the rule of English and Spanish, so it is not shown as it was
    /// said. A short English line with a word that looks Spanish reads as Spanish, which
    /// the route through English takes care of, see CaptionPipelineTests.
    @Test func shortLatinTextReadsAsEnglishOrSpanish() {
        for text in ["OK", "OK.", "Hi", "Hi.", "Um.", "Yes.", "Thanks."] {
            #expect(CaptionTarget.language(of: text) == .english, "\(text)")
        }
        for text in ["Sí", "Sí.", "Claro", "Claro.", "Dale.", "Listo.", "Te veo later", "Vale."] {
            #expect(CaptionTarget.language(of: text) == .spanish, "\(text)")
        }
        #expect(CaptionTarget.language(of: "Hay fever.") == .spanish)
    }

    /// The table of routes: none into the same language, one between English and another
    /// language, and two through English between Chinese, Japanese and Spanish, the second
    /// from English into the target.
    @Test func theRouteTableGoesThroughEnglishBetweenTheOtherThree() {
        let zhEn = TranslationRoute(.chinese, into: .english)
        let jaEn = TranslationRoute(.japanese, into: .english)
        let esEn = TranslationRoute(.spanish, into: .english)
        let enZh = TranslationRoute(.chinese, into: .chinese)
        let enJa = TranslationRoute(.japanese, into: .japanese)
        let enEs = TranslationRoute(.spanish, into: .spanish)
        #expect(CaptionTarget.hops(from: .chinese, into: .english) == [zhEn])
        #expect(CaptionTarget.hops(from: .japanese, into: .english) == [jaEn])
        #expect(CaptionTarget.hops(from: .spanish, into: .english) == [esEn])
        #expect(CaptionTarget.hops(from: .english, into: .chinese) == [enZh])
        #expect(CaptionTarget.hops(from: .english, into: .japanese) == [enJa])
        #expect(CaptionTarget.hops(from: .english, into: .spanish) == [enEs])
        #expect(CaptionTarget.hops(from: .chinese, into: .japanese) == [zhEn, enJa])
        #expect(CaptionTarget.hops(from: .chinese, into: .spanish) == [zhEn, enEs])
        #expect(CaptionTarget.hops(from: .japanese, into: .chinese) == [jaEn, enZh])
        #expect(CaptionTarget.hops(from: .japanese, into: .spanish) == [jaEn, enEs])
        #expect(CaptionTarget.hops(from: .spanish, into: .chinese) == [esEn, enZh])
        #expect(CaptionTarget.hops(from: .spanish, into: .japanese) == [esEn, enJa])
        for target in TranslationTarget.allCases {
            #expect(CaptionTarget.hops(from: target, into: target).isEmpty)
            #expect(CaptionTarget.hops(from: nil, into: target).isEmpty)
            // Every route a sentence into the target may take: one into it from English
            // and those of the other languages into English.
            #expect(CaptionTarget.routes(into: target).count == 3)
            for source in TranslationTarget.allCases where source != target {
                let hops = CaptionTarget.hops(from: source, into: target)
                #expect(hops.first?.language.translationLanguage == (source == .english ? target : source))
                #expect(hops.last?.target == target)
            }
        }
        #expect(CaptionTarget.table.count == 12)
    }

    /// While captions run, the routes of a sentence in English and of one in the dictation
    /// language are read ahead, each once, and RewriteEngine keeps every route a sentence
    /// into the target may take with the two of the dictation language, four at most.
    @Test func captionRoutesFitFourCaches() {
        #expect(CaptionTarget.preparedRoutes(into: .chinese, for: .chinese) == [TranslationRoute(.chinese, into: .chinese)])
        #expect(CaptionTarget.preparedRoutes(into: .english, for: .chinese) == [TranslationRoute(.chinese, into: .english)])
        #expect(CaptionTarget.preparedRoutes(into: .japanese, for: .chinese) == [TranslationRoute(.japanese, into: .japanese), TranslationRoute(.chinese, into: .english)])
        #expect(CaptionTarget.preparedRoutes(into: .spanish, for: .japanese) == [TranslationRoute(.spanish, into: .spanish), TranslationRoute(.japanese, into: .english)])
        for language in DictationLanguage.allCases {
            for target in TranslationTarget.allCases {
                let kept = TextCleanup.keptRoutes(captionTarget: target, language)
                #expect(kept.count <= TranslationPrefixSlots.captionsLimit)
                #expect(kept.isSuperset(of: language.translationRoutes))
                #expect(kept.isSuperset(of: CaptionTarget.preparedRoutes(into: target, for: language)))
            }
            #expect(TextCleanup.keptRoutes(captionTarget: nil, language) == Set(language.translationRoutes))
        }
        // The worst case: Chinese dictation, Japanese captions of a Spanish meeting.
        #expect(TextCleanup.keptRoutes(captionTarget: .japanese, .chinese) == [
            TranslationRoute(.chinese, into: .english), TranslationRoute(.chinese, into: .chinese),
            TranslationRoute(.spanish, into: .english), TranslationRoute(.japanese, into: .japanese),
        ])
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
        // captions had English and Chinese then, so Japanese is not taken.
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
