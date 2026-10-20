import Foundation

/// An email's own text, apart from the history it quotes and the signature at its end.
///
/// Quoted history is:
/// - every line that starts with ">", as plain text mail and VisibleText write quotes
/// - an attribution such as "On 12 Oct 2026, at 09:30, Mei Tan <mei.tan@orchard.example>
///   wrote:", "在 2026年10月12日 09:30，Mei Tan 写道：" or "Mei Tan 于2026年10月12日 09:30写道：",
///   which may wrap onto a second line. When quoted lines follow, only the attribution goes.
///   Otherwise everything after it is history, as some mail quotes without ">"
/// - everything from a separator line such as "-----Original Message-----" or
///   "-----原始邮件-----"
/// - everything from an Outlook header block: a From: or 发件人： line with a Sent:, Date:,
///   发送时间： or 日期： line within the next three lines
///
/// A forwarded message keeps its text, since the email is about it: a header block right
/// after "Forwarded message", "Begin forwarded message" or 转发的邮件 is no history. Outlook
/// forwards with the same separator and header block as a reply, so its forwarded text
/// lands in `quotedText`.
///
/// The signature is what follows the last "-- " line of the own text, when it holds 20
/// lines with text or fewer. Blank lines in the own text stay as they are, so PromptHygiene
/// still finds text after a long run of them.
nonisolated struct QuotedHistory: Sendable, Equatable {
    var ownText: String
    var quotedText: String
    var signature: String

    init(ownText: String, quotedText: String = "", signature: String = "") {
        self.ownText = ownText
        self.quotedText = quotedText
        self.signature = signature
    }

    init(splitting text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var own: [Substring] = []
        var quoted: [Substring] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if Self.isQuoted(line) {
                quoted.append(line)
                index += 1
                continue
            }
            if Self.isSeparator(line) || (Self.isHeaderBlock(lines, at: index) && !Self.followsForwardMarker(lines, at: index)) {
                Self.moveTrailingRules(from: &own, to: &quoted)
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
                Self.moveTrailingRules(from: &own, to: &quoted)
                quoted += lines[index...]
                break
            }
            own.append(line)
            index += 1
        }

        var signature: [Substring] = []
        if let dashes = own.lastIndex(where: { $0 == "-- " || $0 == "--" }),
           own[(dashes + 1)...].count(where: { !$0.allSatisfy(\.isWhitespace) }) <= Self.maximumSignatureLines {
            signature = Array(own[(dashes + 1)...])
            own.removeSubrange(dashes...)
        }
        self.init(
            ownText: Self.joined(own),
            quotedText: Self.joined(quoted),
            signature: Self.joined(signature))
    }

    private static let maximumSignatureLines = 20
    /// Attributions and header lines are short. Longer lines are never taken for one.
    private static let maximumMarkerLength = 300

    private static func joined(_ lines: [Substring]) -> String {
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

    private static func isEnglishAttribution(_ line: String) -> Bool {
        line.hasPrefix("On ") && line.lowercased().hasSuffix("wrote:")
    }

    /// A line such as "-----Original Message-----" or "------------------ 原始邮件 ------------------".
    private static func isSeparator(_ line: Substring) -> Bool {
        let rules: Set<Character> = ["-", "_", "=", "—", "*"]
        let trimmed = trimmed(line)
        guard trimmed.count <= maximumMarkerLength, trimmed.count(where: rules.contains) >= 2 else { return false }
        let words = trimmed.filter { !rules.contains($0) }
            .split(whereSeparator: { $0.isWhitespace || $0 == "\u{A0}" })
            .joined(separator: " ")
            .lowercased()
        return separatorWords.contains(words)
    }

    private static let separatorWords: Set<String> = ["original message", "原始邮件", "邮件原件", "原邮件", "回复的原邮件"]

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

    /// Whether a forward marker stands within the three lines with text above `index`.
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

    private static let forwardMarkers = ["forwarded message", "begin forwarded message", "转发的邮件", "转发邮件"]

    /// Moves blank lines and lines such as "________" at the end of the own text into the
    /// history that starts after them, as Outlook puts such a line above its header block.
    private static func moveTrailingRules(from own: inout [Substring], to quoted: inout [Substring]) {
        var moved: [Substring] = []
        while let last = own.last {
            let text = trimmed(last)
            guard text.isEmpty || (text.count >= 5 && text.allSatisfy({ "-_=—*".contains($0) })) else { break }
            moved.insert(own.removeLast(), at: 0)
        }
        quoted += moved
    }
}
