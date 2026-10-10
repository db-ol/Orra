import Foundation

/// Writes numbers that the speech model spelled out in Chinese characters as digits, such as
/// 二零二六年 as 2026年 and 百分之五十 as 50%.
///
/// Qwen3-ASR often writes a Chinese number the way it was spoken. A wrong conversion is far
/// worse than a missed one, so these rules convert only a few patterns where a reader clearly
/// expects digits, and leave everything else as dictated:
/// - Readings digit by digit (零〇一二三四五六七八九, and 幺 as 1) of three digits or more,
///   such as phone numbers, codes and model numbers: 幺三八零零幺三八零零零 is 13800138000.
///   A year needs four digits (二零二六年). Counting (一二三四五) stays unless a word such
///   as 验证码 comes before it.
/// - Dates: a month with its day and 号 or 日 (十月一日 is 10月1日), and a month after a year
///   in digits. A day without a month (十五号), ranges of days and lunar dates stay.
/// - Times: an hour after a time of day such as 下午 (下午三点 is 下午3点), or with minutes
///   and 分 (三点二十分 is 3点20分). 三点半, 三点以后 and 三点十分, which can mean very, need
///   a time of day.
/// - Percentages: 百分之三点五 is 3.5%.
/// - Money: a number with 十, 百, 千, 万 or 亿 before 元, 块 or a currency word such as 美元
///   (三百五十块 is 350块, 三万五千元 is 3.5万元).
/// - Measurements: a number with 十, 百 or 千, or a decimal, before a real unit such as 公里,
///   公斤, 小时, 天, 岁, 年 or GB (三点五公里 is 3.5公里). 度 is a unit only for a temperature,
///   after 零下 or with 摄氏.
/// - Model numbers and versions after a Latin name: M五 is M5, RX 三五零 is RX 350 and
///   macOS 十五点一 is macOS 15.1. After a space only when a space, punctuation, a Latin unit
///   or the end follows. A space that was there stays, and none is added.
///
/// Everything else stays in words: single digits (三本书, 五公里), numbers before a plain
/// counter (二十个人, 十位, 十八届), 万 and 亿 without a currency (两万人, 十二万), ranges
/// (三百到五百元), rough numbers (十几个), ordinals, idioms, sayings and text in book title
/// marks. English is never touched, the speech model already writes its numbers as digits.
/// Applying the rules twice gives the same text as applying them once.
nonisolated enum NumberRules {
    private static let digitValues: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "幺": 1, "两": 2,
    ]
    /// The characters of a reading digit by digit, which has no 两.
    private static let readingDigits: Set<Character> = ["零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "幺"]
    private static let smallPowers: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    private static let numerals = Set(digitValues.keys).union(smallPowers.keys).union(["万", "亿"])

    /// Currency words. A number with 万 or 亿 converts only before one of these.
    private static let currencies: Set<String> = [
        "元", "块", "美元", "欧元", "英镑", "港币", "港元", "美金", "日元", "韩元", "澳元", "加元", "人民币",
    ]
    /// Real units after which a number with 十, 百 or 千, or a decimal, becomes digits.
    private static let units: [[Character]] = (Array(currencies) + [
        "平方公里", "平方米", "立方米", "摄氏度", "公里", "千米", "厘米", "毫米", "纳米", "米", "公斤",
        "千克", "克", "斤", "吨", "毫升", "升", "英寸", "寸", "毫安时", "毫安", "瓦", "度", "周岁", "岁",
        "小时", "分钟", "秒钟", "秒", "天", "周", "个月", "年",
    ]).map { Array($0) }.sorted { $0.count > $1.count }
    /// Words that start with a unit character but are not a unit after a number, such as 元宵
    /// in 十五元宵节 and 年轻 in 二十年轻人.
    private static let notUnits: [[Character]] = [
        "元宵", "元旦", "元素", "元老", "元帅", "元月", "元气", "元首", "天才", "天下", "天干", "天外",
        "天地", "天空", "天气", "天使", "天堂", "天然", "天罡", "天兵", "年轻", "年华", "年糕", "米饭",
        "克服", "岁月", "秒杀", "周末", "周边", "周围", "块头", "斤斤", "升级", "升职", "升学", "度假", "度过",
    ].map { Array($0) }
    /// Latin units after a number: 5G, 4K, 3D and 十六GB. A single digit takes only the ones
    /// that cannot be a word, so 做一PPT stays.
    private static let latinUnits: [[Character]] = [
        "GB", "MB", "TB", "KB", "mAh", "GHz", "MHz", "kHz", "Hz", "kg", "km", "cm", "mm", "G", "K", "D",
    ].map { Array($0) }.sorted { $0.count > $1.count }
    private static let singleDigitLatinUnits: Set<String> = ["G", "K", "D", "GB", "MB", "TB", "KB", "Hz"]
    /// Units of an amount that a smaller unit can follow, as in 三十块零五毛 and 一分三十秒. The
    /// two parts stay whole.
    private static let amountUnits: [[Character]] = ["块", "元", "分", "秒", "小时", "分钟", "度", "米", "斤", "公里", "公斤"].map { Array($0) }
    /// Characters after a number that make it a rough one: 二十多, 十几, 三十来岁, 十余.
    private static let roughAfter: Set<Character> = ["多", "几", "来", "余"]
    /// Characters before a number that make it an ordinal, a weekday, a nickname, a holiday, a
    /// rough number or a song title: 第三, 周一, 礼拜三, 初十, 老三, 双十一, 数十万, 一首十七岁.
    private static let wordBefore: Set<Character> = ["第", "周", "期", "拜", "初", "老", "双", "数", "几", "首"]
    /// Words that end in a digit, such as a school year (高三) or a stock name (张三, 李四). The
    /// digit does not start a number with 十 after it: 张三十八岁 is Zhang San at 18.
    private static let wordsEndingInDigit: [[Character]] = [
        "高一", "高二", "高三", "大一", "大二", "大三", "大四", "研一", "研二", "研三", "张三", "李四",
        "王五", "赵六",
    ].map { Array($0) }
    /// Characters before a lone 一 that let 一点 start a decimal, as in 是一点五米. After other
    /// words 一点 is a little: 便宜一点五十块, 快一点二十分钟.
    private static let beforeOnePoint: Set<Character> = ["是", "约", "达", "为", "共", "到", "至"]
    /// Words before an hour that make 点 a time.
    private static let timesOfDay: [[Character]] = [
        "早上", "上午", "中午", "下午", "晚上", "凌晨", "傍晚", "半夜", "夜里", "早晨", "清晨", "午夜",
        "今晚", "明晚", "昨晚", "今早", "明早",
    ].map { Array($0) }
    /// What may follow 一点 after a time of day for it to be one o'clock. 晚上一点都不冷 is
    /// not at all, so 都, 也, 儿 and nouns keep it.
    private static let afterOneOClock: [[Character]] = [
        "钟", "半", "整", "以前", "之前", "以后", "之后", "左右", "前", "后", "到", "至", "的", "就",
        "才", "准时", "见", "开会", "出发", "起飞", "睡",
    ].map { Array($0) }
    /// Words before a lunar date, which stays in words: 腊月二十三号, 农历八月十五号.
    private static let lunarWords: [[Character]] = ["农历", "阴历", "腊月", "正月", "冬月"].map { Array($0) }
    /// Lunar festivals after a date: 七月七日是七夕.
    private static let lunarFestivals: [[Character]] = ["七夕", "中秋", "重阳", "端午", "元宵", "乞巧", "腊八", "小年"].map { Array($0) }
    /// Round numbers that are figures of speech before 年: 一百年都遇不到, 八百年没见了.
    private static let hyperboleNumbers: Set<String> = ["一百", "一千", "八百"]
    /// Sayings and titles kept wherever a number touches them. Readings such as 九一八 must
    /// match the whole number.
    private static let setPhrases: [[Character]] = [
        "十年寒窗", "十年树木", "十天半个月", "十年如一日",
        "十年磨一剑", "十年生死", "十年一觉", "二十年来辨", "二十年后又是一条好汉", "五百年前是一家",
        "九千岁", "八十天环游", "一千年以后", "十年一品", "十年一刻", "一百年不动摇",
        "人过四十天过午", "十年饮冰", "十年怕井绳", "十年不晚", "十年功", "十年河东", "十年河西",
        "十年一剑", "十年修得", "十年之约", "九月九日忆", "七月七日长生殿", "三月三日天气新",
        "三五一群", "七七八八",
        // Readings that are dates of events, weekdays or chants: 九一八, 五一二, 一三五.
        "九一八", "一二九", "一二八", "五一二", "三一五", "一二一", 
        "三六九", "四一二", "八一三",
    ].map { Array($0) }
    private static let numeralPhrases = setPhrases.filter { $0.allSatisfy { numerals.contains($0) } }
    private static let wordPhrases = setPhrases.filter { !$0.allSatisfy { numerals.contains($0) } }

    /// A number as spoken, without its unit.
    private enum Spoken {
        /// One digit character, such as 三 or 两.
        case single(Int, Character)
        /// Digits read one by one, such as 三五零, as the digits they stand for.
        case reading(String)
        /// A number with 十, 百, 千, 万 or 亿, and the largest of 万, 亿 and 万亿 (as 兆) in it.
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
            // 唯一十八岁 ends a word with 一, and 张三十八岁 a word with a digit, so the digit
            // does not start a number with 十.
            if run.count > 1, characters[start + 1] == "十" {
                if characters[start] == "一", isHan(before) { return nil }
                if wordsEndingInDigit.contains(where: { starts($0, at: start - 1, in: characters) }) { return nil }
            }
            // 几个十年 is a stage of life, not a count.
            if starts("几个", at: start - 2, in: characters) { return nil }
            // The rest of a decimal or a time that stayed in words, such as 五 in 三点五分.
            if before == "点", start > 1, numerals.contains(characters[start - 2]) || isASCIIDigit(characters[start - 2]) {
                return nil
            }
        }
        if let model = afterLatinName(run, in: characters) {
            return model
        }
        guard let spoken = parse(characters[run]) else { return nil }
        let next = end < characters.count ? characters[end] : nil
        if endsRange(before: start, in: characters) { return nil }
        // The second part of an amount, such as 三十 in 一分三十秒, stays with the first.
        if let unit = amountUnits.first(where: { starts($0, at: start - $0.count, in: characters) }) {
            // 一个小时二十分钟 has 个 between the number and its unit.
            var numberEnd = start - unit.count
            if numberEnd > 0, characters[numberEnd - 1] == "个" {
                numberEnd -= 1
            }
            if numberEnd > 0, numerals.contains(characters[numberEnd - 1]) { return nil }
        }
        switch next {
        case "点":
            return timeOrDecimal(run, spoken, in: characters)
        case "月":
            return month(run, spoken, in: characters)
        default:
            break
        }
        if let next, roughAfter.contains(next) { return nil }
        let unit = unitLength(at: end, in: characters)
        switch spoken {
        case .single(let value, let character):
            // 5G, 3D and 5% are written with digits. 两 is a count, not a digit.
            guard character != "两", character != "幺", next == "%" || latinUnit(at: end, in: characters, single: true) else { return nil }
            return (Array(String(value)), end)
        case .reading(let digits):
            // 一二三四五 and 五四三二一 are counting, unless a word such as 验证码 or 房间 says
            // it is a code.
            guard digits.count >= 3, !isCounting(digits) || followsCodeWord(start, in: characters) else { return nil }
            if next == "年" {
                return digits.count == 4 ? (Array(digits), end) : nil
            }
            // 三五七个 and 三四五天 are ranges.
            if unit > 0 || next == "个" { return nil }
            return (Array(digits), end)
        case .compound(let value, let large):
            guard let digits = compoundDigits(value, large: large).map(Array.init) else { return nil }
            if unit > 0 {
                return measure(run, digits, large: large, unit: unit, in: characters)
            }
            guard large == nil else { return nil }
            if next == "%" || latinUnit(at: end, in: characters, single: false) {
                return (digits, end)
            }
            // 一百二十八 GB keeps the space the speech model wrote.
            if next == " ", latinUnit(at: end + 1, in: characters, single: false) {
                return (digits, end)
            }
            return nil
        }
    }

    /// A number with 十, 百, 千, 万 or 亿 before a unit, such as 三百五十块.
    private static func measure(_ run: Range<Int>, _ digits: [Character], large: Character?, unit: Int, in characters: [Character]) -> (text: [Character], end: Int)? {
        let start = run.lowerBound
        let end = run.upperBound
        let unitText = String(characters[end..<end + unit])
        let afterUnit = end + unit
        let following = afterUnit < characters.count ? characters[afterUnit] : nil
        let numberText = String(characters[run])
        // 两万人 and 十二万公里 stay. Only money keeps 万 and 亿 as units.
        if large != nil, !currencies.contains(unitText) { return nil }
        if unitText == "度", !isTemperature(before: start, in: characters) { return nil }
        // 三千一个月 and 两百一小时 are a price for one month or one hour, not 3100 and 210.
        if end - start > 1, characters[end - 1] == "一", ["百", "千", "万"].contains(characters[end - 2]) { return nil }
        // 一百年都遇不到 and 八百年没见了 are figures of speech.
        if unitText == "年", hyperboleNumbers.contains(numberText), numberText == "八百" || following == "都" || following == "也" {
            return nil
        }
        guard let following, numerals.contains(following) else { return (digits, end) }
        let followingEnd = numeralsEnd(from: afterUnit, in: characters)
        // 十块八块 and 十年八年 are rough, like 七八个.
        if followingEnd == afterUnit + 1, starts(Array(unitText), at: followingEnd, in: characters) { return nil }
        // 三十块零五毛 and 九十九块九 stay whole. 两百元一张 is a price for one.
        if amountUnits.contains(Array(unitText)) {
            let perOne = followingEnd == afterUnit + 1 && following == "一"
                && !(followingEnd < characters.count && "毛角分秒两".contains(characters[followingEnd]))
            if !perOne { return nil }
        }
        return (digits, end)
    }

    /// Whether 度 after the number at `index` is a temperature: 零下 or 摄氏 comes before it.
    private static func isTemperature(before index: Int, in characters: [Character]) -> Bool {
        starts("零下", at: index - 2, in: characters) || starts("摄氏", at: index - 2, in: characters)
    }

    /// Whether the number at `index` ends a range, as 五百 in 三百到五百元 and 十 in
    /// 零下五到零下十度. Both ends of a range stay in words. A range of days after a month is
    /// handled with the month, and a range of times after a time of day with the time.
    private static func endsRange(before index: Int, in characters: [Character]) -> Bool {
        var connector = index - 1
        if starts("零下", at: index - 2, in: characters) {
            connector = index - 3
        }
        guard connector > 0, characters[connector] == "到" || characters[connector] == "至" else { return false }
        var before = connector - 1
        if ["降", "涨", "升"].contains(characters[before]), before > 0 {
            before -= 1
        }
        return numerals.contains(characters[before]) || roughAfter.contains(characters[before])
    }

    /// Whether 分 and not 分钟 follows minutes that end at `index`.
    private static func isMinutes(endingAt index: Int, in characters: [Character]) -> Bool {
        starts("分", at: index, in: characters) && !starts("分钟", at: index, in: characters)
    }

    /// The minutes in `run` after an hour, such as 20 for 二十 and 05 for 零五, or nil when
    /// they are not minutes.
    private static func minutes(_ run: Range<Int>, isTime: Bool, in characters: [Character]) -> String? {
        let minutes = characters[run]
        let isMinutes = isMinutes(endingAt: run.upperBound, in: characters)
        if minutes.contains("十"), case .compound(let value, .none)? = parse(minutes), (10...59).contains(value) {
            // 三点十分 could be three points that matter a lot (三点十分重要) and needs a time
            // of day. 下午三点二十块 is not a time.
            if !isTime, minutes.count == 1 { return nil }
            if !isMinutes, unitLength(at: run.upperBound, in: characters) > 0 { return nil }
            return String(value)
        }
        guard let last = minutes.last, last != "幺", let value = digitValues[last], value > 0 else { return nil }
        // 三点零五分, and 下午三点零五 after a time of day.
        if minutes.count == 2, minutes.first == "零" { return "0\(value)" }
        // 下午三点五分 is a time. Without a time of day it could be a score and stays.
        if minutes.count == 1, isTime, isMinutes { return String(value) }
        return nil
    }

    /// Whether digits read one by one count up or down by one or two, as in 一二三四五,
    /// 五四三二一 and 一三五七九.
    private static func isCounting(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        let steps = zip(values, values.dropFirst()).map { $1 - $0 }
        return [1, -1, 2, -2].contains { step in steps.allSatisfy { $0 == step } }
    }

    /// Whether a word such as 号码, 验证码, 电话 or 房间 comes shortly before `index`, or a group
    /// of a code that converts, as in 幺三九 幺二三四 五六七八, where the groups after the
    /// first convert with it.
    private static func followsCodeWord(_ index: Int, in characters: [Character]) -> Bool {
        let words: [[Character]] = ["码", "号", "电话", "打", "拨", "房", "室"].map { Array($0) }
        if (max(0, index - 4)..<index).contains(where: { position in
            words.contains { starts($0, at: position, in: characters) }
        }) {
            return true
        }
        guard index > 1, characters[index - 1] == " " else { return false }
        let groupEnd = index - 1
        var first = runStart(endingAt: groupEnd, in: characters) { isASCIIDigit($0) }
        if groupEnd - first >= 3 { return true }
        while first > 0, readingDigits.contains(characters[first - 1]) {
            first -= 1
        }
        guard groupEnd - first >= 3, first == 0 || !numerals.contains(characters[first - 1]),
              case .reading? = parse(characters[first..<groupEnd]) else { return false }
        return conversion(of: first..<groupEnd, in: characters) != nil
    }

    /// A model number or version right after a Latin name, such as RX 三五零, M五 or macOS
    /// 十五点一. Chinese may follow only right after a model name (M五芯片), not after a word
    /// that looks like a person's name (Tom八成) and not after a space. Even then 一 (App一打开),
    /// 十分 as very and a number before a unit or a counter (PPT三个) are left to the other
    /// rules. After a space a single digit must not be 一 or 零. A version converts whole when
    /// no Chinese follows it, or 以上, 以下 or 版 does, so Tom三点十五到 stays.
    private static func afterLatinName(_ run: Range<Int>, in characters: [Character]) -> (text: [Character], end: Int)? {
        let start = run.lowerBound
        let end = run.upperBound
        guard start > 0 else { return nil }
        let before = characters[start - 1]
        let joined = isASCIILetter(before) || (before == "-" && start > 1 && isLatinOrDigit(characters[start - 2]))
        let spaced = before == " " && start > 1 && isASCIILetter(characters[start - 2])
        guard joined || spaced, let spoken = parse(characters[run]) else { return nil }
        let next = characters[safe: end]
        if next == "点", let major = wholeNumber(spoken) {
            var parts = [String(major)]
            var partsEnd = end
            while characters[safe: partsEnd] == "点", let first = characters[safe: partsEnd + 1], numerals.contains(first) {
                let partEnd = numeralsEnd(from: partsEnd + 1, in: characters)
                let part = characters[(partsEnd + 1)..<partEnd]
                if part.allSatisfy({ readingDigits.contains($0) }) {
                    parts.append(String(part.map { Character(String(digitValues[$0]!)) }))
                } else if case .compound(let value, .none)? = parse(part), (10...19).contains(value) {
                    parts.append(String(value))
                } else {
                    return nil
                }
                partsEnd = partEnd
            }
            if let after = characters[safe: partsEnd], isHan(after),
               !["以上", "以下", "版"].contains(where: { starts($0, at: partsEnd, in: characters) }) {
                return nil
            }
            return parts.count > 1 ? (Array(parts.joined(separator: ".")), partsEnd) : nil
        }
        let text: String
        switch spoken {
        case .single(let value, let character):
            guard character != "两", character != "幺", !(spaced && (character == "一" || character == "零")) else { return nil }
            text = String(value)
        case .reading(let digits):
            text = digits
        case .compound(let value, let large):
            guard let digits = compoundDigits(value, large: large) else { return nil }
            text = digits
        }
        if let next {
            if next == "月" || roughAfter.contains(next) { return nil }
            if isHan(next) {
                let isModel = before == "-" || looksLikeModel(endingAt: start - 1, in: characters)
                guard joined, isModel, characters[start] != "一" || run.count > 1, !(characters[start] == "十" && next == "分") else { return nil }
                // 做PPT三个小时 counts hours. A code such as G一零二次 is not counted.
                if case .reading = spoken {} else if unitLength(at: end, in: characters) > 0 || "个次遍位张本条只件份页种".contains(next) {
                    return nil
                }
            } else if spaced, next != " ", isLatinOrDigit(next) || next == "%", !latinUnit(at: end, in: characters, single: false) {
                return nil
            }
        }
        return (Array(text), end)
    }

    /// An hour before 点 that is a time, or a decimal before a unit, such as 三点五公里.
    private static func timeOrDecimal(_ run: Range<Int>, _ spoken: Spoken, in characters: [Character]) -> (text: [Character], end: Int)? {
        let start = run.lowerBound
        guard let hour = wholeNumber(spoken) else { return nil }
        let after = run.upperBound + 1
        let isHour = hour <= 24
        let isTime = isHour && (followsTimeOfDay(start, in: characters) || endsRangeOfTimes(start, in: characters))
        let isOne = run.count == 1 && characters[start] == "一"
        guard after < characters.count else {
            return isTime ? (Array("\(hour)点"), after) : nil
        }
        let next = characters[after]
        if roughAfter.contains(next) { return nil }
        if numerals.contains(next) {
            // 便宜一点五十块 and 快一点五个小时 are a little and then a number, unless a word such
            // as 是 or 约 comes before 一点.
            if isOne, !isTime, start > 0, isHan(characters[start - 1]), !beforeOnePoint.contains(characters[start - 1]) {
                return nil
            }
            let end = numeralsEnd(from: after, in: characters)
            if isHour, let minutes = minutes(after..<end, isTime: isTime, in: characters),
               isTime || isMinutes(endingAt: end, in: characters) {
                return (Array("\(hour)点\(minutes)"), end)
            }
            // 下午三点一刻 keeps 一刻 in words.
            if isTime, end == after + 1, next == "一" || next == "三", starts("刻", at: end, in: characters) {
                return (Array("\(hour)点"), after)
            }
            return decimal(hour, after..<end, numberStart: start, in: characters)
        }
        guard isTime else { return nil }
        // 晚上一点都不冷 is not at all.
        if isOne, isHan(next), !afterOneOClock.contains(where: { starts($0, at: after, in: characters) }) {
            return nil
        }
        return (Array("\(hour)点"), after)
    }

    /// A decimal whose digits after 点 are in `fraction`, such as 三点五亿元, when a unit
    /// follows.
    private static func decimal(_ whole: Int, _ fraction: Range<Int>, numberStart: Int, in characters: [Character]) -> (text: [Character], end: Int)? {
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
        let unit = unitLength(at: end, in: characters)
        if large.isEmpty {
            guard unit > 0 || characters[safe: end] == "%" || latinUnit(at: end, in: characters, single: false) else { return nil }
            if characters[safe: end] == "度", !isTemperature(before: numberStart, in: characters) {
                return nil
            }
        } else {
            guard unit > 0, currencies.contains(String(characters[end..<end + unit])) else { return nil }
        }
        return (Array("\(whole).\(digits)\(large)"), end)
    }

    /// A month in a date, with its day: 十月一日 is 10月1日. A month after a year in digits
    /// converts alone. 二月春风, 十月稻田, lunar dates (农历八月十五号), dates of lunar festivals
    /// (七月七日是七夕) and ranges of days (十月一号至七号) stay.
    private static func month(_ run: Range<Int>, _ spoken: Spoken, in characters: [Character]) -> (text: [Character], end: Int)? {
        guard let value = wholeNumber(spoken), (1...12).contains(value) else { return nil }
        if case .single(_, "两") = spoken { return nil }
        let start = run.lowerBound
        let after = run.upperBound + 1
        if lunarWords.contains(where: { starts($0, at: start - $0.count, in: characters) }) { return nil }
        // 十月 十日 has a space the speech model wrote.
        let dayStart = characters[safe: after] == " " ? after + 1 : after
        if let first = characters[safe: dayStart], numerals.contains(first) {
            let dayEnd = numeralsEnd(from: dayStart, in: characters)
            if characters[safe: dayEnd] == "号" || characters[safe: dayEnd] == "日",
               let day = parse(characters[dayStart..<dayEnd]), let dayValue = wholeNumber(day), (1...31).contains(dayValue) {
                if case .single(_, "两") = day { return nil }
                if lunarFestivalFollows(dayEnd + 1, in: characters) { return nil }
                if ["到", "至"].contains(characters[safe: dayEnd + 1]), let next = characters[safe: dayEnd + 2], numerals.contains(next),
                   characters[safe: numeralsEnd(from: dayEnd + 2, in: characters)] != "月" {
                    return nil
                }
                return (Array("\(value)月" + String(characters[after..<dayStart]) + "\(dayValue)"), dayEnd)
            }
        }
        let year = characters[safe: start - 1] == " " ? start - 2 : start - 1
        guard year > 0, characters[year] == "年", yearConverts(endingAt: year, in: characters) else { return nil }
        return (Array(String(value)), run.upperBound)
    }

    /// Whether a lunar festival starts at `index`, or after 是 or 的 there, as in 七月七日是七夕.
    private static func lunarFestivalFollows(_ index: Int, in characters: [Character]) -> Bool {
        let festival = ["是", "的"].contains(characters[safe: index]) ? index + 1 : index
        return lunarFestivals.contains(where: { starts($0, at: festival, in: characters) })
    }

    /// Whether the year before 年 at `index` is in digits or becomes digits, as 二零二六 does
    /// and 一九 does not.
    private static func yearConverts(endingAt index: Int, in characters: [Character]) -> Bool {
        if index > 0, isASCIIDigit(characters[index - 1]) { return true }
        let first = runStart(endingAt: index, in: characters) { readingDigits.contains($0) }
        return index - first == 4 && (first == 0 || !numerals.contains(characters[first - 1]))
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
        guard let spoken = parse(characters[numberStart..<numberEnd]), let value = wholeNumber(spoken) else { return kept }
        if case .single(_, let character) = spoken, character == "两" || character == "幺" { return kept }
        var text = String(value)
        var end = numberEnd
        if characters[safe: end] == "点", let first = characters[safe: end + 1], readingDigits.contains(first) {
            let fractionEnd = numeralsEnd(from: end + 1, in: characters)
            let fraction = characters[(end + 1)..<fractionEnd]
            guard fraction.allSatisfy({ readingDigits.contains($0) && $0 != "幺" }) else { return kept }
            text += "." + fraction.map { String(digitValues[$0]!) }.joined()
            end = fractionEnd
        }
        if let next = characters[safe: end], roughAfter.contains(next) {
            return (Array(characters[index..<end]), end)
        }
        // 百分之五点多 is rough, and 百分之三到五 is a range whose end has no 百分之.
        if let next = characters[safe: end], ["点", "到", "至"].contains(next), let second = characters[safe: end + 1],
           !starts("百分之", at: end + 1, in: characters), roughAfter.contains(second) || numerals.contains(second) {
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
        // 万亿 is one unit in Chinese news: 一百二十六万亿元. The value is kept with 兆.
        if run.count > 2, run.suffix(2).elementsEqual(["万", "亿"]),
           let prefix = parse(run.dropLast(2)), let value = wholeNumber(prefix), value < 10_000 {
            return .compound(value * 1_000_000_000_000, large: "兆")
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
    /// 百, 千, 万 or 亿 at the end counts in the next smaller place, so 三千五 is 3500 and 两万三
    /// is 23000.
    private static func compoundValue(_ run: ArraySlice<Character>) -> Int? {
        var total = 0
        var rest = run
        var lastPower = 1
        for (mark, scale) in [("亿" as Character, 100_000_000), ("万", 10_000)] {
            guard let index = rest.firstIndex(of: mark) else { continue }
            // 三千五万 leaves out a place, too unclear to read.
            guard let section = sectionValue(rest[..<index], isFirst: rest.startIndex == run.startIndex, abbreviates: false),
                  section.value > 0, section.value < 10_000 else { return nil }
            // 二亿一万 reads as 2.1亿 and a missing 零, so it stays.
            if rest.startIndex != run.startIndex, !section.sawPower, rest.first != "零" { return nil }
            total += section.value * scale
            rest = rest[(index + 1)...]
            lastPower = scale
        }
        if rest.count == 1, let digit = digitValues[rest.first!], digit > 0, rest.first != "两", lastPower > 1 {
            return total + digit * lastPower / 10
        }
        guard let section = sectionValue(rest, isFirst: rest.startIndex == run.startIndex, abbreviates: true),
              section.value < 10_000, section.sawPower || lastPower > 1 else { return nil }
        if rest.first == "零", lastPower == 1 { return nil }
        return total + section.value
    }

    /// The value of numerals with 十, 百 and 千 only, such as 三千零五 or 十二. An empty run is
    /// 0. 十 may start the number only when it is the first section.
    private static func sectionValue(_ run: ArraySlice<Character>, isFirst: Bool, abbreviates: Bool) -> (value: Int, sawPower: Bool)? {
        var value = 0
        var digit: Int?
        var digitIsLiang = false
        var smallestPower = 10_000
        var powerBeforeDigit = 0
        var afterZero = false
        var sawPower = false
        for (offset, character) in run.enumerated() {
            if character == "零" || character == "〇" {
                if (offset == 0 && isFirst) || digit != nil || afterZero { return nil }
                afterZero = true
                powerBeforeDigit = 0
            } else if let power = smallPowers[character] {
                guard power < smallestPower, !(digitIsLiang && power == 10),
                      let count = digit ?? (power == 10 && offset == 0 && isFirst ? 1 : nil) else { return nil }
                value += count * power
                smallestPower = power
                powerBeforeDigit = power
                digit = nil
                digitIsLiang = false
                afterZero = false
                sawPower = true
            } else if character != "幺", let number = digitValues[character], digit == nil {
                digit = number
                digitIsLiang = character == "两"
                afterZero = false
            } else {
                return nil
            }
        }
        if afterZero || (digitIsLiang && abbreviates) { return nil }
        if let digit {
            if powerBeforeDigit >= 100 {
                guard abbreviates else { return nil }
                value += digit * smallestPower / 10
            } else {
                value += digit
            }
        }
        return (value, sawPower)
    }

    /// Digits for a number, keeping 万, 亿 or 万亿 as a unit: 20000 with 万 is 2万, 35000 is
    /// 3.5万. An amount that needs more places, such as 13888 or 20050, is written whole below
    /// 1亿 and stays in words above it, since 1.3888万 and 2.005万 are not how anyone writes.
    private static func compoundDigits(_ value: Int, large: Character?) -> String? {
        guard let large else { return String(value) }
        let unit = large == "兆" ? 1_000_000_000_000 : large == "亿" ? 100_000_000 : 10_000
        let places = String(unit).count - 1
        let name = large == "兆" ? "万亿" : String(large)
        let whole = value / unit
        let rest = value % unit
        guard rest > 0 else { return "\(whole)\(name)" }
        var fraction = String(rest)
        fraction = String(repeating: "0", count: places - fraction.count) + fraction
        while fraction.hasSuffix("0") {
            fraction.removeLast()
        }
        if fraction.count <= 2, !fraction.hasPrefix("0") {
            return "\(whole).\(fraction)\(name)"
        }
        return value < 100_000_000 ? String(value) : nil
    }

    /// Whether a phrase such as 十年寒窗 overlaps the numerals in `run`. A phrase of numerals
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

    /// Whether the hour at `index` ends a range of times after a time of day, such as 四 in
    /// 下午三点半到四点.
    private static func endsRangeOfTimes(_ index: Int, in characters: [Character]) -> Bool {
        guard index >= 2, characters[index - 1] == "到" || characters[index - 1] == "至" else { return false }
        let first = runStart(endingAt: index - 1, in: characters) { numerals.contains($0) || isASCIIDigit($0) || "点半分钟".contains($0) }
        return first < index - 2 && characters[first..<(index - 1)].contains("点") && followsTimeOfDay(first, in: characters)
    }

    private static func followsTimeOfDay(_ index: Int, in characters: [Character]) -> Bool {
        timesOfDay.contains { starts($0, at: index - $0.count, in: characters) }
    }

    /// The length of the unit that starts at `index`, or 0.
    private static func unitLength(at index: Int, in characters: [Character]) -> Int {
        guard index < characters.count, !notUnits.contains(where: { starts($0, at: index, in: characters) }) else { return 0 }
        return units.first { starts($0, at: index, in: characters) }?.count ?? 0
    }

    /// Whether a Latin unit such as GB or K starts at `index`, and no other letter follows.
    private static func latinUnit(at index: Int, in characters: [Character], single: Bool) -> Bool {
        guard let unit = latinUnits.first(where: { starts($0, at: index, in: characters) }) else { return false }
        if let after = characters[safe: index + unit.count], isASCIILetter(after) { return false }
        return !single || singleDigitLatinUnits.contains(String(unit))
    }

    /// The start of the run of characters that pass `test` and end right before `index`.
    private static func runStart(endingAt index: Int, in characters: [Character], where test: (Character) -> Bool) -> Int {
        var first = index
        while first > 0, test(characters[first - 1]) {
            first -= 1
        }
        return first
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

    /// Whether the Latin word that ends at `index` looks like a model name rather than a
    /// person's name or a common word: one letter (M), all capitals (RX, PPT) or a capital
    /// after the first letter (iPhone, macOS). Tom, Amy and Python do not.
    private static func looksLikeModel(endingAt index: Int, in characters: [Character]) -> Bool {
        let first = runStart(endingAt: index, in: characters) { isLatinOrDigit($0) }
        let word = characters[first...index]
        return word.count == 1 || word.contains(where: isASCIIDigit) || word.dropFirst().contains(where: { $0.isUppercase })
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
        character.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || $0.value >= 0x20000 && $0.value <= 0x2FFFF }
    }
}

private extension Array {
    /// The element at `index`, or nil outside the array.
    nonisolated subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
