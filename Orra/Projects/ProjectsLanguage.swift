import Foundation
import NaturalLanguage

/// The language of a text in Projects. Phase 1 explains and drafts in Chinese and English
/// only, so every other language reads as `other`, and mail in it gets no draft.
nonisolated enum ProjectsLanguage: String, CaseIterable, Sendable, Codable {
    case zh
    case en
    case other

    /// The language a text is mostly written in.
    ///
    /// Chinese when `ChineseText.isMostlyChinese` says so: Chinese characters, at least as
    /// many of them as words in other scripts, and no kana. The katakana middle dot and long
    /// sound mark, which Chinese text borrows as in 安娜・林, do not count as kana. Otherwise
    /// text whose Latin letters outnumber all other letters, Chinese characters included, is
    /// English, unless it holds at least 40 Latin letters and the recognizer is sure it is
    /// German, Spanish, French, Italian, Portuguese or Dutch. Kana, Hangul, Cyrillic and
    /// every other script give `other`, and so does text without letters. Shorter text,
    /// and other languages in Latin letters, read as English.
    static func reading(_ text: String) -> ProjectsLanguage {
        let withoutBorrowedKana = String(text.unicodeScalars.filter { !borrowedKana.contains($0) })
        if ChineseText.isMostlyChinese(withoutBorrowedKana) {
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
        guard latin > otherLetters else { return .other }
        return latin >= recognizedLetters && isSurelyAnotherLatinLanguage(text) ? .other : .en
    }

    /// The language explanations are written in, from the localization Orra's interface
    /// shows, such as "zh-Hans" or "en" (`AppLanguage.launchLocalization`). Chinese for a
    /// Chinese interface, and English for every other one, Japanese and Spanish included.
    static func forExplanations(interface: String) -> ProjectsLanguage {
        Locale.Language(identifier: interface).languageCode?.identifier == "zh" ? .zh : .en
    }

    /// The katakana middle dot and long sound mark.
    private static let borrowedKana: Set<Unicode.Scalar> = ["\u{30FB}", "\u{30FC}"]

    /// Below this many Latin letters the recognizer guesses too often, so the text stays English.
    private static let recognizedLetters = 40

    /// The languages the recognizer chooses from. With every language open, the names in an
    /// English mail, such as Chinese or Indonesian names, can make it sure of another
    /// language. Among these it reads such mail as English.
    private static let latinLanguages: [NLLanguage] = [.english, .german, .spanish, .french, .italian, .portuguese, .dutch]

    /// Whether the recognizer gives a language other than English a probability of at
    /// least 0.9.
    private static func isSurelyAnotherLatinLanguage(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = latinLanguages
        recognizer.processString(text)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first else { return false }
        return language != .english && probability >= 0.9
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
