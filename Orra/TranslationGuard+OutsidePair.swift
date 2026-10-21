import Foundation
import NaturalLanguage

/// The checks of a route from English into a target outside the user's pair, such as
/// English into Japanese for a user who dictates in Chinese, see TranslationPlan. They are
/// the checks of that route, as for English text of a user who dictates in the target's
/// language, with three more that the measurements of 2026-10-19 and 2026-10-20 found
/// these routes need, see docs/manual-testing.md. Measured on the route from English of
/// 319 FLEURS sentences per target, on human text and on made up translations:
/// - Into Japanese, no Han character that Japanese does not write, see
///   `hasHanOutsideJapanese(_:source:)`. The checks of the route let through 13 of 319
///   Chinese sentences given as Japanese and 19 of 79 Japanese sentences with two or more
///   simplified forms. With this one they held back all of them, and no human Japanese
///   text.
/// - Into Japanese, a 1 that counts one thing, as in 1つの文化 for "a singular culture",
///   is no new number when every number of the English is kept, see
///   `countingOnes(in:source:)`.
/// - Into Spanish, no other language that NLLanguageRecognizer finds well ahead of
///   Spanish, see `isOtherThanSpanish(_:)`. The checks of the route let through 72 of 318
///   Portuguese and 90 of 305 French sentences given as Spanish.
///
/// Into Chinese the route's checks already hold back every kana, so they stay as they
/// are. The routes between English and the dictation language keep their checks, so
/// nothing changes for them.
nonisolated extension TranslationGuard {
    /// Nil when `output`, the translation of `source` on `route` into a target outside the
    /// user's pair, may be pasted. `source` is English, or the English of a translation
    /// through English.
    static func checkOutsidePair(source: String, output: String, route: TranslationRoute) -> Failure? {
        guard route.language != .chinese else { return check(source: source, output: output, target: route.target) }
        let numbers = route.target == .japanese ? countingOnes(in: output, source: source) : output
        if let failure = checkPair(source: source, output: output, route: route, numbers: numbers) {
            return failure
        }
        switch route.target {
        case .japanese: return hasHanOutsideJapanese(output, source: source) ? .hanOutsideJapanese : nil
        case .spanish: return isOtherThanSpanish(output) ? .otherThanSpanish : nil
        case .english, .chinese: return nil
        }
    }

    // MARK: Japanese

    /// Whether a Japanese translation holds a Han character that Shift_JIS (Windows code
    /// page 932) cannot write, such as the simplified 报, 龙 or 该, other than one the source
    /// holds, as a short Chinese name may stay in the English, and other than a standard
    /// Japanese form that Shift_JIS lacks, see `japaneseFormsOutsideShiftJIS`. Japanese is
    /// written in the characters of Shift_JIS: none of the 319 human Japanese sentences of
    /// FLEURS holds one outside it, while 317 of 319 Chinese sentences do. On the route
    /// from English, through English or not, it held back 8 of 1,153 model translations
    /// into Japanese, each with Chinese characters in it, such as 九龙 or 集邮.
    static func hasHanOutsideJapanese(_ output: String, source: String) -> Bool {
        let sourceScalars = Set(source.unicodeScalars)
        return output.unicodeScalars.contains { scalar in
            TranslationDirection.isHan(scalar) && !sourceScalars.contains(scalar) && !japaneseFormsOutsideShiftJIS.contains(scalar)
                && !String(scalar).canBeConverted(to: shiftJIS)
        }
    }

    /// Windows code page 932, Shift_JIS as Japanese Windows and macOS write it.
    static let shiftJIS = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

    /// Standard Japanese forms that Shift_JIS lacks, since it has only a simpler form, such
    /// as 剥 for 剝 or 嘘 for 噓: the three of the Jōyō table of 2010 (剝, 頰, 塡), those
    /// JIS X 0213 added in 2004, and the print standard forms of common kanji outside the
    /// Jōyō table, such as 鷗, 俠 and 蔣. Each is in JIS X 0213 and is no simplified Chinese
    /// form. JIS X 0213 as a whole is not taken, since it holds simplified forms such as
    /// 关, 开 and 种, which 46 of the 479 characters outside Shift_JIS of the Chinese FLEURS
    /// sentences are.
    static let japaneseFormsOutsideShiftJIS = Set("剝頰塡俱吞噓姸屛幷瘦繫鷗俠蔣醬瀆摑禱蠟麴鹼驒蟬顚搔攢潑醱繡囊".unicodeScalars)

    /// `output` with each 1 that counts one thing written as 一, which the number check
    /// does not read, as it does not read 一つ:
    /// - a 1 right before a counter, such as 1つ, 1人, 1分 or 1か月, or after 分の, as in
    ///   3分の1, when the English source has a word for one: a, an, one, single, singular,
    ///   once, alone, each or per. Not after 時, so the minute of 10時1分 stays a number.
    /// - the 1 of 1年中 and 1日中 (all year, all day) when the source has all, whole, entire,
    ///   round or throughout.
    ///
    /// Only when every number of the English is in `output`, see `keepsNumbers(of:in:)`.
    /// Nearly every English sentence has a word for one, and the number check reads only
    /// the numbers a translation adds, so 1分後 for "in 5 minutes" would pass otherwise.
    ///
    /// Japanese writes 1つの文化 for "a singular culture" and 1分間 for "for a minute". The
    /// number check held back 13 of the 319 human Japanese sentences of FLEURS translated
    /// from English, 6 of them for such a 1.
    static func countingOnes(in output: String, source: String) -> String {
        guard keepsNumbers(of: source, in: output) else { return output }
        let words = Set(all(lowercaseWord, in: source.lowercased()))
        var text = output
        if !words.isDisjoint(with: wordsForOne) {
            text = replacing(countedOne, in: text) { _ in "一" }
        }
        if !words.isDisjoint(with: wordsForAll) {
            text = replacing(oneAllAlong, in: text) { _ in "一" }
        }
        return text
    }

    /// Whether every number of the English `source` is in `output`, a Japanese
    /// translation, by the values the number check reads, see `englishNumbers(_:)`.
    static func keepsNumbers(of source: String, in output: String) -> Bool {
        let values = pairSourceValues(output)
        return englishNumbers(source).allSatisfy { number in
            values.contains { abs($0 - number) < 1e-6 * max(1, abs(number)) }
        }
    }

    /// The numbers of an English text: each run of digits, and each number word but one,
    /// with twenty five as 25. One is left out, since a counted 1 may stand for it.
    static func englishNumbers(_ text: String) -> [Double] {
        var numbers = all(decimal, in: joinedNumbers(asciiDigits(text))).compactMap(Double.init)
        let words = all(lowercaseWord, in: text.lowercased().replacingOccurrences(of: "-", with: " "))
        var index = 0
        while index < words.count {
            if let ten = tens[words[index]] {
                if index + 1 < words.count, let one = ones[words[index + 1]], (1..<10).contains(one) {
                    numbers.append(ten + one)
                    index += 1
                } else {
                    numbers.append(ten)
                }
            } else if words[index] != "one", let one = ones[words[index]] {
                numbers.append(one)
            }
            index += 1
        }
        return numbers
    }

    static let wordsForOne: Set<String> = ["a", "an", "one", "single", "singular", "once", "alone", "each", "per"]
    static let wordsForAll: Set<String> = ["all", "whole", "entire", "round", "throughout"]

    /// A 1, not part of a longer number or a clock time, right before a counter, or after
    /// 分の.
    private static let countedOne = regex("(?<![0-9０-９.,時])1(?=(?:つ|人|名|分|秒|時間|日|週|年|か月|ヶ月|カ月|ケ月|箇月|回|度|個|件|枚|台|本|匹|頭|羽|冊|杯|番|位|歳|才|社|軒|点|部|通|曲|品|種|段|階|歩|晩|泊|世紀|語|行|文|期|周|食|組|袋|箱|席|室|棟|作|話|巻|章|節|票|面))|(?<=分の)1(?![0-9０-９.,])")
    /// The 1 of 1年中 and 1日中.
    private static let oneAllAlong = regex("(?<![0-9０-９.,])1(?=年中|日中)")

    // MARK: Spanish

    /// Whether NLLanguageRecognizer, held to Spanish and the languages a Spanish translation
    /// may slip into (Portuguese, French, Italian, Catalan and English), finds another one
    /// ahead of Spanish by `otherThanSpanishLead` or more, in a text of
    /// `otherThanSpanishLetters` Latin letters or more. It held back all 318 Portuguese and
    /// 305 French FLEURS sentences given as Spanish, and none of 2,536 Spanish texts, human
    /// and translated. Cut to their first 30 to 60 letters, it held back 2,013 of 2,014
    /// Portuguese and French pieces and none of 1,033 Spanish ones. The closest Spanish text
    /// trailed by 0.48, a sentence that opens with the Catalan dish Pa amb Oli. With 20
    /// letters and any lead, short Spanish such as “Por favor, revisen esta PR.” read as
    /// Portuguese.
    static func isOtherThanSpanish(_ output: String) -> Bool {
        guard output.unicodeScalars.filter(LanguageGuard.isLatin).count >= otherThanSpanishLetters else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.spanish, .portuguese, .french, .italian, .catalan, .english]
        recognizer.processString(output)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 6)
        let spanish = hypotheses[.spanish] ?? 0
        return hypotheses.contains { $0.key != .spanish && $0.value - spanish >= otherThanSpanishLead }
    }

    static let otherThanSpanishLetters = 30
    static let otherThanSpanishLead = 0.7
}
