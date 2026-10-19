import Foundation

/// The signs that an email went out to a list or came from a machine rather than a person:
/// the List-Id, List-Unsubscribe and Precedence headers, a sender such as noreply@, and
/// the wording of an unsubscribe footer.
///
/// The caller passes the header values plain, unfolded and decoded. The senders and the
/// footer wording follow the phase 0 prototype (match.py), which set aside all 9 list mails
/// of the synthetic set and no project mail. Sorting sets list mail aside only when no
/// project person is in it, see SortingPolicy.
nonisolated struct ListMail: Sendable, Equatable {
    /// Why an email counts as list mail, strongest first.
    nonisolated enum Sign: String, Sendable, Codable, CaseIterable {
        case listID
        case listUnsubscribe
        case bulkPrecedence
        case noReplySender
        case unsubscribeText
    }

    /// The List-Id header, or nil without one.
    var listID: String?
    /// The List-Unsubscribe header, or nil without one.
    var listUnsubscribe: String?
    /// The Precedence header, or nil without one.
    var precedence: String?

    /// Empty values count as no header.
    init(listID: String? = nil, listUnsubscribe: String? = nil, precedence: String? = nil) {
        self.listID = Self.present(listID)
        self.listUnsubscribe = Self.present(listUnsubscribe)
        self.precedence = Self.present(precedence)
    }

    /// The three headers from an email's headers as name and value pairs, with the names
    /// in any case. The first header of each name counts.
    init(headers: [(name: String, value: String)]) {
        func first(_ name: String) -> String? {
            headers.first { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        self.init(listID: first("List-Id"), listUnsubscribe: first("List-Unsubscribe"), precedence: first("Precedence"))
    }

    /// The list's identifier from List-Id, the part in angle brackets, lowercased, or nil
    /// without the header. A rule for a mailing list compares this.
    var listIdentifier: String? {
        listID.flatMap(Self.identifier)
    }

    /// The strongest sign that the email is list mail, or nil when there is none.
    /// `sender` is the sender's lowercased address and `text` the email's own text.
    func sign(sender: String, text: String) -> Sign? {
        if listIdentifier != nil {
            return .listID
        }
        if listUnsubscribe != nil {
            return .listUnsubscribe
        }
        if let precedence, Self.bulkPrecedences.contains(precedence.trimmingCharacters(in: .whitespaces).lowercased()) {
            return .bulkPrecedence
        }
        if Self.isNoReplySender(sender) {
            return .noReplySender
        }
        if Self.hasUnsubscribeText(text) {
            return .unsubscribeText
        }
        return nil
    }

    /// The identifier in a List-Id value such as `Weekly <weekly.list.example>`: the part in
    /// the last angle brackets, or the whole value without them, lowercased.
    static func identifier(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.lastIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
            text = String(text[text.index(after: open)..<close])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.isEmpty ? nil : text
    }

    /// Whether the address is a sender that people do not write from, such as noreply@,
    /// newsletter@ or billing@. A tag after + is ignored. Only the whole local part counts,
    /// so bill.chen@ is a person.
    static func isNoReplySender(_ address: String) -> Bool {
        guard let at = address.lastIndex(of: "@") else { return false }
        var local = address[..<at].lowercased()
        if let plus = local.firstIndex(of: "+") {
            local = String(local[..<plus])
        }
        if local.firstMatch(of: /^(no|do[-_.]?not)[-_.]?reply/) != nil {
            return true
        }
        return bulkSenders.contains(local)
    }

    /// Whether the text holds the wording of an unsubscribe footer or of a message sent by
    /// a system, in English or Chinese.
    static func hasUnsubscribeText(_ text: String) -> Bool {
        let english = /\b(unsubscrib\w*|do[ -]not[ -]reply|automated (message|e-?mail|notification))\b/.ignoresCase()
        let chinese = /退订|取消订阅|请勿(直接)?回复|(本|此|该)(邮件|信|消息)[^。\n]{0,8}自动(发送|生成)/
        return text.firstMatch(of: english) != nil || text.firstMatch(of: chinese) != nil
    }

    private static let bulkPrecedences: Set<String> = ["bulk", "list", "junk"]

    /// Local parts of senders that send to many people. Names people use, such as hello,
    /// info or bill, are left out.
    private static let bulkSenders: Set<String> = [
        "newsletter", "newsletters", "news", "digest", "updates",
        "notification", "notifications", "notify", "notice", "notices", "alert", "alerts",
        "promo", "promos", "promotions", "marketing", "offers", "deals", "events",
        "alumni", "jobs", "careers", "cfp",
        "billing", "receipt", "receipts", "order", "orders", "renew", "renewal", "renewals",
        "mailer-daemon", "postmaster", "bounce", "bounces",
    ]

    private static func present(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
