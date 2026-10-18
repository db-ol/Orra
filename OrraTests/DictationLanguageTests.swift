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

    /// A new user starts with the Mac's first language: Japanese or Spanish in any region,
    /// and Chinese for every other language.
    @Test func aNewUserStartsWithTheMacsFirstLanguage() {
        #expect(DictationLanguage.preferred(macLanguages: ["ja-JP", "en-US"]) == .japanese)
        #expect(DictationLanguage.preferred(macLanguages: ["ja"]) == .japanese)
        #expect(DictationLanguage.preferred(macLanguages: ["es-419", "en-US"]) == .spanish)
        #expect(DictationLanguage.preferred(macLanguages: ["es-ES"]) == .spanish)
        #expect(DictationLanguage.preferred(macLanguages: ["es-MX"]) == .spanish)
        // Only the first language counts.
        #expect(DictationLanguage.preferred(macLanguages: ["en-US", "ja-JP"]) == .chinese)
        #expect(DictationLanguage.preferred(macLanguages: ["zh-Hans-CN", "es-ES"]) == .chinese)
        #expect(DictationLanguage.preferred(macLanguages: ["zh-Hant-HK"]) == .chinese)
        #expect(DictationLanguage.preferred(macLanguages: ["pt-BR"]) == .chinese)
        #expect(DictationLanguage.preferred(macLanguages: ["fr-FR"]) == .chinese)
        #expect(DictationLanguage.preferred(macLanguages: []) == .chinese)
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
            #expect(DictationLanguagePreference.load(setUpBefore: true, macLanguages: ["ja-JP"], from: defaults) == .chinese)
        }
    }

    /// A new user starts with the Mac's language, and one who set Orra up before with
    /// Chinese, whatever the Mac's language. A saved choice wins over both.
    @Test func onlyANewUserStartsWithTheMacsLanguage() throws {
        try withTestDefaults("dictationLanguage") { defaults in
            #expect(DictationLanguagePreference.load(setUpBefore: false, macLanguages: ["ja-JP"], from: defaults) == .japanese)
            #expect(DictationLanguagePreference.load(setUpBefore: false, macLanguages: ["es-ES"], from: defaults) == .spanish)
            #expect(DictationLanguagePreference.load(setUpBefore: false, macLanguages: ["en-US"], from: defaults) == .chinese)
            #expect(DictationLanguagePreference.load(setUpBefore: true, macLanguages: ["ja-JP"], from: defaults) == .chinese)
            #expect(DictationLanguagePreference.load(setUpBefore: true, macLanguages: ["es-ES"], from: defaults) == .chinese)
            DictationLanguagePreference.save(.spanish, to: defaults)
            #expect(DictationLanguagePreference.load(setUpBefore: false, macLanguages: ["ja-JP"], from: defaults) == .spanish)
            #expect(DictationLanguagePreference.load(setUpBefore: true, macLanguages: ["en-US"], from: defaults) == .spanish)
        }
    }

    /// The first launch saves the language a new user started with, so the next launch,
    /// when the user looks set up, keeps it. A saved choice is never replaced.
    @Test func aNewUsersLanguageStaysOnceSetUp() throws {
        try withTestDefaults("dictationLanguage") { defaults in
            let first = DictationLanguagePreference.load(setUpBefore: false, macLanguages: ["ja-JP"], from: defaults)
            DictationLanguagePreference.keep(first, in: defaults)
            #expect(DictationLanguagePreference.load(setUpBefore: true, macLanguages: ["ja-JP"], from: defaults) == .japanese)
            DictationLanguagePreference.keep(.chinese, in: defaults)
            #expect(DictationLanguagePreference.saved(in: defaults) == .japanese)
        }
        // A user who set Orra up before keeps Chinese, also after the Mac changes language.
        try withTestDefaults("dictationLanguage") { defaults in
            DictationLanguagePreference.keep(DictationLanguagePreference.load(setUpBefore: true, macLanguages: ["es-ES"], from: defaults), in: defaults)
            #expect(DictationLanguagePreference.load(setUpBefore: true, macLanguages: ["ja-JP"], from: defaults) == .chinese)
        }
    }
}
