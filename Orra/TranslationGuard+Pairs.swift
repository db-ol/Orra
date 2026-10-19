import Foundation
import NaturalLanguage

/// The checks of the Japanese and Spanish routes. They do what the Chinese checks do, with
/// the words, numbers and scripts of the pair:
/// - Units count kana and words with accents, see `pairUnits`.
/// - Openers, short replies, correction cues and instructions before a colon have Japanese
///   and Spanish forms.
/// - Numbers read 億, 兆 and the Japanese eras, Spanish number words, and Spanish formats,
///   in which 2.500 may be 2500 and 3,5 may be 3.5.
/// - Each target has a check that the translation is in its language, such as no kana
///   left in English, no Spanish left in English, no English or Chinese left in Japanese
///   and no English left in Spanish.
///
/// The Chinese routes keep `check(source:output:target:)`, so nothing changes for them.
nonisolated extension TranslationGuard {
    /// Nil when the translation of `source` on `route` may be pasted.
    static func check(source: String, output: String, route: TranslationRoute) -> Failure? {
        guard route.language != .chinese else { return check(source: source, output: output, target: route.target) }
        return checkPair(source: source, output: output, route: route)
    }

    /// A translation may be at most `longest` times as long as its source, in `pairUnits`,
    /// and at least this many times from 6 units on. Japanese is more compact than
    /// English, and Spanish a little longer.
    static func shortest(_ route: TranslationRoute) -> Double {
        route.target == .japanese ? shortestChinese : shortestEnglish
    }

    private static func checkPair(source: String, output: String, route: TranslationRoute) -> Failure? {
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .empty
        }
        switch RewriteGuard.checkOpeners(source: source, output: output, openers: pairOpeners, excuses: pairExcuses, anywhere: pairAnywhere, latinBoundaries: true) {
        case .assistantOpener(let phrase): return .assistantOpener(phrase)
        case .assistantPhrase(let phrase): return .assistantPhrase(phrase)
        default: break
        }

        if RewriteGuard.isShouting(source: source, output: output) {
            return .caseChanged
        }
        // Kana is Japanese, so only a Japanese translation or one of a source with kana may
        // hold it. Hangul and Cyrillic never.
        if RewriteGuard.hasForeignScript(output, allowingKana: route.target == .japanese || hasKana(source)), !RewriteGuard.hasForeignScript(source) {
            return .foreignScript
        }

        let sourceUnits = pairUnits(source)
        let outputUnits = pairUnits(output)
        let bareOutput = RewriteGuard.bare(output)
        if pairShortReplies.contains(bareOutput), bareOutput != RewriteGuard.bare(source), sourceUnits >= 4 {
            return .bareShortReply
        }
        if RewriteGuard.newlines(output) > RewriteGuard.newlines(source) + 1 {
            return .addedLines
        }
        if RewriteGuard.hasMarkup(output), !RewriteGuard.hasMarkup(source) {
            return .addedMarkup
        }

        // A correction can make the translation much shorter than the source, and change
        // a long number.
        let corrects = matches(pairCorrectionCue, source)
        let added = newPairNumbers(source: source, output: output, target: route.target, corrects: corrects)
        if !added.isEmpty {
            return .newNumber(added)
        }

        if outputUnits > max(sourceUnits * longest, sourceUnits + 8) {
            return .tooLong(output: outputUnits, source: sourceUnits)
        }
        if sourceUnits >= 6, outputUnits < sourceUnits * shortest(route), !corrects {
            return .tooShort(output: outputUnits, source: sourceUnits)
        }

        switch route.target {
        case .english:
            if let failure = checkEnglish(source: source, output: output, language: route.language) {
                return failure
            }
        case .japanese:
            let letters = RewriteGuard.count(output, where: RewriteGuard.isLatinLetter)
            let han = RewriteGuard.han(output).count
            let kana = kanaCount(output)
            let script = letters + han + kana
            if script > 0, Double(letters) / Double(script) > 0.6, han + kana < 2 {
                return .notJapanese
            }
            if isChineseInJapanese(source: source, output: output) {
                return .chineseInJapanese
            }
            if isEnglishInJapanese(output) {
                return .englishInJapanese
            }
            let sourceWords = Set(RewriteGuard.latinWords(source))
            let newWords = RewriteGuard.latinWords(output).filter { !sourceWords.contains($0) }.count
            if newWords > 2 {
                return .newLatinWords(newWords)
            }
        case .spanish:
            let words = TranslationDirection.latinWords(output)
            if isEnglishLeft(output: output, words: words) {
                return .notSpanish
            }
            if hasRunsLeft(hanRun, source: source, output: output) {
                return .hanInSpanish
            }
            let foreign = Set(lowercaseWords(words).flatMap { $0.unicodeScalars.filter(isForeignAccent) }).subtracting(source.unicodeScalars)
            if !foreign.isEmpty {
                return .foreignLatin
            }
        case .chinese:
            break
        }

        if contains(output, "{") || contains(output, "\":"), !contains(source, "{") {
            return .json
        }

        // An instruction before a colon, translated without its colon, was likely carried
        // out, as for Chinese.
        if let first = colon.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)),
           !matches(timeColon, source), !matches(colon, output) {
            let before = (source as NSString).substring(to: first.range.location)
            if matches(instruction, before) || matches(pairInstruction, before) || outputUnits < 0.6 * sourceUnits {
                return .lostInstruction
            }
        }

        // Acronyms stay in English and Spanish. Japanese may write some in katakana or Han
        // characters, as Chinese may, so they are not checked there.
        if route.target != .japanese {
            let lost = lostPairAcronyms(source: source, output: output)
            if !lost.isEmpty {
                return .acronymLost(lost)
            }
        }
        return nil
    }

    /// The checks of an English translation: no Han characters or kana other than a short
    /// name copied from the source, no accented letters the source lacks, and no Spanish
    /// left.
    private static func checkEnglish(source: String, output: String, language: DictationLanguage) -> Failure? {
        if hasRunsLeft(hanRun, source: source, output: output) {
            return .hanInEnglish
        }
        if hasRunsLeft(kanaRun, source: source, output: output) {
            return .kanaInEnglish
        }
        // Names keep their accents, such as Chișinău or Fernández, so only a word in
        // lowercase with an accent the source lacks is another language.
        let words = TranslationDirection.latinWords(output)
        if lowercaseWords(words).contains(where: { matches(accent, $0) }), !matches(accent, source) {
            return .accentedLatin
        }
        if language == .spanish, isSpanishLeft(output, words: words) {
            return .notEnglish
        }
        return nil
    }

    // MARK: Language left in the translation

    /// Spanish left in an English translation: ¿ or ¡, or at least two Spanish function
    /// words and as many as English ones, or for 20 letters and more a text with more
    /// Spanish than English words that NLLanguageRecognizer finds Spanish rather than
    /// English. `words` are the output's, see TranslationDirection.latinWords.
    static func isSpanishLeft(_ output: String, words: [String]) -> Bool {
        if output.contains("¿") || output.contains("¡") {
            return true
        }
        let counts = TranslationDirection.SpanishCounts(output, words: words)
        if counts.spanish >= 4, counts.spanish >= counts.english {
            return true
        }
        return latinLetterCount(output) >= LanguageGuard.minimumLatinLetters && counts.spanish > counts.english && TranslationDirection.englishOrSpanish(output) == .spanish
    }

    /// English left in a Spanish translation: at least two English function words and
    /// more than the Spanish ones, or for 20 letters and more a text with more English than
    /// Spanish words that NLLanguageRecognizer finds English rather than Spanish. `words`
    /// are the output's, see TranslationDirection.latinWords.
    static func isEnglishLeft(output: String, words: [String]) -> Bool {
        let counts = TranslationDirection.SpanishCounts(output, words: words)
        if counts.english >= 4, counts.english > counts.spanish {
            return true
        }
        return latinLetterCount(output) >= LanguageGuard.minimumLatinLetters && counts.english > counts.spanish && TranslationDirection.englishOrSpanish(output) == .english
    }

    /// Chinese in a Japanese translation: two or more characters that only simplified
    /// Chinese writes and the source lacks, or no kana and 8 Han characters or more in a
    /// translation of a source that has kana or no Han at all, with one such character or
    /// from `hanOnlyLength` Han characters on. A name or place in Han characters alone, such
    /// as 東京駅八重洲中央口, stays Japanese.
    static func isChineseInJapanese(source: String, output: String) -> Bool {
        let sourceScalars = Set(source.unicodeScalars)
        let simplified = output.unicodeScalars.filter { simplifiedOnly.contains($0) && !sourceScalars.contains($0) }
        if simplified.count >= 2 {
            return true
        }
        let sourceIsHanOnly = !RewriteGuard.han(source).isEmpty && !hasKana(source)
        let han = RewriteGuard.han(output).count
        return !sourceIsHanOnly && han >= 8 && !hasKana(output) && (simplified.count == 1 || han >= hanOnlyLength)
    }

    /// Han characters without kana that make a Japanese translation Chinese even without a
    /// character that only simplified Chinese writes. Japanese sentences hold kana, and a
    /// name or place this long is rare.
    static let hanOnlyLength = 20

    /// Simplified characters that Japanese writes differently, so Japanese text does not
    /// hold them, such as 这 们 说 吗, for 這 們 説 and the particle か. Characters that
    /// Japanese writes too are left out, such as 区 (港区), 号 (番号), 写 (写真), 没 (没頭),
    /// 欧 (欧州) and 里 (里帰り).
    static let simplifiedOnly = Set("这们说么吗还让给对过时东车门问间现发实应该话请谢欢题难觉买卖钱务产码电脑个吧呢见长开关头场边认识语读传动业亚书导团员".unicodeScalars)

    /// English left in a Japanese translation, outside quotes: a lowercase Latin letter
    /// right after katakana, as in レcep, or a run of words in lowercase with an English
    /// function word, as in 45.99ドル plus 税金です. A name, a title in capitals or a quoted
    /// word, such as “good morning”, stays.
    static func isEnglishInJapanese(_ output: String) -> Bool {
        let unquoted = TranslationGuard.replacing(quoted, in: output) { _ in "" }
        if matches(katakanaThenLowercase, unquoted) {
            return true
        }
        for run in all(lowercaseRun, in: unquoted) {
            let words = run.split(separator: " ").map(String.init)
            if words.contains(where: { TranslationDirection.englishFunction.contains($0) || englishLeftWords.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Words that join a sentence, which a name in lowercase does not hold.
    static let englishLeftWords: Set<String> = ["plus", "minus", "per", "than", "then", "also", "very", "really", "only", "even", "still", "maybe"]

    private static func latinLetterCount(_ text: String) -> Int {
        text.unicodeScalars.filter(LanguageGuard.isLatin).count
    }

    /// Letters with an accent that Spanish does not write, such as à, ç or ö: another
    /// language.
    private static func isForeignAccent(_ scalar: Unicode.Scalar) -> Bool {
        LanguageGuard.isLatin(scalar) && !scalar.isASCII && !TranslationDirection.spanishAccents.contains(scalar)
    }

    // MARK: Measures

    /// A rough size that compares Japanese, Spanish and English: a Han character is one
    /// unit, a word 1.6 units, a distinct number one unit, as for Chinese, and a kana
    /// `kanaUnits`. Words have accented letters too.
    static func pairUnits(_ text: String) -> Double {
        Double(RewriteGuard.han(text).count) + 1.6 * Double(TranslationDirection.latinWords(text).count) + Double(RewriteGuard.numbers(text).count) + kanaUnits * Double(kanaCount(text))
    }

    /// What a kana weighs in `pairUnits`. With 0.5 the median English sentence of FLEURS
    /// was as long as its Japanese one, but short text in kana only, which takes more kana
    /// per word, ran into the length limit, such as いまどこ？もうついた？ with its English.
    /// With 0.7 the shortest English sentence of FLEURS is still 0.5 of its Japanese one.
    static let kanaUnits = 0.7

    static func kanaCount(_ text: String) -> Int {
        text.unicodeScalars.filter(isKanaLetter).count
    }

    static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isKanaLetter)
    }

    /// Hiragana and katakana, without the marks ・ and ー that other text may hold.
    private static func isKanaLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041...0x3096).contains(scalar.value) || (0x30A1...0x30FA).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value)
    }

    // MARK: Acronyms

    /// The acronyms of the source missing from the output, as `lostAcronyms` finds them,
    /// with the Spanish forms that stand for the same: IA for AI, ONU for UN, UE for EU,
    /// EE. UU. or estadounidense for US and OTAN for NATO, both ways. OK, AM and PM are
    /// words that a translation writes its own way, such as de acuerdo or de la tarde.
    static func lostPairAcronyms(source: String, output: String) -> [String] {
        lostAcronyms(source: source, output: output).filter { acronym in
            !notAcronyms.contains(acronym) && !(acronymEquivalents[acronym] ?? []).contains { output.localizedCaseInsensitiveContains($0) }
        }
    }

    static let notAcronyms: Set<String> = ["OK", "AM", "PM"]

    static let acronymEquivalents: [String: [String]] = [
        "AI": ["IA"], "IA": ["AI"],
        "UN": ["ONU"], "ONU": ["UN"],
        "EU": ["UE"], "UE": ["EU"],
        "US": ["EE. UU.", "EE.UU.", "EEUU", "USA", "estadounidense"], "USA": ["EE. UU.", "EE.UU.", "EEUU", "US", "estadounidense"], "EEUU": ["US", "USA"],
        "NATO": ["OTAN"], "OTAN": ["NATO"],
    ]

    /// The words of Latin letters that start in lowercase, which names do not, of those
    /// TranslationDirection.latinWords found.
    private static func lowercaseWords(_ words: [String]) -> [String] {
        words.filter { $0.first?.isLowercase == true }
    }

    // MARK: Numbers

    /// The numbers of the output that no value of the source explains, as `newNumbers`
    /// finds them, with the numbers of the pair. Into Spanish each number of the output may
    /// be read with a comma or a point for thousands, and passes when either reading is
    /// explained. `corrects` says whether the source has a correction cue, see
    /// `pairCorrectionCue`.
    static func newPairNumbers(source: String, output: String, target: TranslationTarget, corrects: Bool) -> [String] {
        let have = pairSourceValues(source)
        // The minutes of a full hour, as in 12:00, bring no number.
        let folded = asciiDigits(output.replacingOccurrences(of: ":00", with: ""))
        var added: [String] = []
        let tokens = target == .spanish ? all(spanishNumber, in: folded) : all(decimal, in: joinedNumbers(folded))
        for number in tokens {
            let readings = target == .spanish ? spanishReadings(number) : Double(number).map { [$0] } ?? []
            let explained = readings.contains { value in
                // Seven digits or more before the point have to match exactly, unless the
                // source corrects itself.
                let long = !corrects && abs(value) >= 1e6
                return have.contains(where: { long ? abs(value - $0) < 0.001 : abs(value - $0) < 1e-6 * max(1, abs($0)) })
            }
            if !explained {
                added.append(number)
            }
        }
        return added
    }

    /// Every value a number of a Japanese, Spanish or English source can stand for: the
    /// values of `sourceValues`, with 億 and 兆, 3万5千 as 35000, the eras 令和 and 平成,
    /// Spanish number words, times, months and weekdays, and both readings of Spanish
    /// formats, each also divided and multiplied as `sourceValues` does.
    static func pairSourceValues(_ text: String) -> Set<Double> {
        var base: Set<Double> = []
        let folded = asciiDigits(text)
        // 1.5億, 3兆, 2 millones.
        let ns = folded as NSString
        for match in digitsWithPairMultiplier.matches(in: folded, range: NSRange(location: 0, length: ns.length)) {
            let unit = ns.substring(with: match.range(at: 2)).lowercased()
            guard let multiplier = pairMultipliers[unit] else { continue }
            for value in spanishReadings(ns.substring(with: match.range(at: 1))) {
                base.formUnion([value, value * multiplier])
            }
        }
        // 3万5千, 2 mil 500.
        let joined = replacing(thousandAndDigits, in: joinedNumbers(folded)) { groups in String((Int(groups[1]) ?? 0) * 1000 + (Int(groups[2]) ?? 0)) }
        for number in all(decimal, in: joined) {
            if let value = Double(number) {
                base.insert(value)
            }
        }
        // Both readings of 2.500 and 3,5.
        for number in all(spanishNumber, in: folded) {
            base.formUnion(spanishReadings(number))
        }
        for run in all(japaneseNumeral, in: text) {
            base.insert(japaneseValue(run))
        }
        for match in era.matches(in: folded, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            let yearText = ns.substring(with: match.range(at: 2))
            let year = yearText == "元" ? 1 : Double(yearText) ?? japaneseValue(yearText)
            base.formUnion([year, (name == "令和" ? 2018 : 1988) + year])
        }
        base.formUnion(spanishValues(text))
        base.formUnion(japaneseWordValues(text))
        return sourceValues(text).union(expanded(base, dividedBy: [1e3, 1e4, 1e6, 1e8, 1e9, 1e12], times: [1000, 1e4, 1e8]))
    }

    /// The values a number written in Spanish may have: 2,500 and 2.500 are 2500 or 2.5,
    /// 3,5 is 3.5, and 1,500,000 is 1500000.
    static func spanishReadings(_ number: String) -> [Double] {
        var readings: [Double] = []
        // Comma for thousands, point for decimals, as es-419 in Mexico writes.
        let commaThousands = number.replacingOccurrences(of: ",", with: "")
        if let value = Double(commaThousands), commaThousands.filter({ $0 == "." }).count <= 1 {
            readings.append(value)
        }
        // Point for thousands, comma for decimals, as most of Latin America writes.
        let pointThousands = number.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        if let value = Double(pointThousands), pointThousands.filter({ $0 == "." }).count <= 1 {
            readings.append(value)
        }
        return readings
    }

    /// The value of a run of Japanese numerals with 万, 億 and 兆: 三億五千万 is 350000000.
    static func japaneseValue(_ run: String) -> Double {
        var total = 0.0
        var section = 0.0
        var digit: Double?
        for scalar in run.unicodeScalars {
            if let value = chineseDigits[scalar] {
                digit = (digit ?? 0) * 10 + value
            } else if let unit = chineseUnits[scalar] {
                section += (digit ?? 1) * unit
                digit = nil
            } else if let big = japaneseBigUnits[scalar] {
                total += (section + (digit ?? 0)) * big
                section = 0
                digit = nil
            }
        }
        return total + section + (digit ?? 0)
    }

    private static let japaneseBigUnits: [Unicode.Scalar: Double] = ["万": 1e4, "億": 1e8, "亿": 1e8, "兆": 1e12]

    /// Noon, midnight, weekdays and half past in Japanese.
    static func japaneseWordValues(_ text: String) -> Set<Double> {
        var values: Set<Double> = []
        if contains(text, "正午") {
            values.insert(12)
        }
        if contains(text, "真夜中") || contains(text, "深夜") || contains(text, "夜中") {
            values.formUnion([0, 12, 24])
        }
        for (index, day) in ["月曜", "火曜", "水曜", "木曜", "金曜", "土曜", "日曜"].enumerated() where contains(text, day) {
            values.formUnion([Double(index + 1), index == 6 ? 0 : Double(index + 1)])
        }
        return values
    }

    /// The values of Spanish number words, composed as dos mil quinientos is 2500 and mil
    /// millones 1000000000, and of times, months and weekdays.
    static func spanishValues(_ text: String) -> Set<Double> {
        var values: Set<Double> = []
        let lower = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let words = all(lowercaseWord, in: lower)
        var total = 0.0
        var current = 0.0
        var inNumber = false
        func end() {
            if inNumber {
                values.insert(total + current)
            }
            total = 0
            current = 0
            inNumber = false
        }
        for (index, word) in words.enumerated() {
            if let value = spanishNumberWords[word] {
                values.insert(value)
                current += value
                inNumber = true
            } else if word == "mil" {
                values.insert(1000)
                current = max(current, 1) * 1000
                total += current
                current = 0
                inNumber = true
            } else if word == "millon" || word == "millones" {
                values.insert(1e6)
                total = (total + max(current, inNumber ? 0 : 1)) * 1e6
                current = 0
                inNumber = true
            } else if word == "y", inNumber, index + 1 < words.count, spanishNumberWords[words[index + 1]] != nil {
                continue
            } else {
                end()
            }
        }
        end()
        for (index, month) in spanishMonths.enumerated() where words.contains(month) {
            values.insert(Double(index + 1))
        }
        for (index, day) in spanishWeekdays.enumerated() where words.contains(day) {
            values.formUnion([Double(index + 1), index == 6 ? 0 : Double(index + 1)])
        }
        if matches(spanishHalf, lower) {
            values.formUnion([30, 0.5])
        }
        if matches(spanishQuarter, lower) {
            values.formUnion([15, 45, 0.25])
        }
        if words.contains("mediodia") {
            values.insert(12)
        }
        if words.contains("medianoche") {
            values.formUnion([0, 12, 24])
        }
        return values
    }

    static let spanishNumberWords: [String: Double] = [
        "cero": 0, "un": 1, "uno": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8,
        "nueve": 9, "diez": 10, "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15, "dieciseis": 16,
        "diecisiete": 17, "dieciocho": 18, "diecinueve": 19, "veinte": 20, "veintiun": 21, "veintiuno": 21, "veintiuna": 21,
        "veintidos": 22, "veintitres": 23, "veinticuatro": 24, "veinticinco": 25, "veintiseis": 26, "veintisiete": 27,
        "veintiocho": 28, "veintinueve": 29, "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60, "setenta": 70,
        "ochenta": 80, "noventa": 90, "cien": 100, "ciento": 100, "doscientos": 200, "doscientas": 200, "trescientos": 300,
        "trescientas": 300, "cuatrocientos": 400, "cuatrocientas": 400, "quinientos": 500, "quinientas": 500,
        "seiscientos": 600, "seiscientas": 600, "setecientos": 700, "setecientas": 700, "ochocientos": 800,
        "ochocientas": 800, "novecientos": 900, "novecientas": 900,
        "primero": 1, "primer": 1, "primera": 1, "segundo": 2, "segunda": 2, "tercero": 3, "tercer": 3, "tercera": 3,
        "cuarto": 4, "cuarta": 4, "quinto": 5, "quinta": 5, "sexto": 6, "septimo": 7, "octavo": 8, "noveno": 9, "decimo": 10,
    ]
    static let spanishMonths = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
    static let spanishWeekdays = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]

    /// Units after digits in Japanese and Spanish: 1.5億, 3兆, 2 millones, 5 mil.
    static let pairMultipliers: [String: Double] = ["億": 1e8, "兆": 1e12, "万": 1e4, "千": 1e3, "mil": 1e3, "millon": 1e6, "millón": 1e6, "millones": 1e6, "billon": 1e12, "billón": 1e12, "billones": 1e12]

    // MARK: Tables

    /// RewriteGuard.openers with the Japanese and Spanish forms added to each group, so a
    /// translation that starts like its source passes.
    static let pairOpeners: [[String]] = zip(RewriteGuard.openers, [
        ["understood", "もちろん", "かしこまりました", "承知しました", "承知いたしました", "了解", "わかりました", "分かりました", "claro", "por supuesto", "con gusto", "de acuerdo", "vale", "entendido"],
        ["以下は", "以下が", "aquí tienes", "aquí está", "a continuación"],
        ["excuse me", "申し訳ありません", "申し訳ございません", "すみません", "ごめん", "lo siento", "perdón", "disculpa", "disculpe"],
        ["できません", "no puedo"],
        ["good morning", "good afternoon", "good evening", "こんにちは", "こんばんは", "おはよう", "hola", "buenas", "buenos días"],
        ["いい質問", "buena pregunta"],
        ["aiとして", "como ia", "como modelo"],
        [],
    ]).map(+)

    /// RewriteGuard.excuses with the Japanese and Spanish words that excuse a group, and a
    /// negation for "I can't", which Japanese and Spanish say in many ways.
    static let pairExcuses: [String: [String]] = RewriteGuard.excuses.merging([
        "sure": ["yes", "got it", "はい", "ええ", "うん", "えーと", "えっと", "あの", "sí", "si", "eh", "em", "este", "bueno", "ok", "listo", "dale"],
        "hello": ["えーと", "eh", "oye", "hey"],
        "i can't": ["ない", "ません", "無理", "no", "can't", "cannot"],
        "as an ai": ["として", "como"],
    ], uniquingKeysWith: +)

    /// RewriteGuard.anywhere with Japanese and Spanish forms added to each group.
    static let pairAnywhere: [[String]] = zip(RewriteGuard.anywhere, [
        ["aiとして", "como ia", "como una ia"],
        ["言語モデル", "modelo de lenguaje"],
        ["私はai", "soy una ia"],
        ["システムプロンプト", "prompt del sistema", "indicaciones del sistema"],
        ["私の指示", "mis instrucciones"],
        [], [], [], [], [],
    ]).map(+)

    /// RewriteGuard.shortReplies with Japanese and Spanish ones.
    static let pairShortReplies: Set<String> = Set((RewriteGuard.shortReplies.union(["はい", "いいえ", "うん", "ええ", "了解", "了解です", "わかりました", "sí", "si", "vale", "claro", "hola", "de acuerdo", "listo"])).map(RewriteGuard.bare))

    /// `correctionCue` with Japanese and Spanish ones.
    static let pairCorrectionCue = regex(correctionCue.pattern + #"|いや|じゃなくて|ではなく|間違えた|間違い|訂正|言い直|perd[oó]n|\bdigo\b|mejor dicho|quise decir|\bo sea\b|no,? espera"#, .caseInsensitive)

    /// Japanese and Spanish words of an instruction before a colon.
    static let pairInstruction = regex("翻訳|訳し|訳す|答え|返信|書いて|要約|言って|traduc|tradúc|contesta|responde|escribe|resume|dime", .caseInsensitive)

    private static let kanaRun = regex("[\u{3041}-\u{3096}\u{30A1}-\u{30FA}\u{30FC}]+")
    /// Text in quotes, which a translation may keep in English.
    private static let quoted = regex(#"“[^”]*”|「[^」]*」|『[^』]*』|"[^"]*"|'[^']*'|‘[^’]*’"#)
    private static let katakanaThenLowercase = regex("[\u{30A1}-\u{30FA}][a-z]")
    /// Words in lowercase, one or more, separated by spaces, outside a version, a file
    /// name, an address or a number such as 802.11a.
    private static let lowercaseRun = regex(#"(?<![A-Za-z0-9._@/-])[a-z]+(?: [a-z]+)*(?![A-Za-z0-9._@/-])"#)
    private static let japaneseNumeral = regex("[零〇一二三四五六七八九十百千万億兆]+")
    private static let era = regex("(令和|平成)\\s*(\\d+|元|[一二三四五六七八九十]+)\\s*年")
    private static let digitsWithPairMultiplier = regex(#"(\d+(?:[.,]\d+)?)\s*(億|兆|万|千|mil(?:l[oó]n(?:es)?)?\b|bill[oó]n(?:es)?)"#, .caseInsensitive)
    private static let thousandAndDigits = regex(#"(\d+)\s+mil\s+(\d{1,3})(?![\d.,])"#)
    /// A number as Spanish may write it, with points or commas between digits.
    private static let spanishNumber = regex(#"\d+(?:[.,]\d+)*"#)
    private static let spanishHalf = regex(#"\by media\b"#)
    private static let spanishQuarter = regex(#"\by cuarto\b|\bmenos cuarto\b"#)
}
