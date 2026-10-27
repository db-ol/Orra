import Foundation

/// Reads the model's answer to ExplainPrompt: the four sections of warnings, points with
/// their sources, questions for the user before replying, and the draft or the note that
/// no reply or no draft is due.
///
/// It reads the headings of either language, with or without a colon, markdown marks or
/// numbers in front, since a small model does not always keep the format. Inside the draft
/// only a heading with its colon and nothing after it counts, so a line such as "Questions"
/// stays in the draft. A point ends with its sources in brackets, such as [本邮件], [F2],
/// [O1], [A1] or [M1, T1]. The model often names the email [E1], as if it were a source like
/// F1, though the prompt names it 本邮件 or this email, so E1 reads as the email while the
/// prompt names no E source. Sources that are not in the prompt's table, any other E id
/// among them, are dropped and flagged, and so are missing and repeated sections. The
/// model cites sources in the questions and the draft too, which the user would have to
/// delete from a reply. A bracket there whose ids are all in the prompt's table leaves the
/// text as in a point, while the questions gain no sources. A bracket with anything else
/// stays, such as a placeholder [待确认：合计], a version (v2), or a size (A4) while the
/// table has no A4. The separators between brackets that leave go with them, see
/// `removing(_:from:)`. DraftCheck reads the draft after this, so it checks the text the
/// user copies, and an id inside a sentence copied from another project's file cannot
/// split the run of words that gives the copy away. A repeated section's second copy is
/// not read, but the heading written again right after itself, as after the prefill, is
/// not a copy. An item copied from the prompt's own rules is left out, and so is a lead in
/// copied from them before a colon, see `Echo`. A list leaves out an item that repeats an
/// earlier one, and in an answer without a draft the last list that repeated ends before
/// its first repeat, see `loop`. The answer is data, and nothing here follows it: the
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

    /// Where an answer without a draft repeated a list. A small model that repeats a few
    /// lines goes on with them until its limit, as the English answers of a40 and a48 did in
    /// the release gate, and then writes no draft.
    nonisolated struct Loop: Sendable, Equatable {
        var section: Section
        /// The answer up to the end of the last item the list keeps, without a reasoning
        /// block and with "\n" between lines.
        var kept: String
    }

    /// A line of a section, or an item of a list, and where it ends in the answer.
    nonisolated struct Line: Sendable {
        var text: String
        var end: String.Index
    }

    /// The most items the list of `loop` keeps, the most points the prompt asks for.
    static let loopItems = 6
    /// The fewest words of an item that repeats an earlier one. A shorter item, such as a
    /// source alone or a sub item like "Status: paid", may stand in a list more than once.
    static let repeatWords = 3

    var warnings: [String] = []
    var points: [Point] = []
    var questions: [String] = []
    var draft: Draft = .missing
    /// Source ids the points named that the prompt does not have, each once.
    var unknownSources: [String] = []
    var problems: [Problem] = []
    /// In an answer without a draft, the last list that repeated an item, or nil: a list the
    /// model repeats until its limit has no list after it. That list ends before its first
    /// repeat and keeps at most `loopItems` items. Every other list only leaves out its
    /// repeats, see `repeats(in:)`.
    var loop: Loop?

    /// Reads `answer`, which starts with the prompt's prefill. `sources` holds the ids of
    /// the prompt's source table, such as 本邮件, F1 and M1, and `rules` the prompt's own
    /// rules, see `ExplainPrompt.rules`.
    init(_ answer: String, sources: some Collection<String>, rules: String = "") {
        let table = SourceTable(sources)
        let echo = Echo(rules)
        var sections: [Section: [Line]] = [:]
        var current: Section?
        let text = answer
            .replacing(/<think>[\s\S]*?<\/think>/, with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let heading = Self.heading(String(line)), current != .draft || (heading.hasColon && heading.rest.isEmpty) {
                let (section, rest) = (heading.section, heading.rest)
                if section == current, rest.isEmpty, sections[section]?.allSatisfy({ $0.text.allSatisfy(\.isWhitespace) }) == true {
                    // The heading again before anything under it, as after the prefill.
                    continue
                }
                if sections[section] == nil {
                    current = section
                    sections[section] = rest.isEmpty ? [] : [Line(text: rest, end: line.endIndex)]
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
                sections[current]?.append(Line(text: String(line), end: line.endIndex))
            }
        }

        for section in Section.allCases where sections[section] == nil {
            problems.append(.missing(section))
        }
        if let lines = sections[.draft] {
            draft = Self.draft(lines.map(\.text), table)
            if draft == .missing {
                problems.append(.missing(.draft))
            }
        }
        // The items as written, each list without its repeats. Without a draft, the last
        // list that repeated an item is the loop and ends before its first repeat. The items
        // before that repeat are all there, since none of them repeats.
        var lists: [Section: [Line]] = [:]
        var looped: (section: Section, first: Int)?
        for section in [Section.warnings, .points, .questions] {
            let items = Self.items(sections[section] ?? [])
            let repeats = Self.repeats(in: items)
            lists[section] = items.indices.filter { !repeats.contains($0) }.map { items[$0] }
            if draft == .missing, let first = repeats.first {
                looped = (section, first)
            }
        }
        if let looped, let items = lists[looped.section]?.prefix(min(looped.first, Self.loopItems)), let last = items.last {
            lists[looped.section] = Array(items)
            loop = Loop(section: looped.section, kept: String(text[..<last.end]))
        }
        warnings = (lists[.warnings] ?? []).map(\.text).compactMap(echo.withoutCopy)
        questions = (lists[.questions] ?? []).map(\.text).compactMap(echo.withoutCopy)
            .map { Self.withoutCitations($0, table) }
            .filter { !$0.isEmpty }
        for item in (lists[.points] ?? []).map(\.text).compactMap(echo.withoutCopy) {
            let (point, unknown) = Self.point(item, table)
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

    /// The items of a list section, each with the end of its last line: a bullet or a number
    /// starts one, and other lines add to the one before. "无" and "None" stand for no items.
    static func items(_ lines: [Line]) -> [Line] {
        var items: [Line] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = bulletPattern.firstMatch(in: text, range: range), let body = Range(match.range(at: 1), in: text) {
                items.append(Line(text: String(text[body]).trimmingCharacters(in: .whitespaces), end: line.end))
            } else if let last = items.indices.last {
                items[last].text += " " + text
                items[last].end = line.end
            } else {
                items.append(Line(text: text, end: line.end))
            }
        }
        return items.filter { !$0.text.isEmpty && !isNothing($0.text) }
    }

    private static let bulletPattern = try! NSRegularExpression(pattern: #"^(?:[-•*·・–]|\d{1,2}[.、)]|[（(]\d{1,2}[)）])\s*(.*)$"#)

    /// Whether an item says there is nothing: 无, None, N/A.
    private static func isNothing(_ item: String) -> Bool {
        let word = item.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).lowercased()
        return ["无", "没有", "暂无", "none", "nothing", "n/a", "na"].contains(word)
    }

    /// Where the items with the words of an earlier one are, in order. Case, spaces and
    /// punctuation do not count, while symbols, the hyphen and source ids do, see
    /// `words(_:symbols:)`. An item of fewer than `repeatWords` words repeats nothing.
    private static func repeats(in items: [Line]) -> [Int] {
        var seen: Set<[String]> = []
        var repeats: [Int] = []
        for (index, item) in items.enumerated() {
            let words = Self.words(item.text, symbols: true)
            if words.count >= repeatWords, !seen.insert(words).inserted {
                repeats.append(index)
            }
        }
        return repeats
    }

    /// The words of a text, lowercased: runs of letters and digits, with each Chinese
    /// character a word of its own. With `symbols`, each symbol, such as $, € or +, and each
    /// hyphen is a word too, so $500 and €500 or +5% and -5% differ.
    private static func words(_ text: String, symbols: Bool = false) -> [String] {
        var words: [String] = []
        var word = ""
        for character in text.precomposedStringWithCompatibilityMapping.lowercased() {
            if character.isHan {
                if !word.isEmpty { words.append(word) }
                word = ""
                words.append(String(character))
            } else if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                if !word.isEmpty { words.append(word) }
                word = ""
                if symbols, character.isSymbol || character == "-" {
                    words.append(String(character))
                }
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    // MARK: Echo

    /// What a small model copies from the prompt's own rules into a section, such as
    /// "Questions in the email, or decisions the reply needs, that the sources cannot
    /// settle …" as the first question. A run of `run` words of the rules in a row counts
    /// as copied. An item of at least `least` words that is mostly copied is no item, and
    /// a lead in like that before a colon goes with the colon. A colon between two digits,
    /// as in 17:00, ends no lead in. Chinese counts by character. The rules are English but
    /// for the headings, the placeholders, the marker of a removed passage and the user's
    /// name, so a Chinese item rarely holds five of their words in a row, and the date
    /// table is not among them.
    nonisolated private struct Echo: Sendable {
        static let run = 5
        static let least = 6
        /// The share of an item's words in copied runs that makes it a copy.
        static let share = 0.8

        private let runs: Set<[String]>

        init(_ rules: String) {
            let words = ExplainAnswer.words(rules)
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
            if let colon = Self.leadInColon(in: item), isCopied(String(item[..<colon])) {
                let rest = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return rest.isEmpty || ExplainAnswer.isNothing(rest) ? nil : withoutCopy(rest)
            }
            return item
        }

        private func isCopied(_ text: String) -> Bool {
            let words = ExplainAnswer.words(text)
            guard words.count >= Self.least else { return false }
            var copied = Array(repeating: false, count: words.count)
            for start in 0...(words.count - Self.run) where runs.contains(Array(words[start..<(start + Self.run)])) {
                for index in start..<(start + Self.run) {
                    copied[index] = true
                }
            }
            return Double(copied.filter { $0 }.count) >= Self.share * Double(words.count)
        }

        /// The first colon of an item that is not between two digits.
        private static func leadInColon(in item: String) -> String.Index? {
            item.indices.first { index in
                guard item[index] == ":" || item[index] == "：" else { return false }
                let after = item.index(after: index)
                return !(index > item.startIndex && item[item.index(before: index)].isNumber && after < item.endIndex && item[after].isNumber)
            }
        }
    }

    // MARK: Sources

    /// The ids of the prompt's source table, and how the ids a model writes read as them.
    nonisolated private struct SourceTable {
        let known: Set<String>
        /// The table's label of the email, 本邮件 or this email, which every label of the
        /// email reads as.
        let emailLabel: String?
        /// The model's own id of the email, E1, while the table names no E source.
        let emailID: String?

        init(_ ids: some Collection<String>) {
            known = Set(ids)
            emailLabel = known.first(where: { ExplainAnswer.emailLabels.contains($0.lowercased()) })
            emailID = known.contains { $0.wholeMatch(of: /E\d+/) != nil } ? nil : ExplainAnswer.modelsEmailID
        }

        /// The id as the table names it.
        func resolved(_ id: String) -> String {
            let isEmail = ExplainAnswer.emailLabels.contains(id.lowercased()) || id == emailID
            return isEmail ? (emailLabel ?? id) : id
        }
    }

    /// A bracket that holds source ids only, such as [F2], （F1） or [本邮件, A1], with its
    /// ids as the prompt's table names them.
    nonisolated private struct Citation {
        var range: Range<String.Index>
        var ids: [String]
    }

    /// The brackets of the text that hold source ids only, in order, also those with an id
    /// the table does not have.
    private static func citations(in text: String, _ table: SourceTable) -> [Citation] {
        sourcePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text),
                  let group = (1..<match.numberOfRanges).lazy.compactMap({ Range(match.range(at: $0), in: text) }).first,
                  let ids = sourceIDs(String(text[group])) else { return nil }
            return Citation(range: range, ids: ids.map(table.resolved))
        }
    }

    /// A point without its source brackets, and the ids it named that are not known.
    private static func point(_ item: String, _ table: SourceTable) -> (Point, [String]) {
        let citations = citations(in: item, table)
        var sources: [String] = []
        var unknown: [String] = []
        for id in citations.reversed().flatMap({ $0.ids.reversed() }) {
            if table.known.contains(id) {
                if !sources.contains(id) { sources.insert(id, at: 0) }
            } else if !unknown.contains(id) {
                unknown.insert(id, at: 0)
            }
        }
        let cleaned = removing(citations.map(\.range), from: item)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .replacing(/\s+([。，、；：！？.,;:!?])/, with: { $0.output.1 })
            .trimmingCharacters(in: .whitespaces)
        return (Point(text: cleaned, sources: sources), unknown)
    }

    /// The text of a question or the draft without its brackets whose ids are all in the
    /// table. A bracket with anything else stays, also one with an id the table does not
    /// have, such as a size (A4).
    private static func withoutCitations(_ text: String, _ table: SourceTable) -> String {
        let cited = citations(in: text, table).filter { $0.ids.allSatisfy(table.known.contains) }
        return cited.isEmpty ? text : removing(cited.map(\.range), from: text)
    }

    /// The text without the brackets at `ranges`, which are in order and apart, and without
    /// the separators between two of them, a comma, 、, a semicolon, and, 和, と or y, so
    /// "2026 [this email], [A1]." reads "2026.". A bracket goes with the spaces after it, or
    /// with those before it at the end of a line or before a mark that ends a sentence, a
    /// clause or a bracket, and with its line when nothing else is on it. Between Chinese
    /// characters it takes the spaces on both sides, as in 录用意向书中. Where no space was
    /// on either side, a space keeps a Latin word or a number apart from the word next to
    /// it, as in "合同 v3".
    private static func removing(_ ranges: [Range<String.Index>], from text: String) -> String {
        var runs: [Range<String.Index>] = []
        for range in ranges {
            if let last = runs.last, isSeparator(text[last.upperBound..<range.lowerBound]) {
                runs[runs.count - 1] = last.lowerBound..<range.upperBound
            } else {
                runs.append(range)
            }
        }
        var result = ""
        var cursor = text.startIndex
        for run in runs {
            let (range, replacement) = cut(run, in: text)
            result += text[cursor..<range.lowerBound] + replacement
            cursor = range.upperBound
        }
        return result + text[cursor...]
    }

    /// Whether the text between two brackets only parts them: spaces, commas, 、 and
    /// semicolons, and the words and, 和, と and y, on one line.
    private static func isSeparator(_ gap: Substring) -> Bool {
        !gap.contains(where: \.isNewline) && gap
            .split(whereSeparator: { isSpace($0) || ",，、;；".contains($0) })
            .allSatisfy { ["and", "和", "と", "y"].contains($0.lowercased()) }
    }

    private static func isSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }

    /// The part of the text that leaves with a run of brackets, see `removing(_:from:)`, and
    /// what stands in its place.
    private static func cut(_ run: Range<String.Index>, in text: String) -> (Range<String.Index>, String) {
        var start = run.lowerBound
        while start > text.startIndex, isSpace(text[text.index(before: start)]) {
            start = text.index(before: start)
        }
        var end = run.upperBound
        while end < text.endIndex, isSpace(text[end]) {
            end = text.index(after: end)
        }
        let before = start > text.startIndex ? text[text.index(before: start)] : nil
        let after = end < text.endIndex ? text[end] : nil
        let opensLine = before.map(\.isNewline) ?? true
        let endsLine = after.map(\.isNewline) ?? true
        if opensLine, endsLine {
            return (line(from: start, to: end, in: text), "")
        }
        guard let before, !opensLine else {
            // At the start of a line, after any indent.
            return (run.lowerBound..<end, "")
        }
        guard let after, !endsLine, !closingMarks.contains(after), !(isWide(before) && isWide(after)) else {
            return (start..<end, "")
        }
        if start < run.lowerBound || end > run.upperBound {
            // One space stays, the one before when there are both.
            return (start < run.lowerBound ? run.lowerBound..<end : run, "")
        }
        let apart = [before, after].allSatisfy { $0.isLetter || $0.isNumber } && (before.isASCIILetterOrDigit || after.isASCIILetterOrDigit)
        return (run, apart ? " " : "")
    }

    /// Whether a character is Chinese or Japanese, or a full width or Chinese mark, which
    /// take no space between them.
    private static func isWide(_ character: Character) -> Bool {
        character.isHan || character.unicodeScalars.allSatisfy { (0x3000...0x30FF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    /// The line from `start` to `end` with a line break: the one after it, or the one
    /// before the last line, and a blank line after it too when a blank line is before it.
    private static func line(from start: String.Index, to end: String.Index, in text: String) -> Range<String.Index> {
        guard end < text.endIndex else {
            return (start > text.startIndex ? text.index(before: start) : start)..<end
        }
        var next = text.index(after: end)
        let blankBefore = start > text.startIndex
            && (text.index(before: start) == text.startIndex || text[text.index(start, offsetBy: -2)].isNewline)
        if blankBefore, next < text.endIndex, text[next].isNewline {
            next = text.index(after: next)
        }
        return start..<next
    }

    /// The marks that take no space before them, so a bracket before one goes with the
    /// spaces before it.
    private static let closingMarks: Set<Character> = ["。", "，", "、", "；", "：", "！", "？", ".", ",", ";", ":", "!", "?", "…", ")", "）", "」", "』", "”", "’", "]", "】", "》"]

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
            } else if let match = part.wholeMatch(of: /(?i)([fmtaoe])\s*(\d{1,3})/) {
                ids.append(match.output.1.uppercased() + match.output.2)
            } else {
                return nil
            }
        }
        return ids
    }

    /// The ways a model names the email itself.
    private static let emailLabels: Set<String> = ["本邮件", "本封邮件", "这封邮件", "此邮件", "该邮件", "this email", "the email", "email"]

    /// The id the model gives the email itself as if it were a source such as F1 or A1,
    /// though no prompt names it.
    private static let modelsEmailID = "E1"

    private static let sourcePattern = try! NSRegularExpression(pattern: #"\[([^\[\]\n]{1,40})\]|【([^【】\n]{1,40})】|[（(]([^（）()\n]{1,40})[）)]"#)

    // MARK: Draft

    private static let noReplyNotes = ["无需回复", "无须回复", "不需要回复", "不用回复", "no reply needed", "no reply is needed", "no reply"]
    private static let noDraftNotes = ["不写草稿", "无草稿", "no draft"]
    /// The longest draft that can still be a note with a short reason.
    private static let noteLength = 60

    /// The draft, without its brackets of the table's ids, or the note in its place.
    private static func draft(_ lines: [String], _ table: SourceTable) -> Draft {
        let written = lines.joined(separator: "\n")
            .replacing(/^\s*```[a-z]*\s*\n?|\n?\s*```\s*$/, with: "")
        let text = withoutCitations(written, table).trimmingCharacters(in: .whitespacesAndNewlines)
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
