import Foundation

/// Cheap checks on a translation from the local model, so a translation that answered the
/// dictation, carried it out, lost part of it or changed a number is never pasted. The
/// text without translation is pasted instead.
///
/// A port of guards2.py of the translation benchmark of 2026-10-12, which builds on the
/// cleanup checks in RewriteGuard, and one more check: an acronym of the source has to come
/// through unchanged in English, after the model once turned GMV into QoM. Over every
/// output of the benchmark's prompt variants it held back none that was right, and it
/// caught every adversarial output that answered. TranslationGuardTests runs those outputs
/// and expects the verdicts of the Python version. Two differences are deliberate: a number
/// of 7 or more digits has to come through exactly, see `newNumbers`, and Chinese numerals
/// said digit by digit or with 零 are read as written, see `digitReadings` and
/// `chineseValue`.
nonisolated enum TranslationGuard {
    /// Why a translation was held back. `logName` names the check without any of the text.
    enum Failure: Equatable, Sendable, CustomStringConvertible {
        case empty
        case assistantOpener(String)
        case assistantPhrase(String)
        case caseChanged
        case foreignScript
        case bareShortReply
        case addedLines
        case addedMarkup
        /// Numbers that none of the source's numbers explains.
        case newNumber([String])
        case tooLong(output: Double, source: Double)
        case tooShort(output: Double, source: Double)
        /// A Chinese translation that is mostly Latin letters.
        case notChinese
        /// English words in a Chinese translation that the source did not have.
        case newLatinWords(Int)
        /// Han characters in an English translation, other than a short name of the source.
        case hanInEnglish
        /// Accented letters in English: another language.
        case accentedLatin
        /// Braces or a JSON key the source did not have.
        case json
        /// The source has an instruction before a colon, and the translation lost the
        /// colon, so it likely carried out what followed instead of translating it.
        case lostInstruction
        /// Acronyms of the source missing from an English translation.
        case acronymLost([String])
        /// A Japanese translation that is mostly Latin letters.
        case notJapanese
        /// Chinese in a Japanese translation, see TranslationGuard.isChineseInJapanese.
        case chineseInJapanese
        /// English left in a Japanese translation, see TranslationGuard.isEnglishInJapanese.
        case englishInJapanese
        /// Kana in an English translation, other than a short name of the source.
        case kanaInEnglish
        /// Spanish left in an English translation.
        case notEnglish
        /// English left in a Spanish translation.
        case notSpanish
        /// Accented letters in Spanish that Spanish does not write: another language.
        case foreignLatin
        /// Han characters in a Spanish translation, other than a short name of the source.
        case hanInSpanish

        /// The reason in the words of guards2.py, for the tests. It may hold numbers and
        /// acronyms from the text, so it is never logged.
        var description: String {
            switch self {
            case .empty: "empty output"
            case .assistantOpener(let phrase): "assistant opener '\(phrase)'"
            case .assistantPhrase(let phrase): "assistant phrase '\(phrase)'"
            case .caseChanged: "case changed"
            case .foreignScript: "foreign script"
            case .bareShortReply: "bare short reply"
            case .addedLines: "added lines"
            case .addedMarkup: "added markup"
            case .newNumber(let numbers): "new number " + numbers.joined(separator: ",")
            case .tooLong(let output, let source): "too long (\(Self.rounded(output)) vs \(Self.rounded(source)))"
            case .tooShort(let output, let source): "too short (\(Self.rounded(output)) vs \(Self.rounded(source)))"
            case .notChinese: "not Chinese"
            case .newLatinWords(let count): "new Latin words in Chinese output (\(count))"
            case .hanInEnglish: "Han in English output"
            case .accentedLatin: "accented Latin"
            case .json: "JSON in output"
            case .lostInstruction: "lost the instruction before a colon"
            case .acronymLost(let acronyms): "acronym lost " + acronyms.joined(separator: ",")
            case .notJapanese: "not Japanese"
            case .chineseInJapanese: "Chinese in Japanese output"
            case .englishInJapanese: "English in Japanese output"
            case .kanaInEnglish: "kana in English output"
            case .notEnglish: "Spanish in English output"
            case .notSpanish: "English in Spanish output"
            case .foreignLatin: "foreign accented Latin"
            case .hanInSpanish: "Han in Spanish output"
            }
        }

        /// The check that failed, for the log.
        var logName: String {
            switch self {
            case .empty: "empty"
            case .assistantOpener: "assistant opener"
            case .assistantPhrase: "assistant phrase"
            case .caseChanged: "case changed"
            case .foreignScript: "foreign script"
            case .bareShortReply: "bare short reply"
            case .addedLines: "added lines"
            case .addedMarkup: "added markup"
            case .newNumber: "new number"
            case .tooLong: "too long"
            case .tooShort: "too short"
            case .notChinese: "not Chinese"
            case .newLatinWords: "new Latin words"
            case .hanInEnglish: "Han in English"
            case .accentedLatin: "accented Latin"
            case .json: "JSON"
            case .lostInstruction: "lost instruction"
            case .acronymLost: "acronym"
            case .notJapanese: "not Japanese"
            case .chineseInJapanese: "Chinese in Japanese"
            case .englishInJapanese: "English in Japanese"
            case .kanaInEnglish: "kana in English"
            case .notEnglish: "not English"
            case .notSpanish: "not Spanish"
            case .foreignLatin: "foreign accent"
            case .hanInSpanish: "Han in Spanish"
            }
        }

        /// Python's "{:.0f}", which rounds half to even.
        private static func rounded(_ value: Double) -> String {
            String(format: "%.0f", value)
        }
    }

    /// A translation may be at most this many times as long as its source, in
    /// RewriteGuard.units.
    static let longest = 2.6
    /// And at least this many times, for English and for Chinese, which is more compact.
    static let shortestEnglish = 0.4
    static let shortestChinese = 0.3

    /// Nil when the translation of `source` into `target` may be pasted.
    static func check(source: String, output: String, target: TranslationTarget) -> Failure? {
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .empty
        }
        switch RewriteGuard.checkOpeners(source: source, output: output) {
        case .assistantOpener(let phrase): return .assistantOpener(phrase)
        case .assistantPhrase(let phrase): return .assistantPhrase(phrase)
        default: break
        }

        if RewriteGuard.isShouting(source: source, output: output) {
            return .caseChanged
        }
        if RewriteGuard.hasForeignScript(output), !RewriteGuard.hasForeignScript(source) {
            return .foreignScript
        }

        let sourceUnits = RewriteGuard.units(source)
        let outputUnits = RewriteGuard.units(output)
        let bareOutput = RewriteGuard.bare(output)
        if RewriteGuard.bareShortReplies.contains(bareOutput), bareOutput != RewriteGuard.bare(source), sourceUnits >= 4 {
            return .bareShortReply
        }
        if RewriteGuard.newlines(output) > RewriteGuard.newlines(source) + 1 {
            return .addedLines
        }
        if RewriteGuard.hasMarkup(output), !RewriteGuard.hasMarkup(source) {
            return .addedMarkup
        }

        let added = newNumbers(source: source, output: output)
        if !added.isEmpty {
            return .newNumber(added)
        }

        if outputUnits > max(sourceUnits * longest, sourceUnits + 8) {
            return .tooLong(output: outputUnits, source: sourceUnits)
        }
        // A correction can make the translation much shorter than the source.
        let shortest = target == .chinese ? shortestChinese : shortestEnglish
        if sourceUnits >= 6, outputUnits < sourceUnits * shortest, !matches(correctionCue, source) {
            return .tooShort(output: outputUnits, source: sourceUnits)
        }

        switch target {
        case .chinese, .japanese, .spanish:
            let letters = RewriteGuard.count(output, where: RewriteGuard.isLatinLetter)
            let han = RewriteGuard.han(output).count
            let script = letters + han
            if script > 0, Double(letters) / Double(script) > 0.6, han < 2 {
                return .notChinese
            }
            let sourceWords = Set(RewriteGuard.latinWords(source))
            let newWords = RewriteGuard.latinWords(output).filter { !sourceWords.contains($0) }.count
            if newWords > 2 {
                return .newLatinWords(newWords)
            }
        case .english:
            // Han may stay only as a short name copied from the source.
            if hasRunsLeft(hanRun, source: source, output: output) {
                return .hanInEnglish
            }
        }

        if target == .english, matches(accent, output), !matches(accent, source) {
            return .accentedLatin
        }
        if contains(output, "{") || contains(output, "\":"), !contains(source, "{") {
            return .json
        }

        // "翻译成英文：…" translated without its colon was likely carried out. Reported
        // speech such as 他说：… passes unless the translation is much shorter.
        if let first = colon.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)),
           !matches(timeColon, source), !matches(colon, output) {
            let before = (source as NSString).substring(to: first.range.location)
            if matches(instruction, before) || outputUnits < 0.6 * sourceUnits {
                return .lostInstruction
            }
        }

        if target == .english {
            let lost = lostAcronyms(source: source, output: output)
            if !lost.isEmpty {
                return .acronymLost(lost)
            }
        }
        return nil
    }

    /// Whether `output` holds runs of `regex`, such as Han characters, other than a short
    /// name copied from the source: a run the source lacks, or more than 4 characters in all.
    static func hasRunsLeft(_ regex: NSRegularExpression, source: String, output: String) -> Bool {
        let runs = all(regex, in: output)
        return !runs.isEmpty && (runs.contains(where: { !contains(source, $0) }) || runs.reduce(0, { $0 + $1.unicodeScalars.count }) > 4)
    }

    // MARK: Acronyms

    /// The acronyms of the source, two or more capitals that are not part of a longer word,
    /// a plural s allowed, that the output does not have in the same form. In order, once
    /// each.
    static func lostAcronyms(source: String, output: String) -> [String] {
        var lost: [String] = []
        for acronym in all(acronym, in: source) where !lost.contains(acronym) {
            let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: acronym) + "(?=s?(?![A-Za-z]))"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if !matches(regex, output) {
                lost.append(acronym)
            }
        }
        return lost
    }

    // MARK: Numbers

    /// The numbers of the output, as written there, that no value of the source explains.
    /// A translation may write a number in digits or words, in thousands or in 万, and a
    /// time in 12 or 24 hours, but never bring a number of its own.
    ///
    /// guards2.py accepts a number within a millionth of a source value, which lets a
    /// changed last digit of a phone number through. Here a number of `exactDigits` or more
    /// digits before any point has to match a source value exactly, unless the source has
    /// a correction cue (13812345678，不对，最后一位是9). This differs from guards2.py on
    /// purpose, as the reading of Chinese digits in `digitReadings` and `chineseValue` does.
    /// No output of the benchmark gets another verdict from either.
    static func newNumbers(source: String, output: String) -> [String] {
        let have = sourceValues(source)
        let exact = !matches(correctionCue, source)
        let text = joinedNumbers(asciiDigits(output))
        var added: [String] = []
        for number in all(decimal, in: text) {
            let value = Double(number) ?? .nan
            let long = exact && number.prefix { $0 != "." }.count >= exactDigits
            if !have.contains(where: { long ? abs(value - $0) < 0.001 : abs(value - $0) < 1e-6 * max(1, abs($0)) }) {
                added.append(number)
            }
        }
        return added
    }

    /// Text with ASCII digits, see `asciiDigits`, without thousands separators, and with
    /// 1万2千 and 1万2 as one number, 12000.
    static func joinedNumbers(_ text: String) -> String {
        let joined = replacing(tenThousandsAndThousands, in: removingThousandsSeparators(text)) { groups in thousands(groups[1] + groups[2]) }
        return replacing(tenThousandsAndDigit, in: joined) { groups in thousands(groups[1] + groups[2]) }
    }

    /// Every value a number in the source can stand for: digits with their multipliers
    /// (50K, 3 million, 1.2 亿), Chinese numerals, English number words and ordinals, months,
    /// weekdays, noon, midnight, half and quarter, each also divided by a thousand, ten
    /// thousand, a million, a hundred million and a billion, times a thousand, and moved by
    /// 12 hours.
    static func sourceValues(_ text: String) -> Set<Double> {
        let folded = removingThousandsSeparators(asciiDigits(text))
        var values: Set<Double> = []
        let nsFolded = folded as NSString
        for match in digitsWithMultiplier.matches(in: folded, range: NSRange(location: 0, length: nsFolded.length)) {
            let value = Double(nsFolded.substring(with: match.range(at: 1))) ?? 0
            values.insert(value)
            let unit = match.range(at: 2)
            if unit.location != NSNotFound, let multiplier = multipliers[nsFolded.substring(with: unit).lowercased()] {
                values.insert(value * multiplier)
            }
        }
        for run in all(chineseNumeral, in: text) {
            values.insert(chineseValue(run))
            for scalar in run.unicodeScalars {
                if let digit = chineseDigits[scalar] {
                    values.insert(digit)
                }
            }
        }
        values.formUnion(digitReadings(text))
        // 三点五 is 3.5 and 一点五万 15000.
        let nsText = text as NSString
        for match in chineseDecimal.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let whole = Int(chineseValue(nsText.substring(with: match.range(at: 1))))
            let fraction = nsText.substring(with: match.range(at: 2)).unicodeScalars.map { String(Int(chineseDigits[$0] ?? 0)) }.joined()
            let value = Double("\(whole).\(fraction)") ?? 0
            values.insert(value)
            let unit = match.range(at: 3)
            if unit.location != NSNotFound, let multiplier = multipliers[nsText.substring(with: unit)] {
                values.insert(value * multiplier)
            }
        }
        values.formUnion(englishValues(text))
        if contains(text, "半") {
            values.formUnion([30, 0.5])
        }
        if contains(text, "刻") {
            values.formUnion([15, 45])
        }
        for (index, pattern) in chineseWeekdays.enumerated() {
            if matches(pattern, text) {
                values.formUnion([Double(min(index + 1, 7)), index >= 6 ? 0 : Double(index + 1)])
            }
        }
        return expanded(values, dividedBy: [1e3, 1e4, 1e6, 1e8, 1e9], times: [1000])
    }

    /// The values, each also divided by every divisor, multiplied by every multiplier, and
    /// a whole hour moved by 12 hours.
    static func expanded(_ values: Set<Double>, dividedBy divisors: [Double], times multipliers: [Double]) -> Set<Double> {
        var more: Set<Double> = []
        for value in values {
            for divisor in divisors {
                more.insert(value / divisor)
            }
            if value >= 1, value <= 12, value == value.rounded(.towardZero) {
                more.insert(value + 12)
            }
            if value >= 13, value <= 24, value == value.rounded(.towardZero) {
                more.insert(value - 12)
            }
            for multiplier in multipliers {
                more.insert(value * multiplier)
            }
        }
        return values.union(more)
    }

    /// The values of English number words, ordinals, months and weekdays, and of noon,
    /// midnight, half and quarter, which may also be Chinese (中午, 凌晨).
    static func englishValues(_ text: String) -> Set<Double> {
        var values: Set<Double> = []
        let lower = text.lowercased()
        let words = all(lowercaseWord, in: lower.replacingOccurrences(of: "-", with: " "))
        var index = 0
        while index < words.count {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil
            var value: Double?
            if let tens = tens[word] {
                value = tens
                if let next, let one = ones[next], one < 10 {
                    value = tens + one
                    index += 1
                } else if let next, let ordinal = ordinals[next], ordinal < 10 {
                    value = tens + ordinal
                    index += 1
                }
            } else if let one = ones[word] {
                value = one
            } else if let ordinal = ordinals[word] {
                value = ordinal
            } else if word == "a" || word == "an", let next, ["dozen", "hundred", "thousand", "million", "billion"].contains(next) {
                value = 1
            }
            if let value {
                values.insert(value)
                if index + 1 < words.count, let multiplier = multipliers[words[index + 1]] {
                    values.insert(value * multiplier)
                }
            }
            index += 1
        }
        for (index, pattern) in monthPatterns.enumerated() {
            if matches(pattern, lower) {
                values.insert(Double(index + 1))
            }
        }
        for (index, day) in weekdays.enumerated() where contains(lower, day) {
            values.formUnion([Double(index + 1), index == 6 ? 0 : Double(index + 1)])
        }
        if matches(noon, text) {
            values.insert(12)
        }
        if matches(midnight, text) {
            values.formUnion([0, 12, 24])
        }
        if matches(half, text) {
            values.formUnion([30, 0.5])
        }
        if matches(quarter, text) {
            values.formUnion([15, 45, 0.25])
        }
        return values
    }

    /// The value of a run of Chinese numerals, as guards2.py reads it: 三万五 is 35000 and
    /// 三百五 350. Unlike guards2.py, a 零 after the last unit keeps the last digit in the
    /// ones, so 两千零二 is 2002 and 三万零五 30005, not 2200 and 35000.
    static func chineseValue(_ run: String) -> Double {
        var total = 0.0
        var section = 0.0
        var digit: Double?
        var lastUnit: Double?
        var zeroAfterUnit = false
        for scalar in run.unicodeScalars {
            if let value = chineseDigits[scalar] {
                digit = value
                if value == 0 {
                    zeroAfterUnit = true
                }
            } else if let unit = chineseUnits[scalar] {
                section += (digit ?? 1) * unit
                lastUnit = unit
                digit = nil
                zeroAfterUnit = false
            } else if scalar == "万" || scalar == "亿" {
                let unit: Double = scalar == "万" ? 10_000 : 100_000_000
                total += (section + (digit ?? 0)) * unit
                section = 0
                digit = nil
                lastUnit = unit
                zeroAfterUnit = false
            }
        }
        if let digit {
            if let lastUnit, lastUnit >= 100, !zeroAfterUnit {
                section += digit * (lastUnit / 10).rounded(.down)
            } else {
                section += digit
            }
        }
        return total + section
    }

    /// The values of Chinese numerals said digit by digit, as years and phone numbers are:
    /// 二零零二 is 2002, 二〇二四 2024 and 幺三八 138. A run of three or more digits, without
    /// 十, 百, 千, 万 or 亿, is its string of digits. Two digits count only before 年, as
    /// 九八年 is 98 and also 1998 and 2098, and not when they are a rough count such as
    /// 三四年 (two digits in a row going up) or hold 两, as 两三个 does.
    static func digitReadings(_ text: String) -> Set<Double> {
        var values: Set<Double> = []
        let ns = text as NSString
        for match in chineseDigitRun.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let run = ns.substring(with: match.range)
            if run.contains("两") {
                continue
            }
            let digits = run.unicodeScalars.compactMap { chineseDigits[$0].map(Int.init) }
            guard let value = Double(digits.map(String.init).joined()) else { continue }
            if digits.count >= 3 {
                values.insert(value)
            } else if digits.count == 2 {
                let end = match.range.location + match.range.length
                let beforeYear = end < ns.length && ns.substring(with: NSRange(location: end, length: 1)) == "年"
                if beforeYear, digits[1] != digits[0] + 1 {
                    values.formUnion([value, 1900 + value, 2000 + value])
                }
            }
        }
        return values
    }

    /// Numbers this long, phone numbers and IDs, have to come through exactly.
    static let exactDigits = 7

    // MARK: Tables

    static let chineseDigits: [Unicode.Scalar: Double] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "幺": 1,
    ]
    static let chineseUnits: [Unicode.Scalar: Double] = ["十": 10, "百": 100, "千": 1000]
    static let ones: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Double] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let ordinals: [String: Double] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
        "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]
    static let multipliers: [String: Double] = [
        "hundred": 100, "thousand": 1e3, "k": 1e3, "million": 1e6, "m": 1e6, "mn": 1e6, "billion": 1e9, "bn": 1e9, "b": 1e9,
        "dozen": 12, "万": 1e4, "亿": 1e8, "千": 1e3, "百万": 1e6, "千万": 1e7,
    ]
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    // MARK: Patterns

    // NSRegularExpression, which reads code points as Python does and has lookbehind.
    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let thousandsSeparator = regex(#"(?<=\d),(?=\d{3})"#)
    static let digitsWithMultiplier = regex(#"(\d+(?:\.\d+)?)\s*(百万|千万|万|亿|千|[kKmMbB]n?\b|thousand|million|billion|hundred|dozen)?"#)
    static let chineseNumeral = regex("[零〇一二两三四五六七八九十百千万亿幺]+")
    /// A run of Chinese numerals with no unit inside or around it, and not the decimals of
    /// a number such as 三点一四一五九, which `chineseDecimal` reads.
    static let chineseDigitRun = regex("(?<![零〇一二两三四五六七八九幺十百千万亿])(?<![零〇一二两三四五六七八九十百千万亿]点)[零〇一二两三四五六七八九幺]++(?![十百千万亿])")
    static let chineseDecimal = regex("([零一二两三四五六七八九十]+)点([零一二三四五六七八九]+)(万|亿)?")
    static let tenThousandsAndThousands = regex(#"(\d+)\s*万\s*(\d)\s*千"#)
    static let tenThousandsAndDigit = regex(#"(\d+)\s*万\s*(\d)(?![\d.])"#)
    static let decimal = regex(#"\d+(?:\.\d+)?"#)
    static let lowercaseWord = regex("[a-z]+")
    /// A month's name or its first three letters, in lowercase text.
    static let monthPatterns = months.map { month in regex("\\b(\(month)|\(month.prefix(3)))\\b") }
    /// 周一 to 周日 and 周天, also with 星期 or 礼拜.
    static let chineseWeekdays = "一二三四五六日天".map { regex("(周|星期|礼拜)" + String($0)) }
    static let noon = regex(#"\bnoon\b|中午"#, .caseInsensitive)
    static let midnight = regex(#"\bmidnight\b|午夜|半夜|凌晨"#, .caseInsensitive)
    static let half = regex(#"\bhalf\b"#, .caseInsensitive)
    static let quarter = regex(#"\bquarter\b"#, .caseInsensitive)
    static let hanRun = regex("[\u{3400}-\u{9FFF}\u{F900}-\u{FAFF}]+")
    static let accent = regex("[\u{C0}-\u{D6}\u{D8}-\u{F6}\u{F8}-\u{24F}]")
    static let colon = regex("[:：]")
    static let timeColon = regex(#"\d[:：]\d"#)
    static let acronym = regex("(?<![A-Za-z])[A-Z]{2,}(?=s?(?![A-Za-z]))")
    /// Words that signal a spoken correction, which can make a translation much shorter.
    static let correctionCue = regex(#"不对|不是|我是说|说错了|应该是|删掉|算了|撤回|i mean|sorry|actually|scratch that|no wait|\bwait\b|never mind|rather"#, .caseInsensitive)
    /// Words of an instruction before a colon: translate, answer, 翻译, 用英文说.
    static let instruction = regex("翻译|译成|回答|回复|输出|用.{1,3}(说|写|回)|写一|总结|translate|answer|reply|respond|output|write|summari[sz]e|say", .caseInsensitive)

    // MARK: Helpers

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func all(_ regex: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Whether `text` holds `part`, code point for code point, as Python's `in` compares.
    static func contains(_ text: String, _ part: String) -> Bool {
        (text as NSString).range(of: part, options: .literal).location != NSNotFound
    }

    /// Every match replaced by what `replacement` makes of its groups.
    static func replacing(_ regex: NSRegularExpression, in text: String, with replacement: ([String]) -> String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += replacement(groups)
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }

    /// The digits times 1000 without leading zeros, as Python's str(int(digits) * 1000).
    static func thousands(_ digits: String) -> String {
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : trimmed + "000"
    }

    static func removingThousandsSeparators(_ text: String) -> String {
        thousandsSeparator.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }

    /// Decimal digits of any script, full width ones among them, as ASCII digits, so
    /// Double reads them as Python's float does.
    static func asciiDigits(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.numericType == .decimal, let value = scalar.properties.numericValue, !scalar.isASCII {
                result.append(Unicode.Scalar(UInt8(48 + Int(value))))
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }
}
