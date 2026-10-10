import Foundation

/// Writes numbers that the speech model spelled out in Chinese characters as digits, such as
/// 二零二六年 as 2026年 and 百分之五十 as 50%.
///
/// Qwen3-ASR often writes a Chinese number the way it was spoken. These rules convert only
/// where a reader expects digits, and leave the text as dictated whenever they are unsure:
/// - Readings digit by digit (零〇一二三四五六七八九, and 幺 as 1) of three digits or more,
///   such as phone numbers, codes and room numbers: 幺三八零零幺三八零零零 is 13800138000.
///   A year needs four digits (二零二六年), and a reading before a counter such as 个 is a
///   range (三四五个) and stays.
/// - Numbers with 十, 百, 千, 万 or 亿 before a unit or counter such as 元, 块, 个, 人, 天,
///   公里 or 页, or before a Latin unit such as GB: 三百五十块 is 350块. 万 and 亿 stay as
///   units the way Chinese news writes them, so 两万人 is 2万人, 三万五千元 is 3.5万元, and
///   they need no unit after them: 十二万 is 12万 and 三万五 is 3.5万.
/// - Percentages (百分之三点五 is 3.5%), decimals before a unit (三点五公里 is 3.5公里), and
///   times: an hour after a time of day such as 下午, or before 半, 钟, 整, minutes or a word
///   such as 以后 (下午三点 is 下午3点, 三点二十分 is 3点20分). A decimal before 分 under 25
///   could be a time or a score (三点五分) and stays.
/// - Dates: a month with a day, with 份 or after a year (十月一日 is 10月1日), and the day
///   after such a month even when it is a single digit.
/// - A number right after a Latin model name: RX 三五零 is RX 350, iPhone 十五 is iPhone 15,
///   M五 is M5 and macOS 十五点一 is macOS 15.1. A space that was there stays, and none is
///   added between Chinese and digits.
///
/// Single digits with a counter stay in words (一个人, 三本书, 两次), the way Chinese writes
/// small counts. So do ranges and rough numbers (七八个, 十几个, 二十多个, 三十来岁), ordinals
/// (第十五届), weekdays (星期一), idioms and set phrases (一心一意, 三五成群, 十万火急),
/// 万一, 千万, 十分 as very, 一点 as a little, holidays such as 双十一 and 九一八, and text in
/// book title marks. English is never touched, the speech model already writes its numbers
/// as digits. Applying the rules twice gives the same text as applying them once.
nonisolated enum NumberRules {
    private static let digitValues: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "幺": 1, "两": 2,
    ]
    /// The characters of a reading digit by digit, which has no 两.
    private static let readingDigits: Set<Character> = ["零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "幺"]
    private static let smallPowers: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    private static let numerals = Set(digitValues.keys).union(smallPowers.keys).union(["万", "亿"])

    /// Units and counters after which a number with 十, 百, 千, 万 or 亿 becomes digits. 月,
    /// 点 and 号 or 日 after a month have rules of their own. 里, 尺, 行 and 字 are left out
    /// because of names and set phrases such as 十八里店, 三千尺, 十三行 and 十字路口.
    private static let units: [[Character]] = [
        "平方公里", "平方米", "立方米", "公里", "公斤", "厘米", "毫米", "毫升", "小时", "分钟",
        "秒钟", "世纪", "年代", "周年", "周岁", "星期", "元", "块", "毛", "角", "分", "个", "位",
        "人", "次", "年", "日", "号", "秒", "岁", "天", "周", "米", "斤", "克", "吨", "页", "张",
        "件", "台", "倍", "度", "层", "楼", "本", "份", "条", "辆", "部", "家", "所", "名", "篇",
        "首", "套", "只", "场", "届", "期", "集", "章", "节", "轮", "遍", "趟", "道", "题", "星", "票",
    ].map { Array($0) }.sorted { $0.count > $1.count }
    /// Characters after a number that make it a rough one: 二十多, 十几, 三十来岁, 十余.
    private static let roughAfter: Set<Character> = ["多", "几", "来", "余"]
    /// Characters before a number that make it an ordinal, a weekday, a nickname, a holiday or
    /// a rough number: 第三, 周一, 星期一, 礼拜三, 初十, 老三, 双十一, 数十万, 几十.
    private static let wordBefore: Set<Character> = ["第", "周", "期", "拜", "初", "老", "双", "数", "几"]
    /// Characters after a final 一 that make it part of a word such as 一起 or 一下.
    private static let wordsAfterOne: Set<Character> = [
        "下", "些", "样", "起", "直", "般", "切", "律", "定", "共", "半", "边", "同", "旦", "致", "向", "再",
        "会", "阵", "心", "模", "举", "味", "概", "贯",
    ]
    /// Words before an hour that make 点 a time.
    private static let timesOfDay: [[Character]] = [
        "早上", "上午", "中午", "下午", "晚上", "凌晨", "傍晚", "半夜", "夜里", "早晨", "清晨", "午夜",
        "今晚", "明晚", "昨晚", "今早", "明早",
    ].map { Array($0) }
    /// Words after 点 that make it a time. 半, 钟 and 整 do it for any hour, the others not
    /// for 一, since 好一点以后 is a little and not one o'clock.
    private static let clockWords: [[Character]] = ["半", "钟", "整"].map { Array($0) }
    private static let laterWords: [[Character]] = ["以前", "之前", "以后", "之后", "左右", "才", "准时"].map { Array($0) }
    /// Idioms, set phrases, names and titles with a number in them, kept wherever a number
    /// touches them. Phrases of numerals only, such as 九一八, must match the whole number.
    private static let setPhrases: [[Character]] = [
        "一心一意", "三心二意", "一模一样", "七上八下", "乱七八糟", "十全十美", "三五成群", "九牛一毛",
        "十有八九", "八九不离十", "半斤八两", "三天两头", "一举两得", "五花八门", "万无一失", "千方百计",
        "九九归一", "三番五次", "五湖四海", "一五一十", "不三不四", "略知一二", "三十六计", "三十而立",
        "四十不惑", "五十知天命", "十年寒窗", "十年树木", "百年树人", "三十年河东", "三十年河西",
        "十天半个月", "十万火急", "十万八千里", "一千零一夜", "十万个为什么", "七七四十九", "九九八十一",
        "九一八", "一二九", "一二三", "七七八八", "二百五",
    ].map { Array($0) }
    private static let numeralPhrases = setPhrases.filter { $0.allSatisfy { numerals.contains($0) } }
    private static let wordPhrases = setPhrases.filter { !$0.allSatisfy { numerals.contains($0) } }

    /// A number as spoken, without its unit.
    private enum Spoken {
        /// One digit character, such as 三 or 两.
        case single(Int, Character)
        /// Digits read one by one, such as 三五零, as the digits they stand for.
        case reading(String)
        /// A number with 十, 百, 千, 万 or 亿, and the largest of 万 and 亿 in it.
        case compound(Int, large: Character?)
    }

    static func writingNumbersAsDigits(in text: String) -> String {
        let characters = Array(text)
        guard characters.contains(where: { numerals.contains($0) }) else { return text }
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var titleDepth = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "《" {
                titleDepth += 1
            } else if character == "》" {
                titleDepth = max(0, titleDepth - 1)
            }
            guard titleDepth == 0, numerals.contains(character) else {
                output.append(character)
                index += 1
                continue
            }
            if starts("百分之", at: index, in: characters) {
                let percent = percentage(at: index, in: characters)
                output.append(contentsOf: percent.text)
                index = percent.end
                continue
            }
            let end = numeralsEnd(from: index, in: characters)
            if let converted = conversion(of: index..<end, in: characters) {
                output.append(contentsOf: converted.text)
                index = converted.end
            } else {
                output.append(contentsOf: characters[index..<end])
                index = end
            }
        }
        return String(output)
    }

    /// The digits for the numerals in `run` and the index to go on from, or nil to keep them.
    private static func conversion(of run: Range<Int>, in characters: [Character]) -> (text: [Character], end: Int)? {
        let start = run.lowerBound
        let end = run.upperBound
        if touchesSetPhrase(run, in: characters) { return nil }
        if start > 0 {
            let before = characters[start - 1]
            if wordBefore.contains(before) || isASCIIDigit(before) || before == "." { return nil }
            // The rest of a decimal or a time that stayed in words, such as 五 in 三点五分.
            if before == "点", start > 1, numerals.contains(characters[start - 2]) || isASCIIDigit(characters[start - 2]) {
                return nil
            }
        }
        if end - start > 1, characters[end - 1] == "一", end < characters.count, wordsAfterOne.contains(characters[end]) {
            return nil
        }
        if let model = afterLatinName(run, in: characters) {
            return model
        }
        guard let spoken = parse(characters[run]) else { return nil }
        let next = end < characters.count ? characters[end] : nil
        switch next {
        case "点":
            return timeOrDecimal(run, spoken, in: characters)
        case "月":
            return month(run, spoken, in: characters)
        case "号", "日":
            if let day = dayAfterMonth(run, spoken, in: characters) {
                return (day, end)
            }
        default:
            break
        }
        if let next, roughAfter.contains(next) { return nil }
        let unit = unitLength(at: end, in: characters)
        switch spoken {
        case .single(let value, let character):
            // 5G, 3D and 5% are written with digits. 两 is a count, not a digit.
            guard character != "两", character != "幺", let next, isASCIILetter(next) || next == "%" else { return nil }
            return (Array(String(value)), end)
        case .reading(let digits):
            guard digits.count >= 3 else { return nil }
            if next == "年" {
                return digits.count == 4 ? (Array(digits), end) : nil
            }
            // 三四五个 is a range. A code is not counted.
            if unit > 0, next != "号" { return nil }
            return (Array(digits), end)
        case .compound(let value, let large):
            let digits = Array(compoundDigits(value, large: large))
            if unit > 0 {
                let unitText = String(characters[end..<end + unit])
                // 十分 is very, and 三百分之一 is a fraction.
                if unitText == "分" {
                    if end - start == 1 { return nil }
                    if end + 1 < characters.count, characters[end + 1] == "之" { return nil }
                }
                // 一百个不愿意 and 一万个理由 are figures of speech.
                if unitText == "个", end - start == 2, characters[start] == "一", ["百", "千", "万", "亿"].contains(characters[start + 1]) {
                    return nil
                }
                return (digits, end)
            }
            if let next, isASCIILetter(next) || next == "%" {
                return (digits, end)
            }
            // 万 and 亿 are units of their own: 十二万 is 12万 and 三万五 is 3.5万.
            if large != nil {
                return (digits, end)
            }
            return nil
        }
    }

    /// A model number or version right after a Latin name, such as RX 三五零, M五 or macOS
    /// 十五点一. Right after a letter (M五) any number counts. After a space it needs more
    /// than one digit, or a single digit that is not 一, 两 or 零 and stands alone, and it
    /// must not be a count such as Tom 三十岁, which the other rules handle.
    private static func afterLatinName(_ run: Range<Int>, in characters: [Character]) -> (text: [Character], end: Int)? {
        let start = run.lowerBound
        guard start > 0 else { return nil }
        let before = characters[start - 1]
        let joined = isASCIILetter(before) || (before == "-" && start > 1 && isLatinOrDigit(characters[start - 2]))
        let spaced = before == " " && start > 1 && isASCIILetter(characters[start - 2])
        guard joined || spaced, let spoken = parse(characters[run]) else { return nil }
        var end = run.upperBound
        var text: String
        var isVersion = false
        switch spoken {
        case .single(let value, let character):
            guard character != "两", character != "幺" else { return nil }
            text = String(value)
        case .reading(let digits):
            text = digits
        case .compound(let value, let large):
            text = compoundDigits(value, large: large)
        }
        // A version such as 十五点一 or 三点十二. Minutes such as 三点二十 stay a time.
        if end < characters.count, characters[end] == "点", end + 1 < characters.count,
           numerals.contains(characters[end + 1]), let major = wholeNumber(spoken) {
            let minorEnd = numeralsEnd(from: end + 1, in: characters)
            let minorCharacters = characters[(end + 1)..<minorEnd]
            var minor: String?
            if minorCharacters.allSatisfy({ readingDigits.contains($0) }) {
                minor = String(minorCharacters.map { Character(String(digitValues[$0]!)) })
            } else if case .compound(let value, .none)? = parse(minorCharacters), (11...19).contains(value) {
                minor = String(value)
            }
            let after = minorEnd < characters.count ? characters[minorEnd] : nil
            if let minor, after.map({ ["分", "钟", "半"].contains($0) }) != true {
                text = "\(major).\(minor)"
                end = minorEnd
                isVersion = true
            }
        }
        let next = end < characters.count ? characters[end] : nil
        if let next, roughAfter.contains(next) { return nil }
        if !isVersion {
            let counted = unitLength(at: end, in: characters) > 0 || next == "点" || next == "月"
            switch spoken {
            case .single(_, let character):
                if spaced {
                    guard character != "一", character != "零" else { return nil }
                    if let next, isHan(next) { return nil }
                } else if counted {
                    return nil
                } else if character == "一", let next, wordsAfterOne.contains(next) {
                    return nil
                }
            case .reading(let digits):
                if spaced, digits.count < 3 || counted { return nil }
                if joined, digits.count < 3, counted { return nil }
            case .compound:
                if spaced, counted { return nil }
            }
        }
        return (Array(text), end)
    }

    /// An hour before 点 that is a time, or a decimal before a unit, such as 三点五公里.
    private static func timeOrDecimal(_ run: Range<Int>, _ spoken: Spoken, in characters: [Character]) -> (text: [Character], end: Int)? {
        let start = run.lowerBound
        guard let hour = wholeNumber(spoken) else { return nil }
        // 这三点 and 那两点 are points of a list.
        if start > 0, ["这", "那", "哪"].contains(characters[start - 1]) { return nil }
        let after = run.upperBound + 1
        let isHour = hour <= 24
        let isTime = followsTimeOfDay(start, in: characters) || endsRangeOfTimes(start, in: characters)
        guard after < characters.count else {
            return isHour && isTime ? (Array("\(hour)点"), after) : nil
        }
        let next = characters[after]
        if roughAfter.contains(next) { return nil }
        if numerals.contains(next) {
            let end = numeralsEnd(from: after, in: characters)
            let minutes = characters[after..<end]
            let following = end < characters.count ? characters[end] : nil
            if isHour, minutes.contains("十"), case .compound(let value, .none)? = parse(minutes), (10...59).contains(value) {
                return (Array("\(hour)点\(value)"), end)
            }
            if isHour, minutes.count == 2, minutes.first == "零", following == "分",
               let last = minutes.last, last != "幺", let value = digitValues[last], value > 0 {
                return (Array("\(hour)点0\(value)"), end)
            }
            // 三点一刻 keeps 一刻 in words.
            if isHour, minutes.count == 1, let first = minutes.first, first == "一" || first == "三", following == "刻" {
                return (Array("\(hour)点"), after)
            }
            return decimal(hour, after..<end, in: characters, couldBeTime: isHour)
        }
        guard isHour else { return nil }
        if isTime || clockWords.contains(where: { starts($0, at: after, in: characters) }) {
            return (Array("\(hour)点"), after)
        }
        if characters[start] != "一", laterWords.contains(where: { starts($0, at: after, in: characters) }) {
            return (Array("\(hour)点"), after)
        }
        return nil
    }

    /// A decimal whose digits after 点 are in `fraction`, such as 三点五亿元, when a unit
    /// follows. 分 after a number up to 24 could be minutes and stays.
    private static func decimal(_ whole: Int, _ fraction: Range<Int>, in characters: [Character], couldBeTime: Bool) -> (text: [Character], end: Int)? {
        var digits = ""
        var index = fraction.lowerBound
        while index < fraction.upperBound, characters[index] != "幺", readingDigits.contains(characters[index]) {
            digits.append(String(digitValues[characters[index]]!))
            index += 1
        }
        guard !digits.isEmpty else { return nil }
        var large = ""
        if index < fraction.upperBound {
            guard index == fraction.upperBound - 1, ["万", "亿"].contains(characters[index]) else { return nil }
            large = String(characters[index])
        }
        let end = fraction.upperBound
        if large.isEmpty {
            let unit = unitLength(at: end, in: characters)
            let next = end < characters.count ? characters[end] : nil
            guard unit > 0 || next.map({ isASCIILetter($0) || $0 == "%" }) == true else { return nil }
            if couldBeTime, unit == 1, next == "分" { return nil }
        }
        return (Array("\(whole).\(digits)\(large)"), end)
    }

    /// A month in a date: before a day, before 份, or after a year. 二月春风 and 十月稻田
    /// stay.
    private static func month(_ run: Range<Int>, _ spoken: Spoken, in characters: [Character]) -> (text: [Character], end: Int)? {
        guard let value = wholeNumber(spoken), (1...12).contains(value) else { return nil }
        if case .single(_, "两") = spoken { return nil }
        let start = run.lowerBound
        let after = run.upperBound + 1
        var isDate = after < characters.count && characters[after] == "份"
        if !isDate, after < characters.count, numerals.contains(characters[after]) {
            let dayEnd = numeralsEnd(from: after, in: characters)
            if dayEnd < characters.count, ["号", "日"].contains(characters[dayEnd]),
               let day = parse(characters[after..<dayEnd]), isDay(day) {
                isDate = true
            }
        }
        if !isDate, start > 1, characters[start - 1] == "年" {
            let year = characters[start - 2]
            isDate = numerals.contains(year) || isASCIIDigit(year)
        }
        return isDate ? (Array(String(value)), run.upperBound) : nil
    }

    /// The day after a month in a date, such as 八 in 三月八号.
    private static func dayAfterMonth(_ run: Range<Int>, _ spoken: Spoken, in characters: [Character]) -> [Character]? {
        let start = run.lowerBound
        guard start > 1, characters[start - 1] == "月", isDay(spoken), let value = wholeNumber(spoken) else { return nil }
        let monthEnd = characters[start - 2]
        guard numerals.contains(monthEnd) || isASCIIDigit(monthEnd) else { return nil }
        return Array(String(value))
    }

    private static func isDay(_ spoken: Spoken) -> Bool {
        if case .single(_, let character) = spoken, character == "两" || character == "幺" { return false }
        guard let value = wholeNumber(spoken) else { return false }
        return (1...31).contains(value)
    }

    /// 百分之 and a number, written as a percentage. Whatever is not converted is kept along
    /// with its number, so 百分之八九十 and 百分之百 stay as they are.
    private static func percentage(at index: Int, in characters: [Character]) -> (text: [Character], end: Int) {
        let numberStart = index + 3
        guard numberStart < characters.count, numerals.contains(characters[numberStart]) else {
            return (Array(characters[index..<numberStart]), numberStart)
        }
        let numberEnd = numeralsEnd(from: numberStart, in: characters)
        let kept = (Array(characters[index..<numberEnd]), numberEnd)
        guard !touchesSetPhrase(numberStart..<numberEnd, in: characters),
              let spoken = parse(characters[numberStart..<numberEnd]),
              let value = wholeNumber(spoken) else { return kept }
        if case .single(_, let character) = spoken, character == "两" || character == "幺" { return kept }
        var text = String(value)
        var end = numberEnd
        if end + 1 < characters.count, characters[end] == "点", readingDigits.contains(characters[end + 1]) {
            let fractionEnd = numeralsEnd(from: end + 1, in: characters)
            let fraction = characters[(end + 1)..<fractionEnd]
            guard fraction.allSatisfy({ readingDigits.contains($0) && $0 != "幺" }) else { return kept }
            text += "." + fraction.map { String(digitValues[$0]!) }.joined()
            end = fractionEnd
        }
        if end < characters.count, roughAfter.contains(characters[end]) {
            return (Array(characters[index..<end]), end)
        }
        return (Array(text + "%"), end)
    }

    /// Reads a run of numerals: one digit, digits one by one, or a number with powers of ten.
    private static func parse(_ run: ArraySlice<Character>) -> Spoken? {
        guard let first = run.first else { return nil }
        if run.count == 1, let value = digitValues[first] {
            return .single(value, first)
        }
        if run.allSatisfy({ readingDigits.contains($0) }) {
            return .reading(String(run.map { Character(String(digitValues[$0]!)) }))
        }
        guard let value = compoundValue(run) else { return nil }
        let large: Character? = run.contains("亿") ? "亿" : run.contains("万") ? "万" : nil
        return .compound(value, large: large)
    }

    /// The value of a single digit or a number with powers of ten, nil for a reading.
    private static func wholeNumber(_ spoken: Spoken) -> Int? {
        switch spoken {
        case .single(let value, let character):
            character == "幺" ? nil : value
        case .reading:
            nil
        case .compound(let value, let large):
            large == nil ? value : nil
        }
    }

    /// The value of a number written with 十, 百, 千, 万 or 亿, such as 一千零五十, or nil when
    /// the numerals are not one number, as in 七八, 二三十, 两三 or 七七四十九. A digit after
    /// 百, 千 or 万 counts in the next smaller place, so 三千五 is 3500 and 两万三 is 23000.
    private static func compoundValue(_ run: ArraySlice<Character>) -> Int? {
        var hundredMillions = 0
        var tenThousands = 0
        var section = 0
        var digit: Int?
        var digitIsLiang = false
        var smallestPower = 10_000
        var largeLevel = 3
        var powerBeforeDigit = 0
        var afterZero = false
        var sawPower = false
        for (offset, character) in run.enumerated() {
            if character == "零" || character == "〇" {
                if offset == 0 || digit != nil || afterZero { return nil }
                afterZero = true
                powerBeforeDigit = 0
            } else if character == "幺" {
                return nil
            } else if let value = digitValues[character] {
                if digit != nil { return nil }
                digit = value
                digitIsLiang = character == "两"
                afterZero = false
            } else if let power = smallPowers[character] {
                var value = digit
                if value == nil, power == 10, offset == 0 {
                    value = 1
                }
                guard let value, power < smallestPower, !(digitIsLiang && power == 10) else { return nil }
                section += value * power
                smallestPower = power
                digit = nil
                digitIsLiang = false
                powerBeforeDigit = power
                afterZero = false
                sawPower = true
            } else if character == "万" || character == "亿" {
                let isWan = character == "万"
                if let value = digit {
                    // 三千五万 leaves out a place, too unclear to read.
                    if powerBeforeDigit >= 100 { return nil }
                    section += value
                }
                guard section > 0, largeLevel > (isWan ? 1 : 2) else { return nil }
                if isWan {
                    tenThousands = section
                    largeLevel = 1
                    powerBeforeDigit = 10_000
                } else {
                    hundredMillions = tenThousands * 10_000 + section
                    tenThousands = 0
                    largeLevel = 2
                    powerBeforeDigit = 100_000_000
                }
                section = 0
                digit = nil
                digitIsLiang = false
                smallestPower = 10_000
                afterZero = false
                sawPower = true
            } else {
                return nil
            }
        }
        if afterZero { return nil }
        if let value = digit {
            if digitIsLiang { return nil }
            section += powerBeforeDigit >= 100 ? value * powerBeforeDigit / 10 : value
        }
        guard sawPower else { return nil }
        return hundredMillions * 100_000_000 + tenThousands * 10_000 + section
    }

    /// Digits for a number, keeping 万 or 亿 as a unit: 20000 with 万 is 2万, 35000 is 3.5万.
    private static func compoundDigits(_ value: Int, large: Character?) -> String {
        guard let large else { return String(value) }
        let places = large == "亿" ? 8 : 4
        let unit = large == "亿" ? 100_000_000 : 10_000
        let whole = value / unit
        let rest = value % unit
        guard rest > 0 else { return "\(whole)\(large)" }
        var fraction = String(rest)
        fraction = String(repeating: "0", count: places - fraction.count) + fraction
        while fraction.hasSuffix("0") {
            fraction.removeLast()
        }
        return "\(whole).\(fraction)\(large)"
    }

    /// Whether a phrase such as 三五成群 overlaps the numerals in `run`. A phrase of numerals
    /// only must be the whole run, so 一二三 stays and 幺三八一二三四 does not.
    private static func touchesSetPhrase(_ run: Range<Int>, in characters: [Character]) -> Bool {
        if numeralPhrases.contains(where: { $0.count == run.count && starts($0, at: run.lowerBound, in: characters) }) {
            return true
        }
        for phrase in wordPhrases {
            let first = max(0, run.lowerBound - phrase.count + 1)
            for start in first..<run.upperBound where starts(phrase, at: start, in: characters) {
                return true
            }
        }
        return false
    }

    /// Whether the hour at `index` ends a range after a time of day, such as 四 in
    /// 下午三点半到四点.
    private static func endsRangeOfTimes(_ index: Int, in characters: [Character]) -> Bool {
        guard index >= 2, characters[index - 1] == "到" || characters[index - 1] == "至" else { return false }
        var first = index - 1
        while first > 0, numerals.contains(characters[first - 1]) || ["点", "半", "分", "钟"].contains(characters[first - 1]) {
            first -= 1
        }
        return first < index - 2 && characters[first..<(index - 1)].contains("点") && followsTimeOfDay(first, in: characters)
    }

    private static func followsTimeOfDay(_ index: Int, in characters: [Character]) -> Bool {
        timesOfDay.contains { word in
            index >= word.count && starts(word, at: index - word.count, in: characters)
        }
    }

    /// The length of the unit or counter that starts at `index`, or 0.
    private static func unitLength(at index: Int, in characters: [Character]) -> Int {
        guard index < characters.count else { return 0 }
        return units.first { starts($0, at: index, in: characters) }?.count ?? 0
    }

    private static func numeralsEnd(from index: Int, in characters: [Character]) -> Int {
        var end = index
        while end < characters.count, numerals.contains(characters[end]) {
            end += 1
        }
        return end
    }

    private static func starts(_ word: String, at index: Int, in characters: [Character]) -> Bool {
        starts(Array(word), at: index, in: characters)
    }

    private static func starts(_ word: [Character], at index: Int, in characters: [Character]) -> Bool {
        guard index >= 0, index + word.count <= characters.count else { return false }
        for (offset, character) in word.enumerated() where characters[index + offset] != character {
            return false
        }
        return true
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func isLatinOrDigit(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF:
                true
            default:
                false
            }
        }
    }
}

/// Whether Orra writes spoken numbers as digits. On until the user turns it off in Settings.
nonisolated enum NumberPreference {
    static let defaultsKey = "writesNumbersAsDigits"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func save(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }
}
