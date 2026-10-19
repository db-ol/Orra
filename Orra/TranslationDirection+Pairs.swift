import Foundation
import NaturalLanguage

/// The direction rules for Japanese and Spanish, which find whether a text is in English,
/// in the dictation language, or in neither. Chinese keeps the rule of
/// `TranslationDirection.sourceLanguage(of:)`.
nonisolated extension TranslationDirection {
    // MARK: Japanese

    /// A kana weighs this many Han characters. Kana carry the grammar of Japanese, so a
    /// few of them make a sentence Japanese, as in このPRをreviewしてください.
    static let kanaWeight = 1.5

    /// The language of a text for a user who dictates in Japanese. With h Han characters, k
    /// kana, L Latin letters and fe English function words, J = h + 1.5 k and
    /// E = L / 5 + 2 fe, as the Chinese rule weighs English, where a word with an apostrophe
    /// inside, such as I'll, counts as a function word. The text is Japanese when
    /// J >= E, and English when E > J, unless letters of other scripts, such as Hangul,
    /// outnumber both. Kana only Japanese, such as はい or ありがとう, is always Japanese.
    /// Han characters alone cannot tell Japanese from Chinese, so Chinese counts as
    /// Japanese and is translated into English too. An honorific right after a name
    /// (田中さん, 山田様, Emilyさん) does not count, so "Thanks, 山田さん" is English. Nil
    /// without a letter.
    static func japaneseSource(of text: String) -> Source? {
        let scalars = Array(text.precomposedStringWithCompatibilityMapping.unicodeScalars)
        var han = 0
        var kana = 0
        var latin = 0
        var other = 0
        var afterName = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if afterName, let honorific = japaneseHonorifics.first(where: { scalars[index...].starts(with: $0) }) {
                index += honorific.count
                afterName = false
                continue
            }
            index += 1
            afterName = false
            guard scalar.properties.isAlphabetic else { continue }
            if LanguageGuard.isHan(scalar) {
                han += 1
                afterName = true
            } else if LanguageGuard.isKana(scalar) {
                kana += 1
            } else if LanguageGuard.isLatin(scalar) {
                latin += 1
                afterName = true
            } else if isLetter(scalar) {
                other += 1
            }
        }
        guard han + kana + latin + other > 0 else { return nil }
        let japanese = Double(han) + kanaWeight * Double(kana)
        // English function words, and words with an apostrophe inside, such as I'll.
        let englishFunction = words(String(String.UnicodeScalarView(scalars))).filter { englishFunction.contains($0) || $0.contains("'") || $0.contains("’") }.count
        let english = Double(latin) / 5 + Double(2 * englishFunction)
        let others = Double(other)
        if japanese > 0, japanese >= english, japanese >= others {
            return .partner
        }
        if english > japanese, english >= others {
            return .english
        }
        return .other
    }

    /// Whether a text holds words of `language` that a translation into English has to
    /// translate, also when most of it is English: a Han character or kana for Japanese,
    /// and for Spanish a word the Spanish rule counts, such as mañana or de, or ¿ or ¡.
    /// Always false for Chinese, whose routes keep their rules.
    static func holdsWords(of language: DictationLanguage, in text: String) -> Bool {
        switch language {
        case .chinese: false
        case .japanese: text.unicodeScalars.contains { LanguageGuard.isHan($0) || LanguageGuard.isKana($0) }
        case .spanish: SpanishCounts(text.precomposedStringWithCompatibilityMapping).spanish > 0
        }
    }

    /// Honorifics after a name, which the rule leaves out.
    static let japaneseHonorifics: [[Unicode.Scalar]] = ["さん", "さま", "様", "くん", "ちゃん", "氏"].map { Array($0.unicodeScalars) }

    // MARK: Spanish

    /// The language of a text for a user who dictates in Spanish. Letters of other scripts,
    /// Han characters and kana among them, from LanguageGuard.otherScriptShare of all
    /// letters on make it another language. Otherwise S counts 2 for each Spanish
    /// function word (1 for de, del, el, la, los, las and y, which names and places hold, as
    /// in María de la Cruz or Los Angeles), 1 for each word in lowercase with an accent or
    /// ñ, and 2 for ¿ or ¡. E counts 2 for each English function word, leaving out a, no, me, he and has,
    /// which Spanish shares, and each word with an apostrophe inside, such as don't. A word
    /// in capitals only, such as LA or PR, counts for neither. The text is Spanish when
    /// S > E + 1 and English when E > S + 1. A closer call, such as Sure or Plan B, goes to
    /// NLLanguageRecognizer, held to English and Spanish, and without an answer the text
    /// counts as Spanish, so it is translated into English. Nil without a letter.
    static func spanishSource(of text: String) -> Source? {
        let folded = text.precomposedStringWithCompatibilityMapping
        var latin = 0
        var foreign = 0
        for scalar in folded.unicodeScalars where scalar.properties.isAlphabetic {
            if LanguageGuard.isLatin(scalar) {
                latin += 1
            } else if isLetter(scalar) {
                foreign += 1
            }
        }
        let letters = latin + foreign
        guard letters > 0 else { return nil }
        if Double(foreign) >= Double(letters) * LanguageGuard.otherScriptShare {
            return .other
        }
        let counts = SpanishCounts(folded)
        if counts.spanish > counts.english + 1 {
            return .partner
        }
        if counts.english > counts.spanish + 1 {
            return .english
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(folded)
        return recognizer.dominantLanguage == .english ? .english : .partner
    }

    /// The scores of the Spanish rule.
    struct SpanishCounts: Equatable {
        var spanish = 0.0
        var english = 0.0

        init(_ text: String) {
            for word in TranslationDirection.latinWords(text) {
                let letters = word.filter(\.isLetter)
                if letters.count >= 2, letters == letters.uppercased() {
                    continue
                }
                let lower = word.lowercased()
                if let weight = TranslationDirection.spanishFunction[lower] {
                    spanish += weight
                }
                // An accent in a word in lowercase, since names such as José or Bogotá carry
                // theirs in English too.
                if word.first?.isLowercase == true, lower.unicodeScalars.contains(where: TranslationDirection.spanishAccents.contains) {
                    spanish += 1
                }
                if TranslationDirection.englishFunctionForSpanish.contains(lower) || lower.contains(where: { $0 == "'" || $0 == "’" }) {
                    english += 2
                }
            }
            if text.contains("¿") || text.contains("¡") {
                spanish += 2
            }
        }
    }

    /// Spanish function words and common short words, with their weight. The words names
    /// and places hold weigh 1.
    static let spanishFunction: [String: Double] = {
        var words: [String: Double] = [:]
        for word in ["de", "del", "el", "la", "los", "las", "y"] {
            words[word] = 1
        }
        let common = """
        un una unos unas al en o que qué por para con sin sobre entre desde hasta es eres soy somos está estás están estoy \
        estamos fue fui ser estar hay tengo tienes tiene tenemos tienen hago hace haces hacer voy vas va vamos ir puedo \
        puedes puede podemos quiero quieres quiere necesito necesitas sé sabes creo se lo le les te nos mi mis tu tus su sus \
        yo tú él ella ellos ellas nosotros usted ustedes este esta esto estos estas ese esa eso esos esas aquí ahí allí \
        como cómo cuando cuándo donde dónde quién cuál cuánto pero más muy ya también porque pues si sí bien mucho muchas \
        muchos poco todo todos nada algo ahora después luego antes siempre nunca hola gracias vale claro bueno buena \
        buenos buenas perdón mañana hoy ayer día mejor otro otra listo lista perfecto perfecta genial exacto oye mira \
        verdad igualmente ahorita ojalá dale ajá órale ándale
        """
        for word in common.split(whereSeparator: \.isWhitespace) {
            words[String(word)] = 2
        }
        return words
    }()

    /// The English function words of the Chinese rule without those Spanish shares or
    /// writes too: a, no, me, he, has, ok and okay.
    static let englishFunctionForSpanish = englishFunction.subtracting(["a", "no", "me", "he", "has", "ok", "okay"])

    /// The letters with an accent that Spanish writes.
    static let spanishAccents = Set("áéíóúüñ".unicodeScalars)

    /// Words of Latin letters, accented ones too, in their case, with an apostrophe inside a
    /// word kept: don't, l’eau.
    static func latinWords(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return latinWord.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static let latinWord = try! NSRegularExpression(pattern: "\\p{Latin}+(?:['’]\\p{Latin}+)*")

    /// A letter of any script.
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }
}
