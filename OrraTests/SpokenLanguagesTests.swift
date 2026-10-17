import Foundation
import Testing
@testable import Orra

struct SpokenLanguagesTests {
    @Test func chineseAndEnglishAlwaysStay() {
        let languages = SpokenLanguages.chineseAndEnglish
        #expect(languages.contains(.chinese))
        #expect(languages.contains(.english))
        #expect(!languages.contains(.spanish))
        #expect(!languages.contains(.japanese))
        #expect(languages.passes == [.chinese, .english])
        #expect(languages.setting(.chinese, on: false) == languages)
        #expect(languages.setting(.english, on: true) == languages)
        #expect(SpokenLanguages(adding: [.chinese, .english]) == languages)
    }

    @Test func addedLanguagesComeAfterChineseAndEnglishInTheOrderOfSettings() {
        let both = SpokenLanguages.chineseAndEnglish.setting(.japanese, on: true).setting(.spanish, on: true)
        #expect(both.contains(.spanish))
        #expect(both.contains(.japanese))
        #expect(both.passes == [.chinese, .english, .spanish, .japanese])
        #expect(both.setting(.spanish, on: false).passes == [.chinese, .english, .japanese])
    }

    @Test func thePreferenceKeepsTheAddedLanguagesByName() throws {
        try withTestDefaults("spokenLanguages") { defaults in
            #expect(SpokenLanguagesPreference.load(from: defaults) == .chineseAndEnglish)
            SpokenLanguagesPreference.save(SpokenLanguages(adding: [.japanese, .spanish]), to: defaults)
            #expect(defaults.stringArray(forKey: SpokenLanguagesPreference.defaultsKey) == ["Spanish", "Japanese"])
            #expect(SpokenLanguagesPreference.load(from: defaults) == SpokenLanguages(adding: [.spanish, .japanese]))
            SpokenLanguagesPreference.save(.chineseAndEnglish, to: defaults)
            #expect(SpokenLanguagesPreference.load(from: defaults) == .chineseAndEnglish)
            // A name Orra does not know, as from a later version, is left out.
            defaults.set(["Spanish", "Klingon", "Chinese"], forKey: SpokenLanguagesPreference.defaultsKey)
            #expect(SpokenLanguagesPreference.load(from: defaults) == SpokenLanguages(adding: [.spanish]))
        }
    }
}
