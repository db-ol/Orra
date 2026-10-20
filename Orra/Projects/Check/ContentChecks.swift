import Foundation

/// Warnings about what an email says or carries, found in code, so the user sees them even
/// when the model leaves them out:
/// - `link`: a web address, a Markdown link or image, or an HTML tag that links or loads
/// - `paymentChange`: a new account or another change of where to pay
/// - `paymentTermsChange`: a payment moved earlier, made in full at once, or other new terms
/// - `unknownSenderPayment`: talk of payment from a sender who is not among the people the
///   user knows
/// - `credentialRequest` and `personalDataRequest`: words for passwords and codes, and for
///   ID, passport and card numbers and other personal data
/// - `attachmentNameSpoofing`: an attachment that runs code or hides its type behind
///   direction controls
/// - `forgedQuote`: words given as the user's own, quoted, forwarded or said, that match
///   nothing the user sent
///
/// The checks read the email's visible text with its quoted history, since a forged quote
/// sits there. They look for words, not intent, so a notice that mentions a password counts
/// as well as a request for one. There is no pattern for script text in a subject or a
/// name, since Orra never builds script text. They read the first `checkedLength`
/// characters of the text and of the subject, and every pattern is bounded, so a hostile
/// email cannot make them slow. The phase 0 prototype (common.py, `content_checks`) is the
/// reference.
nonisolated enum ContentChecks {
    nonisolated struct Input: Sendable, Equatable {
        /// An attachment's name and MIME type, as the email gives them.
        nonisolated struct Attachment: Sendable, Equatable {
            var name: String
            var type: String
        }

        var subject: String
        /// The email's visible text, with its quoted history.
        var text: String
        var attachments: [Attachment] = []
        /// Whether the sender is among the people the user listed for a project or wrote
        /// with before, or at a domain the user listed.
        var senderIsKnown: Bool
        /// The user's own names and addresses.
        var own: [SenderChecks.Person] = []
        /// The text of the mail the user sent, or nil when Orra does not read the user's
        /// sent mail, which leaves quotes unchecked. Quotes of mail older than what Orra
        /// read count as not found.
        var sentTexts: [String]? = nil
    }

    /// The text and the subject are read this far. Mail text this long is rare, and a
    /// warning in it is shown well before.
    static let checkedLength = 65_536

    /// The warnings about the email, in the order of `ProjectsWarning.allCases`. Off the
    /// main actor, since the text may be long.
    @concurrent
    static func warnings(for input: Input) async -> [ProjectsWarning] {
        let text = plain(String(input.text.prefix(checkedLength)))
        let subject = plain(String(input.subject.prefix(checkedLength)))
        let flat = SortingText.matchingForm(subject + "\n" + text)
        var warnings: Set<ProjectsWarning> = []
        if !linkRanges(in: subject + "\n" + text).isEmpty {
            warnings.insert(.link)
        }
        if matches(paymentChange, flat) {
            warnings.insert(.paymentChange)
        }
        if matches(paymentTerms, flat) {
            warnings.insert(.paymentTermsChange)
        }
        if !input.senderIsKnown, matches(paymentWords, flat) {
            warnings.insert(.unknownSenderPayment)
        }
        if matches(credentials, flat) {
            warnings.insert(.credentialRequest)
        }
        if matches(personalData, flat) {
            warnings.insert(.personalDataRequest)
        }
        if input.attachments.contains(where: isRisky) {
            warnings.insert(.attachmentNameSpoofing)
        }
        if let sent = input.sentTexts, hasForgedQuote(in: text, own: input.own, sent: sent) {
            warnings.insert(.forgedQuote)
        }
        return ProjectsWarning.allCases.filter(warnings.contains)
    }

    // MARK: Links

    /// Where `text` holds a link: a web address with a scheme or www, a host with a path,
    /// a host under a common top level domain, a Markdown link or image, or an HTML tag
    /// that links or loads. Email addresses are no links. A full stop or comma at the end
    /// belongs to the sentence. Overlapping finds are merged.
    static func linkRanges(in text: String) -> [Range<String.Index>] {
        let whole = NSRange(text.startIndex..., in: text)
        return merged(linkPatterns.flatMap { $0.matches(in: text, range: whole) }.compactMap { match in
            guard var range = Range(match.range, in: text) else { return nil }
            while range.upperBound > range.lowerBound, ".,;:!?".contains(text[text.index(before: range.upperBound)]) {
                range = range.lowerBound..<text.index(before: range.upperBound)
            }
            return range.isEmpty ? nil : range
        })
    }

    /// The ranges in the order of the text, with overlapping and touching ones joined.
    static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var merged: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The characters a web address may hold, from RFC 3986, so an address ends at the
    /// Chinese text after it.
    private static let urlCharacters = #"[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]"#

    private static let linkPatterns: [NSRegularExpression] = [
        // A scheme, such as https://, javascript: or mailto:
        #"(?<![A-Za-z0-9])(?:https?|ftps?|file|data|javascript|vbscript|mailto|tel|sms|webcal|hxxps?):"# + urlCharacters + "+",
        // Markdown images and links, reference style too. The bounds keep the patterns
        // fast on a hostile text, as one of many "![" in a row.
        #"!\[[^\]\n]{0,200}+\]\s{0,3}+[(\[][^)\]\n]{0,500}+[)\]]"#,
        #"\[[^\]\n]{0,200}+\]\([^)\n]{0,500}+\)"#,
        // HTML tags that link or load, so not <a.mara@studio.example>
        #"</?(?:a|img|iframe|object|embed|link|script|svg|video|audio|source|form|base|meta)(?=[\s>/])[^>\n]{0,500}+>"#,
        // www.
        #"(?<![A-Za-z0-9@.-])www\."# + urlCharacters + "+",
        // A host with a path
        #"(?<![A-Za-z0-9_@.-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,24}(?::\d{1,5})?/"# + urlCharacters + "*",
        // A host under a common top level domain. Not ai, app or cc, which are also file
        // names such as logo-v2.ai, Viewer.app and main.cc. With a scheme, www or a path they
        // count.
        #"(?<![A-Za-z0-9_@.-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+(?:com|net|org|cn|io|co|uk|de|jp|hk|tw|sg|info|biz|me|dev|xyz|top|site|online|example|edu|gov|ly|gl|gg|to|tv|link|click|shop|store|ru|us|ca|au|fr|nl|eu|vip|club|live)(?![A-Za-z0-9_@-])"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    // MARK: Words

    /// The text in compatibility form, so full width letters and digits read as plain
    /// ones, without format characters such as zero width spaces.
    private static func plain(_ text: String) -> String {
        SortingText.withoutFormatCharacters(text.precomposedStringWithCompatibilityMapping)
    }

    /// Whether one of the patterns matches the text.
    static func matches(_ patterns: [NSRegularExpression], _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Builds patterns that read the matching form of `SortingText`: lowercase, on one
    /// line, with full width punctuation such as ，and ！ made plain.
    static func patterns(_ sources: [String]) -> [NSRegularExpression] {
        sources.map { try! NSRegularExpression(pattern: $0) }
    }

    private static let paymentChange = patterns([
        #"(?:新|变更|更换|更改|换了?|改用|调整|启用)[^。!?]{0,10}(?:账户|账号|帐户|帐号|收款|银行卡|卡号|开户行)"#,
        #"(?:账户|账号|帐户|帐号|收款(?:账户|账号|信息|方|人)|银行卡|开户行)[^。!?]{0,10}(?:变更|更换|更改|改为|改成|换成|换为|调整|停用|作废|注销|冻结)"#,
        #"(?:转|打|汇|付|存)(?:至|到|入|进)[^。!?]{0,8}新的?(?:账户|账号|帐户|帐号|卡)"#,
        #"发票[^。!?]{0,12}(?:开给|开到|改开|改抬头)[^。!?]{0,12}新"#,
        #"\bnew (?:bank |banking |beneficiary |receiving |payment |remittance )?(?:account|bank details|banking details|beneficiary|iban|payee|payment details|remittance details|wire instructions)\b"#,
        #"\b(?:bank|banking|account|payment|wire|remittance|beneficiary) (?:details|information|info|instructions|account) (?:have|has) (?:been )?(?:changed|updated|moved)\b"#,
        #"\b(?:changed|updated|switched|moved) (?:our |my |the )?(?:bank|banking|bank account|payment account|receiving account|payment details|remittance details)\b"#,
        #"\b(?:old|previous|former) (?:bank )?account\b[^.!?]{0,40}\b(?:closed|no longer|not be used|invalid|suspended)"#,
        #"\bplease (?:pay|transfer|wire|remit|send (?:the )?(?:payment|funds))\b[^.!?]{0,40}\bnew\b"#,
    ])

    private static let paymentTerms = patterns([
        #"(?:付款|尾款|定金|订金|首付|首款|余款|款项|货款|进度款|费用|账期|结算)(?:(?!账户|账号|帐户|帐号|收款)[^。!?]){0,16}(?:改为|改成|调整为|调整成|变更为|改到|提前|一次性?(?:付清|结清|支付)|先付|全额(?:支付|付款|预付)|预付)"#,
        #"(?:提前|一次性|全额)[^。!?]{0,6}(?:付清|结清|支付|付款)"#,
        #"(?:付款|结算)(?:方式|条件|比例|节点|时间)[^。!?]{0,6}(?:调整|变更|改)"#,
        #"\b(?:payment|balance|deposit|invoice|fee|instal(?:l)?ment|remaining amount|final payment)s?\b[^.!?]{0,40}\b(?:now due|due (?:now|immediately|today|earlier|before|upfront|in advance)|in advance|upfront|up front|earlier than (?:agreed|planned)|moved (?:up|forward)|brought forward|(?:has|have) (?:been )?changed|instead of)"#,
        #"\b(?:pay|settle|transfer) (?:the )?(?:full|entire|whole|remaining|total) (?:amount|balance|fee|sum|payment) (?:now|today|upfront|up front|in advance|before)\b"#,
        #"\b(?:new|changed|updated|revised) (?:payment )?terms\b"#,
    ])

    private static let paymentWords = patterns([
        #"发票|付款|转账|汇款|续费|账单|缴费|支付|收款|打款|欠费|逾期"#,
        #"\b(?:invoices?|payments?|pay|paid|wire|bank transfer|remit|remittance|billing|(?:your|the|this) bill|bills? (?:for|of)|overdue|amount due|balance due)\b"#,
    ])

    private static let credentials = patterns([
        #"密码|口令|验证码|校验码|动态码|登录(?:信息|凭证|账号)|账号(?:和|与|及)密码"#,
        #"\bpass(?:word|code|phrase)s?\b|\bverification code\b|\bone[- ]time (?:code|password|passcode|pin)\b|\botp\b|\b2fa\b|\bsecurity code\b|\bcredentials\b"#,
        #"\b(?:log ?in|sign[- ]?in) (?:details|credentials|information|info)\b|\b(?:bank|account|email|mail|portal) log ?in\b|\bverify your (?:account|identity|login|password|credentials)\b|\bpin (?:code|number)\b"#,
    ])

    private static let personalData = patterns([
        #"身份证|护照|证件|出生日期|户口|社保(?:号|卡)|驾照|驾驶证|银行卡号|信用卡|卡号|家庭住址|家庭地址|门锁密码|入户门?锁?密码|门禁(?:密码|码|卡)|房产证|结婚证"#,
        #"\bpassport\b|\b(?:id|identity|identification) (?:card|number|document|photo|copy)\b|\bdate of birth\b|\bbirth ?date\b|\bdob\b|\bsocial security\b|\bssn\b|\bdriver['’]?s licen[cs]e\b"#,
        #"\b(?:credit |debit |bank )?card (?:number|details)\b|\bcvv\b|\bcvc\b|\bhome address\b|\bdoor (?:code|pin)\b|\btax (?:id|number)\b"#,
    ])

    // MARK: Attachments

    /// Whether an attachment runs code, by its last extension or its MIME type, or hides
    /// its type behind direction controls, as a name that ends in a right to left override
    /// and fdp.exe shows as exe.pdf.
    private static func isRisky(_ attachment: Input.Attachment) -> Bool {
        if attachment.name.unicodeScalars.contains(where: { directionControls.contains($0.value) }) {
            return true
        }
        let name = plain(attachment.name).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = name.lastIndex(of: "."),
           riskyExtensions.contains(name[name.index(after: dot)...].trimmingCharacters(in: .whitespaces)) {
            return true
        }
        let type = attachment.type.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return executableTypes.contains(type)
    }

    private static let directionControls: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

    private static let riskyExtensions: Set<String> = [
        "exe", "scr", "bat", "cmd", "com", "pif", "msi", "msp", "js", "jse", "vbs", "vbe", "wsf", "wsh", "hta",
        "jar", "ps1", "psm1", "sh", "command", "app", "pkg", "dmg", "apk", "lnk", "reg", "cpl", "iso", "img",
        "vhd", "scf", "docm", "xlsm", "pptm",
    ]

    private static let executableTypes: Set<String> = [
        "application/x-msdownload", "application/x-msdos-program", "application/x-msi", "application/x-executable",
        "application/x-dosexec", "application/vnd.microsoft.portable-executable", "application/x-sh", "application/x-csh",
        "application/x-apple-diskimage", "application/java-archive", "application/x-java-archive", "application/hta",
        "application/x-ms-shortcut", "application/javascript", "text/javascript", "application/x-bat",
    ]

    // MARK: Quotes

    /// Whether the text gives words as the user's own that the user's sent mail does not
    /// hold: a quoted line such as "> 白露：同意" or "> Bai Lu: agreed", the quoted lines
    /// under an "On … Bai Lu wrote:" line, the text of a forwarded message from the user,
    /// and words in quotes after "you said" or "您说过". A claim matches when the first 20
    /// letters and digits of it stand in one sent text. A text with more than
    /// `mostClaims` different claims counts as forged, since no real thread quotes the
    /// user that often and comparing them all would take long.
    private static func hasForgedQuote(in text: String, own: [SenderChecks.Person], sent: [String]) -> Bool {
        let names = Set(own.flatMap { SenderChecks.nameForms($0.name) })
        let addresses = Set(own.compactMap { ProjectsAddress.normalized($0.address) })
        var probes: Set<String> = []
        for claim in claims(in: text, names: names, addresses: addresses) {
            let form = quoteForm(claim)
            if form.count >= 4 {
                probes.insert(String(form.prefix(20)))
            }
        }
        guard probes.count <= mostClaims else { return true }
        let sentForms = sent.map(quoteForm)
        return probes.contains { probe in !sentForms.contains { $0.contains(probe) } }
    }

    /// The most claims a text may hold before it counts as forged.
    static let mostClaims = 100

    /// The lines read after a quote header or a From line, enough for the 20 letters and
    /// digits a claim is compared by.
    private static let claimLines = 20

    /// The letters and digits of a text, lowercase, which ignores how a quote was wrapped
    /// and punctuated.
    private static func quoteForm(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The words the text gives as the user's own.
    private static func claims(in text: String, names: Set<String>, addresses: Set<String>) -> [String] {
        let lines = text.lowercased().split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var claims: [String] = []
        let terms = names.union(addresses)
        func namesUser(_ line: String) -> Bool {
            terms.contains { !SenderChecks.occurrences(of: $0, in: line).isEmpty }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let body = unquoted(line)
            // > 白露：同意 and > Bai Lu: agreed. Only a quoted line, since an unquoted one is
            // more often a task list, as in 白露：确认瓷砖颜色.
            if line.drop(while: \.isWhitespace).first == ">" {
                for name in names where body.hasPrefix(name) {
                    let rest = body.dropFirst(name.count).drop(while: { $0 == " " })
                    if rest.first == ":" {
                        claims.append(String(rest.dropFirst()))
                    }
                }
            }
            // On … Bai Lu <…> wrote:, then quoted lines
            if namesUser(line), matches([quoteHeader], body) {
                var quoted: [String] = []
                var next = index + 1
                while next < min(lines.count, index + 1 + claimLines), lines[next].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(unquoted(lines[next]))
                    next += 1
                }
                claims.append(quoted.joined(separator: " "))
            }
            // A forwarded or quoted message from the user: 发件人：白露, then its text
            if let match = fromHeader.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
               let value = Range(match.range(at: 1), in: body), namesUser(String(body[value])) {
                var next = index + 1
                while next < min(lines.count, index + 1 + claimLines), matches([messageHeader], unquoted(lines[next])) {
                    next += 1
                }
                var message: [String] = []
                let last = min(lines.count, next + claimLines)
                while next < last {
                    var part = unquoted(lines[next])
                    if part.isEmpty, !message.isEmpty { break }
                    if let label = bodyLabel.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)),
                       let end = Range(label.range, in: part)?.upperBound {
                        part = String(part[end...])
                    }
                    if !part.isEmpty {
                        message.append(part)
                    }
                    next += 1
                }
                claims.append(message.joined(separator: " "))
            }
            index += 1
        }
        let speakers = (["you", "您", "你"] + names.map { NSRegularExpression.escapedPattern(for: $0) }).joined(separator: "|")
        let said = try! NSRegularExpression(pattern:
            #"(?<![a-z])(?:"# + speakers + #")(?![a-z])\s{0,3}(?:之前|上次|昨天|前天|刚才|在邮件里|在信里|在电话里)?\s{0,3}(?:说过?|写过?|讲过?|答应过?|同意过?|确认过?|said|wrote|agreed|confirmed|promised|told (?:me|us))(?:\s{0,3}(?:that|了|的是))?\s{0,3}[:,：，]?\s{0,3}["“'‘「『]([^"”'’」』]{4,300})["”'’」』]"#)
        let whole = text.lowercased()
        for match in said.matches(in: whole, range: NSRange(whole.startIndex..., in: whole)) {
            if let range = Range(match.range(at: 1), in: whole) {
                claims.append(String(whole[range]))
            }
        }
        return claims
    }

    /// A line without the quote marks and spaces at its start.
    private static func unquoted(_ line: String) -> String {
        String(line.drop(while: { $0 == ">" || $0.isWhitespace })).trimmingCharacters(in: .whitespaces)
    }

    private static let quoteHeader = try! NSRegularExpression(pattern: #"(?:\bwrote|写道)\s{0,3}:?$"#)
    private static let fromHeader = try! NSRegularExpression(pattern: #"^(?:发件人|from)\s*:\s*(.+)$"#)
    private static let messageHeader = try! NSRegularExpression(pattern: #"^(?:发件人|收件人|抄送|主题|日期|时间|发送时间|from|to|cc|subject|date|sent)\s*:"#)
    private static let bodyLabel = try! NSRegularExpression(pattern: #"^(?:内容|正文|content|body)\s*:\s*"#)
}
