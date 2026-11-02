import Foundation

/// Decides in code whether an email needs a reply, and in which language the draft is
/// written. Code step 1 of phase 0, its largest single gain: the reply decision went from
/// 62 to 88 right of 105, and the reply language from 42 to 49 right of 50.
///
/// A reply is due only when the email plausibly asks the user for something. None is due
/// when the user sent the email, when the user answered it later in its thread, for list
/// mail, for mail that none of the user's addresses gets in To and that does not name the
/// user, and for a forward whose sender asks the user nothing. Otherwise the draft is in the
/// language of the email's own text, Chinese or English, read with
/// `ProjectsLanguage.reading(_:)` without the lines that PromptHygiene takes out, so a fake
/// English system line in a Chinese email does not turn the reply into English. An email in
/// another language needs a reply but gets no draft.
/// Of an email that forwards a message, only the sender's own words count, see
/// `QuotedHistory.sendersWords(in:subject:)`, so a Chinese note over a forwarded English
/// mail gets a Chinese draft, and the footer of a forwarded newsletter makes it no list
/// mail.
nonisolated struct ReplyRule: Sendable, Equatable {
    /// Another message of the email's thread.
    nonisolated struct Message: Sendable, Equatable {
        /// The sender's address.
        var sender: String
        var date: Date
    }

    nonisolated enum NoReplyReason: String, Sendable, Equatable, Codable {
        /// The user sent the email.
        case sentByUser
        /// The user answered it later in the thread.
        case answeredLater
        /// It went out to a list or came from a machine.
        case listMail
        /// None of the user's addresses is in To, and the text does not name the user: the
        /// user is only in Cc, or the email went to other people or to a group.
        case notAddressed
        /// It forwards a message, and the sender's own note asks the user nothing.
        case forwardedNotice
    }

    nonisolated enum Decision: Sendable, Equatable, Codable {
        case noReply(NoReplyReason)
        /// A reply is due. The language is zh or en for a draft, or other for an email that
        /// gets no draft.
        case reply(ProjectsLanguage)

        /// The language of the draft, or nil when no draft is written.
        var draftLanguage: ProjectsLanguage? {
            if case .reply(let language) = self, language != .other {
                return language
            }
            return nil
        }
    }

    /// The user's own addresses, normalized.
    let ownAddresses: Set<String>
    /// The forms of the user's name that a text addresses the user by, see
    /// `nameForms(_:)`.
    let ownNames: [String]

    /// - Parameter ownName: the user's name, as Mail's accounts give it, or nil.
    init(ownAddresses: [String], ownName: String? = nil) {
        self.ownAddresses = Set(ownAddresses.compactMap(ProjectsAddress.normalized))
        ownNames = ownName.map(Self.nameForms) ?? []
    }

    /// The decision for one email.
    /// - Parameters:
    ///   - sender: the email's sender, an address or "Name <address>".
    ///   - to: its To addresses, in the same forms.
    ///   - cc: its Cc addresses.
    ///   - date: when the email was sent or received.
    ///   - thread: the other messages of its thread.
    ///   - list: its list headers.
    ///   - text: its own text, raw or already through PromptHygiene. It is cleaned here,
    ///     which changes nothing in text that was cleaned before.
    ///   - subject: its subject, read for the language when the text has no letters.
    func decision(sender: String, to: [String], cc: [String], date: Date, thread: [Message], list: ListMail, text: String, subject: String) -> Decision {
        let address = ProjectsAddress.normalized(sender)
        if isOwn(address) {
            return .noReply(.sentByUser)
        }
        if thread.contains(where: { $0.date > date && isOwn(ProjectsAddress.normalized($0.sender)) }) {
            return .noReply(.answeredLater)
        }
        let split = QuotedHistory(splitting: text, subject: subject)
        let readable = Self.readable(QuotedHistory.sendersWords(in: text, split: split))
        if list.sign(sender: address ?? "", text: readable) != nil {
            return .noReply(.listMail)
        }
        if !isAddressed(to: to, cc: cc, text: readable) {
            return .noReply(.notAddressed)
        }
        if !split.forwards.isEmpty, !Self.asks(Self.readable(split.note)) {
            return .noReply(.forwardedNotice)
        }
        return .reply(Self.language(text: readable, subject: subject))
    }

    /// The language of the text, or of the subject when the text has no letters. Text and
    /// subject without letters give other.
    static func language(text: String, subject: String) -> ProjectsLanguage {
        if hasLetters(text) {
            return ProjectsLanguage.reading(text)
        }
        let subject = readable(subject)
        return hasLetters(subject) ? ProjectsLanguage.reading(subject) : .other
    }

    /// Whether the email is meant for the user: one of the user's addresses is in To, also
    /// with a tag after +, or the text names the user. Without the user's addresses, or with
    /// neither To nor Cc, such as mail to undisclosed recipients, it cannot tell, and says
    /// yes. It reads the recipients that sorting reads, To first, see
    /// `SortingService.maximumRecipients`, so the mark in the list and the draft agree.
    private func isAddressed(to: [String], cc: [String], text: String) -> Bool {
        let read = to.prefix(SortingService.maximumRecipients)
        let to = read.compactMap(ProjectsAddress.normalized)
        let cc = cc.prefix(SortingService.maximumRecipients - read.count).compactMap(ProjectsAddress.normalized)
        guard !ownAddresses.isEmpty, !(to.isEmpty && cc.isEmpty) else { return true }
        let own = Set(ownAddresses.map(Self.untagged))
        return to.contains { own.contains(Self.untagged($0)) } || names(text)
    }

    /// The address without a tag after + in its local part, as bai.lu+print@lumenhaus.example
    /// reaches bai.lu@lumenhaus.example.
    private static func untagged(_ address: String) -> String {
        guard let at = address.lastIndex(of: "@"), let plus = address[..<at].firstIndex(of: "+") else { return address }
        return String(address[..<plus] + address[at...])
    }

    /// Whether the text holds a form of the user's name: a form in Latin letters as a word
    /// of its own, in any case, and a form in other letters anywhere, since Chinese and
    /// Japanese write a title or an honorific right after a name, as in さくらさん.
    private func names(_ text: String) -> Bool {
        let text = text.precomposedStringWithCompatibilityMapping.lowercased()
        return ownNames.contains { name in
            name.unicodeScalars.allSatisfy(ProjectsLanguage.isLatin) ? Self.containsWord(text, name) : text.contains(name)
        }
    }

    private func isOwn(_ address: String?) -> Bool {
        address.map(ownAddresses.contains) ?? false
    }

    /// The forms of a name that address its bearer, lowercased: each part of two letters
    /// or more, and for a Chinese name its pinyin, which English mail writes, by syllable
    /// and as one word, as in Xiaoming for 小明, its given name when it has three characters
    /// or more, and its family name with a title, as in 白老师.
    static func nameForms(_ name: String) -> [String] {
        var forms: [String] = []
        let parts = name.precomposedStringWithCompatibilityMapping.lowercased()
            .split { !$0.isLetter }.map(String.init)
        for part in parts where part.count >= 2 {
            forms.append(part)
            guard part.contains(where: \.isHan) else { continue }
            let isChineseName = part.allSatisfy(\.isHan) && part.count <= 4
            if isChineseName {
                if part.count >= 3 {
                    forms.append(String(part.dropFirst()))
                }
                forms += titles.map { String(part.prefix(1)) + $0 }
            }
            let pinyin = part.applyingTransform(.mandarinToLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false) ?? ""
            let syllables = pinyin.lowercased().split { !$0.isASCIILetter }.map(String.init)
            forms += syllables.filter { $0.count >= 2 }
            if isChineseName, syllables.count == part.count {
                // The whole name and the given name as one word, as in Bailu and Xiaoming.
                forms.append(syllables.joined())
                if part.count >= 3 {
                    forms.append(syllables.dropFirst().joined())
                }
            }
        }
        var seen = Set<String>()
        return forms.filter { seen.insert($0).inserted }
    }

    /// Titles that follow a Chinese family name when people address its bearer.
    private static let titles = ["老师", "教授", "博士", "先生", "女士", "小姐", "总", "经理", "主任", "同学"]

    /// Whether the text asks its reader something: a question mark, or wording that asks
    /// for an answer, a decision or an action, in English, Chinese, Japanese or Spanish.
    /// Wording that only passes something on, such as "please see below" or 请查收, does
    /// not ask.
    static func asks(_ text: String) -> Bool {
        text.contains { "?？¿".contains($0) } || requestWording.contains { text.firstMatch(of: $0) != nil }
    }

    // Built once rather than for every email.
    nonisolated(unsafe) private static let requestWording: [Regex<Substring>] = [
        /\b(?:can|could|would|will)\s+(?:you|u)\b/.ignoresCase(),
        /\blet\s+(?:me|us)\s+know\b/.ignoresCase(),
        /\bplease\b(?!\s+(?:see|find|note|read)\b)/.ignoresCase(),
        /\b(?:pls|plz|kindly|reply|respond|confirm|rsvp|approve|sign|decide|handle|asap)\b/.ignoresCase(),
        /\b(?:need|want)s?\s+(?:you|your|u|this|it)\b/.ignoresCase(),
        /\b(?:take|have)\s+a\s+look\b|\bfollow\s+up\b/.ignoresCase(),
        /\byour\s+(?:thoughts|feedback|input|comments?|opinion|views?|decision|approval|answer|help)\b/.ignoresCase(),
        /请(?!知悉|参考|查收|查阅|见|看下面|看以下|看附件)/,
        /麻烦|劳驾|拜托|烦请|务必|尽快|能否|可否|能不能|可不可以|需要你|需要您|帮忙|帮我|看看|看下|一下|处理|跟进|过目|定夺|回复|答复|回信|告知|确认|反馈/,
        /ください|下さい|お願い|いただけ|頂け|ますか|でしょうか/,
        /\bpor\s+favor\b|\bpodr[ií]as?\b|\bpuedes\b|\bfavor\s+de\b|\bconfirm[ae]\b|\bresp[oó]nde\b|\bav[ií]same\b|\bme\s+avisas\b/.ignoresCase(),
    ]

    /// The text through PromptHygiene, without its markers.
    private static func readable(_ text: String) -> String {
        PromptHygiene.withoutMarkers(PromptHygiene(text, source: .mail).text)
    }

    /// Whether the text holds the word with no letter or digit joined to it.
    private static func containsWord(_ text: String, _ word: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: word, range: start..<text.endIndex) {
            let joinedBefore = range.lowerBound > text.startIndex && isLetterOrDigit(text[text.index(before: range.lowerBound)])
            let joinedAfter = range.upperBound < text.endIndex && isLetterOrDigit(text[range.upperBound])
            if !joinedBefore && !joinedAfter {
                return true
            }
            start = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isLetterOrDigit(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func hasLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic }
    }
}
