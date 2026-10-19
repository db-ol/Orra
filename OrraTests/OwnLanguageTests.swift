import Foundation
import Testing
@testable import Orra

/// The user's own language, which the language settings start from: the language Orra
/// shows when it is Chinese, Japanese or Spanish, otherwise the first of those in the
/// Mac's languages, otherwise none.
struct OwnLanguageTests {
    /// Orra in Chinese, Japanese or Spanish gives that language, whatever the Mac's.
    @Test func orrasLanguageComesFirst() {
        #expect(OwnLanguage.find(interface: "zh-Hans", macLanguages: ["en-US"]) == .chinese)
        #expect(OwnLanguage.find(interface: "ja", macLanguages: ["en-US"]) == .japanese)
        #expect(OwnLanguage.find(interface: "es-419", macLanguages: ["en-US"]) == .spanish)
        // Picked for Orra in the welcome window on a Mac in another of the three.
        #expect(OwnLanguage.find(interface: "ja", macLanguages: ["zh-Hans-CN", "en-US"]) == .japanese)
        #expect(OwnLanguage.find(interface: "zh-Hans", macLanguages: ["es-ES"]) == .chinese)
    }

    /// Orra in English gives the first of the three in the Mac's languages, in any script
    /// and region.
    @Test func withOrraInEnglishTheMacsLanguagesCount() {
        #expect(OwnLanguage.find(interface: "en", macLanguages: ["en-US", "zh-Hans-CN"]) == .chinese)
        #expect(OwnLanguage.find(interface: "en", macLanguages: ["en-US", "ja-JP"]) == .japanese)
        #expect(OwnLanguage.find(interface: "en", macLanguages: ["en-US", "fr-FR", "es-MX"]) == .spanish)
        // English picked for Orra on a Japanese Mac.
        #expect(OwnLanguage.find(interface: "en", macLanguages: ["ja-JP", "en-US"]) == .japanese)
        // Traditional Chinese, which shows Orra in English, and Cantonese count as Chinese.
        #expect(OwnLanguage.find(interface: "en", macLanguages: ["zh-Hant-TW", "en-US"]) == .chinese)
        #expect(OwnLanguage.find(interface: "en", macLanguages: ["yue-Hant-HK", "ja-JP"]) == .chinese)
        // Only the first of the three counts.
        #expect(OwnLanguage.find(interface: "en", macLanguages: ["en-US", "ja-JP", "zh-Hans-CN"]) == .japanese)
    }

    /// With none of the three there is none, and each setting starts its own way.
    @Test func noneOfTheThreeGivesNone() {
        #expect(OwnLanguage.find(interface: "en", macLanguages: ["en-US"]) == nil)
        #expect(OwnLanguage.find(interface: "en", macLanguages: ["fr-FR"]) == nil)
        #expect(OwnLanguage.find(interface: "en", macLanguages: ["ko-KR", "pt-BR"]) == nil)
        #expect(OwnLanguage.find(interface: "en", macLanguages: []) == nil)
    }

    /// From Orra's language as the user chose it, with the localization macOS shows for
    /// the Mac's own choice.
    @Test func orrasChoiceGivesTheLanguageItShows() {
        // English first and Chinese second shows Orra in English.
        #expect(OwnLanguage.current(appLanguage: .system, macLanguages: ["en-US", "zh-Hans-CN"]) == .chinese)
        // German first and Japanese second shows Orra in Japanese.
        #expect(OwnLanguage.current(appLanguage: .system, macLanguages: ["de-DE", "ja-JP"]) == .japanese)
        #expect(OwnLanguage.current(appLanguage: .system, macLanguages: ["fr-FR", "es-ES"]) == .spanish)
        #expect(OwnLanguage.current(appLanguage: .system, macLanguages: ["zh-Hant-TW", "en-US"]) == .chinese)
        #expect(OwnLanguage.current(appLanguage: .system, macLanguages: ["fr-FR"]) == nil)
        #expect(OwnLanguage.current(appLanguage: .english, macLanguages: ["ja-JP", "en-US"]) == .japanese)
        #expect(OwnLanguage.current(appLanguage: .english, macLanguages: ["en-US"]) == nil)
        #expect(OwnLanguage.current(appLanguage: .chinese, macLanguages: ["en-US", "ja-JP"]) == .chinese)
        #expect(OwnLanguage.current(appLanguage: .spanish, macLanguages: ["ja-JP"]) == .spanish)
    }
}
