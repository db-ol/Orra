import Foundation

/// The user's own language among the three Orra knows besides English: Chinese, Japanese
/// or Spanish, the languages of DictationLanguage. The language settings start from it,
/// such as a new user's dictation language, see `DictationLanguage.preferred`.
///
/// It is the language Orra shows when that is Chinese, Japanese or Spanish. With Orra in
/// English it is the first of the three in the Mac's languages, any Chinese included. So a
/// Mac with English first and Chinese second, which shows Orra in English, gives Chinese,
/// and a Japanese Mac whose user picked English for Orra gives Japanese. With none of the
/// three, such as on a Mac in English or French only, there is none, and each setting
/// starts its own way.
nonisolated enum OwnLanguage {
    /// From the localization Orra shows, such as "en" or "ja", and the Mac's languages as
    /// System Settings lists them.
    static func find(interface: String, macLanguages: [String]) -> DictationLanguage? {
        language(of: interface) ?? macLanguages.lazy.compactMap(language(of:)).first
    }

    /// From Orra's language as saved, so a language picked in the welcome window counts at
    /// once, and the Mac's languages.
    static func current(appLanguage: AppLanguage = .load(), macLanguages: [String] = AppLanguage.macLanguages()) -> DictationLanguage? {
        find(interface: appLanguage.localization(macLanguages: macLanguages), macLanguages: macLanguages)
    }

    /// Chinese, Japanese or Spanish for a language such as "zh-Hant-TW", "ja" or "es-MX", in
    /// any script and region, and nil for any other. Cantonese counts as Chinese, which Orra
    /// dictates as Mandarin and Cantonese.
    private static func language(of identifier: String) -> DictationLanguage? {
        switch Locale.Language(identifier: identifier).languageCode?.identifier {
        case "zh", "yue": .chinese
        case "ja": .japanese
        case "es": .spanish
        default: nil
        }
    }
}
