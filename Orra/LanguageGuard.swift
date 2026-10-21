import Foundation
import NaturalLanguage

/// Catches a transcript the model wrote in a language other than the user's dictation
/// language and English, see DictationLanguage.
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
/// With Japanese chosen, kana and Han characters are Japanese, since Han characters alone
/// cannot tell Japanese from Chinese, and other scripts stay foreign. With Spanish chosen,
/// Han characters and kana are foreign like any other script, and Latin text is Spanish
/// when NLLanguageRecognizer finds Spanish the most likely language, so Portuguese, Catalan,
/// Italian or Swedish stays foreign. On the 200 FLEURS clips of each, the model's text was
/// Japanese or Spanish by these rules every time.
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

    /// What the guard finds a text written in, for the user's dictation language.
    nonisolated enum Verdict: Equatable, Sendable {
        /// Chinese, English, a mix of them, or too little to judge: the text Orra's steps
        /// were made for. With Japanese or Spanish chosen, English.
        case chineseOrEnglish
        /// Japanese, also mixed with English, for a user who dictates in Japanese.
        case japanese
        /// Spanish, or Latin text too short to judge, for a user who dictates in Spanish.
        case spanish
        /// A language the user does not dictate in.
        case foreign
    }

    /// Whether the text looks written in a language other than the dictation language and
    /// English.
    static func isForeign(_ text: String, for language: DictationLanguage = .chinese) -> Bool {
        verdict(on: text, for: language) == .foreign
    }

    /// Whether a caption's text looks written in none of the four languages Live Captions
    /// read, Chinese, English, Japanese and Spanish, whatever the dictation language: the
    /// verdict for Chinese finds it foreign, the one for Japanese finds no Japanese and
    /// the one for Spanish no Spanish. So a meeting in any of the four keeps the speech
    /// model's first pass, and only a fifth language, such as Swedish or Korean, is
    /// transcribed again, see Transcription.transcribeCaption. Measured on 2026-10-19 on
    /// 753 clips and 1,006 caption sentences of Chinese, Cantonese and mixed speech, this
    /// kept every first pass the Chinese verdict keeps and none held a kana, and Japanese
    /// and Spanish meetings needed no other pass.
    static func isForeignToCaptions(_ text: String) -> Bool {
        verdict(on: text, for: .chinese) == .foreign
            && verdict(on: text, for: .japanese) != .japanese
            && verdict(on: text, for: .spanish) != .spanish
    }

    /// Whether the steps made for Chinese and English take the text: the filler and number
    /// rules, the cleanup model and learning from corrections. Every text with Chinese
    /// chosen, as before the choice. With Japanese or Spanish chosen, English only: not
    /// their own language, and not text in another language that no pass could change,
    /// which the cleanup model's checks cannot read either.
    static func takesChineseAndEnglishSteps(_ text: String, for language: DictationLanguage) -> Bool {
        language == .chinese || verdict(on: text, for: language) == .chineseOrEnglish
    }

    /// For Chinese, the verdict Orra always had: other scripts from `otherScriptShare` of
    /// the letters on, kana among them, are foreign, and so is Latin text long enough to
    /// judge that is not English. For Japanese, kana and Han characters count as Japanese.
    /// For Spanish, Han characters and kana count as other scripts, and Latin text long
    /// enough to judge is Spanish, English or foreign, in that order.
    static func verdict(on text: String, for language: DictationLanguage = .chinese) -> Verdict {
        var han = 0
        var latin = 0
        var kana = 0
        var other = 0
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars where scalar.properties.isAlphabetic {
            if isHan(scalar) {
                han += 1
            } else if isLatin(scalar) {
                latin += 1
            } else if language != .chinese, isKana(scalar) {
                kana += 1
            } else if scalar.properties.generalCategory.isLetter {
                other += 1
            }
        }
        let letters = Double(han + latin + kana + other)
        // Latin text with a few Han characters at most, long enough to judge.
        let isLatinText = latin >= minimumLatinLetters && Double(latin) >= letters * 0.9
        switch language {
        case .chinese:
            guard letters > 0 else { return .chineseOrEnglish }
            if Double(other) >= letters * otherScriptShare { return .foreign }
            guard isLatinText else { return .chineseOrEnglish }
            return isEnglish(text) ? .chineseOrEnglish : .foreign
        case .japanese:
            guard letters > 0 else { return .chineseOrEnglish }
            if Double(other) >= letters * otherScriptShare { return .foreign }
            if isLatinText { return isEnglish(text) ? .chineseOrEnglish : .foreign }
            // Latin text too short to judge is English, as for Chinese.
            if Double(latin) >= letters * 0.9 { return .chineseOrEnglish }
            return han + kana > 0 ? .japanese : .chineseOrEnglish
        case .spanish:
            if Double(han + kana + other) >= letters * otherScriptShare, letters > 0 { return .foreign }
            guard isLatinText else { return .spanish }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if recognizer.dominantLanguage == .spanish { return .spanish }
            let english = recognizer.languageHypotheses(withMaximum: 80)[.english] ?? 0
            return english >= englishFloor ? .chineseOrEnglish : .foreign
        }
    }

    /// Whether NLLanguageRecognizer gives Latin text a chance of being English of at least
    /// `englishFloor`.
    private static func isEnglish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let english = recognizer.languageHypotheses(withMaximum: 80)[.english] ?? 0
        return english >= englishFloor
    }

    /// Han ideographs: the unified blocks, their extensions and the compatibility block.
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: true
        default: false
        }
    }

    /// Kana, with the marks 々 and 〆 that Japanese writes with Han characters. A letter of
    /// another script for a user who dictates in Chinese.
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

extension Unicode.GeneralCategory {
    /// A letter of any script.
    nonisolated var isLetter: Bool {
        switch self {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }
}
