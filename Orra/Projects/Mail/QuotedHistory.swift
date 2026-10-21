import Foundation

/// An email's own text, apart from the history it quotes and the signature at its end, with
/// the messages it forwards.
///
/// Quoted history is:
/// - every line that starts with ">", as plain text mail and VisibleText write quotes
/// - an attribution such as "On 12 Oct 2026, at 09:30, Mei Tan <mei.tan@orchard.example>
///   wrote:", "在 2026年10月12日 09:30，Mei Tan 写道：" or "Mei Tan 于2026年10月12日 09:30写道：",
///   which may wrap onto a second line. When quoted lines follow, only the attribution goes.
///   Otherwise everything after it is history, as some mail quotes without ">", but only for
///   an attribution with a date or an address, so a sentence such as "On Monday the printer
///   wrote:" keeps the rest of the email as own text
/// - everything from a separator line such as "-----Original Message-----" or
///   "-----原始邮件-----"
/// - everything from an Outlook header block: a From: or 发件人： line with a Sent:, Date:,
///   发送时间： or 日期： line within the next three lines
///
/// A forwarded message keeps its text, since the email is about it. It starts at a line
/// that holds only a forward marker, with or without dashes around it or a colon after it,
/// in English, Chinese, Japanese or Spanish, such as:
/// - "---------- Forwarded message ---------" (Gmail) and "---------- 转发的邮件 ---------"
///   or "---------- 已轉寄郵件 ----------" (Gmail in Chinese)
/// - "Begin forwarded message:" and "下面是被转发的邮件：" (Apple Mail)
/// - "-------- Forwarded Message --------" (Thunderbird, Yahoo) and "-------- 转发的消息
///   --------" (Thunderbird in Chinese)
/// - "-------- 转发邮件信息 --------" (NetEase 163 and 126)
///
/// Its header block follows: the lines that start with From, Date, Sent, Subject, To or Cc,
/// or 发件人, 日期, 时间, 发送时间, 发送日期, 主题, 收件人 or 抄送, in any order, which `forwards`
/// keeps apart from its text. Outlook, QQ Mail, Foxmail and some phones forward with the
/// separator or the header block of a reply, such as "-----Original Message-----" or
/// "------------------ 原始邮件 ------------------". So when the subject says the email is a
/// forward, with FW:, Fwd: or 转发： in front, the first separator or header block followed
/// by a header line starts the forwarded message, and a later one is that message's own
/// history. A header block within three lines of a line that names a forward stays own
/// text too, as Outlook writes some forwards.
///
/// `ownText` keeps the forwarded messages with their marker and header lines, so whatever
/// reads the email's text reads them too. `note` is the sender's own words before the first
/// of them. Splitting the own text again with the same subject gives the same forwards.
///
/// The signature is what follows the last "-- " line of the sender's own words, when it
/// holds 20 lines with text or fewer. A forwarded message keeps its own signature in its
/// text. A line of two dashes without the space is no signature line, since it often only
/// sets text apart. Blank lines in the own text stay as they are, so PromptHygiene still
/// finds text after a long run of them. Later checks for payment changes and other warnings
/// read the signature too, since it is the sender's text.
nonisolated struct QuotedHistory: Sendable, Equatable {
    /// A message the email forwards, with the values of its header block as the forwarding
    /// mail wrote them, such as "Mei Tan <mei.tan@orchard.example>" or "2026年10月12日 09:30".
    /// A value is empty when the block has no line for it.
    nonisolated struct Forward: Sendable, Equatable {
        var sender: String
        var date: String
        var subject: String
        var to: String
        var cc: String
        /// The forwarded message's text, without its marker and header lines and without
        /// the history it quotes.
        var text: String

        init(sender: String = "", date: String = "", subject: String = "", to: String = "", cc: String = "", text: String = "") {
            self.sender = sender
            self.date = date
            self.subject = subject
            self.to = to
            self.cc = cc
            self.text = text
        }
    }

    var ownText: String
    var quotedText: String
    var signature: String
    /// The sender's own words: the own text before the first forwarded message, without the
    /// signature. All of the own text when the email forwards nothing.
    var note: String
    /// The messages the email forwards, in their order. Their text is in `ownText` too.
    var forwards: [Forward]

    init(ownText: String, quotedText: String = "", signature: String = "", note: String? = nil, forwards: [Forward] = []) {
        self.ownText = ownText
        self.quotedText = quotedText
        self.signature = signature
        self.note = note ?? ownText
        self.forwards = forwards
    }

    /// Splits `text`, the visible text of an email with the subject `subject`.
    init(splitting text: String, subject: String = "") {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let isForward = Self.isForward(subject: subject)
        var own: [Substring] = []
        var quoted: [Substring] = []
        // Where each forwarded message starts in `own`, the number of its marker and header
        // lines, and the values of its header.
        var starts: [(at: Int, lines: Int, header: Forward)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if Self.isQuoted(line) {
                quoted.append(line)
                index += 1
                continue
            }
            if let forward = Self.forward(lines, at: index, bySubject: isForward && starts.isEmpty) {
                starts.append((own.count, forward.lines, forward.header))
                own += lines[index..<(index + forward.lines)]
                index += forward.lines
                continue
            }
            // The lines of the last forwarded message's marker and header stay its own.
            let kept = starts.last.map { $0.at + $0.lines } ?? 0
            if Self.isSeparator(line) || (Self.isHeaderBlock(lines, at: index) && !Self.followsForwardMarker(lines, at: index)) {
                Self.moveTrailingRules(from: &own, to: &quoted, keeping: kept)
                quoted += lines[index...]
                break
            }
            if let span = Self.attribution(lines, at: index) {
                let next = lines[(index + span)...].firstIndex { !$0.allSatisfy(\.isWhitespace) }
                if let next, Self.isQuoted(lines[next]) {
                    quoted += lines[index..<(index + span)]
                    index += span
                    continue
                }
                if lines[index..<(index + span)].contains(where: Self.hasDateOrAddress) {
                    Self.moveTrailingRules(from: &own, to: &quoted, keeping: kept)
                    quoted += lines[index...]
                    break
                }
            }
            own.append(line)
            index += 1
        }

        // The signature is the sender's, so it is looked for in the note only.
        let noteEnd = starts.first?.at ?? own.count
        var signature: [Substring] = []
        if let dashes = own[..<noteEnd].lastIndex(where: { $0 == "-- " }),
           own[(dashes + 1)..<noteEnd].count(where: { !$0.allSatisfy(\.isWhitespace) }) <= Self.maximumSignatureLines {
            signature = Array(own[(dashes + 1)..<noteEnd])
            own.removeSubrange(dashes..<noteEnd)
            let removed = noteEnd - dashes
            starts = starts.map { ($0.at - removed, $0.lines, $0.header) }
        }

        // Each part before a forwarded message loses the rule lines above its marker, such
        // as the line Outlook puts above its header block.
        var forwards: [Forward] = []
        for (number, start) in starts.enumerated() {
            var forward = start.header
            let body = own[(start.at + start.lines)..<(number + 1 < starts.count ? starts[number + 1].at : own.count)]
            forward.text = Self.joined(number + 1 < starts.count ? Self.withoutTrailingRules(body) : body)
            forwards.append(forward)
        }
        let note = starts.first.map { Self.joined(Self.withoutTrailingRules(own[..<$0.at])) }
        self.init(
            ownText: Self.joined(own),
            quotedText: Self.joined(quoted),
            signature: Self.joined(signature),
            note: note,
            forwards: forwards)
    }

    /// Whether a subject says its email is a forward: FW:, Fwd: or 转发： stands first.
    static func isForward(subject: String) -> Bool {
        let text = subject.drop { $0.isWhitespace }
        guard let colon = text.prefix(8).firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        return forwardPrefixes.contains(text[..<colon].filter { !$0.isWhitespace }.lowercased())
    }

    private static let forwardPrefixes: Set<String> = ["fw", "fwd", "转发", "轉發", "转寄", "轉寄", "rv", "転送"]

    private static let maximumSignatureLines = 20
    /// Attributions and header lines are short. Longer lines are never taken for one.
    private static let maximumMarkerLength = 300
    /// The header lines of a forwarded message may list many people.
    private static let maximumHeaderLineLength = 2_000

    private static func joined(_ lines: some Sequence<Substring>) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isQuoted(_ line: Substring) -> Bool {
        line.drop { $0 == " " || $0 == "\t" }.first == ">"
    }

    private static func trimmed(_ line: Substring) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    /// The number of lines of the attribution that starts at `index`, or nil.
    private static func attribution(_ lines: [Substring], at index: Int) -> Int? {
        let line = trimmed(lines[index])
        guard !line.isEmpty, line.count <= maximumMarkerLength else { return nil }
        if isEnglishAttribution(line) || line.hasSuffix("写道：") || line.hasSuffix("写道:") { return 1 }
        // A long address wraps an attribution onto a second line, so one that spans two
        // lines holds the address.
        guard index + 1 < lines.count else { return nil }
        let next = trimmed(lines[index + 1])
        guard next.count <= maximumMarkerLength, !isQuoted(lines[index + 1]), (line + next).contains("@") else { return nil }
        if line.hasPrefix("On "), next.lowercased().hasSuffix("wrote:") { return 2 }
        if next.hasSuffix("写道：") || next.hasSuffix("写道:"), line.hasPrefix("在") || next.hasPrefix("于") { return 2 }
        return nil
    }

    /// Whether an attribution line holds a digit, as of a date or a time, or an address.
    private static func hasDateOrAddress(_ line: Substring) -> Bool {
        line.contains { $0 == "@" || $0.isNumber }
    }

    private static func isEnglishAttribution(_ line: String) -> Bool {
        line.hasPrefix("On ") && line.lowercased().hasSuffix("wrote:")
    }

    /// The characters that draw a rule around the words of a separator or a forward marker.
    private static let ruleCharacters: Set<Character> = ["-", "_", "=", "—", "–", "*"]

    /// The words of a short line without its rule characters, lowercased, with each run of
    /// white space one space. Nil for a line too long to be a marker.
    private static func markerWords(_ line: Substring) -> String? {
        let trimmed = trimmed(line)
        guard trimmed.count <= maximumMarkerLength else { return nil }
        return trimmed.filter { !ruleCharacters.contains($0) }
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// A line such as "-----Original Message-----" or "------------------ 原始邮件 ------------------".
    private static func isSeparator(_ line: Substring) -> Bool {
        guard trimmed(line).count(where: ruleCharacters.contains) >= 2, let words = markerWords(line) else { return false }
        return separatorWords.contains(words)
    }

    /// QQ Mail and Foxmail write "Original" alone in English.
    private static let separatorWords: Set<String> = ["original message", "original", "原始邮件", "邮件原件", "原邮件", "回复的原邮件"]

    /// A line that holds only a forward marker, such as "---------- Forwarded message
    /// ---------" or "下面是被转发的邮件：".
    private static func isForwardMarker(_ line: Substring) -> Bool {
        guard let words = markerWords(line) else { return false }
        return forwardMarkerWords.contains(words.trimmingCharacters(in: CharacterSet(charactersIn: ":： ")))
    }

    private static let forwardMarkerWords: Set<String> = [
        "forwarded message", "begin forwarded message", "forwarded email", "forwarded mail", "forwarding message", "forwarding messages",
        "转发的邮件", "转发邮件", "转发的消息", "转发消息", "转发的信息", "转发邮件信息", "被转发的邮件", "下面是被转发的邮件", "以下是转发的邮件", "以下为转发的邮件",
        "轉寄的郵件", "轉寄郵件", "已轉寄郵件", "開始轉寄郵件", "轉發的郵件", "轉寄的訊息",
        "転送されたメッセージ", "転送メッセージ", "転送されたメール",
        "mensaje reenviado", "inicio del mensaje reenviado", "correo reenviado",
    ]

    /// Whether an Outlook header block starts at `index`.
    private static func isHeaderBlock(_ lines: [Substring], at index: Int) -> Bool {
        let line = trimmed(lines[index])
        guard line.count <= maximumMarkerLength, fromLabels.contains(where: { line.lowercased().hasPrefix($0) }) else { return false }
        for next in lines[(index + 1)..<min(lines.count, index + 4)] {
            let text = trimmed(next).lowercased()
            if sentLabels.contains(where: { text.hasPrefix($0) }) { return true }
        }
        return false
    }

    private static let fromLabels = ["from:", "发件人:", "发件人：", "寄件者:", "寄件者："]
    private static let sentLabels = ["sent:", "date:", "发送时间:", "发送时间：", "日期:", "日期：", "时间:", "时间：", "寄件日期:", "寄件日期："]

    /// Whether a line that names a forward stands within the three lines with text above
    /// `index`.
    private static func followsForwardMarker(_ lines: [Substring], at index: Int) -> Bool {
        var seen = 0
        var cursor = index - 1
        while cursor >= 0, seen < 3, index - cursor <= 10 {
            let line = trimmed(lines[cursor]).lowercased()
            cursor -= 1
            guard !line.isEmpty else { continue }
            seen += 1
            if forwardMarkers.contains(where: { line.contains($0) }) { return true }
        }
        return false
    }

    private static let forwardMarkers = [
        "forwarded message", "begin forwarded message", "转发的邮件", "转发邮件", "转发的消息", "被转发的邮件", "轉寄的郵件", "已轉寄郵件",
        "開始轉寄郵件", "転送されたメッセージ", "mensaje reenviado",
    ]

    // MARK: Forwarded messages

    /// The forwarded message that starts at `index`: the number of its marker and header
    /// lines, with the blank lines between them, and the values of its header. Nil when none
    /// starts there. With `bySubject`, a separator or a header block followed by a header
    /// line starts one too.
    private static func forward(_ lines: [Substring], at index: Int, bySubject: Bool) -> (lines: Int, header: Forward)? {
        let line = lines[index]
        let isMarker = isForwardMarker(line)
        let headerStart: Int
        if isMarker || (bySubject && isSeparator(line)) {
            headerStart = index + 1
        } else if bySubject, isHeaderBlock(lines, at: index) {
            headerStart = index
        } else {
            return nil
        }
        var first = headerStart
        while first < lines.count, first - headerStart < 3, lines[first].allSatisfy(\.isWhitespace) {
            first += 1
        }
        var header = Forward()
        var seen: Set<Field> = []
        var end = first
        while end < lines.count, let (field, value) = headerField(lines[end]) {
            if field != .other {
                guard seen.insert(field).inserted else { break }
            }
            switch field {
            case .sender: header.sender = value
            case .date: header.date = value
            case .subject: header.subject = value
            case .to: header.to = value
            case .cc: header.cc = value
            case .other: break
            }
            end += 1
        }
        if end == first {
            // A separator with no header line is history, as in a reply.
            return isMarker ? (1, header) : nil
        }
        return (end - index, header)
    }

    private enum Field {
        case sender, date, subject, to, cc, other
    }

    /// The field and the value of a header line of a forwarded message, such as
    /// "From: Mei Tan <mei.tan@orchard.example>" or "发送时间: 2026年10月12日 9:30", or nil.
    private static func headerField(_ line: Substring) -> (Field, String)? {
        let text = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*|")))
        guard text.count <= maximumHeaderLineLength,
              let colon = text.prefix(24).firstIndex(where: { $0 == ":" || $0 == "：" }),
              let field = headerLabels[text[..<colon].filter { !$0.isWhitespace }.lowercased()]
        else { return nil }
        // QQ Mail ends the people's lines with a semicolon.
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ";；")))
        return (field, value)
    }

    private static let headerLabels: [String: Field] = [
        "from": .sender, "发件人": .sender, "寄件人": .sender, "寄件者": .sender, "發件人": .sender, "差出人": .sender, "de": .sender,
        "date": .date, "sent": .date, "日期": .date, "时间": .date, "時間": .date, "发送时间": .date, "發送時間": .date,
        "发送日期": .date, "寄件日期": .date, "日付": .date, "送信日時": .date, "fecha": .date, "enviado": .date,
        "subject": .subject, "主题": .subject, "主題": .subject, "標題": .subject, "主旨": .subject, "标题": .subject, "件名": .subject, "asunto": .subject,
        "to": .to, "收件人": .to, "收件者": .to, "宛先": .to, "para": .to,
        "cc": .cc, "抄送": .cc, "抄送人": .cc, "副本": .cc,
        "reply-to": .other, "bcc": .other, "密送": .other, "回复给": .other, "回覆給": .other, "返信先": .other, "respondera": .other,
    ]

    // MARK: Rules

    private static func isRule(_ line: Substring) -> Bool {
        let text = trimmed(line)
        return text.count >= 5 && text.allSatisfy { "-_=—*".contains($0) }
    }

    /// The lines without the blank and rule lines at their end.
    private static func withoutTrailingRules(_ lines: ArraySlice<Substring>) -> ArraySlice<Substring> {
        var lines = lines
        while let last = lines.last, last.allSatisfy(\.isWhitespace) || isRule(last) {
            lines.removeLast()
        }
        return lines
    }

    /// Moves blank lines and lines such as "________" at the end of the own text into the
    /// history that starts after them, as Outlook puts such a line above its header block.
    /// The first `keeping` lines stay.
    private static func moveTrailingRules(from own: inout [Substring], to quoted: inout [Substring], keeping: Int) {
        var moved: [Substring] = []
        while own.count > keeping, let last = own.last, last.allSatisfy(\.isWhitespace) || isRule(last) {
            moved.insert(own.removeLast(), at: 0)
        }
        quoted += moved
    }
}
