import Foundation

/// Cheap checks on the cleanup model's polish of a dictation, so a polish that answered
/// the dictation, carried it out, translated it, lost a number or an English word, or
/// grew is never pasted. What Orra would paste without Polish is pasted instead, see
/// PolishStep.
///
/// It reuses the pieces of RewriteGuard: the assistant openers and phrases, the foreign
/// script, the markup, the added lines and the bare short replies, and TranslationGuard's
/// new numbers, which read a number in words too. A polish rewords and shortens on
/// purpose, so the rest differs from a cleanup's checks, which do not change: no lost
/// number unless a spoken correction removed it, every English word of a text with
/// Chinese kept, the shares of Han characters and English words kept, a question kept a
/// question, never longer than the transcript beyond a margin, and not far shorter than
/// it, with a bound for each style. The bounds come from the measurement described in
/// PolishPrompt, where they held back no polish that was right.
nonisolated enum PolishGuard {
    /// Why a polish was held back. `logName` names the check without any of the text.
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
        /// Numbers that no number of the transcript stands for.
        case newNumber([String])
        /// Digits of the transcript the polish lost, other than ones a spoken correction
        /// took back.
        case lostNumber([String])
        /// English words of a transcript with Chinese that the polish lost, other than
        /// fillers and words a spoken correction took back.
        case lostWords([String])
        /// The polish has Han characters the English transcript did not have, or the share
        /// of Han characters moved: a translation.
        case translated
        /// The transcript asks a question and the polish does not.
        case lostQuestion
        case longer(output: Double, source: Double)
        case muchShorter(output: Double, source: Double)

        /// The reason with its details, for the tests. It may hold digits and words from
        /// the text, so it is never logged.
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
            case .lostNumber(let numbers): "lost number " + numbers.joined(separator: ",")
            case .lostWords(let words): "lost words " + words.joined(separator: ",")
            case .translated: "translated"
            case .lostQuestion: "lost the question"
            case .longer(let output, let source): "longer than source (\(Self.rounded(output)) vs \(Self.rounded(source)))"
            case .muchShorter(let output, let source): "much shorter than source (\(Self.rounded(output)) vs \(Self.rounded(source)))"
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
            case .lostNumber: "lost number"
            case .lostWords: "lost words"
            case .translated: "translated"
            case .lostQuestion: "lost question"
            case .longer: "longer"
            case .muchShorter: "much shorter"
            }
        }

        private static func rounded(_ value: Double) -> String {
            String(format: "%.1f", value)
        }
    }

    /// A polish may be at most this many times as long as its transcript, in
    /// RewriteGuard.units, plus `longerMargin`, for a word that grammar asks for. No polish
    /// of the measurement grew, other than a translation.
    static let longest = 1.0
    static let longerMargin = 2.0

    /// And at least this many times as long, for a transcript of `shortnessFloor` units or
    /// more. Concise keeps only the points, so it may be much shorter than Clear. In the
    /// measurement the shortest Clear polish without a spoken correction was 0.60 of its
    /// transcript, and the shortest Concise one 0.38.
    static func shortest(_ style: PolishStyle) -> Double {
        switch style {
        case .clear: 0.5
        case .concise: 0.25
        }
    }

    static let shortnessFloor = 8.0

    /// The most the share of Han characters may move, see `hanShare`. In the measurement it
    /// moved by 0.25 at most in a polish, as Concise drops Chinese words around English
    /// terms, and by 0.44 in a translation.
    static let largestShareChange = 0.35

    /// RewriteGuard's phrases, and the key of the polish prompt's answer.
    static let anywhere = RewriteGuard.anywhere + [["\"polished\""]]

    /// English fillers, which a polish may drop from a text with Chinese.
    static let englishFillers: Set<String> = [
        "um", "umm", "uh", "uhh", "er", "erm", "hmm", "mm", "like", "so", "well", "ok", "okay",
        "oh", "ah", "yeah", "basically", "actually", "literally", "sorry",
    ]

    /// Words of a spoken self correction. What the transcript says before the last of them
    /// may be gone from the polish, such as 8点 in 明天早上8点，啊不，9点. A 不 counts only
    /// as a clause of its own, also after 啊 or 哦, since it is mostly a plain no. Sorry and
    /// actually do not count: sorry is mostly an apology and actually a filler, and either
    /// would let a polish drop what came before it.
    static let correctionCue = TranslationGuard.regex(#"不对|哦不是|我是说|我的意思是|说错了|(?:^|[，,。])\s*[啊哦噢]?不\s*[，,]|\bi mean\b|scratch that|\bno wait\b|\bmake that\b"#, .caseInsensitive)

    /// Nil when the polish may be pasted in place of the transcript.
    static func check(source: String, output: String, style: PolishStyle) -> Failure? {
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .empty
        }
        switch RewriteGuard.checkOpeners(source: source, output: output, openers: RewriteGuard.openers, excuses: RewriteGuard.excuses, anywhere: anywhere) {
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
        // A polish adds no line breaks.
        if RewriteGuard.newlines(output) > RewriteGuard.newlines(source) {
            return .addedLines
        }
        if RewriteGuard.hasMarkup(output), !RewriteGuard.hasMarkup(source) {
            return .addedMarkup
        }

        // A number of the polish that no number of the transcript stands for, read as
        // TranslationGuard reads them, so 5分钟 for 五分钟 or 2 minutes for two minutes is
        // no new number, and a number of 7 digits or more has to match exactly.
        let added = TranslationGuard.newNumbers(source: source, output: output)
        if !added.isEmpty {
            return .newNumber(added)
        }
        let sourceNumbers = RewriteGuard.numbers(source)
        let outputNumbers = RewriteGuard.numbers(output)

        if isTranslated(source: source, output: output) {
            return .translated
        }
        let correction = lastCorrection(in: folded(source))
        let lostWords = lostTerms(source: source, output: output).filter { !isCorrected($0, in: source, before: correction) }
        if !lostWords.isEmpty {
            return .lostWords(lostWords)
        }
        let lostNumbers = sourceNumbers.keys.filter { outputNumbers[$0] == nil }.filter { !isCorrected($0, in: source, before: correction) }
        if !lostNumbers.isEmpty {
            return .lostNumber(lostNumbers.sorted())
        }
        if asks(source), !asks(output) {
            return .lostQuestion
        }

        if outputUnits > sourceUnits * longest + longerMargin {
            return .longer(output: outputUnits, source: sourceUnits)
        }
        // A spoken correction may take back much of the text, as in "Send it to the whole
        // team, no wait, scratch that, just to the leads", so it gets the bound of Concise.
        let floor = correction == nil ? shortest(style) : min(shortest(style), shortest(.concise))
        if sourceUnits >= shortnessFloor, outputUnits < sourceUnits * floor {
            return .muchShorter(output: outputUnits, source: sourceUnits)
        }
        return nil
    }

    // MARK: Language

    /// Whether the polish is a translation: Han characters the English transcript did not
    /// have, or a share of Han characters that moved by more than `largestShareChange`.
    static func isTranslated(source: String, output: String) -> Bool {
        guard let sourceShare = hanShare(source), sourceShare > 0 else {
            return !RewriteGuard.han(output).isEmpty
        }
        guard let outputShare = hanShare(output) else { return false }
        return abs(outputShare - sourceShare) > largestShareChange
    }

    /// The share of Han characters in a text, against Han characters and English words
    /// weighed as in RewriteGuard.units, nil without either.
    static func hanShare(_ text: String) -> Double? {
        let han = Double(RewriteGuard.han(text).count)
        let words = 1.6 * Double(RewriteGuard.latinWords(text).count)
        return han + words > 0 ? han / (han + words) : nil
    }

    /// The English words of two letters or more of a transcript with Chinese that the
    /// polish does not have, lowercased, in order and once each. Fillers such as um, like
    /// and you know may go. A word counts as kept when the polish holds it in any case,
    /// also inside a longer word, such as issue in issues.
    static func lostTerms(source: String, output: String) -> [String] {
        guard !RewriteGuard.han(source).isEmpty else { return [] }
        let withoutFillers = source.replacing(youKnow, with: " ")
        let kept = output.lowercased()
        var lost: [String] = []
        for word in RewriteGuard.latinWords(withoutFillers) where word.count >= 2 && !englishFillers.contains(word) && !lost.contains(word) {
            if !kept.contains(word) {
                lost.append(word)
            }
        }
        return lost
    }

    // MARK: Corrections

    /// The text with ASCII digits and without thousands separators, as RewriteGuard.numbers
    /// reads it, so a number's place in it can be found.
    static func folded(_ text: String) -> String {
        var ascii = ""
        for scalar in text.unicodeScalars {
            if (0xFF10...0xFF19).contains(scalar.value), let digit = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) {
                ascii.unicodeScalars.append(digit)
            } else {
                ascii.unicodeScalars.append(scalar)
            }
        }
        return thousandsSeparator.stringByReplacingMatches(in: ascii, range: NSRange(location: 0, length: (ascii as NSString).length), withTemplate: "")
    }

    /// Where the last correction cue of a folded text starts, in UTF-16 offsets, nil
    /// without one.
    static func lastCorrection(in folded: String) -> Int? {
        correctionCue.matches(in: folded, range: NSRange(location: 0, length: (folded as NSString).length)).last?.range.location
    }

    /// Whether a lost number or word first occurs before the last correction cue of the
    /// transcript, so the correction may have taken it back.
    static func isCorrected(_ item: String, in source: String, before correction: Int?) -> Bool {
        guard let correction else { return false }
        let text = folded(source) as NSString
        let found = text.range(of: item, options: .caseInsensitive)
        return found.location != NSNotFound && found.location < correction
    }

    // MARK: Helpers

    /// Whether a text asks: it has a question mark.
    static func asks(_ text: String) -> Bool {
        text.contains("?") || text.contains("？")
    }

    private static let thousandsSeparator = try! NSRegularExpression(pattern: #"(?<=\d),(?=\d{3})"#)
    nonisolated(unsafe) private static let youKnow = /(?i)\byou know\b/
}
