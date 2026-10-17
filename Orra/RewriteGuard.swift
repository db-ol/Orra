import Foundation

/// Cheap checks on the cleanup model's output, so a cleanup that answered the dictation,
/// carried it out or changed what it says is never pasted. The text after the rule steps
/// is pasted instead.
///
/// A port of the cleanup part of bench/hardening/guards.py, measured on 2026-10-10 with the
/// hardened prompt: on the 178 regular cases of Tools/rewrite-eval it held back 6 outputs
/// and none that matched the expected text, and it caught every adversarial output a judge
/// marked as answered. RewriteGuardTests runs the outputs of that measurement and expects
/// the verdicts of the Python version.
nonisolated enum RewriteGuard {
    /// Why an output was held back. `logName` names the check without any of the text.
    enum Failure: Equatable, Sendable, CustomStringConvertible {
        case empty
        /// Starts like an assistant's answer: "Sure", "Here is", "抱歉".
        case assistantOpener(String)
        /// Talks about itself or the prompt: "language model", "system prompt".
        case assistantPhrase(String)
        case caseChanged
        case foreignScript
        case bareShortReply
        case addedLines
        case addedMarkup
        /// Digits the transcript did not have.
        case newNumber([String])
        case longer(output: Double, source: Double)
        case muchShorter(output: Double, source: Double)
        /// Han characters and English words the transcript did not have.
        case newContent(han: Int, words: Int)

        /// The reason in the words of guards.py, for the tests. It may hold digits from the
        /// text, so it is never logged.
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
            case .longer(let output, let source): "longer than source (\(Self.rounded(output)) vs \(Self.rounded(source)))"
            case .muchShorter(let output, let source): "much shorter than source (\(Self.rounded(output)) vs \(Self.rounded(source)))"
            case .newContent(let han, let words): "new content (\(han) Han, \(words) words)"
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
            case .longer: "longer"
            case .muchShorter: "much shorter"
            case .newContent: "new content"
            }
        }

        /// Python's "{:.0f}", which rounds half to even.
        private static func rounded(_ value: Double) -> String {
            String(format: "%.0f", value)
        }
    }

    /// Phrases an assistant opens with when it answers instead of cleaning up. A group trips
    /// only when the output starts with one of its forms and the transcript has none of
    /// them, so a faithful cleanup of "Sure, …" passes.
    static let openers: [[String]] = [
        ["sure", "certainly", "of course", "no problem", "ok", "okay", "alright", "all right", "当然", "好的", "没问题"],
        ["here is", "here's", "here are", "the following", "以下是"],
        ["i'm sorry", "i am sorry", "sorry", "抱歉", "对不起", "很抱歉"],
        ["i can't", "i cannot", "i can not", "i'm unable", "i am unable", "我无法", "我不能"],
        ["hello", "hi", "hey", "你好", "您好", "嗨"],
        ["great question", "好问题"],
        ["as an ai", "as a", "as an", "作为一个", "作为ai", "作为人工智能", "作为一名"],
        ["ahoy", "arr"],
    ]

    /// Transcript words that excuse an opener group, keyed by the group's first form:
    /// hesitation sounds can come out as 嗯 or Okay, and 好啊 as Okay.
    static let excuses: [String: [String]] = [
        "sure": ["嗯", "哦", "呃", "额", "好", "um", "uh", "hmm", "mm"],
        "hello": ["嗯", "um", "uh"],
    ]

    /// Phrases that are suspicious anywhere in the output unless the transcript has one of
    /// the same group.
    static let anywhere: [[String]] = [
        ["as an ai", "作为一个ai", "作为一个人工智能", "作为人工智能"],
        ["language model", "语言模型"],
        ["i'm an ai", "i am an ai", "我是一个ai", "我是一个人工智能", "我是人工智能"],
        ["system prompt", "系统提示"],
        ["my instructions", "我的指令"],
        ["<transcript"], ["</transcript"], ["\"cleaned\""], ["\"translation\""], ["\"transcript\""],
    ]

    static let shortReplies: Set<String> = ["ok", "okay", "yes", "no", "好", "好的", "是", "否", "是的", "不是", "对", "不对", "hello", "你好"]

    /// `shortReplies` as `bare(_:)` leaves them, to compare with a bare output.
    static let bareShortReplies = Set(shortReplies.map(bare))

    /// Nil when the output may be pasted in place of the source.
    static func check(source: String, output: String) -> Failure? {
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Empty is fine only when the source was filler alone.
            return units(source) <= 2 ? nil : .empty
        }
        if let failure = checkOpeners(source: source, output: output) {
            return failure
        }

        // Shouting: the output turned to capitals.
        let upper = count(output, where: { ("A"..."Z").contains($0) })
        let letters = count(output, where: isLatinLetter)
        let sourceLetters = max(count(source, where: isLatinLetter), 1)
        let sourceUpper = count(source, where: { ("A"..."Z").contains($0) })
        if letters >= 10, Double(upper) / Double(letters) > 0.6, Double(sourceUpper) / Double(sourceLetters) < 0.3 {
            return .caseChanged
        }

        if hasForeignScript(output), !hasForeignScript(source) {
            return .foreignScript
        }

        let sourceUnits = units(source)
        let outputUnits = units(output)

        // A bare short reply for a longer source is an answer, not a cleanup.
        let bareOutput = bare(output)
        if bareShortReplies.contains(bareOutput), bareOutput != bare(source), sourceUnits >= 4 {
            return .bareShortReply
        }

        // Structure the source did not have.
        if newlines(output) > newlines(source) + 1 {
            return .addedLines
        }
        if hasMarkup(output), !hasMarkup(source) {
            return .addedMarkup
        }

        // Cleanup may drop a corrected number but never invent one.
        let added = subtract(numbers(output), numbers(source))
        if !added.isEmpty {
            return .newNumber(added.keys.sorted())
        }

        // Cleanup never grows the text and only deletes.
        if outputUnits > sourceUnits * 1.05 + 1.6 {
            return .longer(output: outputUnits, source: sourceUnits)
        }
        if sourceUnits >= 8, outputUnits < sourceUnits * 0.35 {
            return .muchShorter(output: outputUnits, source: sourceUnits)
        }
        let newHan = subtract(counts(han(output)), counts(han(source))).values.reduce(0, +)
        let sourceWords = Set(latinWords(source))
        let newWords = latinWords(output).filter { !sourceWords.contains($0) }.count
        let new = Double(newHan) + 1.6 * Double(newWords)
        if new >= 2, new > 0.1 * max(outputUnits, 1) {
            return .newContent(han: newHan, words: newWords)
        }
        return nil
    }

    // MARK: Openers and phrases

    static func checkOpeners(source: String, output: String) -> Failure? {
        let outputText = normalized(output)
        let head = Array(outputText.unicodeScalars.prefix(24))
        let sourceText = normalized(source)
        for group in openers {
            let hit = group.first { phrase in
                let scalars = Array(phrase.unicodeScalars)
                guard head.starts(with: scalars) else { return false }
                return head.count == scalars.count || !isASCII(phrase) || !head[scalars.count].properties.isAlphabetic
            }
            guard let hit else { continue }
            let allowed = group + (excuses[group[0]] ?? [])
            let excused = allowed.contains { phrase in
                isASCII(phrase) ? containsWord(phrase, in: sourceText) : sourceText.contains(phrase)
            }
            if !excused {
                return .assistantOpener(hit)
            }
        }
        let outputCompact = outputText.replacingOccurrences(of: " ", with: "")
        let sourceCompact = sourceText.replacingOccurrences(of: " ", with: "")
        for group in anywhere {
            let compact = group.map { $0.replacingOccurrences(of: " ", with: "") }
            guard let index = compact.firstIndex(where: { outputCompact.contains($0) }) else { continue }
            if !compact.contains(where: { sourceCompact.contains($0) }) {
                return .assistantPhrase(group[index])
            }
        }
        return nil
    }

    // MARK: Measures

    /// A rough size that compares Chinese and English: one Han character is one unit, an
    /// English word 1.6 units, and each distinct number one unit, as guards.py counts it.
    static func units(_ text: String) -> Double {
        Double(han(text).count) + 1.6 * Double(latinWords(text).count) + Double(numbers(text).count)
    }

    /// The Han characters, in the ranges guards.py uses.
    static func han(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter(isHan)
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
    }

    /// English words in lowercase, without apostrophes at either end.
    static func latinWords(_ text: String) -> [String] {
        text.matches(of: latinWord).map { match in
            String(match.output).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
        }
    }

    /// Every run of digits and how often it occurs. Full width digits count as digits, a
    /// thousands separator joins a number, and a colon or point splits it, so 7:30 is 7 and
    /// 30.
    static func numbers(_ text: String) -> [String: Int] {
        var folded = ""
        for scalar in text.unicodeScalars {
            if (0xFF10...0xFF19).contains(scalar.value) {
                folded.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
            } else {
                folded.unicodeScalars.append(scalar)
            }
        }
        let joined = thousandsSeparator.stringByReplacingMatches(in: folded, range: NSRange(folded.startIndex..., in: folded), withTemplate: "") as NSString
        var result: [String: Int] = [:]
        for match in digitRun.matches(in: joined as String, range: NSRange(location: 0, length: joined.length)) {
            result[joined.substring(with: match.range), default: 0] += 1
        }
        return result
    }

    // MARK: Helpers

    // NSRegularExpression, because the separator pattern needs lookbehind.
    private static let thousandsSeparator = try! NSRegularExpression(pattern: #"(?<=\d),(?=\d{3})"#)
    private static let digitRun = try! NSRegularExpression(pattern: #"\d+"#)

    // Built once rather than on every call.
    nonisolated(unsafe) private static let latinWord = /[A-Za-z][A-Za-z'’]*/
    nonisolated(unsafe) private static let markup = /(^|\n)\s*(```|#{1,3} |[-*•] |\d+[.)] )/
    nonisolated(unsafe) private static let whiteSpace = /\s+/
    nonisolated(unsafe) private static let nonWord = /[\s\W_]+/

    static func count(_ text: String, where predicate: (Unicode.Scalar) -> Bool) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (predicate($1) ? 1 : 0) }
    }

    static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
    }

    private static func isASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(\.isASCII)
    }

    /// Kana, Hangul and Cyrillic, which a cleanup should never produce on its own.
    static func hasForeignScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value) || (0x0400...0x04FF).contains(scalar.value)
        }
    }

    static func newlines(_ text: String) -> Int {
        text.unicodeScalars.filter { $0 == "\n" }.count
    }

    static func hasMarkup(_ text: String) -> Bool {
        text.contains(markup)
    }

    /// Lowercased, runs of white space folded to one space, trimmed.
    static func normalized(_ text: String) -> String {
        text.lowercased().replacing(whiteSpace, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased with white space, punctuation and symbols removed.
    static func bare(_ text: String) -> String {
        text.lowercased().replacing(nonWord, with: "")
    }

    /// Whether an ASCII phrase occurs in the text between word boundaries.
    private static func containsWord(_ phrase: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        guard let regex = try? NSRegularExpression(pattern: "\\b" + escaped + "\\b") else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func counts<T: Hashable>(_ items: [T]) -> [T: Int] {
        items.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// Python's Counter subtraction: what the first has more of, with positive counts only.
    private static func subtract<T: Hashable>(_ left: [T: Int], _ right: [T: Int]) -> [T: Int] {
        left.reduce(into: [:]) { result, entry in
            let difference = entry.value - (right[entry.key] ?? 0)
            if difference > 0 {
                result[entry.key] = difference
            }
        }
    }
}
