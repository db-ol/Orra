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
    /// they were on. Empty for mail from a domain that imitates a known one, which holds
    /// nothing a reply may repeat, so a refusal never quotes the account it was asked to
    /// pay into.
    var incomingText: String
    /// The other texts the model read: the excerpts of project files and the project's
    /// other mail.
    var sourceTexts: [String] = []
    /// The questions the window lists for the user to decide, or those of the answer that
    /// wrote the draft when that answer lists more, see ExplainService.finish.
    var questionsForUser: [String] = []
    var today: Date
    /// The domains that imitate a domain the user knows: the sender's, when the sender
    /// checks found it a lookalike. The draft names none of them.
    var imitatingDomains: [String] = []
    /// Whether the email asks someone outside the project for personal data, a credential
    /// or confidential project data. What the window shows of the removals then holds no
    /// value the recipients do not already have, see `OutputChecks.shown`.
    var asksForData = false
    /// The excerpts of other projects' files the model read, whose data and sentences no
    /// draft carries, whoever it reaches. Nil in a check an earlier build saved.
    var otherProjectTexts: [String]? = nil
    /// The names that belong to the projects of those excerpts: each project's name, the
    /// names of its people and the names its domains spell, which no draft carries either,
    /// see `ExplainService.otherProjectNames(_:)`. Nil without such excerpts, and in a check
    /// an earlier build saved.
    var otherProjectNames: [String]? = nil
}

/// Checks a draft after the model and before the user sees it (code step 5 of the phase 0
/// report).
///
/// It removes, each with a placeholder in the reply's language:
/// - links, Markdown and HTML image and link syntax, and web addresses, and any address,
///   host or name of a domain that imitates one the user knows, as the sender checks found
/// - sentences that claim an action, such as "already forwarded", 已转发, "I have moved or
///   sent" or 我已通知, since Orra sends, forwards, moves and tells no one anything, and
///   the model cannot know what the user did
/// - sentences that speak as an assistant, name Orra, or talk about the checks: text that
///   was removed or hidden, words to an assistant, an AI or a model, or commands to run.
///   A person writing their own reply says none of these.
/// - sentences that copy another project's file: a run of 8 words or 12 Chinese characters
///   in a row, a word counting as one and a half characters in a mixed run, that an excerpt
///   of another project's file holds and neither the incoming mail nor the email's own
///   project's sources hold, from every draft, whoever it reaches
/// - another project's data, from every draft, whoever it reaches: amounts, scores, codes
///   and years other than this one and the next and last whose value only an excerpt of
///   another project's file holds, the names and addresses of people in those excerpts,
///   and the names of those projects, of their people and of what their domains spell, see
///   `DraftCheckInput.otherProjectNames`, that neither the incoming mail, the email's own
///   project's sources, the recipients, the user nor the project's people hold. Both rules
///   run before the next one, so the window names the more exact reason. Facts retold in
///   other words, dates and counts stay, so the prompt tells the model to leave other
///   projects out of the draft.
/// - project data when the reply goes to someone outside the project's people: amounts in
///   digits or in Chinese words, scores, codes such as booking, ID and account numbers,
///   years that are not this year or the next or last, and the names and addresses of other
///   people, unless the incoming mail already holds them
///
/// Its own placeholders, which a revision keeps, are left as they are: a sentence
/// placeholder is a sentence of its own, and no placeholder counts toward a rule. What it
/// took out shows in the window as `OutputChecks.shown` gives it: a link as its host only,
/// and with a data request no value the recipients do not already have.
///
/// It reads full width letters and digits as plain ones, and names with any spaces in
/// them. Names of the project's people are always caught, in Chinese and in pinyin. Other
/// names come from the source texts: Chinese ones by the rules of `ScreenNames`, Latin ones
/// from the natural language tagger, so some may be missed. Addresses are those of the
/// project's people and every address in the source texts, and only the whole address in
/// the incoming mail counts as one it holds.
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
            /// Data that only an excerpt of another project's file holds.
            case otherProjectData
            /// A sentence that copies an excerpt of another project's file.
            case otherProjectText
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
        /// What the check took out. A removal of a kind a later Orra added is left out when
        /// a saved result is read, so the explanation around it still reads.
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

        let links = ContentChecks.merged(OutputChecks.linkRanges(in: original) + imitationRanges(in: original, input: input))
        removals += links.map { Removal(kind: .link, text: String(original[$0])) }
        let language = ProjectsLanguage.reading(replacing(links.map { ($0, " ") }, in: original))
        var draft = replacing(links.map { ($0, placeholder(.link, style)) }, in: original)

        var sentences: [(Range<String.Index>, String)] = []
        for range in sentenceRanges(in: draft) {
            let sentence = withoutPlaceholders(String(draft[range]))
            let form = SortingText.matchingForm(sentence)
            let kind: Removal.Kind
            if speaksAsAssistant(sentence, form: form) {
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

        // Another project's files, from every draft, before the rule for people outside the
        // project, so the window names the more exact reason.
        let copies = copiesOtherProject(draft, input: input)
        removals += copies.map { Removal(kind: .otherProjectText, text: String(draft[$0])) }
        draft = replacing(copies.map { ($0, placeholder(.otherProjectText, style)) }, in: draft)
        let otherData = otherProjectData(in: draft, input: input)
        removals += otherData.map { Removal(kind: .otherProjectData, text: String(draft[$0])) }
        draft = replacing(otherData.map { ($0, placeholder(.otherProjectData, style)) }, in: draft)

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
        let withholding = input.asksForData ? input.incomingText : nil
        let shown = removals.map { removal in
            Removal(kind: removal.kind, text: OutputChecks.shown(removal.text, withholding: withholding, language: style))
        }
        return Result(draft: kept ? draft : nil, language: language, removals: shown, flags: flags, outsideRecipients: outside)
    }

    // MARK: Placeholders

    /// What stands where the check took something out, in Chinese or else in English. The
    /// window's other texts use the link and project data ones too, see `OutputChecks.shown`.
    static func placeholder(_ kind: Removal.Kind, _ language: ProjectsLanguage) -> String {
        switch kind {
        case .link: language == .zh ? "[已删去链接]" : "[link removed]"
        case .actionClaim: language == .zh ? "[已删去一句：声称已经办了某事]" : "[sentence removed: it claims an action]"
        case .assistantVoice: language == .zh ? "[已删去一句：以助手的口吻]" : "[sentence removed: it speaks as an assistant]"
        case .projectData: language == .zh ? "[已删去项目资料]" : "[project data removed]"
        case .otherProjectData: language == .zh ? "[已删去其他项目的资料]" : "[another project's data removed]"
        case .otherProjectText: language == .zh ? "[已删去一句：出自其他项目的文件]" : "[sentence removed: it is from another project's file]"
        }
    }

    /// Every placeholder of the check in both languages, the sentence ones apart.
    private static let placeholders: (sentences: [String], parts: [String]) = {
        let languages: [ProjectsLanguage] = [.zh, .en]
        return (
            languages.flatMap { [placeholder(.actionClaim, $0), placeholder(.assistantVoice, $0), placeholder(.otherProjectText, $0)] },
            languages.flatMap { [placeholder(.link, $0), placeholder(.projectData, $0), placeholder(.otherProjectData, $0)] }
        )
    }()

    /// A sentence without the check's link and project data placeholders, so the words in
    /// them never count toward a rule. Sentence placeholders are no part of a sentence, see
    /// `sentenceRanges(in:)`.
    private static func withoutPlaceholders(_ sentence: String) -> String {
        placeholders.parts.reduce(sentence) { $0.replacingOccurrences(of: $1, with: " ") }
    }

    /// A placeholder for what only the user can decide, as the explanation prompt asks
    /// for: [待确认：…] or [to confirm: …], and 待定, TBC and TBD in brackets. The total the
    /// prompt leaves to the user, [待确认：合计] or [to confirm: total], is no question.
    private static let confirmPlaceholder = try! NSRegularExpression(
        pattern: #"[\[［【]\s*(?:待确认|待確認|待定|to confirm|tbc|tbd)(?!\s*[:：]\s*(?:合计|total)\s*[\]］】])"#,
        options: .caseInsensitive
    )

    // MARK: Imitating domains

    /// Where the text names a domain that imitates a known one: an address there, the
    /// domain or a subdomain of it, or its name without the top level label, such as
    /// pic-c0nf for pic-c0nf.example. Mail programs make an address or a host into a link,
    /// and the name alone still points the reader there. The name alone does not count
    /// inside another host or address, nor when it is also the name of a domain of the
    /// user, the project's people or the other recipients, as for qingshi.co against
    /// qingshi.example, where it names the real company too. Read in compatibility form,
    /// so full width letters count too.
    private static func imitationRanges(in text: String, input: DraftCheckInput) -> [Range<String.Index>] {
        let domains = Set(input.imitatingDomains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@."))).lowercased() }.filter { $0.contains(".") })
        guard !domains.isEmpty else { return [] }
        var knownNames: Set<String> = []
        for person in input.own + input.projectPeople + input.recipients {
            guard let address = ProjectsAddress.normalized(person.address), let domain = address.split(separator: "@").last, !domains.contains(String(domain)) else { continue }
            let labels = domain.split(separator: ".").dropLast()
            knownNames.formUnion(labels.map(String.init) + [labels.joined(separator: ".")])
        }
        let folded = OutputChecks.Folded(text)
        let whole = NSRange(folded.text.startIndex..., in: folded.text)
        var found: [Range<String.Index>] = []
        for domain in domains {
            var patterns = [#"(?<![A-Za-z0-9_.-])(?:[A-Za-z0-9._%+-]+@)?(?:[A-Za-z0-9-]+\.)*"# + NSRegularExpression.escapedPattern(for: domain) + #"(?![A-Za-z0-9_-])"#]
            if let dot = domain.lastIndex(of: "."), domain.distance(from: domain.startIndex, to: dot) >= 4, !knownNames.contains(String(domain[..<dot])) {
                patterns.append(#"(?<![A-Za-z0-9_@.-])"# + NSRegularExpression.escapedPattern(for: String(domain[..<dot])) + #"(?![A-Za-z0-9_@-]|\.[A-Za-z0-9])"#)
            }
            for pattern in patterns {
                let expression = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                found += expression.matches(in: folded.text, range: whole).compactMap { Range($0.range, in: folded.text) }
            }
        }
        return ContentChecks.merged(found.compactMap(folded.original))
    }

    // MARK: Sentences

    /// The sentences of the text: up to 。！？!?… or a full stop before a space, with the
    /// closing quotes and brackets after them, or up to the end of the line. White space
    /// between sentences belongs to none. A sentence placeholder of the check stands for a
    /// sentence, so it ends the one before it and is left out.
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
            if character == "[", let placeholder = placeholders.sentences.first(where: { text[index...].hasPrefix($0) }) {
                close(at: index)
                next = text.index(index, offsetBy: placeholder.count)
            } else if character.isNewline {
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

    /// Whether a sentence speaks as an assistant, names Orra, or talks about the checks:
    /// the voice patterns read its matching form, and AI in capitals counts as a word of
    /// its own, since ai in lower case is also a name in pinyin. AI as the Illustrator file
    /// format, as in AI格式, an AI file or AI or EPS, counts for neither.
    private static func speaksAsAssistant(_ sentence: String, form: String) -> Bool {
        let plain = sentence.precomposedStringWithCompatibilityMapping
        let range = NSRange(plain.startIndex..., in: plain)
        guard fileFormatAI.firstMatch(in: plain, range: range) != nil else {
            return ContentChecks.matches(assistantVoice, form) || ContentChecks.matches([capitalAI], plain)
        }
        let rest = fileFormatAI.stringByReplacingMatches(in: plain, range: range, withTemplate: "Illustrator")
        return ContentChecks.matches(assistantVoice, SortingText.matchingForm(rest)) || ContentChecks.matches([capitalAI], rest)
    }

    private static let capitalAI = try! NSRegularExpression(pattern: #"(?<![A-Za-z])(?:AI|A\.I\.)(?![A-Za-z])"#)

    /// AI as a file format: next to a word for a file or a format, or next to another
    /// format such as EPS or PDF.
    private static let fileFormatAI = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z.])AI(?=\s?(?:files?\b|formats?\b|versions?\b|sources?\b|文件|格式|源文件|档|稿|版)|\s?(?:[,/、]|or\b|and\b|或|和)\s?(?:EPS|PDF|SVG|PSD|PNG|INDD)\b)|(?<=(?:EPS|PDF|SVG|PSD|PNG|INDD)\s?(?:[,/、]|or|and|或|和)\s?)AI(?![A-Za-z])|(?<=\.)ai(?![A-Za-z])"#,
        options: .caseInsensitive
    )

    /// A sentence that speaks as an assistant, names Orra, or talks about an assistant or
    /// the checks: text removed or hidden, words to an assistant or a model, and commands
    /// to run. Not a job title, as in 我是王总的助理, my assistant or an assistant manager,
    /// and not a draft of a contract, as in "here is the draft agreement". The checks name
    /// an assistant 助手 in Chinese, while a person's assistant is 助理.
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
        // An assistant as someone the email or the checks address, not a job title.
        #"\b(?:an?|the|any) (?:ai |virtual |digital |email |automated )?assistants?\b(?! (?:professor|manager|director|editor|engineer|coach|principal|producer|curator|designer|architect|accountant|teacher|coordinator|planner|buyer|to the)\b)"#,
        #"\bchatbots?\b|\blanguage models?\b|\bartificial intelligence\b"#,
        // What the checks did: text removed or hidden, and commands to run.
        #"\b(?:removed|hidden|stripped) (?:text|instructions?|content|words|passages?|commands?|comments?|characters|sections? (?:of|in|from) (?:your|the|this|my) (?:e-?mail|message|mail|note))\b"#,
        #"\b(?:text|instructions?|content|words|passages?|commands?) (?:\w+ )?(?:was|were|has been|have been|had been) (?:removed|hidden|stripped|taken out|filtered out)\b"#,
        #"\bexecute (?:the |any |such |these |those |your |this |that )?(?:commands?|instructions?|scripts?)\b|\bruns? (?:the |any |such |these |those |your |this |that )?commands?\b"#,
        #"助手|人工智能|大模型"#,
        #"隐藏(?:的)?(?:文字|内容|字符|信息|指令|段落)|(?:看不到|看不见|不可见)的(?:文字|内容|字符|信息)|写给(?:助手|模型|ai|机器人)"#,
        #"执行(?:这些|这条|此|该|任何|您的|你的)?(?:命令|指令|脚本)"#,
    ])

    /// Whether a sentence, in its matching form, says that the writer forwarded, sent,
    /// moved, deleted, filed, shared or paid something, told someone or set something up,
    /// or is doing so now. A question claims nothing, and neither does a sentence about
    /// what the recipient or someone else did.
    private static func claimsAction(_ sentence: String) -> Bool {
        guard !sentence.hasSuffix("?") else { return false }
        if ContentChecks.matches(actionClaims, sentence) {
            return true
        }
        return ContentChecks.matches(actionsWithoutActor, sentence) && !ContentChecks.matches([otherActor], sentence)
    }

    /// Actions with the writer as the actor. The 已 forms skip the recipient or another
    /// person as the actor, as in 您已发送的文件 and 如已支付, and a question, as in
    /// 请确认第二期款是否已支付. The 将 and 把 forms need 了 or
    /// 过 at the end of a clause, so 发给您过目 and 发给您了解 are plans. Telling someone or
    /// setting something up counts in the first person or done for the reader, since
    /// 王经理已通知我们 is what someone else did, and 已设置 alone may say a password is set.
    private static let actionClaims = ContentChecks.patterns([
        #"(?:我|我们|本人)(?:这边|这里)?(?:已经|已)(?:为您|为你|帮您|帮你|替您|替你|给您|给你|向您|向你)?(?:通知|告知|知会|转告|联系|联络|上报|报告|反馈给|设置|设定|更新)"#,
        #"(?:已经|已)(?:为您|为你|帮您|帮你|替您|替你)(?:通知|告知|知会|转告|联系|联络|上报|报告|设置|设定|更新|回复)"#,
        #"(?<!您|你|贵司|贵方|对方|他|她|如|若|如果|若是|是否|是不是|有没有)(?:已经|已)(?:设置|设定|更新|添加|建立|创建)(?:好)?(?:了)?(?:一条)?(?:自动)?(?:转发|过滤|规则)"#,
        #"\b(?:i|we)(?:(?:'ve|’ve| have| had)(?: already| just| now| also)?| already| just) (?:set up|updated|notified|informed|told|alerted|contacted|reported|escalated|reached out to|let (?:\w+ ){1,3}know)\b"#,
        #"(?<!您|你|贵司|贵方|对方|他|她|如|若|如果|若是|是否|是不是|有没有)(?:已经|已)(?:为您|为你|帮您|帮你|替您|替你|给您|给你|向您|向你)?(?:转发|转交|转给|转到|发送|发出|发给|发过去|发到|寄出|寄给|寄到|删除|删掉|归档|移动|移到|移至|挪到|标记|抄送|付款|付清|转账|汇款|打款|支付|上传|分享|提交)"#,
        #"(?<!您|你|贵司|贵方|对方|他|她|如|若|如果|若是|是否|是不是|有没有)(?:已经|已)(?:将|把)[^。!?]{0,30}(?:转发|转交|转给|发送|发给|寄给|删除|归档|移到|移至|移动到|挪到|抄送|上传|分享)"#,
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

    // MARK: Other projects

    /// The sentences of the draft that copy an excerpt of another project's file: they hold
    /// a run of `copiedRun` that such an excerpt holds and neither the incoming mail nor the
    /// sources of the email's own project hold.
    private static func copiesOtherProject(_ draft: String, input: DraftCheckInput) -> [Range<String.Index>] {
        guard let others = input.otherProjectTexts, !others.isEmpty else { return [] }
        let copied = runs(in: others).subtracting(runs(in: [input.incomingText] + input.sourceTexts))
        guard !copied.isEmpty else { return [] }
        return sentenceRanges(in: draft).filter { range in
            !runs(in: [withoutPlaceholders(String(draft[range]))]).isDisjoint(with: copied)
        }
    }

    /// The weight of a run of words that counts as copied: 12 Chinese characters, of weight
    /// 2 each, or 8 Latin words or numbers, of weight 3 each, or a mix of them.
    private static let copiedRun = 24

    /// Each shortest run of words of the texts in a row whose weight reaches `copiedRun`, in
    /// matching form, see SortingText.matchingForm. A Chinese character is a word of its own,
    /// letters and digits in a row are one, and white space and punctuation only part them.
    /// The shortest run that ends at a word depends only on the words up to it, so a passage
    /// copied whole gives the same runs in the draft and in the excerpt.
    private static func runs(in texts: [String]) -> Set<String> {
        var runs = Set<String>()
        for text in texts {
            var words: [(word: String, weight: Int)] = []
            var current = ""
            for character in SortingText.matchingForm(text) {
                if character.isHan {
                    if !current.isEmpty {
                        words.append((current, 3))
                        current = ""
                    }
                    words.append((String(character), 2))
                } else if character.isLetter || character.isNumber {
                    current.append(character)
                } else if !current.isEmpty {
                    words.append((current, 3))
                    current = ""
                }
            }
            if !current.isEmpty {
                words.append((current, 3))
            }
            var start = 0
            var weight = 0
            for end in words.indices {
                weight += words[end].weight
                while weight - words[start].weight >= copiedRun {
                    weight -= words[start].weight
                    start += 1
                }
                if weight >= copiedRun {
                    runs.insert(words[start...end].map(\.word).joined(separator: " "))
                }
            }
        }
        return runs
    }

    /// Where the draft holds data that only an excerpt of another project's file holds:
    /// amounts, scores, codes and years other than this one and the next and last whose
    /// value such an excerpt holds and neither the incoming mail nor the email's own
    /// project's sources hold, and the names and addresses of people in those excerpts, and
    /// the names of `DraftCheckInput.otherProjectNames`, that none of those texts, the
    /// recipients, the user or the project's people hold. Overlapping finds are merged.
    private static func otherProjectData(in draft: String, input: DraftCheckInput) -> [Range<String.Index>] {
        guard let others = input.otherProjectTexts, !others.isEmpty else { return [] }
        let folded = OutputChecks.Folded(draft)
        let text = folded.text
        let other = others.joined(separator: "\n\n").precomposedStringWithCompatibilityMapping
        let known = ([input.incomingText] + input.sourceTexts).joined(separator: "\n\n").precomposedStringWithCompatibilityMapping
        func values(_ text: String) -> Set<String> {
            Set(OutputChecks.numbers(in: text, skippingDatesAndCodes: false).map(\.value)
                + OutputChecks.numbers(in: NumberRules.writingNumbersAsDigits(in: text), skippingDatesAndCodes: false).map(\.value))
        }
        func codes(_ text: String) -> Set<String> {
            Set(OutputChecks.codes(in: text).map { OutputChecks.codeValue(text[$0]) })
        }
        let otherValues = values(other).subtracting(values(known))
        let otherCodes = codes(other).subtracting(codes(known))
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: input.today)
        var found: [Range<String.Index>] = []
        for code in OutputChecks.codes(in: text) where otherCodes.contains(OutputChecks.codeValue(text[code])) {
            found.append(code)
        }
        for number in OutputChecks.numbers(in: text) where otherValues.contains(number.value) {
            let year = number.value.count == 4 ? Int(number.value).flatMap { (1900...2099).contains($0) ? $0 : nil } : nil
            if number.isAmount || number.isScore || year.map({ abs($0 - thisYear) > 1 }) == true {
                found.append(number.range)
            }
        }
        for match in chineseAmount.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let amounts = OutputChecks.numbers(in: NumberRules.writingNumbersAsDigits(in: String(text[range]))).filter(\.isAmount).map(\.value)
            if amounts.contains(where: otherValues.contains) {
                found.append(range)
            }
        }
        let names = namePatterns(personalNames(in: others) + (input.otherProjectNames ?? []), allowed: input.recipients + input.own + input.projectPeople)
        for patterns in names where !patterns.contains(where: { $0.firstMatch(in: known, range: NSRange(known.startIndex..., in: known)) != nil }) {
            for pattern in patterns {
                found += pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
            }
        }
        let allowed = Set((input.recipients + input.own + input.projectPeople).compactMap { ProjectsAddress.normalized($0.address) })
        for address in addresses(in: other).subtracting(allowed).subtracting(addresses(in: known)) {
            found += SenderChecks.occurrences(of: address, in: text)
        }
        return ContentChecks.merged(found.compactMap(folded.original))
    }

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
        let folded = OutputChecks.Folded(draft)
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
        let incomingAddresses = addresses(in: incoming)
        for address in protectedAddresses(input) where !incomingAddresses.contains(address) {
            found += SenderChecks.occurrences(of: address, in: text)
        }
        return ContentChecks.merged(found.compactMap(folded.original))
    }

    /// An amount in Chinese words, as 五万八千六百元 or 三点五万元. `NumberRules` reads it.
    private static let chineseAmount = try! NSRegularExpression(
        pattern: #"[零〇一二两三四五六七八九十百千万亿点]+(?:元|块|圆|美元|港元|港币|欧元|英镑|日元|人民币)"#
    )

    /// The addresses of the project's people and the addresses in the sources, other than
    /// the recipients' and the user's, lowercased.
    private static func protectedAddresses(_ input: DraftCheckInput) -> Set<String> {
        let allowed = Set((input.recipients + input.own).compactMap { ProjectsAddress.normalized($0.address) })
        let people = Set(input.projectPeople.compactMap { ProjectsAddress.normalized($0.address) })
        return people.union(input.sourceTexts.flatMap(addresses)).subtracting(allowed)
    }

    /// The whole mail addresses in a text, lowercased, read in compatibility form so full
    /// width letters count too. An address inside a longer one is not one of them, so
    /// bowen@pike-build.example holds no owen@pike-build.example.
    private static func addresses(in text: String) -> Set<String> {
        let plain = text.precomposedStringWithCompatibilityMapping
        let matches = OutputChecks.mailAddress.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        return Set(matches.compactMap { Range($0.range, in: plain).flatMap { ProjectsAddress.normalized(String(plain[$0])) } })
    }

    // MARK: Names

    /// The names of the project's people and the personal names in the sources, without
    /// the recipients and the user, each as the patterns of the ways it may be written. A
    /// name needs two Chinese characters or two words, so a lone given name never counts.
    /// A Chinese name is also found in pinyin with the surname first or last, and a two word
    /// Latin name in reverse.
    private static func protectedNames(_ input: DraftCheckInput) -> [[NSRegularExpression]] {
        namePatterns(input.projectPeople.map(\.name) + personalNames(in: input.sourceTexts), allowed: input.recipients + input.own)
    }

    /// The patterns of each of the names, each the ways it may be written, without the names
    /// of the `allowed` people. A name needs two Chinese characters or two words.
    private static func namePatterns(_ names: [String], allowed people: [DraftCheckInput.Person]) -> [[NSRegularExpression]] {
        /// The letters of a form, which compares 宋雨桐's pinyin with Song Yutong.
        func spelling(_ form: String) -> String {
            form.filter { $0.isLetter || $0.isNumber }
        }
        func spellings(_ forms: [String]) -> [String] {
            forms.map(spelling) + forms.flatMap(pinyinForms).map { spelling($0.joined()) }
        }
        let allowed = Set(spellings(people.flatMap { SenderChecks.nameForms($0.name) }))
        let names = names.map(SenderChecks.nameForms)
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

    // MARK: Reading a saved result

    /// A value that reads as nil where it does not decode, such as a removal of a kind a
    /// later Orra added.
    fileprivate nonisolated struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
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
}

nonisolated extension DraftCheck.Result {
    /// Reads a saved result. A removal of a kind a later Orra added is left out, so the
    /// explanation or the draft version that holds the result still reads.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        draft = try container.decodeIfPresent(String.self, forKey: .draft)
        language = try container.decode(ProjectsLanguage.self, forKey: .language)
        removals = try container.decode([DraftCheck.Lenient<DraftCheck.Removal>].self, forKey: .removals).compactMap(\.value)
        flags = try container.decode([DraftCheck.Flag].self, forKey: .flags)
        outsideRecipients = try container.decode([String].self, forKey: .outsideRecipients)
    }
}
