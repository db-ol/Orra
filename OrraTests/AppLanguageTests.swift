import Foundation
import Testing
@testable import Orra

struct AppLanguageTests {
    @Test func theChoiceIsKeptInOrrasOwnDefaults() throws {
        let suite = "io.github.db-ol.OrraTests.language-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppLanguage.load(from: defaults, domain: suite) == .system)
        AppLanguage.chinese.save(to: defaults)
        // The saved value itself: the test run passes its own AppleLanguages as an argument,
        // which a plain read would return instead.
        #expect(defaults.persistentDomain(forName: suite)?[AppLanguage.defaultsKey] as? [String] == ["zh-Hans"])
        #expect(AppLanguage.load(from: defaults, domain: suite) == .chinese)
        AppLanguage.english.save(to: defaults)
        #expect(AppLanguage.load(from: defaults, domain: suite) == .english)
        AppLanguage.japanese.save(to: defaults)
        #expect(defaults.persistentDomain(forName: suite)?[AppLanguage.defaultsKey] as? [String] == ["ja"])
        #expect(AppLanguage.load(from: defaults, domain: suite) == .japanese)
        AppLanguage.spanish.save(to: defaults)
        #expect(defaults.persistentDomain(forName: suite)?[AppLanguage.defaultsKey] as? [String] == ["es-419"])
        #expect(AppLanguage.load(from: defaults, domain: suite) == .spanish)
        AppLanguage.system.save(to: defaults)
        #expect(AppLanguage.load(from: defaults, domain: suite) == .system)
    }

    @Test func aLanguageSetInSystemSettingsIsRead() throws {
        let suite = "io.github.db-ol.OrraTests.language-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["zh-Hans-CN"], forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.load(from: defaults, domain: suite) == .chinese)
        defaults.set(["ja-JP"], forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.load(from: defaults, domain: suite) == .japanese)
        // Any Spanish shows the one Orra has.
        for spanish in ["es-ES", "es-MX", "es"] {
            defaults.set([spanish], forKey: AppLanguage.defaultsKey)
            #expect(AppLanguage.load(from: defaults, domain: suite) == .spanish, "\(spanish)")
        }
        defaults.set(["fr"], forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.load(from: defaults, domain: suite) == .system)
    }

    @Test func eachLanguageReadsInItsOwnName() {
        #expect(AppLanguage.allCases == [.system, .english, .chinese, .japanese, .spanish])
        #expect(AppLanguage.allCases.compactMap(\.nativeName) == ["English", "简体中文", "日本語", "Español"])
    }
}
