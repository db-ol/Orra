import Foundation
import Testing
@testable import Orra

struct DictationLanguageTests {
    @Test func eachChoiceIsNamedInItsOwnLanguagesWithEnglish() {
        #expect(DictationLanguage.allCases == [.chinese, .japanese, .spanish])
        #expect(DictationLanguage.allCases.map(\.name) == ["中文（普通话和粤语）+ English", "日本語 + English", "Español + English"])
        #expect(DictationLanguage.allCases.map(\.isBeta) == [false, true, true])
    }

    @Test func thePassesAreTheLanguageThenEnglish() {
        #expect(DictationLanguage.chinese.passes == [.chinese, .english])
        #expect(DictationLanguage.japanese.passes == [.japanese, .english])
        #expect(DictationLanguage.spanish.passes == [.spanish, .english])
    }

    /// Only Chinese keeps text in simplified characters and takes the digits of the pass
    /// without the vocabulary, as Orra always did.
    @Test func theStepsForChineseRunForChineseOnly() {
        #expect(DictationLanguage.allCases.map(\.simplifiesCharacters) == [true, false, false])
        #expect(DictationLanguage.allCases.map(\.takesDigitsFromPassWithoutVocabulary) == [true, false, false])
    }

    /// A new user starts with their own language, see OwnLanguage: Japanese or Spanish in
    /// any region, and Chinese for Chinese or none of the three.
    @Test func aNewUserStartsWithTheirOwnLanguage() {
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["ja-JP", "en-US"]) == .japanese)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["ja"]) == .japanese)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["es-419", "en-US"]) == .spanish)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["es-ES"]) == .spanish)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["es-MX"]) == .spanish)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["zh-Hans-CN", "es-ES"]) == .chinese)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["zh-Hant-HK"]) == .chinese)
        // Orra in English, with Japanese or Chinese second.
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["en-US", "ja-JP"]) == .japanese)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["en-US", "zh-Hans-CN"]) == .chinese)
        // Orra in the second language, since Orra has none in the first.
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["de-DE", "ja-JP"]) == .japanese)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["fr-FR", "es-ES"]) == .spanish)
        // A language picked for Orra counts before the Mac's, and English picked on a
        // Japanese Mac keeps Japanese.
        #expect(DictationLanguage.preferred(appLanguage: .japanese, macLanguages: ["en-US"]) == .japanese)
        #expect(DictationLanguage.preferred(appLanguage: .chinese, macLanguages: ["es-ES"]) == .chinese)
        #expect(DictationLanguage.preferred(appLanguage: .english, macLanguages: ["ja-JP", "en-US"]) == .japanese)
        // None of the three.
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["en-US"]) == .chinese)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["pt-BR"]) == .chinese)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: ["fr-FR"]) == .chinese)
        #expect(DictationLanguage.preferred(appLanguage: .system, macLanguages: []) == .chinese)
    }

    @Test func theChoiceIsSavedByName() throws {
        try withTestDefaults("dictationLanguage") { defaults in
            #expect(DictationLanguagePreference.saved(in: defaults) == nil)
            for (language, name) in [(DictationLanguage.japanese, "Japanese"), (.spanish, "Spanish"), (.chinese, "Chinese")] {
                DictationLanguagePreference.save(language, to: defaults)
                #expect(defaults.string(forKey: DictationLanguagePreference.defaultsKey) == name)
                #expect(DictationLanguagePreference.saved(in: defaults) == language)
            }
            // A name Orra does not know, as from a later version, counts as none saved.
            defaults.set("Klingon", forKey: DictationLanguagePreference.defaultsKey)
            #expect(DictationLanguagePreference.saved(in: defaults) == nil)
            #expect(DictationLanguagePreference.load(setUpBefore: true, appLanguage: .system, macLanguages: ["ja-JP"], from: defaults) == .chinese)
        }
    }

    /// A new user starts with their own language, and one who set Orra up before with
    /// Chinese, whatever their own language. A saved choice wins over both.
    @Test func onlyANewUserStartsWithTheirOwnLanguage() throws {
        try withTestDefaults("dictationLanguage") { defaults in
            #expect(DictationLanguagePreference.load(setUpBefore: false, appLanguage: .system, macLanguages: ["ja-JP"], from: defaults) == .japanese)
            #expect(DictationLanguagePreference.load(setUpBefore: false, appLanguage: .system, macLanguages: ["es-ES"], from: defaults) == .spanish)
            #expect(DictationLanguagePreference.load(setUpBefore: false, appLanguage: .system, macLanguages: ["en-US"], from: defaults) == .chinese)
            #expect(DictationLanguagePreference.load(setUpBefore: false, appLanguage: .system, macLanguages: ["en-US", "ja-JP"], from: defaults) == .japanese)
            #expect(DictationLanguagePreference.load(setUpBefore: false, appLanguage: .spanish, macLanguages: ["en-US"], from: defaults) == .spanish)
            #expect(DictationLanguagePreference.load(setUpBefore: true, appLanguage: .system, macLanguages: ["ja-JP"], from: defaults) == .chinese)
            #expect(DictationLanguagePreference.load(setUpBefore: true, appLanguage: .system, macLanguages: ["es-ES"], from: defaults) == .chinese)
            #expect(DictationLanguagePreference.load(setUpBefore: true, appLanguage: .japanese, macLanguages: ["en-US", "ja-JP"], from: defaults) == .chinese)
            DictationLanguagePreference.save(.spanish, to: defaults)
            #expect(DictationLanguagePreference.load(setUpBefore: false, appLanguage: .system, macLanguages: ["ja-JP"], from: defaults) == .spanish)
            #expect(DictationLanguagePreference.load(setUpBefore: true, appLanguage: .system, macLanguages: ["en-US"], from: defaults) == .spanish)
        }
    }

    /// The first launch saves the language a new user started with, so the next launch,
    /// when the user looks set up, keeps it. A saved choice is never replaced, so a later
    /// change of Orra's language or the Mac's leaves it alone.
    @Test func aNewUsersLanguageStaysOnceSetUp() throws {
        try withTestDefaults("dictationLanguage") { defaults in
            let first = DictationLanguagePreference.load(setUpBefore: false, appLanguage: .system, macLanguages: ["en-US", "ja-JP"], from: defaults)
            DictationLanguagePreference.keep(first, in: defaults)
            #expect(DictationLanguagePreference.load(setUpBefore: true, appLanguage: .system, macLanguages: ["en-US", "ja-JP"], from: defaults) == .japanese)
            #expect(DictationLanguagePreference.load(setUpBefore: true, appLanguage: .chinese, macLanguages: ["zh-Hans-CN"], from: defaults) == .japanese)
            DictationLanguagePreference.keep(.chinese, in: defaults)
            #expect(DictationLanguagePreference.saved(in: defaults) == .japanese)
        }
        // A user who set Orra up before keeps Chinese, also after the Mac changes language.
        try withTestDefaults("dictationLanguage") { defaults in
            DictationLanguagePreference.keep(DictationLanguagePreference.load(setUpBefore: true, appLanguage: .system, macLanguages: ["es-ES"], from: defaults), in: defaults)
            #expect(DictationLanguagePreference.load(setUpBefore: true, appLanguage: .system, macLanguages: ["ja-JP"], from: defaults) == .chinese)
        }
    }

    /// Orra's language picked in the welcome window sets the dictation language only on a
    /// Mac not set up at this launch, and only until the user picks a dictation language.
    @Test func onlyANewMacFollowsUntilAPick() throws {
        try withTestDefaults("dictationLanguage") { defaults in
            #expect(!DictationLanguagePreference.isPicked(in: defaults))
            #expect(DictationLanguagePreference.follows(setUpBefore: false, in: defaults))
            #expect(!DictationLanguagePreference.follows(setUpBefore: true, in: defaults))
            // A language Orra saved, at launch or following the welcome window, is no pick.
            DictationLanguagePreference.keep(.japanese, in: defaults)
            DictationLanguagePreference.save(.spanish, to: defaults)
            #expect(DictationLanguagePreference.follows(setUpBefore: false, in: defaults))
            DictationLanguagePreference.savePicked(to: defaults)
            #expect(DictationLanguagePreference.isPicked(in: defaults))
            #expect(defaults.bool(forKey: DictationLanguagePreference.pickedKey))
            #expect(!DictationLanguagePreference.follows(setUpBefore: false, in: defaults))
            #expect(DictationLanguagePreference.saved(in: defaults) == .spanish)
        }
    }
}

/// The dictation language in the welcome window follows Orra's language picked right
/// above it, on a new Mac until the user picks a dictation language.
@MainActor
struct DictationLanguageFollowTests {
    let mic = FakeMicrophone()
    let speech = FakeSpeech()
    let inserter = FakeInserter()

    private func controller(follows: Bool, in defaults: UserDefaults, saved: @escaping (DictationLanguage) -> Void = { _ in }) -> PushToTalkController {
        PushToTalkController(
            capture: mic.capture,
            transcription: speech.transcription,
            insert: inserter.insert,
            dictationLanguage: DictationLanguagePreference.saved(in: defaults) ?? .chinese,
            dictationLanguageFollows: follows,
            saveDictationLanguage: {
                DictationLanguagePreference.save($0, to: defaults)
                saved($0)
            },
            saveDictationLanguagePicked: { DictationLanguagePreference.savePicked(to: defaults) }
        )
    }

    /// Each language picked for Orra gives the dictation language a new user starts with
    /// in it. The follow saves the language but not as a pick, so the next launch, before
    /// setup is done, follows too.
    @Test func theDictationLanguageFollowsOrrasLanguage() throws {
        try withTestDefaults("dictationLanguage.follow") { defaults in
            var saved: [DictationLanguage] = []
            let controller = controller(follows: true, in: defaults) { saved.append($0) }
            controller.followAppLanguage(.japanese, macLanguages: ["en-US"])
            #expect(controller.dictationLanguage == .japanese)
            controller.followAppLanguage(.spanish, macLanguages: ["en-US"])
            #expect(controller.dictationLanguage == .spanish)
            controller.followAppLanguage(.english, macLanguages: ["en-US"])
            #expect(controller.dictationLanguage == .chinese)
            // English picked on a Mac with Japanese keeps Japanese.
            controller.followAppLanguage(.english, macLanguages: ["ja-JP", "en-US"])
            #expect(controller.dictationLanguage == .japanese)
            controller.followAppLanguage(.system, macLanguages: ["ja-JP", "en-US"])
            controller.followAppLanguage(.chinese, macLanguages: ["ja-JP", "en-US"])
            #expect(controller.dictationLanguage == .chinese)
            // A change is saved once, through the same path as a pick.
            #expect(saved == [.japanese, .spanish, .chinese, .japanese, .chinese])
            #expect(DictationLanguagePreference.saved(in: defaults) == .chinese)
            #expect(controller.dictationLanguageFollows)
            #expect(!DictationLanguagePreference.isPicked(in: defaults))
            #expect(DictationLanguagePreference.follows(setUpBefore: false, in: defaults))
        }
    }

    /// A pick in Settings or in the welcome window ends the follow, at this launch and at
    /// the next ones.
    @Test func aPickStopsTheFollow() throws {
        try withTestDefaults("dictationLanguage.pick") { defaults in
            let controller = controller(follows: true, in: defaults)
            controller.followAppLanguage(.japanese, macLanguages: ["en-US"])
            controller.setDictationLanguage(.spanish)
            controller.followAppLanguage(.chinese, macLanguages: ["en-US"])
            #expect(controller.dictationLanguage == .spanish)
            #expect(!controller.dictationLanguageFollows)
            #expect(DictationLanguagePreference.saved(in: defaults) == .spanish)
            #expect(DictationLanguagePreference.isPicked(in: defaults))
            #expect(!DictationLanguagePreference.follows(setUpBefore: false, in: defaults))
            let nextLaunch = self.controller(follows: DictationLanguagePreference.follows(setUpBefore: false, in: defaults), in: defaults)
            nextLaunch.followAppLanguage(.japanese, macLanguages: ["en-US"])
            #expect(nextLaunch.dictationLanguage == .spanish)
        }
        // Picking the language already shown counts as a pick too.
        try withTestDefaults("dictationLanguage.pickSame") { defaults in
            var saved: [DictationLanguage] = []
            let controller = controller(follows: true, in: defaults) { saved.append($0) }
            controller.setDictationLanguage(.chinese)
            controller.followAppLanguage(.japanese, macLanguages: ["en-US"])
            #expect(controller.dictationLanguage == .chinese)
            #expect(saved.isEmpty)
            #expect(DictationLanguagePreference.isPicked(in: defaults))
        }
    }

    /// The welcome window comes back at launch while setup is incomplete, also for a user
    /// who lost a permission. On a Mac set up before, Orra's language never moves the
    /// dictation language.
    @Test func aMacSetUpBeforeNeverFollows() throws {
        try withTestDefaults("dictationLanguage.setUp") { defaults in
            DictationLanguagePreference.keep(.chinese, in: defaults)
            var saved: [DictationLanguage] = []
            let controller = controller(follows: DictationLanguagePreference.follows(setUpBefore: true, in: defaults), in: defaults) { saved.append($0) }
            #expect(!controller.dictationLanguageFollows)
            controller.followAppLanguage(.japanese, macLanguages: ["ja-JP"])
            controller.followAppLanguage(.spanish, macLanguages: ["en-US"])
            #expect(controller.dictationLanguage == .chinese)
            #expect(saved.isEmpty)
            #expect(DictationLanguagePreference.saved(in: defaults) == .chinese)
        }
    }
}
