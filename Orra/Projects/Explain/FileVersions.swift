import Foundation

/// Marks the files of a project that a newer file replaced, so the explanation prompt gives
/// only the newest value as current and labels older ones as replaced. Part of code step 3
/// of phase 0, where a stale value given as current was 5 of the 32 wrong facts of the 4B.
///
/// Two signs, in this order:
/// - **A line near the top of a file that says what it replaces**, such as "替代 v1",
///   "replaces schedule-v1" or "supersedes the version of 2026-09-15". The line names a
///   version of the same document, a date or the name of another file, or says "the
///   previous version".
/// - **Files of the same document by their names.** Names that are the same once versions
///   (v2, 第二版), dates, and words such as final, draft, update or 修订 are taken out
///   belong to one document, whatever their format, so quote-v1.pdf and quote-v2.docx do.
///   The current one is, in this order: marked final (final, 终稿, 定稿), the highest
///   version, marked as a revision or an update (revised, update, change, 修订, 变更), not
///   marked as a draft or as old, the latest date in the name, and the latest
///   modification. A file with a later date in its name, such as notes for another
///   meeting, counts as a newer file of the same kind, and the prompt says only that
///   where the two differ the newer one counts.
///
/// A line in a file is never followed when it would make a file replace itself through
/// others. Files the user never added play no part, since the caller passes only the files
/// of the project.
nonisolated struct FileVersions: Sendable, Equatable {
    nonisolated struct File: Sendable, Equatable {
        var url: URL
        var modified: Date
        /// The start of the file's text, where a line such as "替代 v1" stands. The first
        /// 20 lines count.
        var head: String = ""
    }

    nonisolated enum Status: Sendable, Equatable {
        case current
        /// Replaced by this file, the current one of the document.
        case replaced(by: URL)
    }

    /// The status of each file that a newer one replaced. Every other file is current.
    let replaced: [URL: URL]

    init(_ files: [File]) {
        var unique: [File] = []
        for file in files where !unique.contains(where: { $0.url == file.url }) {
            unique.append(file)
        }
        let names = unique.map { Name($0.url.lastPathComponent) }
        let order = unique.indices.sorted { Self.isNewer(unique[$0], names[$0], than: unique[$1], names[$1]) }
        var edges: [Int: Int] = [:]

        func reaches(_ start: Int, _ target: Int) -> Bool {
            var current = start
            var seen: Set<Int> = []
            while let next = edges[current], seen.insert(current).inserted {
                if next == target { return true }
                current = next
            }
            return false
        }
        func add(_ old: Int, replacedBy new: Int) {
            guard old != new, edges[old] == nil, !reaches(new, old) else { return }
            edges[old] = new
        }

        // Lines in the files, newest file first.
        for index in order {
            for target in Self.statedTargets(of: index, files: unique, names: names) {
                add(target, replacedBy: index)
            }
        }
        // Names: every other file of a document is replaced by its current one.
        var families: [String: [Int]] = [:]
        for index in order {
            if let family = names[index].family {
                families[family, default: []].append(index)
            }
        }
        for members in families.values where members.count > 1 {
            guard let current = members.first(where: { edges[$0] == nil }) else { continue }
            for member in members where member != current {
                add(member, replacedBy: current)
            }
        }

        var replaced: [URL: URL] = [:]
        for old in edges.keys {
            var end = old
            var seen: Set<Int> = [old]
            while let next = edges[end], seen.insert(next).inserted {
                end = next
            }
            replaced[unique[old].url] = unique[end].url
        }
        self.replaced = replaced
    }

    func status(of url: URL) -> Status {
        replaced[url].map { .replaced(by: $0) } ?? .current
    }

    // MARK: Names

    /// What a file's name says about its version.
    nonisolated struct Name: Sendable, Equatable {
        /// The name of the document: the file name without its extension, versions, dates
        /// and marks, or nil when nothing else is left.
        var family: String?
        var isFinal = false
        /// The version, such as [2] for v2 or [1, 2] for v1.2, empty without one.
        var version: [Int] = []
        /// -2 old, -1 draft, 0 no mark, 1 a revision or an update.
        var mark = 0
        /// The latest date in the name as 20261011, or 0 without one.
        var date = 0

        /// What the name of a file says.
        init(_ fileName: String) {
            self.init(text: (fileName as NSString).deletingPathExtension)
        }

        /// What a name without its extension, or a line that names a version, says.
        init(text: String) {
            var stem = text.precomposedStringWithCompatibilityMapping.lowercased()
            for pattern in Self.datePatterns {
                for match in Self.matches(pattern, in: stem) {
                    let parts = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: stem).flatMap { Int(stem[$0]) } }
                    if parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) {
                        date = max(date, parts[0] * 10_000 + parts[1] * 100 + parts[2])
                    }
                }
                stem = Self.removing(pattern, from: stem)
            }
            for match in Self.matches(Self.versionPattern, in: stem) {
                let numbers = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: stem).flatMap { Int(stem[$0]) } }
                if !numbers.isEmpty, !numbers.lexicographicallyPrecedes(version) {
                    version = numbers
                }
            }
            stem = Self.removing(Self.versionPattern, from: stem)
            for match in Self.matches(Self.chineseVersionPattern, in: stem) {
                let group = (1..<match.numberOfRanges).lazy.compactMap { Range(match.range(at: $0), in: stem) }.first
                if let group, let number = Self.number(String(stem[group])), ![number].lexicographicallyPrecedes(version) {
                    version = [number]
                }
            }
            stem = Self.removing(Self.chineseVersionPattern, from: stem)
            if Self.hasMatch(Self.finalPattern, in: stem) {
                isFinal = true
            }
            if Self.hasMatch(Self.revisedPattern, in: stem) {
                mark = 1
            }
            if Self.hasMatch(Self.draftPattern, in: stem) {
                mark = -1
            }
            if Self.hasMatch(Self.oldPattern, in: stem) {
                mark = -2
            }
            for pattern in [Self.finalPattern, Self.revisedPattern, Self.draftPattern, Self.oldPattern, Self.copyPattern] {
                stem = Self.removing(pattern, from: stem)
            }
            let family = stem
                .split(whereSeparator: { Self.separators.contains($0) })
                .joined(separator: "-")
            self.family = family.isEmpty ? nil : family
        }

        private static let separators = Set<Character>(" -_.()（）[]【】,，、+~")

        private static let datePatterns = [
            #"(?<!\d)(20\d{2})([-_./])(\d{1,2})\2(\d{1,2})(?!\d)"#,
            #"(?<!\d)(20\d{2})(\d{2})(\d{2})(?!\d)"#,
            #"(20\d{2})年(\d{1,2})月(\d{1,2})日?"#,
        ].map { try! NSRegularExpression(pattern: $0) }
        private static let versionPattern = try! NSRegularExpression(pattern: #"(?<![a-z])(?:v|ver|version|rev|r)[ ._-]?(\d{1,3})(?:\.(\d{1,3}))?(?![a-z\d])"#)
        private static let chineseVersionPattern = try! NSRegularExpression(pattern: #"第\s*([0-9]{1,3}|[一二三四五六七八九十]{1,3})\s*(?:版|稿)|版本\s*([0-9]{1,3})"#)
        private static let finalPattern = try! NSRegularExpression(pattern: #"(?<![a-z])final(?![a-z])|最终版?|终稿|定稿|正式版"#)
        private static let revisedPattern = try! NSRegularExpression(pattern: #"(?<![a-z])(?:revised|revision|rev|update|updated|updates|change|changes|changed|amended|amendment|latest|new)(?![a-z])|修订版?|修改版?|更新版?|变更|调整|新版|最新版?"#)
        private static let draftPattern = try! NSRegularExpression(pattern: #"(?<![a-z])(?:draft|wip|preliminary)(?![a-z])|草稿|初稿|草案|征求意见稿"#)
        private static let oldPattern = try! NSRegularExpression(pattern: #"(?<![a-z])(?:old|obsolete|outdated|superseded)(?![a-z])|旧版?|作废|过期"#)
        private static let copyPattern = try! NSRegularExpression(pattern: #"(?<![a-z])copy(?![a-z])|副本|\(\d+\)|（\d+）"#)

        private static func matches(_ pattern: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        }

        private static func hasMatch(_ pattern: NSRegularExpression, in text: String) -> Bool {
            pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        private static func removing(_ pattern: NSRegularExpression, from text: String) -> String {
            pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }

        /// A number in digits or in Chinese numerals up to 99.
        static func number(_ text: String) -> Int? {
            if let value = Int(text) {
                return value
            }
            let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
            let characters = Array(text)
            if characters == ["十"] {
                return 10
            }
            if characters.count == 1 {
                return digits[characters[0]]
            }
            if characters.count == 2, characters[0] == "十" {
                return digits[characters[1]].map { 10 + $0 }
            }
            if characters.count == 2, characters[1] == "十" {
                return digits[characters[0]].map { $0 * 10 }
            }
            if characters.count == 3, characters[1] == "十", let tens = digits[characters[0]], let ones = digits[characters[2]] {
                return tens * 10 + ones
            }
            return nil
        }
    }

    /// Whether file a is the current one of a document rather than file b.
    private static func isNewer(_ a: File, _ nameA: Name, than b: File, _ nameB: Name) -> Bool {
        if nameA.isFinal != nameB.isFinal {
            return nameA.isFinal
        }
        if nameA.version != nameB.version {
            return nameB.version.lexicographicallyPrecedes(nameA.version)
        }
        if nameA.mark != nameB.mark {
            return nameA.mark > nameB.mark
        }
        if nameA.date != nameB.date {
            return nameA.date > nameB.date
        }
        if a.modified != b.modified {
            return a.modified > b.modified
        }
        return a.url.path < b.url.path
    }

    // MARK: Lines that name what a file replaces

    /// The files that a line near the top of file `index` says it replaces.
    private static func statedTargets(of index: Int, files: [File], names: [Name]) -> [Int] {
        var targets: [Int] = []
        let lines = files[index].head.split(whereSeparator: \.isNewline).prefix(headLines)
        for line in lines {
            let form = SortingText.matchingForm(String(line))
            for statement in statements(in: form) {
                for target in resolve(statement, of: index, files: files, names: names) where !targets.contains(target) {
                    targets.append(target)
                }
            }
        }
        return targets
    }

    /// The lines of a file's head that count.
    private static let headLines = 20

    /// What the line says is replaced: the text after "replaces" or "替代", or before
    /// "作废". "以此为准" stands for the earlier versions of the same document.
    private static func statements(in line: String) -> [String] {
        var found: [String] = []
        let range = NSRange(line.startIndex..., in: line)
        for pattern in [replacesPattern, voidPattern] {
            for match in pattern.matches(in: line, range: range) {
                if let target = Range(match.range(at: 1), in: line) {
                    found.append(String(line[target]))
                }
            }
        }
        if prevailsPattern.firstMatch(in: line, range: range) != nil {
            found.append("previous version")
        }
        return found
    }

    private static let replacesPattern = try! NSRegularExpression(pattern: #"(?:\breplaces|\bsupersedes|\breplacing|\bobsoletes|\btakes the place of|替代|取代|代替|替换)\s*[:：]?\s*([^。；;！!？?\n]{1,80})"#)
    private static let voidPattern = try! NSRegularExpression(pattern: #"([^。；;！!？?\n，,：:（(]{1,40}?)\s*(?:已作废|作废|不再有效|已失效|停止使用)"#)
    private static let prevailsPattern = try! NSRegularExpression(pattern: #"以(?:本|此)(?:版|版本|文件|稿)?为准|this (?:version|file|document) prevails"#)

    /// The files a statement names, among the others: a version of the same document, a
    /// file with a date in its name, a file by its name, or the earlier versions of the
    /// same document.
    private static func resolve(_ statement: String, of index: Int, files: [File], names: [Name]) -> [Int] {
        let named = Name(text: statement)
        let family = names[index].family
        var targets: [Int] = []
        for other in files.indices where other != index {
            let name = names[other]
            let stem = (files[other].url.lastPathComponent as NSString).deletingPathExtension.precomposedStringWithCompatibilityMapping.lowercased()
            if !named.version.isEmpty, name.family == family, name.version == named.version {
                targets.append(other)
            } else if named.date != 0, name.date == named.date, name.family == family || mentions(name.family, in: statement) {
                targets.append(other)
            } else if stem.count >= 4, statement.contains(stem) {
                targets.append(other)
            } else if family != nil, name.family == family, statement.firstMatch(of: previousPattern) != nil,
                      isNewer(files[index], names[index], than: files[other], name) {
                targets.append(other)
            }
        }
        return targets
    }

    /// Whether the statement names a document, as "schedule" or "schedule v1" names the
    /// family schedule.
    private static func mentions(_ family: String?, in statement: String) -> Bool {
        guard let family, family.count >= 3 else { return false }
        return statement.contains(family) || statement.contains(family.replacingOccurrences(of: "-", with: " "))
    }

    nonisolated(unsafe) private static let previousPattern = /\b(?:previous|earlier|prior|old|last)\s+(?:version|draft|edition)|上一版|上版|旧版|之前的版本|原版|前一版/
}
