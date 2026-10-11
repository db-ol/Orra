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
        AppLanguage.system.save(to: defaults)
        #expect(AppLanguage.load(from: defaults, domain: suite) == .system)
    }

    @Test func aLanguageSetInSystemSettingsIsRead() throws {
        let suite = "io.github.db-ol.OrraTests.language-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["zh-Hans-CN"], forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.load(from: defaults, domain: suite) == .chinese)
        defaults.set(["fr"], forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.load(from: defaults, domain: suite) == .system)
    }
}
