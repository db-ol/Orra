import Foundation
import NaturalLanguage

/// Catches a transcript the model wrote in a language other than Chinese, English and the
/// languages the user added under Languages I Speak, see SpokenLanguages.
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
///
/// An added language only ever turns a verdict of foreign into one of that language, so
/// with none added every verdict is as before the setting. Japanese is told by its kana,
/// Spanish by NLLanguageRecognizer, which must find Spanish the most likely language, so
/// Portuguese, Catalan, Italian or Swedish stays foreign with Spanish on. On the 200
/// FLEURS clips of each, the model's text was Spanish or Japanese by these rules every
/// time, and no clip of the speech corpus changed its verdict with both on.
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

    /// What the guard finds a text written in.
    nonisolated enum Verdict: Equatable {
        /// Chinese, English, a mix of them, or too little to judge.
        case chineseOrEnglish
        /// A language the user added.
        case added(SpeechLanguage)
        /// A language the user does not speak.
        case foreign
    }

    /// Whether the text looks written in a language the user does not speak.
    static func isForeign(_ text: String, speaking languages: SpokenLanguages = .chineseAndEnglish) -> Bool {
        verdict(on: text, speaking: languages) == .foreign
    }

    /// The language the user added that the text is written in, nil for Chinese, English
    /// and a language the user does not speak.
    static func addedLanguage(of text: String, speaking languages: SpokenLanguages) -> SpeechLanguage? {
        guard !languages.added.isEmpty, case .added(let language) = verdict(on: text, speaking: languages) else { return nil }
        return language
    }

    static func verdict(on text: String, speaking languages: SpokenLanguages = .chineseAndEnglish) -> Verdict {
        let japanese = languages.contains(.japanese)
        var han = 0
        var latin = 0
        var kana = 0
        var other = 0
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars where scalar.properties.isAlphabetic {
            if isHan(scalar) {
                han += 1
            } else if isLatin(scalar) {
                latin += 1
            } else if japanese, isKana(scalar) {
                kana += 1
            } else if scalar.properties.generalCategory.isLetter {
                other += 1
            }
        }
        let letters = han + latin + kana + other
        guard letters > 0 else { return .chineseOrEnglish }
        if Double(other) >= Double(letters) * otherScriptShare { return .foreign }
        // Foreign but for its kana.
        if kana > 0, Double(kana + other) >= Double(letters) * otherScriptShare { return .added(.japanese) }
        // Latin text with a few Han characters at most, long enough to judge.
        guard latin >= minimumLatinLetters, Double(latin) >= Double(letters) * 0.9 else { return .chineseOrEnglish }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let english = recognizer.languageHypotheses(withMaximum: 80)[.english] ?? 0
        if english >= englishFloor { return .chineseOrEnglish }
        if languages.contains(.spanish), recognizer.dominantLanguage == .spanish { return .added(.spanish) }
        return .foreign
    }

    /// Han ideographs: the unified blocks, their extensions and the compatibility block.
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: true
        default: false
        }
    }

    /// Kana, with the marks 々 and 〆 that Japanese writes with Han characters. A letter
    /// of another script unless Japanese is on.
    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3005, 0x3006, 0x3041...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF: true
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
