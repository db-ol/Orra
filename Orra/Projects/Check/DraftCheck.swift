import Foundation
import NaturalLanguage

/// The plain values a draft is checked with.
nonisolated struct DraftCheckInput: Sendable, Equatable, Codable {
    typealias Person = SenderChecks.Person

    /// The draft the model wrote.
    var draft: String
    /// The language the reply rule chose. A draft in another language is held back, and
    /// with `other` every draft is, since Orra drafts only in Chinese and English.
    var language: ProjectsLanguage
    /// The people the reply goes to. With none, the reply counts as going outside the
    /// project, so a reply whose recipient did not parse carries no project data.
    var recipients: [Person]
    /// The people the user listed for the email's project. With none, every recipient is
    /// outside the project.
    var projectPeople: [Person]
    /// The user's own names and addresses, which a draft may always hold.
    var own: [Person] = []
    /// What the recipients already have: the email, and the earlier messages of its thread
    /// they were on.
    var incomingText: String
    /// The other texts the model read: the excerpts of project files and the project's
    /// other mail.
    var sourceTexts: [String] = []
    /// The questions the window lists for the user to decide.
    var questionsForUser: [String] = []
    var today: Date
}

/// Checks a draft after the model and before the user sees it (code step 5 of the phase 0
/// report).
///
/// It removes, each with a placeholder in the reply's language:
/// - links, Markdown and HTML image and link syntax, and web addresses
/// - sentences that claim an action, such as "already forwarded", 已转发 or "I have moved
///   or sent", since Orra sends, forwards and moves nothing
/// - sentences that speak as an assistant or name Orra
/// - project data when the reply goes to someone outside the project's people: amounts in
///   digits or in Chinese words, scores, codes such as booking, ID and account numbers,
///   years that are not this year or the next or last, and the names and addresses of other
///   people, unless the incoming mail already holds them
///
/// It reads full width letters and digits as plain ones, and names with any spaces in
/// them. Names of the project's people are always caught, in Chinese and in pinyin. Other
/// names come from the source texts: Chinese ones by the rules of `ScreenNames`, Latin ones
/// from the natural language tagger, so some may be missed.
///
/// It flags what OutputChecks finds, and fewer "to confirm" placeholders than questions
/// for the user, which means the draft may decide one only the user can. It holds the draft
/// back when its language, read with `ProjectsLanguage.reading(_:)`, differs from the
/// reply rule's. In phase 0 the best setting failed 13 or 14 of the 64 attack items, most
/// of them by giving project data to someone outside the project, which this check is
/// meant to stop.
nonisolated enum DraftCheck {
    /// A part of the draft the check took out, so the window can show what was removed.
    nonisolated struct Removal: Sendable, Equatable, Codable {
        nonisolated enum Kind: String, Sendable, Codable {
            case link
            case actionClaim
            case assistantVoice
            case projectData
        }

        var kind: Kind
        /// The text taken out.
        var text: String
    }

    nonisolated enum Flag: Sendable, Equatable, Codable {
        /// What OutputChecks found in the checked draft.
        case output(OutputChecks.Finding)
        /// Fewer "to confirm" placeholders than questions for the user.
        case decidesQuestion(placeholders: Int, questions: Int)
    }

    nonisolated struct Result: Sendable, Equatable, Codable {
        /// The checked draft, with each removal replaced by a placeholder, or nil when the
        /// draft is held back for its language.
        var draft: String?
        /// The language the draft reads as, without its links.
        var language: ProjectsLanguage
        var removals: [Removal] = []
        var flags: [Flag] = []
        /// The recipients who are not among the project's people, lowercased. No project
        /// data goes to them.
        var outsideRecipients: [String] = []
    }

    /// Checks the draft. Off the main actor, since finding names in the sources runs the
    /// natural language tagger.
    @concurrent
    static func check(_ input: DraftCheckInput) async -> Result {
        let original = SortingText.withoutFormatCharacters(input.draft)
        let style: ProjectsLanguage = input.language == .zh ? .zh : .en
        var removals: [Removal] = []

        let links = linkRanges(in: original)
        removals += links.map { Removal(kind: .link, text: String(original[$0])) }
        let language = ProjectsLanguage.reading(replacing(links.map { ($0, " ") }, in: original))
        var draft = replacing(links.map { ($0, placeholder(.link, style)) }, in: original)

        var sentences: [(Range<String.Index>, String)] = []
        for range in sentenceRanges(in: draft) {
            let form = SortingText.matchingForm(String(draft[range]))
            let kind: Removal.Kind
            if ContentChecks.matches(assistantVoice, form) {
                kind = .assistantVoice
            } else if claimsAction(form) {
                kind = .actionClaim
            } else {
                continue
            }
            removals.append(Removal(kind: kind, text: String(draft[range])))
            sentences.append((range, placeholder(kind, style)))
        }
        draft = replacing(sentences, in: draft)

        let outside = outsideRecipients(input)
        if !outside.isEmpty || input.recipients.isEmpty {
            let data = projectData(in: draft, input: input)
            removals += data.map { Removal(kind: .projectData, text: String(draft[$0])) }
            draft = replacing(data.map { ($0, placeholder(.projectData, style)) }, in: draft)
        }

        var flags = OutputChecks.findings(in: draft, sources: [input.incomingText] + input.sourceTexts, today: input.today)
            .map(Flag.output)
        let placeholders = confirmPlaceholder.numberOfMatches(in: draft, range: NSRange(draft.startIndex..., in: draft))
        if placeholders < input.questionsForUser.count {
            flags.append(.decidesQuestion(placeholders: placeholders, questions: input.questionsForUser.count))
        }
        let kept = input.language != .other && language == input.language
        return Result(draft: kept ? draft : nil, language: language, removals: removals, flags: flags, outsideRecipients: outside)
    }

    // MARK: Placeholders

    private static func placeholder(_ kind: Removal.Kind, _ language: ProjectsLanguage) -> String {
        switch kind {
        case .link: language == .zh ? "[已删去链接]" : "[link removed]"
        case .actionClaim: language == .zh ? "[已删去一句：声称已经办了某事]" : "[sentence removed: it claims an action]"
        case .assistantVoice: language == .zh ? "[已删去一句：以助手的口吻]" : "[sentence removed: it speaks as an assistant]"
        case .projectData: language == .zh ? "[已删去项目资料]" : "[project data removed]"
        }
    }

    /// A placeholder for what only the user can decide, as the explanation prompt asks
    /// for: [待确认：…] or [to confirm: …], and 待定, TBC and TBD in brackets. The total the
    /// prompt leaves to the user, [待确认：合计] or [to confirm: total], is no question.
    private static let confirmPlaceholder = try! NSRegularExpression(
        pattern: #"[\[［【]\s*(?:待确认|待確認|待定|to confirm|tbc|tbd)(?!\s*[:：]\s*(?:合计|total)\s*[\]］】])"#,
        options: .caseInsensitive
    )

    // MARK: Links

    /// Where the draft holds a link: what `ContentChecks.linkRanges(in:)` finds, and any
    /// other dotted host, such as harbor-pay.zone, unless it ends in a file extension, as
    /// plan_v3.pdf and build.js do. Read in compatibility form, so a host in full width
    /// letters counts too.
    private static func linkRanges(in text: String) -> [Range<String.Index>] {
        let folded = Folded(text)
        var found = ContentChecks.linkRanges(in: folded.text)
        for match in bareHost.matches(in: folded.text, range: NSRange(folded.text.startIndex..., in: folded.text)) {
            guard let range = Range(match.range, in: folded.text), let last = Range(match.range(at: 1), in: folded.text),
                  !fileExtensions.contains(folded.text[last].lowercased()) else { continue }
            found.append(range)
        }
        return ContentChecks.merged(found.compactMap(folded.original))
    }

    private static let bareHost = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_@.-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+([A-Za-z]{2,24})(?![A-Za-z0-9_@-])"#
    )

    private static let fileExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "xlsm", "ppt", "pptx", "key", "pages", "numbers", "txt", "rtf", "md", "csv",
        "json", "xml", "html", "htm", "jpg", "jpeg", "png", "gif", "heic", "webp", "tif", "tiff", "bmp", "svg", "psd", "ai",
        "eps", "indd", "sketch", "fig", "dwg", "dxf", "skp", "rvt", "zip", "rar", "gz", "tar", "mp3", "mp4", "m4a", "mov",
        "wav", "avi", "ics", "vcf", "eml", "msg", "log", "js", "ts", "py", "swift", "cc", "cpp", "java", "app",
    ]

    // MARK: Sentences

    /// The sentences of the text: up to 。！？!?… or a full stop before a space, with the
    /// closing quotes and brackets after them, or up to the end of the line. White space
    /// between sentences belongs to none.
    private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        func close(at end: String.Index) {
            guard let begin = start else { return }
            var last = end
            while last > begin, text[text.index(before: last)].isWhitespace {
                last = text.index(before: last)
            }
            if begin < last {
                ranges.append(begin..<last)
            }
            start = nil
        }
        while index < text.endIndex {
            let character = text[index]
            var next = text.index(after: index)
            if character.isNewline {
                close(at: index)
            } else if start == nil, character.isWhitespace {
                // Between sentences.
            } else {
                if start == nil {
                    start = index
                }
                let fullStop = character == "." && (next == text.endIndex || text[next].isWhitespace)
                if sentenceEnds.contains(character) || fullStop {
                    while next < text.endIndex, sentenceEnds.contains(text[next]) || closers.contains(text[next]) {
                        next = text.index(after: next)
                    }
                    close(at: next)
                }
            }
            index = next
        }
        close(at: text.endIndex)
        return ranges
    }

    private static let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?", "…"]
    private static let closers: Set<Character> = ["”", "’", "\"", "'", ")", "）", "」", "』", "]", "】"]

    /// A sentence that speaks as an assistant, or names Orra. Not a job title, as in
    /// 我是王总的助理, and not a draft of a contract, as in "here is the draft agreement".
    private static let assistantVoice = ContentChecks.patterns([
        #"(?<![a-z])orra(?![a-z])"#,
        #"\bas (?:an? )?(?:ai|a\.i\.|artificial intelligence|(?:ai |virtual |digital |email )?assistant|language model|chatbot|bot)\b"#,
        #"\b(?:i am|i'm|i’m|this is) (?:an? )?(?:ai|a\.i\.|(?:ai |virtual |digital |email )?assistant|language model|chatbot|bot|automated)\b"#,
        #"\b(?:ai|virtual|digital|email) assistant\b|\blanguage model\b"#,
        #"\b(?:automated|automatic|auto-generated|ai-generated|machine-generated) (?:reply|response|message|email|draft)\b"#,
        #"\b(?:generated|drafted|written|composed) (?:by|with|using) (?:an? )?(?:ai|assistant|model|software|tool)\b"#,
        #"\bhere(?:'s|’s| is) (?:a|the|your|my) (?:draft|suggested|possible|proposed) (?:reply|response|answer|email)\b"#,
        #"^(?:(?:sure|certainly|of course|okay|ok)[,!.]? )?(?:here|below)\b[^.!?:]{0,30}\b(?:draft|reply|response|answer)\b[^.!?:]{0,20}:$"#,
        #"(?:我是|作为|身为)[^。!?]{0,12}(?:ai|人工智能|语言模型|大模型|机器人|(?:智能|虚拟|邮件|写作)(?:助手|助理))"#,
        #"ai ?(?:助手|助理)|语言模型"#,
        #"自动(?:生成|回复|撰写|起草)"#,
        #"(?:以下|下面)是[^。!?]{0,8}(?:回复|回信|邮件)的?草稿|(?:回复|回信|邮件)草稿如下|^(?:以下|下面)是(?:草稿|回复|回信):?$"#,
    ])

    /// Whether a sentence, in its matching form, says that the writer forwarded, sent,
    /// moved, deleted, filed, shared or paid something, or is doing so now. A question
    /// claims nothing, and neither does a sentence about what the recipient or someone else
    /// did.
    private static func claimsAction(_ sentence: String) -> Bool {
        guard !sentence.hasSuffix("?") else { return false }
        if ContentChecks.matches(actionClaims, sentence) {
            return true
        }
        return ContentChecks.matches(actionsWithoutActor, sentence) && !ContentChecks.matches([otherActor], sentence)
    }

    /// Actions with the writer as the actor. The 已 forms skip the recipient or another
    /// person as the actor, as in 您已发送的文件 and 如已支付. The 将 and 把 forms need 了 or
    /// 过 at the end of a clause, so 发给您过目 and 发给您了解 are plans.
    private static let actionClaims = ContentChecks.patterns([
        #"(?<!您|你|贵司|贵方|对方|他|她|如|若|如果|若是)(?:已经|已)(?:为您|为你|帮您|帮你|替您|替你|给您|给你|向您|向你)?(?:转发|转交|转给|转到|发送|发出|发给|发过去|发到|寄出|寄给|寄到|删除|删掉|归档|移动|移到|移至|挪到|标记|抄送|付款|付清|转账|汇款|打款|支付|上传|分享|提交)"#,
        #"(?<!您|你|贵司|贵方|对方|他|她|如|若|如果|若是)(?:已经|已)(?:将|把)[^。!?]{0,30}(?:转发|转交|转给|发送|发给|寄给|删除|归档|移到|移至|移动到|挪到|抄送|上传|分享)"#,
        #"(?<!请|麻烦|会|可以|能否|可否|要|需要|想)(?:将|把)[^。!?]{0,30}(?:转发|转交|转给|发送|发给|寄给|删除|归档|移到|移至|移动到|挪到|抄送|上传|分享)[^。!?,]{0,20}?(?:了|过)(?=$|[\s。!?,;:…]|吧|啊|哦)"#,
        #"\b(?:i|we)(?:(?:'ve|’ve| have| had)(?: already| just| now| also)?| already| just) (?:forwarded|sent|moved|deleted|archived|filed|shared|uploaded|paid|transferred|wired|cc'?d)\b"#,
        #"\b(?:i|we)(?:'m|’m|'re|’re| am| are) (?:now )?(?:forwarding|sending|moving|deleting|archiving|sharing|transferring)\b"#,
    ])

    /// Actions that name no actor, which count unless `otherActor` names one.
    private static let actionsWithoutActor = ContentChecks.patterns([
        #"\bgone ahead and (?:forwarded|sent|moved|deleted|archived|filed|shared|uploaded|paid|transferred)\b"#,
        #"\b(?:has|have|had) (?:already |now |just )?been (?:forwarded|sent|moved|deleted|archived|filed|shared|uploaded|paid|transferred|wired|passed on)\b"#,
        #"\balready (?:been )?(?:forwarded|sent|moved|deleted|archived|shared|uploaded|paid|transferred)\b"#,
    ])

    /// The recipient or a third person as the one who acted, as in "I see you already sent
    /// it" or "the files have been sent to the printer by your team".
    private static let otherActor = try! NSRegularExpression(pattern: #"\b(?:you|your|they|he|she)\b|\bby (?!me\b|us\b|myself\b|ourselves\b)"#)

    // MARK: Project data

    /// The recipients who are not among the project's people or the user's own addresses,
    /// lowercased, in their order. A recipient whose address does not parse counts as outside.
    private static func outsideRecipients(_ input: DraftCheckInput) -> [String] {
        let inside = Set((input.projectPeople + input.own).compactMap { ProjectsAddress.normalized($0.address) })
        var outside: [String] = []
        for recipient in input.recipients {
            let address = ProjectsAddress.normalized(recipient.address)
                ?? recipient.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !inside.contains(address), !outside.contains(address) {
                outside.append(address)
            }
        }
        return outside
    }

    /// Where the draft holds project data that the incoming mail does not: amounts and
    /// scores, years other than this one and the next and last, codes, and the names and
    /// addresses of people other than the recipients and the user. Overlapping finds are
    /// merged.
    private static func projectData(in draft: String, input: DraftCheckInput) -> [Range<String.Index>] {
        let folded = Folded(draft)
        let text = folded.text
        let incoming = input.incomingText.precomposedStringWithCompatibilityMapping
        let incomingValues = Set(
            OutputChecks.numbers(in: incoming, skippingDatesAndCodes: false).map(\.value)
                + OutputChecks.numbers(in: NumberRules.writingNumbersAsDigits(in: incoming), skippingDatesAndCodes: false).map(\.value)
        )
        let incomingCodes = Set(OutputChecks.codes(in: incoming).map { OutputChecks.codeValue(incoming[$0]) })
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: input.today)
        var found: [Range<String.Index>] = []
        for code in OutputChecks.codes(in: text) where !incomingCodes.contains(OutputChecks.codeValue(text[code])) {
            found.append(code)
        }
        for number in OutputChecks.numbers(in: text) where !incomingValues.contains(number.value) {
            let year = number.value.count == 4 ? Int(number.value).flatMap { (1900...2099).contains($0) ? $0 : nil } : nil
            if number.isAmount || number.isScore || year.map({ abs($0 - thisYear) > 1 }) == true {
                found.append(number.range)
            }
        }
        for match in chineseAmount.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let values = OutputChecks.numbers(in: NumberRules.writingNumbersAsDigits(in: String(text[range]))).filter(\.isAmount).map(\.value)
            if values.contains(where: { !incomingValues.contains($0) }) {
                found.append(range)
            }
        }
        for patterns in protectedNames(input) where !patterns.contains(where: { $0.firstMatch(in: incoming, range: NSRange(incoming.startIndex..., in: incoming)) != nil }) {
            for pattern in patterns {
                found += pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
            }
        }
        let incomingLower = incoming.lowercased()
        for address in protectedAddresses(input) where !incomingLower.contains(address) {
            found += SenderChecks.occurrences(of: address, in: text)
        }
        return ContentChecks.merged(found.compactMap(folded.original))
    }

    /// An amount in Chinese words, as 五万八千六百元 or 三点五万元. `NumberRules` reads it.
    private static let chineseAmount = try! NSRegularExpression(
        pattern: #"[零〇一二两三四五六七八九十百千万亿点]+(?:元|块|圆|美元|港元|港币|欧元|英镑|日元|人民币)"#
    )

    /// The addresses of the project's people other than the recipients and the user,
    /// lowercased.
    private static func protectedAddresses(_ input: DraftCheckInput) -> Set<String> {
        let allowed = Set((input.recipients + input.own).compactMap { ProjectsAddress.normalized($0.address) })
        return Set(input.projectPeople.compactMap { ProjectsAddress.normalized($0.address) }).subtracting(allowed)
    }

    // MARK: Names

    /// The names of the project's people and the personal names in the sources, without
    /// the recipients and the user, each as the patterns of the ways it may be written. A
    /// name needs two Chinese characters or two words, so a lone given name never counts.
    /// A Chinese name is also found in pinyin with the surname first or last, and a two word
    /// Latin name in reverse.
    private static func protectedNames(_ input: DraftCheckInput) -> [[NSRegularExpression]] {
        /// The letters of a form, which compares 宋雨桐's pinyin with Song Yutong.
        func spelling(_ form: String) -> String {
            form.filter { $0.isLetter || $0.isNumber }
        }
        func spellings(_ forms: [String]) -> [String] {
            forms.map(spelling) + forms.flatMap(pinyinForms).map { spelling($0.joined()) }
        }
        let allowed = Set(spellings((input.recipients + input.own).flatMap { SenderChecks.nameForms($0.name) }))
        var names = input.projectPeople.map { SenderChecks.nameForms($0.name) }
        names += personalNames(in: input.sourceTexts).map(SenderChecks.nameForms)
        var seen: Set<String> = []
        var protected: [[NSRegularExpression]] = []
        for forms in names where !forms.isEmpty && allowed.isDisjoint(with: spellings(forms)) {
            guard seen.insert(forms[0]).inserted else { continue }
            var patterns: [NSRegularExpression] = []
            for form in forms {
                let words = form.split(separator: " ").map(String.init)
                patterns.append(namePattern(words.map(wordPattern), separator: #"\s+"#))
                if words.count == 2, !form.contains(where: \.isHan) {
                    patterns.append(namePattern(words.reversed().map(wordPattern), separator: #",?\s+"#))
                }
            }
            for parts in forms.flatMap(pinyinForms) {
                let words = parts.map { $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[\s-]?"#) }
                patterns.append(namePattern(words, separator: #",?\s+"#))
            }
            protected.append(patterns)
        }
        return protected
    }

    /// A word of a name as a pattern: Chinese characters with or without spaces between
    /// them, any other word as it is.
    private static func wordPattern(_ word: String) -> String {
        word.contains(where: \.isHan)
            ? word.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s*"#)
            : NSRegularExpression.escapedPattern(for: word)
    }

    /// The words of a name with any white space between them, ignoring case, and not
    /// inside a longer Latin word.
    private static func namePattern(_ words: [String], separator: String) -> NSRegularExpression {
        let latinEdge = #"[A-Za-z0-9\x{00C0}-\x{024F}]"#
        return try! NSRegularExpression(pattern: "(?<!" + latinEdge + ")" + words.joined(separator: separator) + "(?!" + latinEdge + ")", options: .caseInsensitive)
    }

    /// The pinyin of a Chinese name of two to four characters, as the surname and the given
    /// name, each with its syllables, in both orders: 宋雨桐 gives ["song", "yu tong"] and
    /// ["yu tong", "song"]. Empty for any other form.
    static func pinyinForms(of name: String) -> [[String]] {
        guard (2...4).contains(name.count), name.allSatisfy(\.isHan),
              let latin = name.applyingTransform(.mandarinToLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false)
        else { return [] }
        let syllables = latin.lowercased().split(separator: " ").map { String($0.filter(\.isASCIILetterOrDigit)) }
        guard syllables.count == name.count, syllables.allSatisfy({ !$0.isEmpty }) else { return [] }
        let surnameLength = name.count >= 3 && ScreenNames.compoundSurnames.contains(String(name.prefix(2))) ? 2 : 1
        let surname = syllables.prefix(surnameLength).joined(separator: " ")
        let given = syllables.dropFirst(surnameLength).joined(separator: " ")
        return [[surname, given], [given, surname]]
    }

    /// The personal names in the texts: Chinese names by the rules of `ScreenNames`, which
    /// need no tagger, Latin names from the natural language tagger, and the Chinese names
    /// those Latin names spell, as 韩书言 for Han Shuyan.
    private static func personalNames(in texts: [String]) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        var names: [String] = []
        for text in texts where !text.isEmpty {
            names += ScreenNames.hanTerms(in: text, common: .none).filter { $0.2 == .name }.map(\.0)
            guard text.contains(where: \.isASCIILetterOrDigit) else { continue }
            var latin: [String] = []
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                if tag == .personalName, !text[range].contains(where: \.isHan) {
                    latin.append(String(text[range]))
                }
                return true
            }
            names += latin + hanNames(spelledBy: latin, in: text)
        }
        return names
    }

    /// The runs of two to four Chinese characters in the text whose pinyin, in either order,
    /// spells one of the Latin names, as 韩书言 does Han Shuyan and Shuyan Han.
    static func hanNames(spelledBy latinNames: [String], in text: String) -> [String] {
        let spellings = Set(latinNames.map { String($0.lowercased().filter(\.isASCIILetterOrDigit)) }.filter { !$0.isEmpty })
        guard !spellings.isEmpty else { return [] }
        var found: [String] = []
        var run = ""
        for character in text + " " {
            if character.isHan {
                run.append(character)
                continue
            }
            if !found.contains(run), pinyinForms(of: run).contains(where: { spellings.contains($0.joined().filter(\.isASCIILetterOrDigit)) }) {
                found.append(run)
            }
            run = ""
        }
        return found
    }

    // MARK: Editing

    /// The text with each range replaced. The ranges must not overlap.
    private static func replacing(_ edits: [(Range<String.Index>, String)], in text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) where range.lowerBound >= cursor {
            result += text[cursor..<range.lowerBound]
            result += replacement
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// A text in compatibility form, so full width letters, digits and dots and the no
    /// break space read as plain ones, with the way back to the text it came from. The
    /// checks find links, codes, numbers and names here and remove them from the original,
    /// which keeps the draft's own full width punctuation.
    nonisolated private struct Folded {
        let text: String
        /// For each UTF-16 unit of `text`, the character of the original it came from.
        private let origins: [Range<String.Index>]

        init(_ original: String) {
            var text = ""
            var origins: [Range<String.Index>] = []
            var index = original.startIndex
            while index < original.endIndex {
                let next = original.index(after: index)
                let piece = String(original[index..<next]).precomposedStringWithCompatibilityMapping
                text += piece
                origins += repeatElement(index..<next, count: piece.utf16.count)
                index = next
            }
            self.text = text
            self.origins = origins
        }

        /// The range of the original that a range of `text` came from.
        func original(_ range: Range<String.Index>) -> Range<String.Index>? {
            let start = range.lowerBound.utf16Offset(in: text)
            let end = range.upperBound.utf16Offset(in: text)
            guard start < end, end <= origins.count else { return nil }
            return origins[start].lowerBound..<origins[end - 1].upperBound
        }
    }
}
