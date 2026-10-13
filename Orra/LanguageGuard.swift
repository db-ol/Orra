import Foundation
import NaturalLanguage

/// Catches a transcript the model wrote in a language other than Chinese or English.
///
/// Orra gives Qwen3-ASR no language hint, so the model picks the language itself, and a
/// fixed hint hurts mixed Chinese and English. The model now and then picks a third
/// language and translates the whole dictation into it: a Mandarin clip that starts with
/// the Catalan dish name "Pa amb Oli" came out in Swedish. speech-swift at commit 1f54e56
/// strips the language the model chose from its output and has no other way to report it,
/// so this reads the language from the text.
///
/// Cantonese counts as Chinese: it is written in Han characters, which pass, and
/// ChineseText.simplified turns traditional ones into simplified.
nonisolated enum LanguageGuard {
    /// Letters of scripts other than Han and Latin, such as kana, Hangul or Cyrillic, from
    /// this share of all letters on make a transcript foreign.
    static let otherScriptShare = 0.2
    /// Latin text needs this many letters before its language is judged. Shorter text
    /// says too little.
    static let minimumLatinLetters = 20
    /// Latin text whose chance of being English, by NLLanguageRecognizer, is below this is
    /// foreign. English transcripts of the speech corpus, FLEURS and ASCEND scored 0.19 at
    /// least, the Swedish one 0.
    static let englishFloor = 0.02

    /// Whether the text looks written in a language other than Chinese or English.
    static func isForeign(_ text: String) -> Bool {
        var han = 0
        var latin = 0
        var other = 0
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars where scalar.properties.isAlphabetic {
            if isHan(scalar) {
                han += 1
            } else if isLatin(scalar) {
                latin += 1
            } else if scalar.properties.generalCategory.isLetter {
                other += 1
            }
        }
        let letters = han + latin + other
        guard letters > 0 else { return false }
        if Double(other) >= Double(letters) * otherScriptShare { return true }
        // Latin text with a few Han characters at most, long enough to judge.
        guard latin >= minimumLatinLetters, Double(latin) >= Double(letters) * 0.9 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let english = recognizer.languageHypotheses(withMaximum: 80)[.english] ?? 0
        return english < englishFloor
    }

    /// Han ideographs: the unified blocks, their extensions and the compatibility block.
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: true
        default: false
        }
    }

    /// Latin letters, with or without accents.
    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: scalar.properties.generalCategory.isLetter
        default: false
        }
    }
}

private extension Unicode.GeneralCategory {
    nonisolated var isLetter: Bool {
        switch self {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }
}
