import Foundation

/// The language of a text in Projects. Phase 1 explains and drafts in Chinese and English
/// only, so every other language reads as `other`, and mail in it gets no draft.
nonisolated enum ProjectsLanguage: String, CaseIterable, Sendable, Codable {
    case zh
    case en
    case other

    /// The language a text is mostly written in.
    ///
    /// Chinese when `ChineseText.isMostlyChinese` says so: Chinese characters, at least as
    /// many of them as words in other scripts, and no kana. Otherwise English when Latin
    /// letters outnumber all other letters, Chinese characters included. Kana, Hangul,
    /// Cyrillic and every other script give `other`, and so does text without letters.
    /// German or Spanish written in Latin letters reads as English.
    static func reading(_ text: String) -> ProjectsLanguage {
        if ChineseText.isMostlyChinese(text) {
            return .zh
        }
        var latin = 0
        var otherLetters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if isLatin(scalar) {
                latin += 1
            } else {
                otherLetters += 1
            }
        }
        return latin > otherLetters ? .en : .other
    }

    /// The language explanations are written in, from the localization Orra's interface
    /// shows, such as "zh-Hans" or "en" (`AppLanguage.launchLocalization`). Chinese for a
    /// Chinese interface, and English for every other one, Japanese and Spanish included.
    static func forExplanations(interface: String) -> ProjectsLanguage {
        Locale.Language(identifier: interface).languageCode?.identifier == "zh" ? .zh : .en
    }

    /// Whether a letter is in the Latin script: ASCII, Latin-1, Latin Extended A and B,
    /// Latin Extended Additional, and the full width forms.
    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            true
        default:
            false
        }
    }
}
