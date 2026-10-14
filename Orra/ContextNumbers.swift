import Foundation

/// Takes numbers back from a transcript without the vocabulary. With any vocabulary as
/// context, even 10 words, Qwen3-ASR writes Chinese numbers the way they are spoken: 1966
/// as 一九六六, 400 as 四百, 6.5 as 六点五. Without a context it writes digits. How the words
/// are framed in the context does not change this. Measured on 2026-10-13 on the Chinese
/// clips of the speech corpus (Tools/speech-eval), the error rate with 10 words rose from
/// 4.69% to 5.91 to 6.41% for every layout tried: one per line, commas, spaces, the reverse
/// order, a heading in English or Chinese, a sentence around the words, and examples or an
/// instruction with digits. A heading also made the model write text for noise.
///
/// So when the transcript with the vocabulary may hold a number in Chinese characters, the
/// same samples are transcribed once more without the vocabulary, and only the numbers are
/// taken from that pass: where the two transcripts differ in a part that is a Chinese
/// number in one and digits of the same value in the other, the digits stand. Everything
/// else, the vocabulary terms first, stays as written with the vocabulary, except a closing
/// bracket for one that came with the digits. A part that overlaps a vocabulary term stays.
nonisolated enum ContextNumbers {
    private static let digitValues: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "幺": 1,
    ]
    private static let smallPowers: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    private static let largePowers: [(Character, Int)] = [("亿", 100_000_000), ("万", 10_000)]
    private static let numerals: Set<Character> = Set(digitValues.keys).union(smallPowers.keys).union(["万", "亿"])
    /// Punctuation and spaces a differing part may carry around its number, as in
    /// 、三十一 against （31.
    private static let punctuation: Set<Character> = Set("·“”‘’（）()《》，、。：；？！,.:;?!\"' ")

    /// Whether the text holds two or more Chinese numerals in a row, possibly with 点
    /// between them, 百分之, a time such as 六点半, or a score such as 六比六. Only then the
    /// pass without the vocabulary can help. Other single numerals, as in 一个, 三本书 and
    /// 快一点, do not count, so most dictations need no second pass.
    static func mayHoldSpokenNumber(_ text: String) -> Bool {
        if text.contains("百分之") { return true }
        let characters = Array(text)
        var run = 0
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if numerals.contains(character) {
                run += 1
                if run >= 2 { return true }
                if run == 1, character != "一", next == "点" { return true }
                if next == "比", index + 2 < characters.count, numerals.contains(characters[index + 2]) { return true }
            } else if character == "点", run > 0, let next, numerals.contains(next) {
                continue
            } else {
                run = 0
            }
        }
        return false
    }

    /// The transcript with the vocabulary, with each number the model wrote in Chinese
    /// characters replaced by the digits of `plain`, the transcript without the vocabulary,
    /// where they have the same value. Parts that overlap one of `terms` stay.
    static func merging(_ text: String, plain: String, terms: [String]) -> String {
        let old = Array(text)
        let new = Array(plain)
        guard old != new, !old.isEmpty, !new.isEmpty else { return text }
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        let protected = termRanges(in: old, terms: terms)
        var result: [Character] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
                result.append(old[i])
                i += 1
                j += 1
                continue
            }
            let start = i
            while i < old.count, removed.contains(i) { i += 1 }
            let newStart = j
            while j < new.count, inserted.contains(j) { j += 1 }
            let spoken = old[start..<i]
            let written = new[newStart..<j]
            if !spoken.isEmpty, !written.isEmpty,
               !protected.contains(where: { $0.overlaps(start..<i) }),
               sameNumber(spoken: spoken, written: written) {
                result.append(contentsOf: written)
            } else if spoken.isEmpty, !written.isEmpty, written.allSatisfy({ $0 == "）" || $0 == ")" }),
                      result.count(where: { $0 == "（" || $0 == "(" }) > result.count(where: { $0 == "）" || $0 == ")" }) {
                // Closes a bracket that came with the digits, as in 50公里（31英里）.
                result.append(contentsOf: written)
            } else {
                result.append(contentsOf: spoken)
            }
        }
        return String(result)
    }

    /// Whether the part in Chinese characters and the part in digits are the same number,
    /// ignoring punctuation and spaces around it: 四百 and 400, 一九六六 and 1966, 六点五 and
    /// 6.5, 百分之三十 and 30%.
    static func sameNumber(spoken: some Collection<Character>, written: some Collection<Character>) -> Bool {
        let spoken = String(spoken.filter { !punctuation.contains($0) })
        var written = String(written.filter { !punctuation.contains($0) || $0 == "." })
        written = written.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if spoken.hasPrefix("百分之") {
            guard written.hasSuffix("%") else { return false }
            written.removeLast()
            return digitsValue(written).map { $0 == value(of: String(spoken.dropFirst(3))) } ?? false
        }
        guard let digits = digitsValue(written), let number = value(of: spoken) else { return false }
        return digits == number
    }

    /// Digits with at most one decimal point, as written: 1966, 05, 6.5. Nil for anything else.
    private static func digitsValue(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        return text
    }

    /// A Chinese number as digits: a reading digit by digit (一九六六 is 1966, 零五 is 05),
    /// a number with 十, 百, 千, 万 or 亿 (两千零五 is 2005, 三十三万 is 330000), either with
    /// decimals after 点 (六点五 is 6.5). Nil when the text is not such a number, as for
    /// 三万五, which can mean 35000.
    static func value(of text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if let point = text.firstIndex(of: "点") {
            let decimals = text[text.index(after: point)...]
            guard !decimals.isEmpty, decimals.allSatisfy({ digitValues[$0] != nil && $0 != "两" }),
                  let whole = value(of: String(text[..<point])), !whole.contains(".") else { return nil }
            return whole + "." + decimals.map { String(digitValues[$0]!) }.joined()
        }
        guard text.allSatisfy(numerals.contains) else { return nil }
        if text.allSatisfy({ digitValues[$0] != nil }) {
            guard text.count == 1 || !text.contains("两") else { return nil }
            return text.map { String(digitValues[$0]!) }.joined()
        }
        var total = 0
        var rest = Substring(text)
        for (unit, size) in largePowers {
            guard let index = rest.firstIndex(of: unit) else { continue }
            let head = rest[..<index]
            guard let part = head.isEmpty ? 1 : section(head) else { return nil }
            total += part * size
            rest = rest[rest.index(after: index)...]
        }
        guard let part = rest.isEmpty ? 0 : section(rest) else { return nil }
        // A unit with a bare digit after it, as 三万五 or 一百五, is said for 35000 and
        // 150, so it is not read at all.
        if let last = text.last, digitValues[last] != nil, text.count >= 2 {
            let before = text[text.index(text.endIndex, offsetBy: -2)]
            if before != "十", before != "零", smallPowers[before] != nil || before == "万" || before == "亿" {
                return nil
            }
        }
        return String(total + part)
    }

    /// A number below 10000 with 十, 百 or 千: 三百零五 is 305, 十五 is 15.
    private static func section(_ text: Substring) -> Int? {
        var total = 0
        var digit: Int?
        var lastPower = Int.max
        for character in text where character != "零" && character != "〇" {
            if let value = digitValues[character] {
                guard digit == nil else { return nil }
                digit = value
            } else if let power = smallPowers[character] {
                guard power < lastPower else { return nil }
                total += (digit ?? 1) * power
                digit = nil
                lastPower = power
            } else {
                return nil
            }
        }
        return total + (digit ?? 0)
    }

    /// The character ranges of the text that hold a vocabulary term with a Chinese numeral,
    /// ignoring case. Other terms cannot overlap a number.
    private static func termRanges(in text: [Character], terms: [String]) -> [Range<Int>] {
        let lowered = text.map { $0.lowercased() }
        var ranges: [Range<Int>] = []
        for term in terms where term.contains(where: numerals.contains) || term.contains("点") {
            let needle = term.map { $0.lowercased() }
            guard !needle.isEmpty, needle.count <= lowered.count else { continue }
            for start in 0...(lowered.count - needle.count) where Array(lowered[start..<(start + needle.count)]) == needle {
                ranges.append(start..<(start + needle.count))
            }
        }
        return ranges
    }
}
