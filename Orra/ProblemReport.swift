import Foundation

/// The diagnostic report the user can attach to a GitHub issue, from Report a Problem… in
/// the menu. Pure, so the tests cover what goes into the file.
///
/// The report holds facts about Orra, the Mac and the settings, Orra's own log and its
/// recent crash reports. Never what the user dictated, the audio, the clipboard, the
/// vocabulary or the learned word pairs: of those it holds counts only. The user's home
/// folder, account name and computer name are taken out. Nothing is sent: the user
/// attaches the file to the issue.
nonisolated enum ProblemReport {
    /// The facts in the report, gathered by ProblemReporter.
    struct Facts: Equatable, Sendable {
        var version: String
        var build: String
        var macOS: String
        var model: String
        var chip: String
        var memoryBytes: UInt64
        var preferredLanguages: [String]
        var interfaceLanguage: String
        var speechModel: String
        var speechModelBytes: Int64?
        var speechModelState: String
        var microphoneAccess: String
        var accessibilityTrusted: Bool
        var talkKeyActive: Bool
        var talkKeys: [String]
        var microphone: String
        var settings: [Setting]
        var vocabularyCount: Int
        var learnedPairCount: Int
    }

    /// A setting that is on or off, by its English name.
    struct Setting: Equatable, Sendable {
        var name: String
        var on: Bool
    }

    /// A crash report file, by name and contents.
    struct CrashReport: Equatable, Sendable {
        var name: String
        var contents: String
    }

    /// Orra's log subsystem, the one every Logger in the app uses.
    static let subsystem = "io.github.db-ol.Orra"
    /// The most log lines the report keeps, the newest ones.
    static let maximumLogLines = 2000
    /// How far back the crash reports go, and how many are kept.
    static let crashReportAge: TimeInterval = 7 * 24 * 60 * 60
    static let maximumCrashReports = 3

    // MARK: Redaction

    /// Takes the user out of `text`: the home folder becomes ~, and the account name, the
    /// full name and the computer name become placeholders. Names shorter than three
    /// characters are left, since they would match inside too many words, except Chinese,
    /// Japanese and Korean names of two. Matching ignores case, and a name matches as a
    /// whole word only. Chinese, Japanese and Korean characters count as a word boundary,
    /// since a Mac set up in Chinese names devices like Jane的AirPods.
    static func redact(_ text: String, home: String, userNames: [String], computerName: String?) -> String {
        var result = text
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if trimmedHome.count > 1 {
            // Not inside a longer folder name, such as /Users/janet for /Users/jane.
            let pattern = NSRegularExpression.escapedPattern(for: trimmedHome) + "(?![\\p{L}\\p{N}._-])"
            if let expression = try? NSRegularExpression(pattern: pattern) {
                result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "~")
            }
        }
        if let computerName {
            result = replaceWord(computerName, with: "<computer>", in: result)
        }
        // The longest first, so a full name goes before the first name inside it.
        for name in userNames.sorted(by: { $0.count > $1.count }) {
            result = replaceWord(name, with: "<user>", in: result)
        }
        return result
    }

    /// Takes the given and family names out of the microphone name, where a device name
    /// such as Jane’s AirPods holds them. They are not taken out of the rest of the report,
    /// since a name like Mark or Will is also a word there.
    static func redactDeviceNames(_ facts: Facts, nameParts: [String]) -> Facts {
        var facts = facts
        for name in nameParts.sorted(by: { $0.count > $1.count }) {
            facts.microphone = replaceWord(name, with: "<user>", in: facts.microphone)
        }
        return facts
    }

    /// A letter or digit that joins a name into a longer word. Chinese, Japanese and Korean
    /// characters do not, since those languages write no spaces between words.
    private static let wordCharacter = "[[\\p{L}\\p{N}]-[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]]"

    private static func replaceWord(_ word: String, with placeholder: String, in text: String) -> String {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let cjk = word.range(of: "^[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]+$", options: .regularExpression) != nil
        let minimum = cjk ? 2 : 3
        guard word.count >= minimum else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard let expression = try? NSRegularExpression(pattern: "(?<!\(wordCharacter))\(escaped)(?!\(wordCharacter))", options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: placeholder))
    }

    // MARK: Formatting

    /// The whole report, before redaction.
    static func format(_ facts: Facts, log: [String], logSource: String, crashReports: [CrashReport], created: Date) -> String {
        var lines: [String] = []
        lines.append("Orra diagnostic report")
        lines.append("Created: \(timestamp(created))")
        lines.append("This report contains no dictated text, audio, clipboard, vocabulary or learned words.")
        lines.append("")
        lines.append("## Orra")
        lines.append("Version: \(facts.version) (\(facts.build))")
        lines.append("Interface language: \(facts.interfaceLanguage)")
        lines.append("")
        lines.append("## Mac")
        lines.append("macOS: \(facts.macOS)")
        lines.append("Model: \(facts.model)")
        lines.append("Chip: \(facts.chip)")
        lines.append("Memory: \(gigabytes(Int64(clamping: facts.memoryBytes)))")
        lines.append("Preferred languages: \(facts.preferredLanguages.joined(separator: ", "))")
        lines.append("")
        lines.append("## Speech model")
        lines.append("Model: \(facts.speechModel)")
        lines.append("State: \(facts.speechModelState)")
        lines.append("Folder size: \(facts.speechModelBytes.map(gigabytes) ?? "no folder")")
        lines.append("")
        lines.append("## Permissions")
        lines.append("Microphone: \(facts.microphoneAccess)")
        lines.append("Accessibility: \(facts.accessibilityTrusted ? "granted" : "not granted")")
        lines.append("Talk key listening: \(yesNo(facts.talkKeyActive))")
        lines.append("")
        lines.append("## Settings")
        lines.append("Talk keys: \(facts.talkKeys.isEmpty ? "none" : facts.talkKeys.joined(separator: ", "))")
        lines.append("Microphone: \(facts.microphone)")
        for setting in facts.settings {
            lines.append("\(setting.name): \(setting.on ? "on" : "off")")
        }
        lines.append("Vocabulary: \(facts.vocabularyCount) words")
        lines.append("Learned word pairs: \(facts.learnedPairCount)")
        lines.append("")
        lines.append("## Log, last hour (\(logSource))")
        if log.isEmpty {
            lines.append("No entries.")
        } else {
            if log.count > maximumLogLines {
                lines.append("\(log.count - maximumLogLines) older lines left out.")
            }
            lines.append(contentsOf: log.suffix(maximumLogLines))
        }
        lines.append("")
        lines.append("## Crash reports, last 7 days")
        if crashReports.isEmpty {
            lines.append("None.")
        }
        for report in crashReports {
            lines.append("")
            lines.append("### \(report.name)")
            lines.append(report.contents)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// One log entry as a line.
    static func logLine(date: Date, level: String, category: String, message: String) -> String {
        "\(timestamp(date)) \(level) [\(category)] \(message)"
    }

    /// The file name, such as Orra-Report-2026-10-10-153012.txt.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Orra-Report-\(formatter.string(from: date)).txt"
    }

    /// Bytes as gigabytes with one decimal, the same in every language.
    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), Double(bytes) / 1_000_000_000)
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: Crash reports

    /// The crash report files to include: Orra's .ips files from the last 7 days, the
    /// newest first, at most three.
    static func crashReportNames(_ files: [(name: String, modified: Date)], now: Date) -> [String] {
        files
            .filter { $0.name.hasPrefix("Orra") && $0.name.hasSuffix(".ips") }
            .filter { now.timeIntervalSince($0.modified) <= crashReportAge }
            .sorted { $0.modified > $1.modified }
            .prefix(maximumCrashReports)
            .map(\.name)
    }

    // MARK: Issue

    /// The new issue page with the bug report form, the version fields filled in. GitHub
    /// issue forms take a field's id as a query parameter.
    static func issueURL(version: String, macOS: String, mac: String) -> URL {
        let items = [
            ("template", "bug_report.yml"),
            ("version", version),
            ("macos", macOS),
            ("mac", mac),
        ]
        // Only unreserved characters stay as they are, so a plus or an ampersand in a value
        // cannot change the query.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let query = items.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return URL(string: "https://github.com/db-ol/Orra/issues/new?\(query)")!
    }
}
