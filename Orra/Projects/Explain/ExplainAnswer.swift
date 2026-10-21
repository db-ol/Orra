import Foundation

/// Reads the model's answer to ExplainPrompt: the four sections of warnings, points with
/// their sources, questions for the user before replying, and the draft or the note that
/// no reply or no draft is due.
///
/// It reads the headings of either language, with or without a colon, markdown marks or
/// numbers in front, since a small model does not always keep the format. Inside the draft
/// only a heading with its colon and nothing after it counts, so a line such as "Questions"
/// stays in the draft. A point ends with its sources in brackets, such as [本邮件], [F2] or
/// [M1, T1]. Sources that are not in the prompt's table are dropped and flagged, and so are
/// missing and repeated sections. A repeated section's second copy is not read, but the
/// heading written again right after itself, as after the prefill, is not a copy. An item
/// copied from the prompt's own instructions is left out, and so is a lead in copied from
/// them before a colon, see `Echo`. The answer is data, and nothing here follows it: the
/// window shows it as plain text only.
nonisolated struct ExplainAnswer: Sendable, Equatable {
    nonisolated enum Section: String, Sendable, CaseIterable, Codable {
        case warnings
        case points
        case questions
        case draft
    }

    nonisolated struct Point: Sendable, Equatable {
        /// The point without its source brackets.
        var text: String
        /// Its sources that are in the prompt's table, in order.
        var sources: [String]
    }

    nonisolated enum Draft: Sendable, Equatable {
        case reply(String)
        /// The model wrote that no reply is needed.
        case noReply
        /// The model wrote that no draft is written.
        case noDraft
        /// No draft section, or an empty one.
        case missing
    }

    nonisolated enum Problem: Sendable, Equatable, Codable {
        case missing(Section)
        case repeated(Section)
        /// A point named a source the prompt does not have.
        case unknownSources
    }

    var warnings: [String] = []
    var points: [Point] = []
    var questions: [String] = []
    var draft: Draft = .missing
    /// Source ids the points named that the prompt does not have, each once.
    var unknownSources: [String] = []
    var problems: [Problem] = []

    /// Reads `answer`, which starts with the prompt's prefill. `sources` holds the ids of
    /// the prompt's source table, such as 本邮件, F1 and M1, and `instructions` the
    /// prompt's own instructions.
    init(_ answer: String, sources: some Collection<String>, instructions: String = "") {
        let known = Set(sources)
        let echo = Echo(instructions)
        var sections: [Section: [String]] = [:]
        var current: Section?
        let text = answer
            .replacing(/<think>[\s\S]*?<\/think>/, with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let heading = Self.heading(line), current != .draft || (heading.hasColon && heading.rest.isEmpty) {
                let (section, rest) = (heading.section, heading.rest)
                if section == current, rest.isEmpty, sections[section]?.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) == true {
                    // The heading again before anything under it, as after the prefill.
                    continue
                }
                if sections[section] == nil {
                    current = section
                    sections[section] = rest.isEmpty ? [] : [rest]
                    continue
                }
                // A heading again on a line of its own: the model began the answer again.
                // A line such as "Warning: …" under a heading is an item.
                if rest.isEmpty {
                    if !problems.contains(.repeated(section)) {
                        problems.append(.repeated(section))
                    }
                    current = nil
                    continue
                }
            }
            if let current {
                sections[current]?.append(line)
            }
        }

        for section in Section.allCases where sections[section] == nil {
            problems.append(.missing(section))
        }
        warnings = Self.items(sections[.warnings] ?? []).compactMap(echo.withoutCopy)
        questions = Self.items(sections[.questions] ?? []).compactMap(echo.withoutCopy)
        for item in Self.items(sections[.points] ?? []).compactMap(echo.withoutCopy) {
            let (point, unknown) = Self.point(item, known: known)
            for id in unknown where !unknownSources.contains(id) {
                unknownSources.append(id)
            }
            if !point.text.isEmpty {
                points.append(point)
            }
        }
        if !unknownSources.isEmpty {
            problems.append(.unknownSources)
        }
        if let lines = sections[.draft] {
            draft = Self.draft(lines)
            if draft == .missing {
                problems.append(.missing(.draft))
            }
        }
    }

    // MARK: Sections

    /// The section a line opens, whether the line has the heading's colon, and any text
    /// after it, or nil for a line that is not a heading.
    static func heading(_ line: String) -> (section: Section, hasColon: Bool, rest: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = headingPattern.firstMatch(in: line, range: range),
              let wordRange = Range(match.range(at: 1), in: line) else { return nil }
        let word = line[wordRange].lowercased()
        let restRange = Range(match.range(at: 2), in: line)
        let rest = restRange.map { String(line[$0]) } ?? ""
        let section: Section
        if word.hasPrefix("警告") || word.hasPrefix("warning") {
            section = .warnings
        } else if word.hasPrefix("要点") || word.hasSuffix("points") {
            section = .points
        } else if word.contains("确认") || word.hasPrefix("before") || word.hasPrefix("question") {
            section = .questions
        } else {
            section = .draft
        }
        return (section, restRange != nil, rest.trimmingCharacters(in: .whitespaces))
    }

    private static let headingPattern = try! NSRegularExpression(
        pattern: #"^[\s#>*_]*(?:\d{1,2}[.、)]\s*|[一二三四][、.]\s*)?(?:\*\*)?(警告|要点|回复前需要?确认|回复草稿|草稿|warnings?|(?:key\s+)?points|before\s+you\s+reply|questions(?:\s+for\s+you)?|draft(?:\s+reply)?|reply\s+draft)(?:\*\*)?\s*(?:[:：]\s*(?:\*\*)?\s*(.*?))?[\s*_]*$"#,
        options: [.caseInsensitive]
    )

    /// The items of a list section: a bullet or a number starts one, and other lines add
    /// to the one before. "无" and "None" stand for no items.
    static func items(_ lines: [String]) -> [String] {
        var items: [String] = []
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = bulletPattern.firstMatch(in: text, range: range), let body = Range(match.range(at: 1), in: text) {
                items.append(String(text[body]).trimmingCharacters(in: .whitespaces))
            } else if let last = items.indices.last {
                items[last] += " " + text
            } else {
                items.append(text)
            }
        }
        return items.filter { !$0.isEmpty && !isNothing($0) }
    }

    private static let bulletPattern = try! NSRegularExpression(pattern: #"^(?:[-•*·・–]|\d{1,2}[.、)]|[（(]\d{1,2}[)）])\s*(.*)$"#)

    /// Whether an item says there is nothing: 无, None, N/A.
    static func isNothing(_ item: String) -> Bool {
        let word = item.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).lowercased()
        return ["无", "没有", "暂无", "none", "nothing", "n/a", "na"].contains(word)
    }

    // MARK: Echo

    /// What a small model copies from the prompt's own instructions into a section, such
    /// as "Questions in the email, or decisions the reply needs, that the sources cannot
    /// settle …" as the first question. A run of `run` words of the instructions in a row
    /// counts as copied. An item of at least `least` words that is mostly copied is no
    /// item, and a lead in like that before a colon goes with the colon. Chinese counts by
    /// character, so a Chinese item never matches the English instructions by chance.
    nonisolated struct Echo: Sendable {
        static let run = 5
        static let least = 6
        /// The share of an item's words in copied runs that makes it a copy.
        static let share = 0.8

        private let runs: Set<[String]>

        init(_ instructions: String) {
            let words = Self.words(instructions)
            var runs: Set<[String]> = []
            if words.count >= Self.run {
                for start in 0...(words.count - Self.run) {
                    runs.insert(Array(words[start..<(start + Self.run)]))
                }
            }
            self.runs = runs
        }

        /// The item without what it copied, or nil when nothing of its own is left.
        func withoutCopy(_ item: String) -> String? {
            guard !runs.isEmpty else { return item }
            if isCopied(item) {
                return nil
            }
            if let colon = item.firstIndex(where: { $0 == ":" || $0 == "：" }), isCopied(String(item[..<colon])) {
                let rest = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return rest.isEmpty || ExplainAnswer.isNothing(rest) ? nil : withoutCopy(rest)
            }
            return item
        }

        private func isCopied(_ text: String) -> Bool {
            let words = Self.words(text)
            guard words.count >= Self.least else { return false }
            var copied = Array(repeating: false, count: words.count)
            for start in 0...(words.count - Self.run) where runs.contains(Array(words[start..<(start + Self.run)])) {
                for index in start..<(start + Self.run) {
                    copied[index] = true
                }
            }
            return Double(copied.filter { $0 }.count) >= Self.share * Double(words.count)
        }

        /// The words of a text, lowercased: runs of letters and digits, with each Chinese
        /// character a word of its own.
        static func words(_ text: String) -> [String] {
            var words: [String] = []
            var word = ""
            for character in text.precomposedStringWithCompatibilityMapping.lowercased() {
                if character.isHan {
                    if !word.isEmpty { words.append(word) }
                    word = ""
                    words.append(String(character))
                } else if character.isLetter || character.isNumber {
                    word.append(character)
                } else if !word.isEmpty {
                    words.append(word)
                    word = ""
                }
            }
            if !word.isEmpty { words.append(word) }
            return words
        }
    }

    // MARK: Points

    /// A point without its source brackets, and the ids it named that are not known.
    private static func point(_ item: String, known: Set<String>) -> (Point, [String]) {
        var text = item
        var sources: [String] = []
        var unknown: [String] = []
        let emailLabel = known.first(where: { emailLabels.contains($0.lowercased()) })
        let range = NSRange(item.startIndex..., in: item)
        for match in sourcePattern.matches(in: item, range: range).reversed() {
            guard let whole = Range(match.range, in: text),
                  let group = (1..<match.numberOfRanges).lazy.compactMap({ Range(match.range(at: $0), in: item) }).first else { continue }
            guard let ids = sourceIDs(String(item[group])) else { continue }
            text.replaceSubrange(whole, with: " ")
            for id in ids.reversed() {
                let resolved = emailLabels.contains(id.lowercased()) ? (emailLabel ?? id) : id
                if known.contains(resolved) {
                    if !sources.contains(resolved) { sources.insert(resolved, at: 0) }
                } else if !unknown.contains(resolved) {
                    unknown.insert(resolved, at: 0)
                }
            }
        }
        let cleaned = text
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .replacing(/\s+([。，、；：！？.,;:!?])/, with: { $0.output.1 })
            .trimmingCharacters(in: .whitespaces)
        return (Point(text: cleaned, sources: sources), unknown)
    }

    /// The ids in a bracket group when every part of it is a source id, or nil when the
    /// group is text, such as a placeholder [待确认：合计].
    private static func sourceIDs(_ group: String) -> [String]? {
        var content = group.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces)
        content = content.replacing(/^(?i:来源|出处|sources?)\s*[:：]?\s*/, with: "")
        let parts = content
            .split(whereSeparator: { ",，、;；/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var ids: [String] = []
        for part in parts {
            if emailLabels.contains(part.lowercased()) {
                ids.append(part)
            } else if let match = part.wholeMatch(of: /(?i)([fmt])\s*(\d{1,3})/) {
                ids.append(match.output.1.uppercased() + match.output.2)
            } else {
                return nil
            }
        }
        return ids
    }

    /// The ways a model names the email itself.
    private static let emailLabels: Set<String> = ["本邮件", "本封邮件", "这封邮件", "此邮件", "该邮件", "this email", "the email", "email"]

    private static let sourcePattern = try! NSRegularExpression(pattern: #"\[([^\[\]\n]{1,40})\]|【([^【】\n]{1,40})】|[（(]([^（）()\n]{1,40})[）)]"#)

    // MARK: Draft

    private static let noReplyNotes = ["无需回复", "无须回复", "不需要回复", "不用回复", "no reply needed", "no reply is needed", "no reply"]
    private static let noDraftNotes = ["不写草稿", "无草稿", "no draft"]
    /// The longest draft that can still be a note with a short reason.
    private static let noteLength = 60

    private static func draft(_ lines: [String]) -> Draft {
        let text = lines.joined(separator: "\n")
            .replacing(/^\s*```[a-z]*\s*\n?|\n?\s*```\s*$/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .missing }
        let word = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines).union(CharacterSet(charactersIn: "“”\"「」"))).lowercased()
        if noReplyNotes.contains(where: { isNote($0, word) }) {
            return .noReply
        }
        if noDraftNotes.contains(where: { isNote($0, word) }) {
            return .noDraft
        }
        return .reply(text)
    }

    /// Whether `text` is the note alone, or the note with a short reason after a mark or
    /// "because", as "无需回复（已回复过）" or "No reply needed, she answered it." A draft
    /// that only starts with the words, as "No draft has reached us yet", is a draft.
    private static func isNote(_ note: String, _ text: String) -> Bool {
        guard text.hasPrefix(note) else { return false }
        let rest = text.dropFirst(note.count)
        guard let next = rest.first else { return true }
        let opensReason = next.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            || rest.hasPrefix(" because ") || rest.hasPrefix(" since ")
        return text.count <= noteLength && opensReason
    }
}
