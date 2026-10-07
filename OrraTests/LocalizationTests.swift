import Foundation
import Testing
@testable import Orra

/// The Simplified Chinese strings: complete, with the same arguments as the English ones,
/// in full width punctuation, and inside the app.
struct LocalizationTests {
    /// The string catalogs in the source tree, keyed by name.
    private static func catalog(_ name: String) throws -> [String: [String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orra/\(name).xcstrings")
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    /// The Chinese value of a catalog entry and its state, or nil.
    private static func chinese(_ entry: [String: Any]) -> (value: String, state: String)? {
        guard let localizations = entry["localizations"] as? [String: Any],
              let zh = localizations["zh-Hans"] as? [String: Any],
              let unit = zh["stringUnit"] as? [String: Any],
              let value = unit["value"] as? String,
              let state = unit["state"] as? String else { return nil }
        return (value, state)
    }

    /// The arguments of a format string as (position, type), and the number of literal
    /// percent signs. Arguments without a position count from 1 in order.
    private static func arguments(_ format: String) -> (arguments: [Int: String], percents: Int) {
        let pattern = /%(?:(\d+)\$)?(@|lld|ld|d|lf|f|%)/
        var arguments: [Int: String] = [:]
        var next = 1
        var percents = 0
        for match in format.matches(of: pattern) {
            let type = String(match.output.2)
            if type == "%" {
                percents += 1
                continue
            }
            let position = match.output.1.flatMap { Int($0) } ?? next
            arguments[position] = type
            next += 1
        }
        return (arguments, percents)
    }

    @Test(arguments: ["Localizable", "InfoPlist"])
    func everyStringHasAChineseTranslation(_ name: String) throws {
        let strings = try Self.catalog(name)
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            let chinese = Self.chinese(entry)
            #expect(chinese?.state == "translated", "\(name): \(key)")
            #expect(chinese?.value.isEmpty == false, "\(name): \(key)")
        }
    }

    @Test func translationsKeepEveryArgument() throws {
        for (key, entry) in try Self.catalog("Localizable") {
            let value = try #require(Self.chinese(entry)?.value)
            let english = Self.arguments(key)
            let translated = Self.arguments(value)
            #expect(translated.arguments == english.arguments, "\(key) -> \(value)")
            #expect(translated.percents == english.percents, "\(key) -> \(value)")
        }
    }

    @Test(arguments: ["Localizable", "InfoPlist"])
    func chineseUsesFullWidthPunctuation(_ name: String) throws {
        let halfWidth = Set(",:;?!()\"")
        for (key, entry) in try Self.catalog(name) {
            let value = try #require(Self.chinese(entry)?.value)
            let found = value.filter { halfWidth.contains($0) }
            #expect(found.isEmpty, "\(key) -> \(value)")
        }
    }

    @Test func theAppCarriesTheChineseStrings() throws {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let chinese = try #require(Bundle(path: path))
        #expect(chinese.localizedString(forKey: "Quit Orra", value: nil, table: nil) == "退出 Orra")
        #expect(chinese.localizedString(forKey: "NSMicrophoneUsageDescription", value: nil, table: "InfoPlist") == "Orra 会在你按住说话键时录下你的声音，并在这台 Mac 上把它转成文字。")
    }

    @Test func chineseIsChosenOnlyWhenItComesBeforeEnglish() {
        let available = Bundle.main.localizations
        #expect(Bundle.preferredLocalizations(from: available, forPreferences: ["en-US", "zh-Hans-US"]).first == "en")
        #expect(Bundle.preferredLocalizations(from: available, forPreferences: ["zh-Hans-CN", "en-US"]).first == "zh-Hans")
    }

    @Test func talkKeyHintsReadAsChineseSentences() throws {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let chinese = try #require(Bundle(path: path))
        func text(_ key: String) -> String {
            chinese.localizedString(forKey: key, value: nil, table: nil)
        }
        let control = text("right Control")
        let fn = text("fn")
        #expect(String(format: text("Hold %@ to talk"), control) == "按住右侧 Control 键说话")
        #expect(String(format: text("Hold %@ or %@ to talk"), control, fn) == "按住右侧 Control 键或左下角的 fn 键说话")
        #expect(String(format: text("Hold %@, %@ or %@ to talk"), control, text("right Option"), fn) == "按住右侧 Control 键、右侧 Option 键或左下角的 fn 键说话")
    }
}
