import Foundation
import NaturalLanguage

/// One email as the sorting rules see it.
///
/// The caller fills it from the mail it read. Addresses are lowercased `local@domain`
/// strings, the Message-ID has no angle brackets, and the text is the email's own text with
/// hidden text, quoted history and lines that address an assistant already taken out.
nonisolated struct SortingInput: Sendable, Equatable {
    /// The Message-ID, without angle brackets.
    var messageID: String
    /// The sender's address.
    var sender: String
    /// The To and Cc addresses.
    var recipients: [String] = []
    var subject: String
    /// The email's own text, cleaned by the caller.
    var text: String
    var attachmentNames: [String] = []
    /// The Mail mailbox the email is in, in the one form that linked mailboxes use too: the
    /// account's name, then each mailbox of its path, joined by "/", such as
    /// "Work/Clients/Harbor". Mail repeats names such as Inbox across accounts, so the
    /// account is always part of it.
    var mailbox: String? = nil
    /// The project of the message this one answers, when that message is known.
    var parentProject: UUID? = nil
    /// Whether the user moved that message to its project.
    var parentMovedByUser = false
    /// The list headers.
    var list = ListMail()
}

/// One of the user's projects as the sorting rules see it.
nonisolated struct SortingCandidate: Sendable, Equatable, Identifiable {
    /// A person the user listed for the project.
    nonisolated struct Person: Sendable, Equatable, Hashable {
        var name: String
        var address: String
    }

    /// A rule the user made, which files mail on its own.
    nonisolated enum Rule: Sendable, Equatable, Hashable {
        /// Mail from this address, or to it when the user sent the mail.
        case sender(String)
        /// Mail from this domain or one under it, or to it when the user sent the mail.
        case domain(String)
        /// Mail to this mailing list, by its List-Id.
        case list(String)
        /// Mail whose subject holds this code, such as a contract number. A code that
        /// starts or ends with a letter or digit is not found inside a longer code, so
        /// PO-12 is not found in PO-123.
        case subjectCode(String)
    }

    var id: UUID
    var name: String
    var description = ""
    var people: [Person] = []
    var domains: [String] = []
    /// Words the user gave for the project.
    var keywords: [String] = []
    var rules: [Rule] = []
    /// The Mail mailboxes linked to the project, in the form of `SortingInput.mailbox`.
    var mailboxes: [String] = []
    /// The addresses seen in the project's mail before, lowercased.
    var peopleSeen: Set<String> = []
    /// The names of the files in the project's folders.
    var fileNames: [String] = []
}

/// The user's projects and own addresses as sorting reads them. What each email is compared
/// with is worked out here once: each project's own words, the people seen in it and its
/// file names. Prepare it again when the projects, their files or the user's addresses
/// change, never for each email.
nonisolated struct SortingProjects: Sendable {
    /// The candidates, in the order that ties keep.
    let candidates: [SortingCandidate]
    /// The user's own addresses, lowercased and sorted.
    let ownAddresses: [String]
    /// The own words of each candidate, see `distinctiveWords(_:ownAddresses:)`.
    let words: [UUID: [String]]
    /// The people seen in each candidate before, lowercased. A caller that looks them up
    /// for each email, as SortingService does, sets them without preparing again.
    var seen: [UUID: Set<String>]
    /// The file names of each candidate, in their matching form.
    let fileNames: [UUID: Set<String>]

    /// Segments the words of every project, which takes a while with many files, so it
    /// runs off the main actor.
    @concurrent
    static func prepare(_ candidates: [SortingCandidate], ownAddresses: [String]) async -> SortingProjects {
        SortingProjects(candidates, ownAddresses: ownAddresses)
    }

    private init(_ candidates: [SortingCandidate], ownAddresses: [String]) {
        self.candidates = candidates
        let own = Set(ownAddresses.map(SortingText.address).filter { !$0.isEmpty })
        self.ownAddresses = own.sorted()
        words = Self.distinctiveWords(candidates, ownAddresses: own)
        seen = Dictionary(candidates.map { ($0.id, Set($0.peopleSeen.map(SortingText.address))) }, uniquingKeysWith: { $0.union($1) })
        fileNames = Dictionary(candidates.map { ($0.id, Set($0.fileNames.map(SortingText.matchingForm))) }, uniquingKeysWith: { $0.union($1) })
    }
}

/// What the rules found for one email, and the candidates ranked by it.
///
/// The signals and the ranking follow the phase 0 prototype (match.py): a thread, a rule
/// or a linked mailbox adds 10 points, people seen before and an attachment name 3 each,
/// the project's own words up to 3, and the three best full text scores 1, 0.6 and 0.3.
/// SortingPolicy decides from these, and SortingPrompt shows the top candidates to the
/// model. Lines that ask for a filing take no part, see FilingRequests.
nonisolated struct SortingSignals: Sendable, Equatable {
    /// The project of the message this email answers, when that project is a candidate.
    var thread: UUID? = nil
    /// Whether the user moved that message to its project.
    var threadMovedByUser = false
    /// Candidates that a rule, person or domain the user set names, as `.rule`, `.person`
    /// or `.domain`, the strongest when several match.
    var rules: [UUID: SortingReason] = [:]
    /// Candidates linked to the Mail mailbox the email is in.
    var mailboxes: [UUID] = []
    /// Candidates where an address of this email was seen before, with those addresses.
    var peopleSeen: [UUID: [String]] = [:]
    /// Candidates with a file named like an attachment.
    var attachments: [UUID] = []
    /// Candidates whose own words the email holds, with those words.
    var words: [UUID: [String]] = [:]
    /// Why the email counts as list mail, or nil.
    var listMail: ListMail.Sign? = nil
    /// Whether an address of this email is a person, domain or rule of any candidate, or
    /// was seen in one before. List mail with a project person is never set aside.
    var hasProjectPeople = false
    /// The full text score of each candidate, higher is better.
    var scores: [UUID: Double] = [:]
    /// Every candidate, best first. Ties keep the order the candidates came in.
    var ranked: [UUID] = []
    /// The lines that asked for a filing and were left out.
    var filingLines = 0

    /// The candidates the model chooses from.
    var topCandidates: [UUID] {
        Array(ranked.prefix(SortingPrompt.candidateCount))
    }
}

nonisolated extension SortingSignals {
    /// Finds the signals of one email among the projects. `score` gives each project's full
    /// text score for the text that votes, the subject and the text without filing
    /// requests. Scores must be above zero, higher for a better match. Zero and less do not
    /// count, so SQLite's bm25(), which is below zero and lower for a better match, is
    /// turned around first. Off the main actor, like the full text search it calls.
    @concurrent
    static func gather(
        for input: SortingInput,
        among projects: SortingProjects,
        score: @Sendable (String) async -> [UUID: Double]
    ) async -> SortingSignals {
        let vote = voteText(input)
        let scores = await score(vote.text)
        return SortingSignals(input: input, projects: projects, vote: vote, scores: scores)
    }

    private init(input: SortingInput, projects: SortingProjects, vote: (text: String, removed: Int), scores fullText: [UUID: Double]) {
        let candidates = projects.candidates
        let own = Set(projects.ownAddresses)
        let sender = SortingText.address(input.sender)
        var everyone: [String] = []
        for address in [sender] + input.recipients.map(SortingText.address)
        where !address.isEmpty && !own.contains(address) && !everyone.contains(address) {
            everyone.append(address)
        }
        // The other side: the sender of incoming mail, the recipients of mail the user sent.
        let counterparts = own.contains(sender) || sender.isEmpty ? everyone : [sender]
        let ids = Set(candidates.map(\.id))
        let attachmentNames = Set(input.attachmentNames.map(SortingText.matchingForm))
        let listIdentifier = input.list.listIdentifier
        let subject = SortingText.matchingForm(input.subject)
        let haystack = SortingText.matchingForm(vote.text)

        if let parent = input.parentProject, ids.contains(parent) {
            thread = parent
            threadMovedByUser = input.parentMovedByUser
        }
        for candidate in candidates {
            if let kind = Self.ruleMatch(candidate, counterparts: counterparts, subject: subject, listIdentifier: listIdentifier) {
                rules[candidate.id] = kind
            }
            if let mailbox = input.mailbox, candidate.mailboxes.contains(mailbox) {
                mailboxes.append(candidate.id)
            }
            let seenBefore = projects.seen[candidate.id, default: []]
            let seen = everyone.filter(seenBefore.contains)
            if !seen.isEmpty {
                peopleSeen[candidate.id] = seen
            }
            if !projects.fileNames[candidate.id, default: []].isDisjoint(with: attachmentNames) {
                attachments.append(candidate.id)
            }
            let hits = projects.words[candidate.id, default: []].filter { Self.contains(haystack, word: $0) }
            if !hits.isEmpty {
                words[candidate.id] = hits
            }
            if !seen.isEmpty || everyone.contains(where: { Self.names(candidate, $0) }) {
                hasProjectPeople = true
            }
        }
        listMail = input.list.sign(sender: sender, text: input.text)
        scores = fullText.filter { ids.contains($0.key) && $0.value > 0 }
        filingLines = vote.removed
        ranked = rank(candidates.map(\.id))
    }

    /// The candidates by points, as match.py ranks them.
    private func rank(_ order: [UUID]) -> [UUID] {
        var points: [UUID: Double] = [:]
        for id in rules.keys {
            points[id, default: 0] += 10
        }
        for id in mailboxes {
            points[id, default: 0] += 10
        }
        if let thread {
            points[thread, default: 0] += 10
        }
        for id in peopleSeen.keys {
            points[id, default: 0] += 3
        }
        for id in attachments {
            points[id, default: 0] += 3
        }
        for (id, hits) in words {
            points[id, default: 0] += Double(min(hits.count, 3))
        }
        let byScore = order.enumerated()
            .filter { scores[$0.element] != nil }
            .sorted { (scores[$0.element]!, -$0.offset) > (scores[$1.element]!, -$1.offset) }
        for (place, item) in byScore.prefix(3).enumerated() {
            points[item.element, default: 0] += [1.0, 0.6, 0.3][place]
        }
        return order.enumerated()
            .sorted { (points[$0.element, default: 0], -$0.offset) > (points[$1.element, default: 0], -$1.offset) }
            .map(\.element)
    }

    /// The text that votes: the subject and the email's text, without the lines that ask
    /// for a filing, and how many lines were left out.
    private static func voteText(_ input: SortingInput) -> (text: String, removed: Int) {
        let body = FilingRequests.removing(from: input.text)
        if FilingRequests.isFilingRequest(input.subject) {
            return ("\n" + body.text, body.removed + 1)
        }
        return (input.subject + "\n" + body.text, body.removed)
    }

    /// The strongest kind of user setting that names an address or the subject of this
    /// email: a rule, then a person, then a domain. `subject` is in its matching form.
    private static func ruleMatch(_ candidate: SortingCandidate, counterparts: [String], subject: String, listIdentifier: String?) -> SortingReason? {
        if candidate.rules.contains(where: { matches($0, counterparts: counterparts, subject: subject, listIdentifier: listIdentifier) }) {
            return .rule
        }
        let people = Set(candidate.people.map { SortingText.address($0.address) })
        if counterparts.contains(where: people.contains) {
            return .person
        }
        if counterparts.contains(where: { address in candidate.domains.contains { isAddress(address, in: $0) } }) {
            return .domain
        }
        return nil
    }

    /// Whether a user rule names this email. `subject` is in its matching form.
    private static func matches(_ rule: SortingCandidate.Rule, counterparts: [String], subject: String, listIdentifier: String?) -> Bool {
        switch rule {
        case .sender(let ruled):
            return counterparts.contains(SortingText.address(ruled))
        case .domain(let domain):
            return counterparts.contains { isAddress($0, in: domain) }
        case .list(let list):
            return listIdentifier != nil && ListMail.identifier(list) == listIdentifier
        case .subjectCode(let code):
            return contains(subject, code: SortingText.matchingForm(code))
        }
    }

    /// Whether one of the candidate's people, domains or rules names the address.
    private static func names(_ candidate: SortingCandidate, _ address: String) -> Bool {
        if candidate.people.contains(where: { SortingText.address($0.address) == address })
            || candidate.domains.contains(where: { isAddress(address, in: $0) }) {
            return true
        }
        return candidate.rules.contains { rule in
            switch rule {
            case .sender(let ruled): SortingText.address(ruled) == address
            case .domain(let domain): isAddress(address, in: domain)
            case .list, .subjectCode: false
            }
        }
    }

    /// Whether the address is in the domain or a domain under it.
    private static func isAddress(_ address: String, in domain: String) -> Bool {
        var domain = SortingText.address(domain)
        if domain.hasPrefix("@") {
            domain.removeFirst()
        }
        guard !domain.isEmpty, let at = address.lastIndex(of: "@") else { return false }
        let host = address[address.index(after: at)...]
        return host == domain || host.hasSuffix("." + domain)
    }

    /// Whether the subject holds the code, with no letter or digit joined to it where the
    /// code itself starts or ends with one.
    private static func contains(_ subject: String, code: String) -> Bool {
        guard let first = code.first, let last = code.last else { return false }
        var start = subject.startIndex
        while let range = subject.range(of: code, range: start..<subject.endIndex) {
            let joinedBefore = first.isASCIILetterOrDigit && range.lowerBound > subject.startIndex
                && subject[subject.index(before: range.lowerBound)].isASCIILetterOrDigit
            let joinedAfter = last.isASCIILetterOrDigit && range.upperBound < subject.endIndex
                && subject[range.upperBound].isASCIILetterOrDigit
            if !joinedBefore && !joinedAfter {
                return true
            }
            start = subject.index(after: range.lowerBound)
        }
        return false
    }

    /// Whether the text holds the word. A Chinese word may stand anywhere. An English word
    /// must stand alone, and may end in s or es, so pic is not found in picture but
    /// speaker is found in speakers.
    private static func contains(_ text: String, word: String) -> Bool {
        if word.contains(where: \.containsHan) {
            return text.contains(word)
        }
        func isEdge(_ index: String.Index) -> Bool {
            index == text.endIndex || !text[index].isASCIILetterOrDigit
        }
        var start = text.startIndex
        while let range = text.range(of: word, range: start..<text.endIndex) {
            let startsWord = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isASCIILetterOrDigit
            if startsWord {
                let rest = text[range.upperBound...]
                if isEdge(range.upperBound)
                    || (rest.hasPrefix("s") && isEdge(text.index(after: range.upperBound)))
                    || (rest.hasPrefix("es") && isEdge(text.index(range.upperBound, offsetBy: 2))) {
                    return true
                }
            }
            start = text.index(after: range.lowerBound)
        }
        return false
    }
}

// MARK: The projects' own words

nonisolated extension SortingProjects {
    /// The words of each candidate that no other candidate has. They come from its name,
    /// its description and its file names: Chinese words of two characters or more,
    /// English words of four letters or more and acronyms of three capitals, without
    /// common words and without the words of the user's own addresses. The words the user
    /// gave for a project always count, unless the user gave the same word for another
    /// project too.
    static func distinctiveWords(_ candidates: [SortingCandidate], ownAddresses: Set<String>) -> [UUID: [String]] {
        let own = ownWords(ownAddresses)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        let found: [Set<String>] = candidates.map { candidate in
            let fileNames = candidate.fileNames.map { ($0 as NSString).deletingPathExtension }
            let source = ([candidate.name, candidate.description] + fileNames).joined(separator: "\n")
            return Set(tokens(source, tokenizer: tokenizer).compactMap(word)).subtracting(own)
        }
        let given: [Set<String>] = candidates.map { candidate in
            Set(candidate.keywords.map(SortingText.matchingForm).filter { $0.count >= 2 })
        }
        var result: [UUID: [String]] = [:]
        for (index, candidate) in candidates.enumerated() {
            var words = found[index]
            var keywords = given[index]
            for other in candidates.indices where other != index {
                words.subtract(found[other])
                words.subtract(given[other])
                keywords.subtract(given[other])
            }
            result[candidate.id] = words.union(keywords).sorted()
        }
        return result
    }

    /// A token as a project word, lowercased, or nil when it does not count.
    private static func word(_ token: String) -> String? {
        if token.allSatisfy(\.isHan) {
            return token.count >= 2 && !commonChinese.contains(token) ? token : nil
        }
        guard token.allSatisfy(\.isASCIILetter) else { return nil }
        let lowered = token.lowercased()
        if token.count >= 4 {
            return commonEnglish.contains(lowered) ? nil : lowered
        }
        return token.count == 3 && token.allSatisfy(\.isUppercase) ? lowered : nil
    }

    /// Words from the user's own addresses, such as the name of their own company, which
    /// many emails hold whatever their project.
    private static func ownWords(_ addresses: Set<String>) -> Set<String> {
        var words = Set<String>()
        for address in addresses {
            guard let at = address.lastIndex(of: "@") else { continue }
            var host = address[address.index(after: at)...]
            // The top level domain names nothing.
            if let dot = host.lastIndex(of: ".") {
                host = host[..<dot]
            }
            let parts = (String(address[..<at]) + "." + String(host)).lowercased().split(whereSeparator: { !$0.isASCIILetter })
            for part in parts where part.count >= 3 {
                words.insert(String(part))
            }
        }
        return words
    }

    /// The words of a text: each run of Chinese characters segmented with the tokenizer on
    /// its own, since NLTokenizer drops most Chinese words when Chinese and English share a
    /// string (phase 0), and the rest split at every character that is not a letter or a
    /// digit.
    private static func tokens(_ text: String, tokenizer: NLTokenizer) -> [String] {
        let text = text.precomposedStringWithCompatibilityMapping
        var tokens: [String] = []
        var run = ""
        var runIsHan = false
        func flush() {
            guard !run.isEmpty else { return }
            if runIsHan {
                tokenizer.string = run
                tokens += tokenizer.tokens(for: run.startIndex..<run.endIndex).map { String(run[$0]) }
            } else {
                tokens += run.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            }
            run = ""
        }
        for character in text {
            if character.isHan != runIsHan {
                flush()
                runIsHan = character.isHan
            }
            run.append(character)
        }
        flush()
        return tokens
    }

    /// Chinese words that many project descriptions and emails hold.
    private static let commonChinese: Set<String> = [
        "项目", "对方", "公司", "客户", "中文", "英文", "写中文", "写英文", "一起", "包括", "合同",
        "设计", "供应商", "示例", "跟进", "业务", "自有", "产品", "工作室", "经理", "负责", "负责人",
        "我们", "他们", "你们", "这个", "那个", "以及", "还有", "需要", "已经", "可以", "进行",
        "相关", "工作", "邮件", "文件", "资料", "时间", "问题", "事情", "联系", "沟通", "方案",
        "计划", "安排", "确认", "通知", "附件", "今年", "明年", "下周", "本周", "老师", "您好",
        "谢谢", "更新", "版本", "修改", "最终", "草稿",
    ]

    /// English words of four letters or more that many project descriptions and emails
    /// hold.
    private static let commonEnglish: Set<String> = [
        "about", "after", "also", "been", "before", "both", "could", "does", "done", "each",
        "from", "have", "here", "into", "just", "like", "made", "make", "many", "more", "most",
        "much", "need", "needs", "only", "other", "over", "same", "should", "some", "such",
        "than", "that", "their", "them", "then", "there", "they", "this", "very", "want",
        "were", "what", "when", "where", "which", "while", "will", "with", "would", "your",
        "client", "clients", "company", "contact", "team", "studio", "project", "projects",
        "work", "works", "write", "writes", "written", "english", "chinese", "language",
        "email", "emails", "mail", "message", "please", "thanks", "thank", "regards", "hello",
        "dear", "best", "manager", "owner", "people", "person", "help", "update", "updates",
        "draft", "drafts", "note", "notes", "list", "plan", "plans", "file", "files",
        "document", "documents", "version", "final", "review", "meeting", "call", "week",
        "month", "year", "today", "tomorrow", "next", "last", "first", "time", "date", "dates",
        "change", "changes", "send", "sent", "reply", "attached", "attachment", "copy", "scan",
        "talk", "give", "gives",
    ]
}

/// The forms of text that sorting compares.
nonisolated enum SortingText {
    /// The text without invisible format characters, such as zero width spaces, soft
    /// hyphens and direction marks.
    static func withoutFormatCharacters(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar.properties.generalCategory != .format {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Full width letters made plain, format characters dropped, lowercased, and every run
    /// of white space made one space, with none at either end.
    static func matchingForm(_ text: String) -> String {
        withoutFormatCharacters(text.precomposedStringWithCompatibilityMapping)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// An address or a domain as sorting compares it: trimmed and lowercased.
    static func address(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
