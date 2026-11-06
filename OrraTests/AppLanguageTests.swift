import Foundation
import Testing
@testable import Orra

struct AppLanguageTests {
    @Test func theChoiceIsKeptInOrrasOwnDefaults() throws {
        let suite = try TestDefaults("language")
        defer { suite.remove() }
        let defaults = suite.defaults
        #expect(AppLanguage.load(from: defaults, domain: suite.name) == .system)
        AppLanguage.chinese.save(to: defaults)
        // The saved value itself: the test run passes its own AppleLanguages as an argument,
        // which a plain read would return instead.
        #expect(defaults.persistentDomain(forName: suite.name)?[AppLanguage.defaultsKey] as? [String] == ["zh-Hans"])
        #expect(AppLanguage.load(from: defaults, domain: suite.name) == .chinese)
        AppLanguage.english.save(to: defaults)
        #expect(AppLanguage.load(from: defaults, domain: suite.name) == .english)
        AppLanguage.japanese.save(to: defaults)
        #expect(defaults.persistentDomain(forName: suite.name)?[AppLanguage.defaultsKey] as? [String] == ["ja"])
        #expect(AppLanguage.load(from: defaults, domain: suite.name) == .japanese)
        AppLanguage.spanish.save(to: defaults)
        #expect(defaults.persistentDomain(forName: suite.name)?[AppLanguage.defaultsKey] as? [String] == ["es-419"])
        #expect(AppLanguage.load(from: defaults, domain: suite.name) == .spanish)
        AppLanguage.system.save(to: defaults)
        #expect(AppLanguage.load(from: defaults, domain: suite.name) == .system)
    }

    @Test func aLanguageSetInSystemSettingsIsRead() throws {
        let suite = try TestDefaults("language")
        defer { suite.remove() }
        let defaults = suite.defaults
        defaults.set(["zh-Hans-CN"], forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.load(from: defaults, domain: suite.name) == .chinese)
        defaults.set(["ja-JP"], forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.load(from: defaults, domain: suite.name) == .japanese)
        // Any Spanish shows the one Orra has.
        for spanish in ["es-ES", "es-MX", "es"] {
            defaults.set([spanish], forKey: AppLanguage.defaultsKey)
            #expect(AppLanguage.load(from: defaults, domain: suite.name) == .spanish, "\(spanish)")
        }
        defaults.set(["fr"], forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.load(from: defaults, domain: suite.name) == .system)
    }

    @Test func eachLanguageReadsInItsOwnName() {
        #expect(AppLanguage.allCases == [.system, .english, .chinese, .japanese, .spanish])
        #expect(AppLanguage.allCases.compactMap(\.nativeName) == ["English", "简体中文", "日本語", "Español"])
    }
}
