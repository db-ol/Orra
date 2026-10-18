import Foundation

/// The language a user dictates in besides English, from Dictation language in Settings,
/// General, and in the welcome window. English is always the other one, so a user can mix
/// the two in one sentence, and there is no third.
///
/// Chinese, Mandarin and Cantonese, is how Orra has always worked. Japanese and Spanish are
/// a beta. LanguageGuard accepts text in them in place of Chinese and asks the speech model
/// for them before English, see LanguageGuard.verdict(on:for:). Their text skips what was
/// made for Chinese and English: simplified characters, the filler and number rules, the
/// cleanup model, whose prompt and RewriteGuard know those two languages only, and learning
/// from corrections. English text of such a user takes them as before.
nonisolated enum DictationLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "Chinese"
    case japanese = "Japanese"
    case spanish = "Spanish"

    var id: String { rawValue }

    /// The choice in its own languages, so a speaker finds it whatever the interface
    /// language is. Never translated.
    var name: String {
        switch self {
        case .chinese: "中文（普通话和粤语）+ English"
        case .japanese: "日本語 + English"
        case .spanish: "Español + English"
        }
    }

    /// Japanese and Spanish are new and measured on read speech only, so their choice says
    /// beta.
    var isBeta: Bool {
        self != .chinese
    }

    /// The language the speech model is told to write first when it chose a language the
    /// user does not dictate in.
    var speechLanguage: SpeechLanguage {
        switch self {
        case .chinese: .chinese
        case .japanese: .japanese
        case .spanish: .spanish
        }
    }

    /// The passes LanguageGuard asks for, in this order, see Transcription.checkingLanguage:
    /// this language, then English. For Chinese the passes Orra always had.
    var passes: [SpeechLanguage] {
        [speechLanguage, .english]
    }

    /// Whether traditional Chinese characters are turned into simplified ones, see
    /// ChineseText. Only for Chinese: Japanese writes Han characters of its own, such as
    /// 駅, which must stay.
    var simplifiesCharacters: Bool {
        self == .chinese
    }

    /// Whether a transcript written with the vocabulary may take its numbers from a pass
    /// without it, see ContextNumbers. Only for Chinese: in Japanese text numbers in Han
    /// characters are Japanese, and English and Spanish text hold none.
    var takesDigitsFromPassWithoutVocabulary: Bool {
        self == .chinese
    }

    /// The choice for a new user, from the Mac's first language: Japanese for Japanese,
    /// Spanish for Spanish, and Chinese for any other, such as English or Chinese.
    static func preferred(macLanguages: [String]) -> DictationLanguage {
        guard let first = macLanguages.first else { return .chinese }
        switch Locale.Language(identifier: first).languageCode {
        case .japanese: return .japanese
        case .spanish: return .spanish
        default: return .chinese
        }
    }
}

/// Keeps the dictation language in UserDefaults, by name.
///
/// A new user starts with the language of the Mac, see `DictationLanguage.preferred`. A
/// user who set Orra up before the choice existed dictated in Chinese and English, so
/// keeps Chinese until they pick another, see `TriggerModePreference.wasSetUpBefore`. A
/// launch with nothing saved saves the language the user started with, see `keep`, since
/// a new user looks set up from the next launch on.
nonisolated enum DictationLanguagePreference {
    static let defaultsKey = "dictationLanguage"

    /// The saved language, or nil when none is saved or the saved one is unknown.
    static func saved(in defaults: UserDefaults = .standard) -> DictationLanguage? {
        defaults.string(forKey: defaultsKey).flatMap(DictationLanguage.init(rawValue:))
    }

    /// The saved language, or the one the user starts with: from the Mac's languages for a
    /// user who never set Orra up, Chinese otherwise.
    static func load(setUpBefore: Bool, macLanguages: [String] = AppLanguage.macLanguages(), from defaults: UserDefaults = .standard) -> DictationLanguage {
        saved(in: defaults) ?? (setUpBefore ? .chinese : .preferred(macLanguages: macLanguages))
    }

    static func save(_ language: DictationLanguage, to defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
    }

    /// Saves the language the user started with, unless one is saved, so it stays once
    /// the user has set Orra up. AppDelegate calls it at launch.
    static func keep(_ language: DictationLanguage, in defaults: UserDefaults = .standard) {
        guard saved(in: defaults) == nil else { return }
        save(language, to: defaults)
    }
}
