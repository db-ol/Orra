import Foundation
import Testing
@testable import Orra

/// The Simplified Chinese, Japanese and Spanish strings: complete, with the same arguments
/// as the English ones, with each language's punctuation, and inside the app.
struct LocalizationTests {
    /// The localizations besides English, as the string catalogs name them. Spanish is
    /// Latin American Spanish, see AppLanguage.
    static let languages = ["zh-Hans", "ja", "es-419"]

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

    /// Every value of a catalog entry in one language with its state: one, or one for each
    /// plural form. Empty when the language has none.
    private static func translations(_ entry: [String: Any], in language: String) -> [(value: String, state: String)] {
        guard let localizations = entry["localizations"] as? [String: Any],
              let localization = localizations[language] as? [String: Any] else { return [] }
        var units: [Any] = [localization["stringUnit"] as Any]
        if let variations = localization["variations"] as? [String: [String: [String: Any]]] {
            units = variations.values.flatMap { $0.values.map { $0["stringUnit"] as Any } }
        }
        return units.compactMap { unit in
            guard let unit = unit as? [String: Any],
                  let value = unit["value"] as? String,
                  let state = unit["state"] as? String else { return nil }
            return (value, state)
        }
    }

    /// The values of every entry in one language, with the entry's key.
    private static func values(_ name: String, in language: String) throws -> [(key: String, value: String)] {
        try catalog(name).flatMap { key, entry in
            translations(entry, in: language).map { (key, $0.value) }
        }
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

    /// The text with each argument as one placeholder character, so "按住%@说话" passes the
    /// checks of the characters around it.
    private static func withoutArguments(_ value: String) -> [Character] {
        Array(value.replacing(/%(?:\d+\$)?(?:@|lld|ld|d|lf|f|%)/, with: "\u{FFFC}"))
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    private static func isLatinOrDigit(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    @Test(arguments: ["Localizable", "InfoPlist"], languages)
    func everyStringIsTranslated(_ name: String, _ language: String) throws {
        let strings = try Self.catalog(name)
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            let translations = Self.translations(entry, in: language)
            #expect(!translations.isEmpty, "\(name) \(language): \(key)")
            for translation in translations {
                #expect(translation.state == "translated", "\(name) \(language): \(key)")
                #expect(!translation.value.isEmpty, "\(name) \(language): \(key)")
            }
        }
    }

    @Test(arguments: languages)
    func translationsKeepEveryArgument(_ language: String) throws {
        for (key, value) in try Self.values("Localizable", in: language) {
            let english = Self.arguments(key)
            let translated = Self.arguments(value)
            #expect(translated.arguments == english.arguments, "\(language): \(key) -> \(value)")
            #expect(translated.percents == english.percents, "\(language): \(key) -> \(value)")
        }
    }

    @Test(arguments: ["Localizable", "InfoPlist"])
    func chineseUsesFullWidthPunctuationAndSpaces(_ name: String) throws {
        let halfWidth = Set(",.:;?!()\"")
        for (key, value) in try Self.values(name, in: "zh-Hans") {
            let text = Self.withoutArguments(value)
            let found = text.filter { halfWidth.contains($0) }
            #expect(found.isEmpty, "\(key) -> \(value)")
            let missingSpace = zip(text, text.dropFirst()).contains { pair in
                (Self.isHan(pair.0) && Self.isLatinOrDigit(pair.1)) || (Self.isLatinOrDigit(pair.0) && Self.isHan(pair.1))
            }
            #expect(!missingSpace, "\(key) -> \(value)")
        }
    }

    /// Japanese ends sentences with 。 and separates with 、, puts “ ” around the names of
    /// buttons and settings and around quoted words, as macOS does, and uses full width
    /// parentheses. A comma or period between digits, as in 1,000 or 15.6, is part of the
    /// number. The ? and : stay half width, as macOS writes them, and there is no !. No
    /// space stands between Japanese and a Latin letter, a digit or an argument, as in
    /// Orraを終了 and %lld秒.
    @Test(arguments: ["Localizable", "InfoPlist"])
    func japaneseUsesJapanesePunctuationWithoutSpaces(_ name: String) throws {
        // Japanese punctuation, kana, kanji and full width forms.
        let japanese: [ClosedRange<UInt32>] = [0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF00...0xFFEF]
        func isJapanese(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { scalar in japanese.contains { $0.contains(scalar.value) } }
        }
        for (key, value) in try Self.values(name, in: "ja") {
            let text = Self.withoutArguments(value)
            let marks = text.indices.filter { index in
                switch text[index] {
                case ",", ".":
                    index == 0 || index == text.count - 1 || !(text[index - 1].isNumber && text[index + 1].isNumber)
                case ";", "!", "(", ")", "\"", "「", "」", "？", "：", "！":
                    true
                default:
                    false
                }
            }
            #expect(marks.isEmpty, "\(key) -> \(value)")
            #expect(!value.contains("..."), "\(key) -> \(value)")
            let isLatin = { (character: Character) in Self.isLatinOrDigit(character) || character == "\u{FFFC}" }
            let spaced = zip(text, zip(text.dropFirst(), text.dropFirst(2))).contains { first, rest in
                rest.0 == " " && ((isJapanese(first) && isLatin(rest.1)) || (isLatin(first) && isJapanese(rest.1)))
            }
            #expect(!spaced, "\(key) -> \(value)")
        }
    }

    /// Spanish opens every question with ¿ and every exclamation with ¡, and uses no full
    /// width punctuation. A Chinese example, such as “三点，哦不对，四点”, keeps its own.
    @Test(arguments: ["Localizable", "InfoPlist"])
    func spanishPairsItsMarksWithoutFullWidthPunctuation(_ name: String) throws {
        let fullWidth = Set("，。：；？！（）、「」")
        for (key, value) in try Self.values(name, in: "es-419") {
            for (opening, closing) in [("¿", "?"), ("¡", "!")] as [(Character, Character)] {
                var open = 0
                var paired = true
                for character in value {
                    if character == opening { open += 1 }
                    if character == closing {
                        if open == 0 { paired = false } else { open -= 1 }
                    }
                }
                #expect(paired && open == 0, "\(key) -> \(value)")
            }
            let text = Array(value)
            let found = text.indices.filter { index in
                fullWidth.contains(text[index]) && !(index > 0 && Self.isHan(text[index - 1]))
            }
            #expect(found.isEmpty, "\(key) -> \(value)")
            #expect(!value.contains("..."), "\(key) -> \(value)")
        }
    }

    /// Xcode rewrites the catalog in this order whenever it builds, so a catalog kept in
    /// another order shows up as a change after every build in Xcode.
    @Test(arguments: ["Localizable", "InfoPlist"])
    func catalogKeepsXcodesOrder(_ name: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orra/\(name).xcstrings")
        let text = try String(contentsOf: url, encoding: .utf8)
        // The keys of "strings" are the only lines indented by four spaces that open an
        // object. Each is decoded as a JSON string to undo its escapes.
        let keys = try text.split(separator: "\n").compactMap { line -> String? in
            guard let match = line.wholeMatch(of: /\ {4}("(?:[^"\\]|\\.)*") : \{/) else { return nil }
            return try JSONDecoder().decode(String.self, from: Data(match.output.1.utf8))
        }
        #expect(!keys.isEmpty)
        let sorted = keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        #expect(keys == sorted, "\(name): sort the keys with localizedStandardCompare, as Xcode does")
    }

    /// The built app has a folder for each language, with the catalog's strings and the
    /// texts of the permission prompts.
    @Test(arguments: languages)
    func theAppCarriesTheStrings(_ language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let strings = try Self.catalog("Localizable")
        let quit = try #require(strings["Quit Orra"].flatMap { Self.translations($0, in: language).first?.value })
        #expect(bundle.localizedString(forKey: "Quit Orra", value: nil, table: nil) == quit)
        let prompts = try Self.catalog("InfoPlist")
        for key in ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription", "NSAppleEventsUsageDescription"] {
            let prompt = try #require(prompts[key].flatMap { Self.translations($0, in: language).first?.value })
            #expect(bundle.localizedString(forKey: key, value: nil, table: "InfoPlist") == prompt)
        }
    }

    @Test func theAppCarriesTheChineseStrings() throws {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let chinese = try #require(Bundle(path: path))
        #expect(chinese.localizedString(forKey: "Quit Orra", value: nil, table: nil) == "退出 Orra")
        #expect(chinese.localizedString(forKey: "NSMicrophoneUsageDescription", value: nil, table: "InfoPlist") == "当你开始听写或翻译，或录制声音样本时，Orra 会使用麦克风，并在这台 Mac 上把你的声音转成文字。")
    }

    /// The English microphone prompt comes from the build setting
    /// INFOPLIST_KEY_NSMicrophoneUsageDescription, and the catalog keeps the same text for
    /// the translations to follow, so the prompt says the same in every language. The
    /// build setting still has the prompt from before 2026-10-20, which only the maintainer
    /// changes, in Xcode. Change it to the catalog's English for Debug and Release before
    /// Xcode builds the app, or Xcode takes the old text back into the catalog. Then remove
    /// withKnownIssue here. Once the two texts match, it fails the test.
    @Test func theEnglishMicrophonePromptMatchesTheCatalog() throws {
        let prompts = try Self.catalog("InfoPlist")
        let english = try #require(prompts["NSMicrophoneUsageDescription"].flatMap { Self.translations($0, in: "en").first?.value })
        withKnownIssue("INFOPLIST_KEY_NSMicrophoneUsageDescription in the project still has the old English prompt") {
            #expect(Bundle.main.infoDictionary?["NSMicrophoneUsageDescription"] as? String == english)
        }
    }

    /// The About text says when Orra goes online. It names no single model, so none of
    /// the models Orra downloads is left out.
    @Test func theAboutTextNamesNoSingleModel() throws {
        let strings = try Self.catalog("Localizable")
        let about = try #require(strings.first { $0.key.hasPrefix("Speech is turned into text on this Mac") })
        let models = ["Speech model", "Cleanup model", "Voice model"]
        for model in models {
            #expect(!about.key.localizedCaseInsensitiveContains(model), "\(model)")
        }
        for language in Self.languages {
            let text = try #require(Self.translations(about.value, in: language).first?.value)
            for model in models {
                let name = try #require(strings[model].flatMap { Self.translations($0, in: language).first?.value })
                #expect(!text.localizedCaseInsensitiveContains(name), "\(language): \(name)")
            }
        }
    }

    /// Spanish has a plural form for one, so the countdown never reads "1 segundos".
    @Test func spanishCountsOneSecondInTheSingular() {
        let spanish = Locale(identifier: "es-419")
        func closes(in seconds: Int) -> String {
            String(localized: LocalizedStringResource("Closes in \(seconds) seconds", locale: spanish))
        }
        #expect(closes(in: 1) == "Se cierra en 1 segundo")
        #expect(closes(in: 5) == "Se cierra en 5 segundos")
        #expect(String(localized: LocalizedStringResource("Closes in \(1) seconds", locale: Locale(identifier: "ja"))) == "1秒後に閉じます")
    }

    @Test func eachLanguageIsChosenOnlyWhenItComesBeforeEnglish() {
        let available = Bundle.main.localizations
        #expect(Set(available).isSuperset(of: ["en"] + Self.languages))
        #expect(Bundle.preferredLocalizations(from: available, forPreferences: ["en-US", "zh-Hans-US"]).first == "en")
        #expect(Bundle.preferredLocalizations(from: available, forPreferences: ["zh-Hans-CN", "en-US"]).first == "zh-Hans")
        // Traditional Chinese does not fall back to Simplified.
        #expect(Bundle.preferredLocalizations(from: available, forPreferences: ["zh-Hant-TW", "en-US"]).first == "en")
        #expect(Bundle.preferredLocalizations(from: available, forPreferences: ["zh-Hant-HK", "zh-Hans-CN", "en-US"]).first == "zh-Hans")
        #expect(Bundle.preferredLocalizations(from: available, forPreferences: ["ja-JP", "en-US"]).first == "ja")
        #expect(Bundle.preferredLocalizations(from: available, forPreferences: ["en-US", "ja-JP"]).first == "en")
        // Every Spanish gets the Latin American one, also Spain's.
        for spanish in ["es-MX", "es-419", "es-ES", "es-US", "es"] {
            #expect(Bundle.preferredLocalizations(from: available, forPreferences: [spanish, "en-US"]).first == "es-419", "\(spanish)")
        }
        #expect(Bundle.preferredLocalizations(from: available, forPreferences: ["fr-FR", "es-MX"]).first == "es-419")
    }

    @Test func talkKeyHintsReadAsChineseSentences() throws {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let chinese = try #require(Bundle(path: path))
        let locale = Locale(identifier: "zh-Hans")
        #expect(Hotkey.rightControl.talkHint(mode: .hold, in: locale) == "按住右侧 Control 键说话")
        #expect(Hotkey.fn.talkHint(mode: .hold, in: locale) == "按住地球仪（fn）键说话")
        #expect(chinese.localizedString(forKey: "%@ (%@)", value: nil, table: nil) == "%@（%@）")
        #expect(chinese.localizedString(forKey: "Windows key", value: nil, table: nil) == "Windows 键")
        #expect(Hotkey.leftCommand.finishHint(in: locale) == "按左侧 Command 键结束")
        #expect(Hotkey.fn.finishHint(in: locale) == "按地球仪（fn）键结束")
    }

    @Test func talkKeyHintsReadAsJapaneseAndSpanishSentences() {
        let japanese = Locale(identifier: "ja")
        #expect(Hotkey.rightControl.talkHint(mode: .hold, in: japanese) == "右Controlキーを押したまま話す")
        #expect(Hotkey.fn.talkHint(mode: .hold, in: japanese) == "地球儀（fn）キーを押したまま話す")
        #expect(Hotkey.leftCommand.finishHint(in: japanese) == "左Commandキーを押して終了")
        #expect(TalkKey.rightOption.fullName(in: japanese) == "⌥ 右Option（Alt）")
        let spanish = Locale(identifier: "es-419")
        #expect(Hotkey.rightControl.talkHint(mode: .hold, in: spanish) == "Mantén presionada la tecla Control derecha para hablar")
        #expect(Hotkey.fn.talkHint(mode: .hold, in: spanish) == "Mantén presionada la tecla fn para hablar")
        #expect(Hotkey.leftCommand.finishHint(in: spanish) == "Presiona la tecla Comando izquierda para terminar")
        #expect(TalkKey.rightOption.fullName(in: spanish) == "⌥ Opción derecha (Alt)")
    }
}
