import Foundation

/// Checks on any text the model wrote, the points of an explanation as well as a draft:
/// - a date written with a weekday it does not fall on, such as 10月20日（周一） in 2026
/// - an amount that none of the sources holds
///
/// The model must not do arithmetic (code step 6 of the phase 0 report). It copies amounts
/// from the sources and leaves totals to the user. So an amount the sources do not hold is
/// flagged, whether the model added it up or made it up. Chinese numerals count as digits
/// wherever `NumberRules.writingNumbersAsDigits` writes them so, as in 五万八千六百元 and
/// 十月十九日. The phase 0 prototype (numcheck.py) is the reference.
nonisolated enum OutputChecks {
    nonisolated struct Finding: Sendable, Equatable {
        nonisolated enum Kind: Sendable {
            /// A date written with a weekday it does not fall on, or a date that does not exist.
            case dateWeekdayMismatch
            /// An amount that none of the sources holds.
            case amountWithoutSource
        }

        var kind: Kind
        /// The date with its weekday, or the amount, as the checked text has it once
        /// Chinese numerals are written as digits.
        var text: String
    }

    /// The findings in `text`, in the order they appear. `sources` are the texts the model
    /// read: the email, its thread and the excerpts of project files. A date without a
    /// year falls in the year that puts it closest to `today`.
    static func findings(in text: String, sources: [String], today: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> [Finding] {
        let checked = NumberRules.writingNumbersAsDigits(in: text)
        var found: [(position: String.Index, finding: Finding)] = []
        let weekdays = weekdayMentions(in: checked)
        var used: Set<Int> = []
        for date in dates(in: checked) {
            guard let pair = Self.weekday(pairedWith: date, among: weekdays, skipping: used, in: checked) else { continue }
            used.insert(pair.index)
            if Self.weekday(of: date, today: today, calendar: calendar) != pair.mention.day {
                var end = max(date.range.upperBound, pair.mention.range.upperBound)
                if end < checked.endIndex, checked[end] == "）" || checked[end] == ")" {
                    end = checked.index(after: end)
                }
                let range = min(date.range.lowerBound, pair.mention.range.lowerBound)..<end
                found.append((range.lowerBound, Finding(kind: .dateWeekdayMismatch, text: String(checked[range]))))
            }
        }
        var supported: Set<String> = []
        for source in sources {
            for form in [source, NumberRules.writingNumbersAsDigits(in: source)] {
                supported.formUnion(numbers(in: form, skippingDatesAndCodes: false).map(\.value))
            }
        }
        for number in numbers(in: checked) where number.isAmount && !supported.contains(number.value) {
            found.append((number.range.lowerBound, Finding(kind: .amountWithoutSource, text: String(checked[number.range]))))
        }
        var seen: [Finding] = []
        for (_, finding) in found.sorted(by: { $0.position < $1.position }) where !seen.contains(finding) {
            seen.append(finding)
        }
        return seen
    }

    // MARK: Numbers

    /// A number in a text, with its value in one form for comparing.
    nonisolated struct Number: Sendable, Equatable {
        /// Where the number stands, with its currency, multiplier, percent sign or score mark.
        var range: Range<String.Index>
        /// The value in plain digits, without separators or zeros at the end of a decimal
        /// part, and with 千, 万, 亿, k and million multiplied out. ¥58,600, 58600元 and
        /// 5.86万 all give 58600.
        var value: String
        /// Whether it reads as an amount: with a currency, a multiplier or a percent sign,
        /// with a decimal point, or with three digits or more and not a year.
        var isAmount: Bool
        /// Whether it reads as a score: with a decimal point, before 分, or out of 5, 10 or 100.
        var isScore: Bool
    }

    /// The numbers in `text`. Numbers inside dates and codes, such as 10 in 2026-10-19 or
    /// 730415 in BK-730415, are skipped unless `skippingDatesAndCodes` is false, which
    /// gives every value a source holds.
    static func numbers(in text: String, skippingDatesAndCodes: Bool = true) -> [Number] {
        let skipped = skippingDatesAndCodes ? dates(in: text).map(\.range) + numericDates(in: text) + codes(in: text) : []
        var numbers: [Number] = []
        for match in numberPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  !skipped.contains(where: { $0.overlaps(range) }),
                  let digitsRange = Range(match.range(withName: "digits"), in: text) else { continue }
            let digits = String(text[digitsRange]).precomposedStringWithCompatibilityMapping
            let plain = digits.filter { $0.isASCII && ($0.isNumber || $0 == ".") }
            guard var value = Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX")) else { continue }
            let multiplier = group("multiplier", of: match, in: text)
            if let multiplier {
                value *= multiplierValue(multiplier)
            }
            let currency = group("currencyBefore", of: match, in: text) ?? group("currencyAfter", of: match, in: text)
            let percent = group("percent", of: match, in: text)
            let score = group("score", of: match, in: text)
            let hasPoint = plain.contains(".")
            let digitCount = plain.filter(\.isNumber).count
            let isYear = plain.count == 4 && digits == plain && (1900...2099).contains(Int(plain) ?? 0)
            let isAmount = currency != nil || multiplier != nil || percent != nil || hasPoint || (digitCount >= 3 && !isYear)
            numbers.append(Number(range: range, value: "\(value)", isAmount: isAmount, isScore: score != nil || hasPoint))
        }
        return numbers
    }

    /// A number, with an optional currency before it, and an optional multiplier, currency,
    /// percent sign or score mark after it. Digits come in groups of three after commas,
    /// or in groups of three or four after spaces or hyphens, as account and phone numbers
    /// do (138 0013 8000, 400-123-4567). Hyphens need two groups, so 2026-2027 stays two.
    private static let numberPattern = try! NSRegularExpression(pattern: [
        #"(?<![A-Za-z0-9_\x{FF10}-\x{FF19}\x{FF21}-\x{FF3A}\x{FF41}-\x{FF5A}])(?<!\d[.．,，])"#,
        #"(?:(?<currencyBefore>[¥￥$€£]|US\$|S\$|HK\$|RMB|CNY|USD|SGD|HKD|EUR|GBP) ?)?"#,
        #"(?<digits>\d{3,}(?:[ \x{00A0}]\d{3,4})+(?!\d)|\d{3,}(?:-\d{3,4}){2,}(?!\d)|\d+(?:[,，]\d{3})+(?:[.．]\d+)?(?!\d)|\d+(?:[.．]\d+)?(?!\d))"#,
        #"(?<multiplier> ?(?:万|亿|千|[kK](?![A-Za-z])|million\b))?"#,
        #"(?<currencyAfter> ?(?:元|块|美元|港元|港币|欧元|英镑|日元|新元|新币|人民币|(?i:rmb|cny|usd|sgd|hkd|eur|gbp|dollars?|yuan)\b))?"#,
        #"(?<percent> ?(?:%|％|percent\b))?"#,
        #"(?<score> ?(?:分(?!钟)|/ ?(?:5|10|100)(?!\d)))?"#,
    ].joined())

    private static func group(_ name: String, of match: NSTextCheckingResult, in text: String) -> String? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound, range.length > 0, let found = Range(range, in: text) else { return nil }
        return String(text[found]).trimmingCharacters(in: .whitespaces)
    }

    private static func multiplierValue(_ word: String) -> Decimal {
        switch word.lowercased() {
        case "千", "k": 1_000
        case "万": 10_000
        case "亿": 100_000_000
        case "million": 1_000_000
        default: 1
        }
    }

    // MARK: Codes

    /// Codes of letters with digits, such as booking references, flight numbers and
    /// account or ID numbers with letters: R4T8WX, BK-730415, LM627. A code has four letters
    /// and digits at least. Ordinals, times, units and versions, such as 21st, 10am, 100kg,
    /// 1080p and v12, are not codes.
    static func codes(in text: String) -> [Range<String.Index>] {
        codePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let code = String(text[range])
            guard code.filter({ $0 != "-" }).count >= 4,
                  notCode.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) == nil else { return nil }
            return range
        }
    }

    /// A code in the one form codes are compared in: uppercase, without hyphens.
    static func codeValue(_ code: Substring) -> String {
        code.uppercased().filter { $0 != "-" }
    }

    private static let codePattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_-])(?=[A-Za-z0-9-]*[0-9])(?=[A-Za-z0-9-]*[A-Za-z])[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*(?![A-Za-z0-9_-])"#
    )

    private static let notCode = try! NSRegularExpression(
        pattern: #"^(?:\d+(?:st|nd|rd|th)|\d{1,2}(?:am|pm)|v\d+|\d+(?:k|kg|g|km|cm|mm|m|gb|mb|tb|kb|ghz|mhz|hz|px|pt|dpi|ppi|ml|l|x|h|hr|hrs|min|mins|s|w|kw|v|p|fps))$"#,
        options: .caseInsensitive
    )

    // MARK: Dates and weekdays

    /// A date with a month and a day, and the year when the text gives it.
    nonisolated struct DateMention: Sendable, Equatable {
        var range: Range<String.Index>
        var year: Int?
        var month: Int
        var day: Int
    }

    /// The dates in `text` written as 2026-10-19, 2026年10月19日, 10月19日, 19 October,
    /// 19th of Oct 2026, October 19 and Oct. 19, 2026. A date inside a longer one counts once.
    static func dates(in text: String) -> [DateMention] {
        var found: [DateMention] = []
        for pattern in datePatterns {
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                var numbers: [String: Int] = [:]
                for name in ["year", "month", "day"] {
                    if let value = group(name, of: match, in: text) {
                        numbers[name] = Int(value) ?? monthNumber(value)
                    }
                }
                guard let month = numbers["month"], let day = numbers["day"],
                      (1...12).contains(month), (1...31).contains(day) else { continue }
                found.append(DateMention(range: range, year: numbers["year"], month: month, day: day))
            }
        }
        return found
            .filter { date in !found.contains { $0 != date && $0.range.contains(date.range) } }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The English month names, and their short forms with or without a full stop. A full
    /// stop after a whole name ends the sentence and is no part of the date.
    private static let monthNames = #"January|February|March|April|May|June|July|August|September|October|November|December|(?:Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept?|Oct|Nov|Dec)\.?"#

    private static let datePatterns: [NSRegularExpression] = [
        #"(?<!\d)(?<year>\d{4}) ?(?:[-/.]|年) ?(?<month>\d{1,2}) ?(?:[-/.]|月) ?(?<day>\d{1,2})(?: ?[日号])?(?!\d)"#,
        #"(?<!\d)(?<month>\d{1,2}) ?月 ?(?<day>\d{1,2}) ?[日号]"#,
        #"(?<![A-Za-z0-9])(?<day>\d{1,2})(?:st|nd|rd|th)? +(?:of +)?(?<month>"# + monthNames + #")(?:,? +(?<year>\d{4}))?(?![A-Za-z0-9])"#,
        #"(?<![A-Za-z])(?<month>"# + monthNames + #") +(?<day>\d{1,2})(?:st|nd|rd|th)?(?:,? +(?<year>\d{4}))?(?![A-Za-z0-9])"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Dates written with slashes or dots, such as 19/10/2026 and 19.10.2026, which may put
    /// the day or the month first. They are no amounts, but their weekday is not checked.
    private static func numericDates(in text: String) -> [Range<String.Index>] {
        numericDatePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    private static let numericDatePattern = try! NSRegularExpression(pattern: #"(?<![\d/.])\d{1,2}([/.])\d{1,2}\1(?:\d{4}|\d{2})(?!\d|[/.]\d)"#)

    private static func monthNumber(_ name: String) -> Int? {
        let prefixes = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return prefixes.firstIndex(of: String(name.lowercased().prefix(3))).map { $0 + 1 }
    }

    /// A weekday in the text, with its number as `Calendar` counts them, Sunday 1 to Saturday 7.
    nonisolated private struct WeekdayMention {
        var range: Range<String.Index>
        var day: Int
    }

    private static func weekdayMentions(in text: String) -> [WeekdayMention] {
        var found: [WeekdayMention] = []
        let whole = NSRange(text.startIndex..., in: text)
        for match in chineseWeekday.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text), let day = text[range].last.flatMap({ chineseDays[$0] }) else { continue }
            found.append(WeekdayMention(range: range, day: day))
        }
        for match in englishWeekday.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            let prefix = String(text[range].lowercased().prefix(3))
            guard let index = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].firstIndex(of: prefix) else { continue }
            found.append(WeekdayMention(range: range, day: index + 1))
        }
        return found
    }

    private static let chineseDays: [Character: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
    private static let chineseWeekday = try! NSRegularExpression(pattern: #"(?:周|星期|礼拜)[一二三四五六日天]"#)
    /// A weekday in full, or a short form that does not stand before a capitalized word
    /// other than a month, since Sun is also a surname, as in 10月20日 Sun Wei.
    private static let englishWeekday = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])(?:(?i:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|(?:Mon|Tues?|Wed|Thu(?:rs?)?|Fri|Sat|Sun)(?:\.|(?![A-Za-z])(?!\s+(?!Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[A-Z])))(?![A-Za-z])"#
    )

    /// The weekday written right next to the date, as in 10月19日（周一）, 19 October
    /// (Monday), 周一 10月19日 and Monday, 19 October, and its index. A weekday right after
    /// the date wins, and a weekday pairs with one date only.
    private static func weekday(pairedWith date: DateMention, among weekdays: [WeekdayMention], skipping used: Set<Int>, in text: String) -> (index: Int, mention: WeekdayMention)? {
        for (index, mention) in weekdays.enumerated() where !used.contains(index) && mention.range.lowerBound >= date.range.upperBound {
            if isGap(text[date.range.upperBound..<mention.range.lowerBound], allowingComma: false) {
                return (index, mention)
            }
        }
        for (index, mention) in weekdays.enumerated() where !used.contains(index) && mention.range.upperBound <= date.range.lowerBound {
            if isGap(text[mention.range.upperBound..<date.range.lowerBound], allowingComma: true) {
                return (index, mention)
            }
        }
        return nil
    }

    /// Whether only spaces and an opening bracket, or a comma when allowed, stand between
    /// a date and its weekday.
    private static func isGap(_ gap: Substring, allowingComma: Bool) -> Bool {
        let allowed: Set<Character> = allowingComma ? [" ", "\u{3000}", "（", "(", ",", "，"] : [" ", "\u{3000}", "（", "("]
        return gap.count <= 3 && gap.allSatisfy(allowed.contains)
    }

    /// The weekday the date falls on, Sunday 1 to Saturday 7, or nil when no such date
    /// exists. A date without a year takes the year that puts it closest to `today`.
    private static func weekday(of date: DateMention, today: Date, calendar: Calendar) -> Int? {
        let thisYear = calendar.component(.year, from: today)
        let years = date.year.map { [$0] } ?? [thisYear - 1, thisYear, thisYear + 1]
        let candidates = years.compactMap { year -> Date? in
            let components = DateComponents(year: year, month: date.month, day: date.day, hour: 12)
            guard let found = calendar.date(from: components),
                  calendar.dateComponents([.year, .month, .day], from: found) == DateComponents(year: year, month: date.month, day: date.day) else { return nil }
            return found
        }
        guard let closest = candidates.min(by: { abs($0.timeIntervalSince(today)) < abs($1.timeIntervalSince(today)) }) else { return nil }
        return calendar.component(.weekday, from: closest)
    }
}
