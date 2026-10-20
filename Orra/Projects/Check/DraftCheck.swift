import Foundation
import NaturalLanguage

/// The plain values a draft is checked with.
nonisolated struct DraftCheckInput: Sendable, Equatable {
    typealias Person = SenderChecks.Person

    /// The draft the model wrote.
    var draft: String
    /// The language the reply rule chose. A draft in another language is held back, and
    /// with `other` every draft is, since Orra drafts only in Chinese and English.
    var language: ProjectsLanguage
    /// The people the reply goes to.
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
/// - project data when the reply goes to someone outside the project's people: amounts,
///   scores, codes such as booking, ID and account numbers, and the names and addresses of
///   other people, unless the incoming mail already holds them
///
/// It flags what OutputChecks finds, and fewer "to confirm" placeholders than questions
/// for the user, which means the draft may decide one only the user can. It holds the draft
/// back when its language, read with `ProjectsLanguage.reading(_:)`, differs from the
/// reply rule's. In phase 0 the best setting failed 13 or 14 of the 64 attack items, most
/// of them by giving project data to someone outside the project, which this check stops.
nonisolated enum DraftCheck {
    /// A part of the draft the check took out, so the window can show what was removed.
    nonisolated struct Removal: Sendable, Equatable {
        nonisolated enum Kind: String, Sendable, Codable, CaseIterable {
            case link
            case actionClaim
            case assistantVoice
            case projectData
        }

        var kind: Kind
        /// The text taken out.
        var text: String
    }

    nonisolated enum Flag: Sendable, Equatable {
        /// What OutputChecks found in the checked draft.
        case output(OutputChecks.Finding)
        /// Fewer "to confirm" placeholders than questions for the user.
        case decidesQuestion(placeholders: Int, questions: Int)
    }

    nonisolated struct Result: Sendable, Equatable {
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

        let links = ContentChecks.linkRanges(in: original)
        removals += links.map { Removal(kind: .link, text: String(original[$0])) }
        let language = ProjectsLanguage.reading(replacing(links.map { ($0, " ") }, in: original))
        var draft = replacing(links.map { ($0, placeholder(.link, style)) }, in: original)

        var sentences: [(Range<String.Index>, String)] = []
        for range in sentenceRanges(in: draft) {
            let form = SortingText.matchingForm(String(draft[range]))
            let kind: Removal.Kind
            if matches(assistantVoice, form) {
                kind = .assistantVoice
            } else if matches(actionClaims, form) {
                kind = .actionClaim
            } else {
                continue
            }
            removals.append(Removal(kind: kind, text: String(draft[range])))
            sentences.append((range, placeholder(kind, style)))
        }
        draft = replacing(sentences, in: draft)

        let outside = outsideRecipients(input)
        if !outside.isEmpty {
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
    /// for: [待确认：…] or [to confirm: …], and 待定, TBC and TBD in brackets.
    private static let confirmPlaceholder = try! NSRegularExpression(
        pattern: #"[\[［【]\s*(?:待确认|待確認|待定|to confirm|tbc|tbd)"#,
        options: .caseInsensitive
    )

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

    private static func matches(_ patterns: [NSRegularExpression], _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Patterns that read the matching form of a sentence: lowercase, on one line, with
    /// full width punctuation such as ，and ！ made plain.
    private static func patterns(_ sources: [String]) -> [NSRegularExpression] {
        sources.map { try! NSRegularExpression(pattern: $0) }
    }

    /// A sentence that speaks as an assistant, or names Orra.
    private static let assistantVoice = patterns([
        #"(?<![a-z])orra(?![a-z])"#,
        #"\bas (?:an? )?(?:ai|a\.i\.|artificial intelligence|(?:ai |virtual |digital |email )?assistant|language model|chatbot|bot)\b"#,
        #"\b(?:i am|i'm|i’m|this is) (?:[a-z]+(?:'s|’s) )?(?:an? )?(?:ai|a\.i\.|(?:ai |virtual |digital |email |personal )?assistant|language model|chatbot|bot|automated)\b"#,
        #"\b(?:ai|virtual|digital|email) assistant\b|\blanguage model\b"#,
        #"\b(?:automated|automatic|auto-generated|ai-generated|machine-generated) (?:reply|response|message|email|draft)\b"#,
        #"\b(?:generated|drafted|written|composed) (?:by|with|using) (?:an? )?(?:ai|assistant|model|software|tool)\b"#,
        #"\bhere(?:'s|’s| is) (?:a|the|your|my) (?:draft|suggested (?:reply|response))\b"#,
        #"^(?:sure|certainly|of course|okay|ok)[,!.]? (?:here|below)\b"#,
        #"(?:我是|作为|身为)[^。!?]{0,12}(?:ai|人工智能|助手|助理|语言模型|大模型|机器人)"#,
        #"ai ?(?:助手|助理)|语言模型"#,
        #"自动(?:生成|回复|撰写|起草)"#,
        #"(?:以下|下面)是[^。!?]{0,8}草稿|草稿如下"#,
    ])

    /// A sentence that says something was forwarded, sent, moved, deleted, filed, shared or
    /// paid, or is being so now.
    private static let actionClaims = patterns([
        #"(?:已经|已)(?:为您|为你|帮您|帮你|替您|替你|给您|给你|向您|向你)?(?:转发|转交|转给|转到|发送|发出|发给|发过去|发到|寄出|寄给|寄到|删除|删掉|归档|移动|移到|移至|挪到|标记|抄送|付款|付清|转账|汇款|打款|支付|上传|分享|提交)"#,
        #"(?:已经|已)(?:将|把)[^。!?]{0,30}(?:转发|转交|转给|发送|发给|寄给|删除|归档|移到|移至|移动到|挪到|抄送|上传|分享)"#,
        #"(?:将|把)[^。!?]{0,30}(?:转发|转交|转给|发送|发给|寄给|删除|归档|移到|移至|移动到|挪到|抄送|上传|分享)[^。!?,]{0,20}?(?:了|过)(?![吗呢么])"#,
        #"\b(?:i|we)(?:'ve|’ve| have| had)? (?:already |just |now |also )?(?:forwarded|sent|moved|deleted|archived|filed|shared|uploaded|paid|transferred|wired|cc'?d)\b"#,
        #"\bgone ahead and (?:forwarded|sent|moved|deleted|archived|filed|shared|uploaded|paid|transferred)\b"#,
        #"\b(?:has|have|had) (?:already |now |just )?been (?:forwarded|sent|moved|deleted|archived|filed|shared|uploaded|paid|transferred|wired|passed on)\b"#,
        #"\balready (?:been )?(?:forwarded|sent|moved|deleted|archived|shared|uploaded|paid|transferred)\b"#,
        #"\b(?:i|we)(?:'m|’m|'re|’re| am| are) (?:now )?(?:forwarding|sending|moving|deleting|archiving|sharing|transferring)\b"#,
    ])

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
    /// scores, codes, and the names and addresses of people other than the recipients and
    /// the user. Overlapping finds are merged.
    private static func projectData(in draft: String, input: DraftCheckInput) -> [Range<String.Index>] {
        let incoming = input.incomingText.precomposedStringWithCompatibilityMapping
        let incomingValues = Set(
            OutputChecks.numbers(in: incoming, skippingDatesAndCodes: false).map(\.value)
                + OutputChecks.numbers(in: NumberRules.writingNumbersAsDigits(in: incoming), skippingDatesAndCodes: false).map(\.value)
        )
        let incomingCodes = Set(OutputChecks.codes(in: incoming).map { OutputChecks.codeValue(incoming[$0]) })
        var found: [Range<String.Index>] = []
        for code in OutputChecks.codes(in: draft) where !incomingCodes.contains(OutputChecks.codeValue(draft[code])) {
            found.append(code)
        }
        for number in OutputChecks.numbers(in: draft) where (number.isAmount || number.isScore) && !incomingValues.contains(number.value) {
            found.append(number.range)
        }
        let incomingLower = incoming.lowercased()
        for term in protectedTerms(input) where !incomingLower.contains(term) {
            found += SenderChecks.occurrences(of: term, in: draft)
        }
        var merged: [Range<String.Index>] = []
        for range in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The names and addresses a reply outside the project must not carry, lowercased:
    /// those of the project's people, and the personal names the tagger finds in the
    /// sources, without the recipients and the user. A name needs two Chinese characters
    /// or two words, so a lone given name never counts.
    private static func protectedTerms(_ input: DraftCheckInput) -> Set<String> {
        let allowed = input.recipients + input.own
        let allowedNames = Set(allowed.flatMap { SenderChecks.nameForms($0.name) })
        let allowedAddresses = Set(allowed.compactMap { ProjectsAddress.normalized($0.address) })
        var names = Set(input.projectPeople.flatMap { SenderChecks.nameForms($0.name) })
        names.formUnion(personalNames(in: input.sourceTexts).flatMap(SenderChecks.nameForms))
        names = names.filter { name in
            !allowedNames.contains(name) && ((name.count >= 2 && name.allSatisfy(\.isHan)) || name.split(separator: " ").count >= 2)
        }
        let addresses = Set(input.projectPeople.compactMap { ProjectsAddress.normalized($0.address) }).subtracting(allowedAddresses)
        return names.union(addresses)
    }

    /// The personal names in the texts, as the natural language tagger finds them.
    private static func personalNames(in texts: [String]) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        var names: [String] = []
        for text in texts where !text.isEmpty {
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                if tag == .personalName {
                    names.append(String(text[range]))
                }
                return true
            }
        }
        return names
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
