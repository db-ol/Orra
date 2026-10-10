import Foundation

/// Writes numbers that the speech model spelled out in Chinese characters as digits, such as
/// 二零二六年 as 2026年 and 百分之五十 as 50%.
///
/// Qwen3-ASR often writes a Chinese number the way it was spoken. These rules convert only
/// where a reader expects digits, and leave the text as dictated whenever they are unsure:
/// - Readings digit by digit (零〇一二三四五六七八九, and 幺 as 1) of three digits or more,
///   such as phone numbers, codes and room numbers: 幺三八零零幺三八零零零 is 13800138000.
///   A year needs four digits (二零二六年), and a reading before a counter such as 个 is a
///   range (三四五个) and stays, as does counting (一二三四五) unless a word such as 验证码
///   comes before it.
/// - Numbers with 十, 百, 千, 万 or 亿 before a unit or counter such as 元, 块, 个, 人, 天,
///   公里 or 页, or before a Latin unit such as GB: 三百五十块 is 350块. 万 and 亿 stay as
///   units the way Chinese news writes them, so 两万人 is 2万人, 三万五千元 is 3.5万元 and
///   一百二十六万亿元 is 126万亿元, and they need no unit at the end of a phrase: 十二万 is
///   12万 and 三万五 is 3.5万. 十万大山 stays. An amount that needs more places, such as
///   一万三千八百八十八元, is written whole. The start of a range converts with its end
///   (三百到五百元 is 300到500元), and a digit after 度 or 块 joins the number (36.5度, 99块9).
/// - Percentages (百分之三点五 is 3.5%), decimals before a unit (三点五公里 is 3.5公里), and
///   times: an hour after a time of day such as 下午, or before 半, 钟, 整, minutes or a word
///   such as 以后 (下午三点 is 下午3点, 三点二十分 is 3点20分). A decimal before 分 under 25
///   could be a time or a score (三点五分) and stays. 晚上一点都不冷 is not at all, and
///   三点十分重要 is three points that matter a lot, so both stay.
/// - Dates: a month with a day, with 份 or after a year (十月一日 is 10月1日), and the day
///   after such a month even when it is a single digit. Lunar dates stay (农历八月十五号).
/// - A number right after a Latin model name: RX 三五零 is RX 350, iPhone 十五 is iPhone 15,
///   M五 is M5 and macOS 十五点一 is macOS 15.1. A space that was there stays, and none is
///   added between Chinese and digits.
///
/// Single digits with a counter stay in words (一个人, 三本书, 两次), the way Chinese writes
/// small counts. So do ranges and rough numbers (七八个, 十几个, 二十多个, 三十来岁), ordinals
/// (第十五届), weekdays (星期一), idioms, poems and set phrases (一心一意, 三五成群, 十万火急),
/// figures of speech (说了一百遍, 十二分满意), words that start with a unit character
/// (十五元宵节, 二十年轻人), 万一, 千万, 十分 as very, 一点 as a little, holidays such as
/// 双十一 and 九一八, and text in book title marks. English is never touched, the speech model already writes its numbers
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
        "秒钟", "世纪", "年代", "周年", "周岁", "星期", "美元", "欧元", "英镑", "港币", "港元",
        "美金", "日元", "韩元", "澳元", "加元", "人民币", "英寸", "纳米", "毫安时", "毫安", "赫兹",
        "元", "块", "毛", "角", "分", "个", "位",
        "人", "次", "年", "日", "号", "秒", "岁", "天", "周", "米", "斤", "克", "吨", "页", "张",
        "件", "台", "倍", "度", "层", "楼", "本", "份", "条", "辆", "部", "家", "所", "名", "篇",
        "首", "套", "只", "场", "届", "期", "集", "章", "节", "轮", "遍", "趟", "道", "题", "星", "票",
        "瓶", "杯", "箱", "包", "支", "颗", "户", "间", "座", "股", "盒", "粒", "根", "碗", "寸", "瓦",
    ].map { Array($0) }.sorted { $0.count > $1.count }
    /// Words that start with a unit character but are not a unit after a number, such as 元宵
    /// in 正月十五元宵节, 年轻 in 二十年轻人 and 号人 in 二十号人马.
    private static let notUnits: [[Character]] = [
        "元宵", "元旦", "元素", "元老", "元帅", "元月", "元气", "元首", "日本", "日子", "日记", "日常",
        "天才", "天下", "天地", "天空", "天气", "天使", "天堂", "天然", "天罡", "天兵", "年轻", "年华",
        "年糕", "分店", "分公司", "分校", "分享", "分别", "分开", "分析", "分配", "分手", "个性", "个体",
        "人才", "人家", "人生", "人马", "期间", "期待", "期望", "期末", "期中", "期限", "台词", "台阶",
        "度假", "度过", "克服", "米饭", "号称", "号码", "号人", "岁月", "秒杀", "周末", "周边", "周围",
        "位置", "位于", "毛笔", "毛病", "块头", "名字", "本人", "本来", "本身", "本地", "条件", "只是",
        "只有", "只要", "只能", "只想", "只好", "节约", "节省", "节奏", "首先", "首都", "星座", "包括",
        "包含", "支持", "支付", "支出", "间隔", "股东", "股票", "股份", "股市", "根本", "根据", "户口",
        "户外", "斤斤", "所以", "所有", "所谓", "所在",
    ].map { Array($0) }
    /// Latin units after a number: 5G, 4K, 3D, 十六GB and 五百M. A single digit takes only
    /// the ones that cannot be a word, so 做一PPT stays.
    private static let latinUnits: [[Character]] = [
        "GB", "MB", "TB", "KB", "PB", "Gb", "Mb", "mAh", "GHz", "MHz", "kHz", "Hz", "kW", "kg",
        "km", "cm", "mm", "ms", "nm", "fps", "Mbps", "G", "K", "D", "M", "T", "W", "P",
    ].map { Array($0) }.sorted { $0.count > $1.count }
    private static let singleDigitLatinUnits: Set<String> = ["G", "K", "D", "GB", "MB", "TB", "KB", "Hz", "W"]
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
    /// Words before N点 that make it the points of a list, as in 以上三点之前都提过.
    private static let listWords: [[Character]] = [
        "这", "那", "哪", "有", "以上", "以下", "上述", "其中", "前面", "后面", "下面", "最后",
    ].map { Array($0) }
    /// What may follow 一点 after a time of day for it to be one o'clock. 晚上一点都不冷 is
    /// not at all, so 都, 也, 儿 and nouns keep it.
    private static let afterOneOClock: [[Character]] = [
        "钟", "半", "整", "以前", "之前", "以后", "之后", "左右", "前", "后", "到", "至", "的", "就",
        "才", "准时", "见", "开会", "出发", "起飞", "睡",
    ].map { Array($0) }
    /// What may follow 十分 after an hour for it to be ten minutes. 三点十分重要 is three
    /// points that are very important.
    private static let afterTenMinutes: Set<Character> = [
        "的", "左", "前", "后", "以", "之", "到", "至", "开", "出", "见", "准", "起", "集", "在", "从",
        "就", "才", "结", "发", "来", "去", "吃", "睡", "打", "回", "走", "钟",
    ]
    /// Words before a lunar date, which stays in words: 腊月二十三号, 农历八月十五号.
    private static let lunarWords: [[Character]] = ["农历", "阴历", "腊月", "正月", "冬月"].map { Array($0) }
    /// Lunar festivals after a date: 七月七日是七夕.
    private static let lunarFestivals: [[Character]] = ["七夕", "中秋", "重阳", "端午", "元宵", "乞巧", "腊八", "小年"].map { Array($0) }
    /// Round numbers that are figures of speech before 遍 or 次, or before 个 and one of
    /// `hyperboleAfterGe`: 说了一百遍, 一百个不愿意, 一万个理由. 一百个用户 is a count.
    private static let hyperboleNumbers: Set<String> = ["一百", "一千", "一万", "十万", "一百万", "一千万", "一亿", "一万万"]
    private static let hyperboleAfterGe: [[Character]] = [
        "不", "没", "理由", "放心", "小心", "想法", "为什么", "冷笑话", "愿意", "心眼", "感谢",
    ].map { Array($0) }
    /// Words after a number with 万 or 亿 and no unit that still make it an amount, as in
    /// 预算三万五的 and 十二万左右. 十万大山 and 九万里 stay.
    private static let afterLargeNumber: [[Character]] = ["的", "左右", "以上", "以下", "以内", "上下"].map { Array($0) }
    /// Idioms, set phrases, names and titles with a number in them, kept wherever a number
    /// touches them. Phrases of numerals only, such as 九一八, must match the whole number.
    private static let setPhrases: [[Character]] = [
        "一心一意", "三心二意", "一模一样", "七上八下", "乱七八糟", "十全十美", "三五成群", "九牛一毛",
        "十有八九", "八九不离十", "半斤八两", "三天两头", "一举两得", "五花八门", "万无一失", "千方百计",
        "九九归一", "三番五次", "五湖四海", "一五一十", "不三不四", "略知一二", "三十六计", "三十而立",
        "四十不惑", "五十知天命", "十年寒窗", "十年树木", "百年树人", "三十年河东", "三十年河西",
        "十天半个月", "十万火急", "十万八千里", "一千零一夜", "十万个为什么", "七七四十九", "九九八十一",
        "九一八", "一二九", "一二三", "七七八八", "二百五",
        // Poems, sayings, titles and fixed terms.
        "十年如一日", "十年磨一剑", "十年生死", "十年一觉", "二十年来辨", "一年三百六十日", "佳丽三千",
        "二十年后又是一条好汉", "五百年前是一家", "十五个吊桶", "十个指头", "一万年太久", "二十四节气",
        "七十二家房客", "十日谈", "四十二章经", "八十天环游", "十八层地狱", "二十八星宿", "三十六天罡",
        "七十二地煞", "九千岁", "十万大山", "九万里", "八万四千法门", "一句顶一万句", "十万天兵",
        "十万青年十万军", "八十万禁军", "十万雪花银", "二万五千里", "九月九日忆", "七月七日长生殿",
        "三月三日天气新", "三言两语",
        // Readings that are dates of events, weekdays or chants: 一二八, 五一二, 三一五, 一三五.
        "一二八", "五一二", "三一五", "一二一", "一三五", "二四六", "一三五七", "三六九",
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
            // The rest of a decimal or a time that stayed in words, such as 五 in 三点五分, or
            // minutes after an hour in digits, such as 二十 in 3点二十分.
            if before == "点", start > 1 {
                if isASCIIDigit(characters[start - 2]) {
                    return minutesAfterDigits(run, in: characters)
                }
                if numerals.contains(characters[start - 2]) { return nil }
            }
        }
        // 正月十五 and 腊月二十三号 are lunar dates.
        if lunarWords.contains(where: { starts($0, at: start - $0.count, in: characters) }) { return nil }
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
            // The day of a month stays in words when the month does.
            if start > 1, characters[start - 1] == "月", numerals.contains(characters[start - 2]) || isASCIIDigit(characters[start - 2]) {
                guard let day = dayAfterMonth(run, spoken, in: characters) else { return nil }
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
            guard character != "两", character != "幺", next == "%" || latinUnit(at: end, in: characters, single: true) else { return nil }
            return (Array(String(value)), end)
        case .reading(let digits):
            // 一二三四五 and 五四三二一 are counting, unless a word such as 验证码 or 房间 says
            // it is a code.
            guard digits.count >= 3, !isCounting(digits) || followsCodeWord(start, in: characters) else { return nil }
            if next == "年" {
                return digits.count == 4 ? (Array(digits), end) : nil
            }
            // 三四五个 is a range. A code is not counted.
            if unit > 0, next != "号" { return nil }
            return (Array(digits), end)
        case .compound(let value, let large):
            guard let digits = compoundDigits(value, large: large).map(Array.init) else { return nil }
            if unit > 0 {
                return countWithUnit(run, digits, value: value, large: large, unit: unit, in: characters)
            }
            if next == "%" || latinUnit(at: end, in: characters, single: false) {
                return (digits, end)
            }
            // 一百二十八 GB keeps the space the speech model wrote.
            if next == " ", latinUnit(at: end + 1, in: characters, single: false) {
                return (digits, end)
            }
            // 三百 in 三百到五百元 starts a range whose end converts.
            if startsRange(run, in: characters) {
                return (digits, end)
            }
            // 万 and 亿 are units of their own: 十二万 is 12万 and 三万五 is 3.5万, at the end of
            // a phrase or before a word such as 左右. 十万大山 and 九万里 stay.
            if large != nil {
                if let next, isHan(next), !afterLargeNumber.contains(where: { starts($0, at: end, in: characters) }) {
                    return nil
                }
                return (digits, end)
            }
            return nil
        }
    }

    /// A number with 十, 百, 千, 万 or 亿 before a unit, such as 三百五十块.
    private static func countWithUnit(_ run: Range<Int>, _ digits: [Character], value: Int, large: Character?, unit: Int, in characters: [Character]) -> (text: [Character], end: Int)? {
        let start = run.lowerBound
        let end = run.upperBound
        let unitText = String(characters[end..<end + unit])
        let afterUnit = end + unit
        let following = afterUnit < characters.count ? characters[afterUnit] : nil
        if unitText == "分" {
            // 十分 is very, and 三百分之一 is a fraction.
            if end - start == 1 || following == "之" { return nil }
            // 十二分满意, 万分感谢 and 一百二十分的努力 are utterly.
            if (value == 12 && large == nil) || large != nil || following == "的" { return nil }
        }
        // 说了一百遍, 一百个不愿意 and 一万个理由 are figures of speech.
        if hyperboleNumbers.contains(String(characters[run])) {
            if unitText == "遍" || unitText == "次" { return nil }
            if unitText == "个", hyperboleAfterGe.contains(where: { starts($0, at: afterUnit, in: characters) }) { return nil }
        }
        guard let following, numerals.contains(following) else { return (digits, end) }
        let singleFollows = numeralsEnd(from: afterUnit, in: characters) == afterUnit + 1
        // 十块八块 and 十年八年 are rough, like 七八个.
        if singleFollows, starts(Array(unitText), at: afterUnit + 1, in: characters) { return nil }
        // 三十六度五 is 36.5度 and 九十九块九 is 99块9. 十块九毛九 stays.
        if large == nil, unitText == "度" || unitText == "块", singleFollows,
           following != "幺", following != "两", let digit = digitValues[following] {
            let after = afterUnit + 1
            let closes = after == characters.count || !isHan(characters[after]) || characters[after] == "的"
                || starts("左右", at: after, in: characters)
            guard closes else { return nil }
            let text = unitText == "度" ? "\(value).\(digit)度" : "\(value)块\(digit)"
            return (Array(text), after)
        }
        return (digits, end)
    }

    /// Whether the number in `run` starts a range such as 三百到五百元 whose end converts.
    private static func startsRange(_ run: Range<Int>, in characters: [Character]) -> Bool {
        let connectors: [[Character]] = ["到", "至", "降到", "涨到", "升到"].map { Array($0) }
        guard let connector = connectors.first(where: { starts($0, at: run.upperBound, in: characters) }) else { return false }
        let second = run.upperBound + connector.count
        guard second < characters.count, numerals.contains(characters[second]) else { return false }
        let secondEnd = numeralsEnd(from: second, in: characters)
        guard case .compound? = parse(characters[second..<secondEnd]), unitLength(at: secondEnd, in: characters) > 0 else { return false }
        return conversion(of: second..<secondEnd, in: characters) != nil
    }

    /// Minutes after an hour that the speech model wrote in digits, such as 二十 in 3点二十分.
    private static func minutesAfterDigits(_ run: Range<Int>, in characters: [Character]) -> (text: [Character], end: Int)? {
        let start = run.lowerBound
        var first = start - 2
        while first > 0, isASCIIDigit(characters[first - 1]) {
            first -= 1
        }
        guard start - 1 - first <= 2, first == 0 || !(characters[first - 1] == "." || isLatinOrDigit(characters[first - 1])),
              let hour = Int(String(characters[first..<(start - 1)])), hour <= 24 else { return nil }
        let minutes = characters[run]
        let following = run.upperBound < characters.count ? characters[run.upperBound] : nil
        if minutes.contains("十"), case .compound(let value, .none)? = parse(minutes), (10...59).contains(value) {
            if tenMeansVery(run, isTime: followsTimeOfDay(first, in: characters), in: characters) { return nil }
            return (Array(String(value)), run.upperBound)
        }
        if minutes.count == 2, minutes.first == "零", following == "分",
           let last = minutes.last, last != "幺", let value = digitValues[last], value > 0 {
            return (Array("0\(value)"), run.upperBound)
        }
        return nil
    }

    /// Whether 十分 after an hour is very, as in 三点十分重要, and not ten minutes.
    private static func tenMeansVery(_ minutes: Range<Int>, isTime: Bool, in characters: [Character]) -> Bool {
        guard !isTime, minutes.count == 1, characters[minutes.lowerBound] == "十" else { return false }
        let after = minutes.upperBound + 1
        guard minutes.upperBound < characters.count, characters[minutes.upperBound] == "分", after < characters.count else { return false }
        return isHan(characters[after]) && !afterTenMinutes.contains(characters[after])
    }

    /// Whether a word such as 号码, 验证码, 电话 or 房间 comes shortly before `index`.
    private static func followsCodeWord(_ index: Int, in characters: [Character]) -> Bool {
        let words: [[Character]] = ["码", "号", "电话", "打", "拨", "房", "室"].map { Array($0) }
        return (max(0, index - 4)..<index).contains { position in
            words.contains { starts($0, at: position, in: characters) }
        }
    }

    /// Whether digits read one by one count up or down, as in 一二三四五 and 五四三二一.
    private static func isCounting(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        let steps = zip(values, values.dropFirst()).map { $1 - $0 }
        return steps.allSatisfy { $0 == 1 } || steps.allSatisfy { $0 == -1 }
    }

    /// A model number or version right after a Latin name, such as RX 三五零, M五 or macOS
    /// 十五点一. Right after a letter (M五) any number counts, but 一 only when no Chinese
    /// follows, since App一打开 is as soon as. After a space it needs more than one digit, or
    /// a single digit that is not 一, 两 or 零 and stands alone, and it must not be a count
    /// such as Tom 三十岁, which the other rules handle.
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
            guard let digits = compoundDigits(value, large: large) else { return nil }
            text = digits
        }
        // A version such as 十五点一, 三点十二 or 十八点二点一, converted whole or not at all.
        // Minutes such as 三点二十 stay a time.
        if end < characters.count, characters[end] == "点", end + 1 < characters.count,
           numerals.contains(characters[end + 1]), let major = wholeNumber(spoken) {
            var parts = [String(major)]
            var partsEnd = end
            while partsEnd + 1 < characters.count, characters[partsEnd] == "点", numerals.contains(characters[partsEnd + 1]) {
                let partEnd = numeralsEnd(from: partsEnd + 1, in: characters)
                let partCharacters = characters[(partsEnd + 1)..<partEnd]
                if partCharacters.allSatisfy({ readingDigits.contains($0) }) {
                    parts.append(String(partCharacters.map { Character(String(digitValues[$0]!)) }))
                } else if case .compound(let value, .none)? = parse(partCharacters), (10...19).contains(value) {
                    parts.append(String(value))
                } else {
                    if parts.count > 1 { return nil }
                    break
                }
                partsEnd = partEnd
            }
            let after = partsEnd < characters.count ? characters[partsEnd] : nil
            if parts.count > 1, after.map({ ["分", "钟", "半"].contains($0) }) != true {
                text = parts.joined(separator: ".")
                end = partsEnd
                isVersion = true
            } else if parts.count > 2 {
                return nil
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
                } else if character == "一", let next, isHan(next) {
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
        // 这三点 and 以上三点 are points of a list.
        let isList = listWords.contains { starts($0, at: start - $0.count, in: characters) }
        if start > 0, ["这", "那", "哪"].contains(characters[start - 1]) { return nil }
        let after = run.upperBound + 1
        let isHour = hour <= 24
        let isTime = followsTimeOfDay(start, in: characters) || endsRangeOfTimes(start, in: characters)
        let isOne = run.count == 1 && characters[start] == "一"
        guard after < characters.count else {
            return (isHour && isTime) || hour >= 100 ? (Array("\(hour)点"), after) : nil
        }
        let next = characters[after]
        if roughAfter.contains(next) { return nil }
        if numerals.contains(next) {
            let end = numeralsEnd(from: after, in: characters)
            let minutes = characters[after..<end]
            let following = end < characters.count ? characters[end] : nil
            if isHour, minutes.contains("十"), case .compound(let value, .none)? = parse(minutes), (10...59).contains(value) {
                if tenMeansVery(after..<end, isTime: isTime, in: characters) { return nil }
                return (Array("\(hour)点\(value)"), end)
            }
            // 三点零五分, and 下午三点零五 after a time of day.
            if isHour, minutes.count == 2, minutes.first == "零", following == "分" || isTime,
               let last = minutes.last, last != "幺", let value = digitValues[last], value > 0 {
                return (Array("\(hour)点0\(value)"), end)
            }
            // 下午三点五分 is a time. Without a time of day it could be a score and stays.
            if isHour, isTime, minutes.count == 1, following == "分", let first = minutes.first,
               first != "幺", first != "零", let value = digitValues[first] {
                return (Array("\(hour)点\(value)"), end)
            }
            // 三点一刻 keeps 一刻 in words.
            if isHour, minutes.count == 1, let first = minutes.first, first == "一" || first == "三", following == "刻" {
                return (Array("\(hour)点"), after)
            }
            return decimal(hour, after..<end, in: characters, couldBeTime: isHour)
        }
        // An index moves in points: 涨了三百点.
        guard isHour else { return hour >= 100 ? (Array("\(hour)点"), after) : nil }
        if clockWords.contains(where: { starts($0, at: after, in: characters) }) {
            return (Array("\(hour)点"), after)
        }
        if isTime {
            // 晚上一点都不冷 is not at all.
            if isOne, isHan(next), !afterOneOClock.contains(where: { starts($0, at: after, in: characters) }) {
                return nil
            }
            return (Array("\(hour)点"), after)
        }
        if !isOne, !isList, laterWords.contains(where: { starts($0, at: after, in: characters) }) {
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
            guard unit > 0 || next == "%" || latinUnit(at: end, in: characters, single: false) else { return nil }
            if couldBeTime, unit == 1, next == "分" { return nil }
        }
        return (Array("\(whole).\(digits)\(large)"), end)
    }

    /// A month in a date: before a day, before 份, or after a year that converts. 二月春风,
    /// 十月稻田, lunar dates (农历八月十五号) and dates of lunar festivals (七月七日是七夕) stay.
    private static func month(_ run: Range<Int>, _ spoken: Spoken, in characters: [Character]) -> (text: [Character], end: Int)? {
        guard let value = wholeNumber(spoken), (1...12).contains(value) else { return nil }
        if case .single(_, "两") = spoken { return nil }
        let start = run.lowerBound
        let after = run.upperBound + 1
        if lunarWords.contains(where: { starts($0, at: start - $0.count, in: characters) }) { return nil }
        var isDate = after < characters.count && characters[after] == "份"
        if !isDate, after < characters.count, numerals.contains(characters[after]) {
            let dayEnd = numeralsEnd(from: after, in: characters)
            if dayEnd < characters.count, ["号", "日"].contains(characters[dayEnd]),
               let day = parse(characters[after..<dayEnd]), isDay(day) {
                var festival = dayEnd + 1
                if festival < characters.count, ["是", "的"].contains(characters[festival]) {
                    festival += 1
                }
                if lunarFestivals.contains(where: { starts($0, at: festival, in: characters) }) { return nil }
                isDate = true
            }
        }
        if !isDate, start > 1, characters[start - 1] == "年" {
            isDate = yearConverts(endingAt: start - 1, in: characters)
        }
        return isDate ? (Array(String(value)), run.upperBound) : nil
    }

    /// Whether the year before 年 at `index` is in digits or becomes digits, as 二零二六 does
    /// and 一九 does not.
    private static func yearConverts(endingAt index: Int, in characters: [Character]) -> Bool {
        if index > 0, isASCIIDigit(characters[index - 1]) { return true }
        var first = index
        while first > 0, readingDigits.contains(characters[first - 1]) {
            first -= 1
        }
        return index - first == 4 && (first == 0 || !numerals.contains(characters[first - 1]))
    }

    /// The day after a month in a date, such as 八 in 三月八号, when the month converts too.
    private static func dayAfterMonth(_ run: Range<Int>, _ spoken: Spoken, in characters: [Character]) -> [Character]? {
        let start = run.lowerBound
        guard start > 1, characters[start - 1] == "月", isDay(spoken), let value = wholeNumber(spoken) else { return nil }
        let monthEnd = start - 1
        if !isASCIIDigit(characters[monthEnd - 1]) {
            var monthStart = monthEnd
            while monthStart > 0, numerals.contains(characters[monthStart - 1]) {
                monthStart -= 1
            }
            guard monthStart < monthEnd, !touchesSetPhrase(monthStart..<monthEnd, in: characters),
                  let month = parse(characters[monthStart..<monthEnd]),
                  self.month(monthStart..<monthEnd, month, in: characters) != nil else { return nil }
        }
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

    /// Digits for a number, keeping 万, 亿 or 万亿 as a unit: 20000 with 万 is 2万, 35000 is
    /// 3.5万. An amount that needs more places, such as 13888 or 20050, is written whole below
    /// 1亿 and stays in words above it, since 1.3888万 and 2.005万 are not how anyone writes.
    private static func compoundDigits(_ value: Int, large: Character?) -> String? {
        guard let large else { return String(value) }
        let places = large == "兆" ? 12 : large == "亿" ? 8 : 4
        let name = large == "兆" ? "万亿" : String(large)
        var unit = 1
        for _ in 0..<places {
            unit *= 10
        }
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
        while first > 0, numerals.contains(characters[first - 1]) || isASCIIDigit(characters[first - 1])
            || ["点", "半", "分", "钟"].contains(characters[first - 1]) {
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
        guard index < characters.count, !notUnits.contains(where: { starts($0, at: index, in: characters) }) else { return 0 }
        return units.first { starts($0, at: index, in: characters) }?.count ?? 0
    }

    /// Whether a Latin unit such as GB or K starts at `index`, and no other letter follows.
    private static func latinUnit(at index: Int, in characters: [Character], single: Bool) -> Bool {
        guard let unit = latinUnits.first(where: { starts($0, at: index, in: characters) }) else { return false }
        let after = index + unit.count
        if after < characters.count, isASCIILetter(characters[after]) { return false }
        return !single || singleDigitLatinUnits.contains(String(unit))
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
