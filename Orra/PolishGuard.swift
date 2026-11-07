import Foundation

/// Cheap checks on the cleanup model's polish of a dictation, so a polish that answered
/// the dictation, carried it out, translated it, lost a number, an English or Chinese
/// word, who acts, a request or a limit, or grew is never pasted. What Orra would paste
/// without Polish is pasted instead, see PolishStep.
///
/// It reuses the pieces of RewriteGuard: the assistant openers and phrases, the foreign
/// script, the markup, the added lines and the bare short replies, and TranslationGuard's
/// new numbers, which read a number in words too. A polish rewords and shortens on
/// purpose, so the rest differs from a cleanup's checks, which do not change: no lost
/// number unless a spoken correction removed it, every English word of a text with
/// Chinese and every Chinese word of an English sentence kept, the shares of Han
/// characters and English words kept, a report of what the speaker did never turned into
/// an order, a request to rewrite text or to look at something and a limit such as 至少
/// or at most kept, a question kept a question, never longer than the transcript beyond a
/// margin, and not far shorter than it, with a bound for each style. The checks are cheap
/// and read words, not meaning, so a polish can still change what was meant in ways they
/// do not see, which is why Paste Original Text brings back the text from before the
/// model.
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
        /// Chinese words of a transcript that is mostly English that the polish lost or
        /// translated.
        case lostChinese([String])
        /// Who acts or is asked changed: a report of what the speaker did turned into an
        /// order, or I need you to into I need to.
        case lostPerson([String])
        /// A request to rewrite text, such as 总结 or TL;DR this, that the polish lost, as
        /// one that carried it out does, or a request to look at something, as 你看一下.
        case lostRequest([String])
        /// A limit such as 至少, 最多 or at least that the polish lost.
        case lostLimit([String])
        /// The polish says something is done where the transcript says it will be, as 我会提前
        /// 安排好的 written as 已提前安排.
        case changedTime
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
            case .lostChinese(let words): "lost Chinese " + words.joined(separator: ",")
            case .lostPerson(let words): "lost person " + words.joined(separator: ",")
            case .lostRequest(let words): "lost request " + words.joined(separator: ",")
            case .lostLimit(let words): "lost limit " + words.joined(separator: ",")
            case .changedTime: "changed the time"
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
            case .lostChinese: "lost Chinese"
            case .lostPerson: "lost person"
            case .lostRequest: "lost request"
            case .lostLimit: "lost limit"
            case .changedTime: "changed time"
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
    /// transcript, and the shortest Concise one 0.36.
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
        let lostHan = lostChinese(source: source, output: output)
        if !lostHan.isEmpty {
            return .lostChinese(lostHan)
        }
        // What a spoken correction took back may go, so the rest of the transcript counts.
        let kept = correction.map { (folded(source) as NSString).substring(from: $0) } ?? source
        let requests = lostRequests(source: kept, output: output)
        if !requests.isEmpty {
            return .lostRequest(requests)
        }
        let limits = lostLimits(source: kept, output: output)
        if !limits.isEmpty {
            return .lostLimit(limits)
        }
        let persons = lostPersons(source: kept, output: output)
        if !persons.isEmpty {
            return .lostPerson(persons)
        }
        if saysDone(output), !saysDone(kept), TranslationGuard.matches(future, kept) {
            return .changedTime
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

    /// Below this share of Han characters, see `hanShare`, a transcript is English with
    /// some Chinese words, and every Chinese word stays. Above it the polish rewords the
    /// Chinese, and `lostTerms` keeps its English words.
    static let englishSentenceShare = 0.5

    /// The runs of Han characters of a transcript that is mostly English that the polish
    /// does not have, other than fillers, in order and once each: 改到 of "Can we 改到
    /// Thursday?" written as reschedule, or 帮我 of "Please 帮我 check the logs" left out.
    static func lostChinese(source: String, output: String) -> [String] {
        guard let share = hanShare(source), share > 0, share < englishSentenceShare else { return [] }
        var lost: [String] = []
        for run in TranslationGuard.all(TranslationGuard.hanRun, in: source) where !TranslationGuard.matches(chineseFillers, run) && !lost.contains(run) {
            if !TranslationGuard.contains(output, run) {
                lost.append(run)
            }
        }
        return lost
    }

    // MARK: Persons, requests and limits

    /// The start of a clause: the start of the text or a mark that ends a clause.
    private static let clauseStart = #"(?:^|[，,。.；;：:！!？?、]\s*)"#

    /// A report of what the speaker told someone, which a polish keeps a report.
    private static let reportedEnglish = TranslationGuard.regex(#"\bI (told|asked|reminded|warned|promised|let) (him|her|them|you|us)\b"#, .caseInsensitive)
    private static let presentForms = ["told": "tell", "asked": "ask", "reminded": "remind", "warned": "warn", "promised": "promise", "let": "let"]
    /// 我告诉他, 我跟他说, 他说, 她答应: who said or promised, with what follows the verb when
    /// it names who was told.
    private static let reportedChinese = TranslationGuard.regex("([我他她])(?:已经|刚才|刚|也|都|就|还)?((?:告诉|让|叫|提醒|通知|问)(?:他|她|你)们?|(?:跟|和)(?:他|她)们?|说|讲|答应|保证)")
    /// What the speaker is doing: 我在写, 我正在改.
    private static let underWay = TranslationGuard.regex("我(?:在|正在)([\u{3400}-\u{9FFF}])")
    /// A request to the listener and the speaker's own need it must not become.
    private static let needYouEnglish = TranslationGuard.regex(#"\bI (?:need|want|would like|['’]d like) you to\b"#, .caseInsensitive)
    private static let needEnglish = TranslationGuard.regex(#"\bI (?:need|want|would like|['’]d like) to\b"#, .caseInsensitive)
    private static let needYouChinese = TranslationGuard.regex("我(?:需要|想让|要)你")
    private static let needChinese = TranslationGuard.regex("我(?:需要|想让|要)(?![你您])")
    private static let you = TranslationGuard.regex(#"\byou\b|[你您]"#, .caseInsensitive)

    /// Who acts or is asked, where the polish changed it: a report of what the speaker did
    /// or does turned into an order to the listener, as I told him written as Tell him, 我告
    /// 诉他 as 告诉他 or 我在写 as 写, who said or promised something left out, as 他说下个月还
    /// 我 written as 说下个月还, a request to the listener turned into the speaker's own need,
    /// as I need you to written as I need to, and a long dictation without its speaker.
    /// Reads these patterns, not the meaning. A short note that leaves out 我 or 你 and stays
    /// clear, as 你帮我看看 written as 帮我看看, keeps who does what and passes.
    static func lostPersons(source: String, output: String) -> [String] {
        var lost: [String] = []
        let said = source.replacingOccurrences(of: "’", with: "'")
        let written = output.replacingOccurrences(of: "’", with: "'")
        let ns = said as NSString
        for match in reportedEnglish.matches(in: said, range: NSRange(location: 0, length: ns.length)) {
            let verb = presentForms[ns.substring(with: match.range(at: 1)).lowercased()] ?? ""
            let object = ns.substring(with: match.range(at: 2))
            if TranslationGuard.matches(TranslationGuard.regex(clauseStart + verb + " " + object + #"\b"#, .caseInsensitive), written) {
                lost.append("I")
                break
            }
        }
        for match in reportedChinese.matches(in: said, range: NSRange(location: 0, length: ns.length)) {
            let who = ns.substring(with: match.range(at: 1))
            let told = ns.substring(with: match.range(at: 2))
            if TranslationGuard.matches(TranslationGuard.regex(clauseStart + NSRegularExpression.escapedPattern(for: told)), written), !TranslationGuard.contains(written, who + told), !lost.contains(who) {
                lost.append(who)
            }
        }
        if !lost.contains("我") {
            for match in underWay.matches(in: said, range: NSRange(location: 0, length: ns.length)) {
                let verb = NSRegularExpression.escapedPattern(for: ns.substring(with: match.range(at: 1)))
                if TranslationGuard.matches(TranslationGuard.regex(clauseStart + verb), written), !TranslationGuard.matches(TranslationGuard.regex("[我在]" + verb), written) {
                    lost.append("我")
                    break
                }
            }
        }
        let needs = (TranslationGuard.matches(needYouEnglish, said) && TranslationGuard.matches(needEnglish, written))
            || (TranslationGuard.matches(needYouChinese, said) && TranslationGuard.matches(needChinese, written))
        if needs, !TranslationGuard.matches(you, written) {
            lost.append("you")
        }
        // A long dictation, a notice or a report, names several people, so what the speaker
        // will not, cannot, will or must do keeps its speaker, as 周四我不在公司 written as 周
        // 四不在公司 does not. Phrases that only lead in or hedge do not count.
        if source.count > longTranscript {
            let speaker = TranslationGuard.replacing(personFillers, in: said) { _ in " " }
            let polished = TranslationGuard.replacing(personFillers, in: written) { _ in " " }
            for (name, pattern) in [("我", speakerChinese), ("I", speakerEnglish)] where !lost.contains(name) {
                if TranslationGuard.matches(pattern, speaker), !TranslationGuard.matches(pattern, polished) {
                    lost.append(name)
                }
            }
        }
        return lost
    }

    /// Longer than this many characters, a transcript is a long dictation for
    /// `lostPersons`. The rambling dictations of the measurement are shorter, and its long
    /// ones and the notices of the review longer.
    static let longTranscript = 200

    /// The speaker with what they will not, cannot, will or must do: 我不, 我没, 我会, 我要, 我
    /// 在, 我得, 我能, also after 也, 都, 还 or 就, and I will, I'll, I won't, I can't, I need,
    /// I want, I have to and I'd like.
    private static let speakerChinese = TranslationGuard.regex("我(?:也|都|还|就)?(?:不|没|会|要|在|得|能)")
    private static let speakerEnglish = TranslationGuard.regex(#"\bi(?:['’]ll| will| won['’]t| can['’]t| cannot| don['’]t| didn['’]t| do not| am not|['’]m not| need| want| have to|['’]d like| would like)\b"#, .caseInsensitive)

    /// Phrases whose 我 or I only leads in or hedges, which a polish may leave out with
    /// them: 我觉得, 我建议, 我跟大家说一下, 我的意思是, I think, I wanted to mention. 我跟他说了
    /// and I told her are no such phrases.
    static let personFillers = TranslationGuard.regex(#"我觉得|我认为|我感觉|我估计|我猜|我建议|我的意思是|我是说|我(?:先|来|再)?(?:想)?(?:(?:跟|和)(?:你|您|大家))?(?:说|讲|同步|汇报|交代)(?:一下)?(?![了过])|\bi (?:think|guess|mean|suppose|believe|feel like|would say|was thinking|(?:just )?wanted to (?:say|mention|flag|ask|tell you|let you know|give you))\b"#, .caseInsensitive)

    /// Words that ask for a text to be rewritten. A polish keeps them, as it keeps the text
    /// after them: one that leaves out 用一句话总结一下 and pastes the summary carried the
    /// request out. "TL;DR this" stays with its this, since "TL;DR:" reads as a summary.
    static let requestWords = TranslationGuard.regex(#"总结|概括|归纳|提炼|改写|重写|翻译|润色|缩写|精简|缩短|扩写|续写|摘要|\b(?:summari[sz]e|shorten|rewrite|rephrase|paraphrase|translate|condense|proofread|tl;?dr)\b(?: this\b)?"#, .caseInsensitive)

    /// Asking the listener to look at something, check it or try it: 你看一下, 你先查一下,
    /// 你帮我确认一下. A polish keeps the verb, with or without 你, so the request stays. In 跟
    /// 你确认一下 the speaker checks, so it does not count.
    private static let askedToLook = TranslationGuard.regex("(?<![跟和给向对])[你您](?:先|再|就)?(?:帮我|帮忙)?(看|查|试|确认|检查)(?:一下|一遍|看|查|试|下)")

    /// The request words of the transcript the polish does not have, lowercased, in order
    /// and once each, and the verb of a request to look at, check or try something the
    /// polish lost.
    static func lostRequests(source: String, output: String) -> [String] {
        let written = output.lowercased()
        var lost: [String] = []
        for word in TranslationGuard.all(requestWords, in: source.lowercased()) where !lost.contains(word) && !TranslationGuard.contains(written, word) {
            lost.append(word)
        }
        let ns = source as NSString
        for match in askedToLook.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let verb = ns.substring(with: match.range(at: 1))
            if !lost.contains(verb), !TranslationGuard.contains(output, verb) {
                lost.append(verb)
            }
        }
        return lost
    }

    /// Limits, each a group of words that say it, so a polish may write 最多 for 不超过 but
    /// may not leave the limit out, as 需要至少再等五天 written as 需再等五天 does. 不超过 and
    /// no more than say at most, not more than.
    static let limits: [(name: String, pattern: NSRegularExpression)] = [
        ("at least", TranslationGuard.regex(#"至少|最少|起码|不少于|不低于|\bat least\b|\bno (?:less|fewer) than\b|\bnot (?:less|fewer) than\b|\bminimum\b"#, .caseInsensitive)),
        ("at most", TranslationGuard.regex(#"最多|至多|顶多|不超过|不高于|\bat most\b|\bno more than\b|\bnot more than\b|\bup to\b|\bmaximum\b"#, .caseInsensitive)),
        ("more than", TranslationGuard.regex(#"以上|(?<!不)多于|(?<!不)超过|(?<!\bno )(?<!\bnot )\bmore than\b"#, .caseInsensitive)),
        ("less than", TranslationGuard.regex(#"以下|以内|(?<!不)少于|不到|(?<!\bno )(?<!\bnot )\b(?:less|fewer) than\b|\bwithin\b"#, .caseInsensitive)),
    ]

    /// The limits of the transcript the polish does not say, in the order of `limits`.
    static func lostLimits(source: String, output: String) -> [String] {
        limits.filter { TranslationGuard.matches($0.pattern, source) && !TranslationGuard.matches($0.pattern, output) }.map(\.name)
    }

    /// Words that say something is done.
    private static let done = TranslationGuard.regex(#"已|\balready\b"#, .caseInsensitive)
    /// Words that say something will be done. 会 of 开会, 会议 and 会员 is a meeting or a
    /// member, not the future.
    static let future = TranslationGuard.regex(#"(?<![开聚晚例年周早大宴约班])会(?![议员场计所长面谈话儿])|将要|\bwill\b|['’]ll\b|\bgoing to\b"#, .caseInsensitive)

    static func saysDone(_ text: String) -> Bool {
        TranslationGuard.matches(done, text)
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

    /// A run of Han characters that is only fillers, which an English sentence may lose.
    private static let chineseFillers = TranslationGuard.regex("^(?:嗯|啊|呃|额|哦|噢|唉|诶|哎|那个|这个|就是|然后|吧|呢|啦|嘛|呀|哈)+$")
    private static let thousandsSeparator = try! NSRegularExpression(pattern: #"(?<=\d),(?=\d{3})"#)
    nonisolated(unsafe) private static let youKnow = /(?i)\byou know\b/
}
