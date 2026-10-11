import Foundation
import Testing
@testable import Orra

struct ProblemReportTests {
    private static let facts = ProblemReport.Facts(
        version: "0.1.1",
        build: "7",
        macOS: "macOS 26.0 (25A354)",
        model: "Mac15,6",
        chip: "Apple M3 Pro",
        memoryBytes: 36_000_000_000,
        preferredLanguages: ["zh-Hans-CN", "en-US"],
        interfaceLanguage: "zh-Hans",
        speechModel: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
        speechModelBytes: 2_470_000_000,
        speechModelState: "installed, loaded",
        microphoneAccess: "granted",
        accessibilityTrusted: true,
        talkKeyActive: true,
        talkKeys: ["rightControl", "fn"],
        microphone: "System default (MacBook Pro Microphone)",
        settings: [.init(name: "Sounds", on: true), .init(name: "Show in Dock", on: false)],
        vocabularyCount: 12,
        learnedPairCount: 3
    )

    @Test func redactsTheHomeFolderAndTheNames() {
        let text = """
        Could not open /Users/jane/Library/Application Support/io.github.db-ol.Orra/Models
        Jane Doe’s AirPods on JANE-MBP, user jane, Janet stays
        """
        let redacted = ProblemReport.redact(text, home: "/Users/jane", userNames: ["jane", "Jane Doe", "Jane", "Doe"], computerName: "JANE-MBP")
        #expect(redacted == """
        Could not open ~/Library/Application Support/io.github.db-ol.Orra/Models
        <user>’s AirPods on <computer>, user <user>, Janet stays
        """)
    }

    @Test func redactsNamesNextToChineseCharacters() {
        let text = "Microphone: Jane Doe的AirPods Pro, 田傲然的AirPods, 张伟的 iPhone 麦克风, Janet的AirPods"
        let redacted = ProblemReport.redact(text, home: "/Users/jane", userNames: ["jane", "Jane Doe", "田傲然", "张伟"], computerName: nil)
        #expect(redacted == "Microphone: <user>的AirPods Pro, <user>的AirPods, <user>的 iPhone 麦克风, Janet的AirPods")
    }

    @Test func redactsNamePartsInTheMicrophoneOnly() {
        var facts = Self.facts
        facts.microphone = "Mark的AirPods Pro, Mark’s iPhone"
        let redacted = ProblemReport.redactDeviceNames(facts, nameParts: ["Mark", "Lee"])
        #expect(redacted.microphone == "<user>的AirPods Pro, <user>’s iPhone")
        // The rest of the report keeps ordinary words that are also a name part.
        let report = ProblemReport.redact("Will mark the Mac", home: "/Users/mark", userNames: ["mark", "Mark Will"], computerName: nil)
        #expect(report == "Will <user> the Mac")
    }

    @Test func leavesShortNamesAndOtherPathsAlone() {
        let text = "/Users/joe/file and /Users/jo, /Users/jo/x, jo"
        let redacted = ProblemReport.redact(text, home: "/Users/jo/", userNames: ["jo"], computerName: nil)
        // A short name matches too much, and the home folder of another user stays.
        #expect(redacted == "/Users/joe/file and ~, ~/x, jo")
    }

    @Test func reportHoldsTheFactsAndCountsOnly() {
        let created = Date(timeIntervalSince1970: 1_791_000_000)
        let report = ProblemReport.format(
            Self.facts,
            log: ["line one", "line two"],
            logSource: "log store",
            crashReports: [.init(name: "Orra-2026-10-09-120000.ips", contents: "{\"crash\":1}")],
            created: created
        )
        #expect(report.contains("Version: 0.1.1 (7)"))
        #expect(report.contains("macOS: macOS 26.0 (25A354)"))
        #expect(report.contains("Model: Mac15,6"))
        #expect(report.contains("Chip: Apple M3 Pro"))
        #expect(report.contains("Memory: 36.0 GB"))
        #expect(report.contains("Preferred languages: zh-Hans-CN, en-US"))
        #expect(report.contains("Folder size: 2.5 GB"))
        #expect(report.contains("Accessibility: granted"))
        #expect(report.contains("Talk keys: rightControl, fn"))
        #expect(report.contains("Sounds: on"))
        #expect(report.contains("Show in Dock: off"))
        #expect(report.contains("Vocabulary: 12 words"))
        #expect(report.contains("Learned word pairs: 3"))
        #expect(report.contains("## Log, last hour (log store)\nline one\nline two"))
        #expect(report.contains("### Orra-2026-10-09-120000.ips\n{\"crash\":1}"))
    }

    @Test func reportKeepsTheNewestLogLines() {
        let log = (1...(ProblemReport.maximumLogLines + 5)).map { "line \($0)" }
        let report = ProblemReport.format(Self.facts, log: log, logSource: "log show", crashReports: [], created: Date())
        #expect(report.contains("5 older lines left out."))
        #expect(!report.contains("line 5\n"))
        #expect(report.contains("line 6\n"))
        #expect(report.contains("None."))
    }

    @Test func picksRecentOrraCrashReports() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let files: [(name: String, modified: Date)] = [
            ("Orra-a.ips", now.addingTimeInterval(-1 * day)),
            ("Orra-b.ips", now.addingTimeInterval(-2 * day)),
            ("Orra-c.ips", now.addingTimeInterval(-3 * day)),
            ("Orra-d.ips", now.addingTimeInterval(-0.5 * day)),
            ("Orra-old.ips", now.addingTimeInterval(-8 * day)),
            ("Safari-x.ips", now),
            ("Orra-e.diag", now),
        ]
        #expect(ProblemReport.crashReportNames(files, now: now) == ["Orra-d.ips", "Orra-a.ips", "Orra-b.ips"])
    }

    @Test func fileNameCarriesTheDate() {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(ProblemReport.fileName(for: date, timeZone: TimeZone(identifier: "UTC")!) == "Orra-Report-2026-10-03-040000.txt")
    }

    private static func value(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func issue(title: String = "", _ text: String) -> ProblemReport.Issue {
        ProblemReport.issue(title: title, whatHappened: text, version: "0.1.1 (7)", macOS: "macOS 26.0 (25A354)", mac: "Mac15,6 Apple M3 Pro")
    }

    @Test func issueURLFillsTheFormFields() {
        let issue = ProblemReport.issue(title: "Hotkey & paste", whatHappened: "Held fn+Space.\nNothing pasted.", version: "0.1.1 (7)", macOS: "macOS 26.0 (25A354)", mac: "Mac15,6 Apple M3+Pro&x")
        #expect(!issue.wasCut)
        #expect(issue.url.absoluteString == "https://github.com/db-ol/Orra/issues/new?template=bug_report.yml&title=Hotkey%20%26%20paste&what-happened=Held%20fn%2BSpace.%0ANothing%20pasted.&version=0.1.1%20%287%29&macos=macOS%2026.0%20%2825A354%29&mac=Mac15%2C6%20Apple%20M3%2BPro%26x")
        #expect(Self.value("mac", in: issue.url) == "Mac15,6 Apple M3+Pro&x")
        #expect(Self.value("what-happened", in: issue.url) == "Held fn+Space.\nNothing pasted.")
    }

    @Test func titleComesFromTheFirstLineWhenEmpty() {
        let issue = Self.issue("  按住 fn 键没有反应 🙁\n第二行")
        #expect(Self.value("title", in: issue.url) == "按住 fn 键没有反应 🙁")
        #expect(Self.value("what-happened", in: issue.url) == "按住 fn 键没有反应 🙁\n第二行")
        let long = Self.issue(title: String(repeating: "word ", count: 100), "Text")
        let title = Self.value("title", in: long.url) ?? ""
        #expect(title.count == ProblemReport.maximumTitleLength)
        #expect(title.hasSuffix("word…"))
        let emoji = Self.issue(title: String(repeating: "👨‍👩‍👧", count: 100), "Text")
        let emojiTitle = Self.value("title", in: emoji.url) ?? ""
        #expect(ProblemReport.encode(emojiTitle).count <= ProblemReport.maximumEncodedTitleLength)
        #expect(emojiTitle.hasSuffix("👨‍👩‍👧…"))
        #expect(emojiTitle.count > 10)
    }

    @Test func emptyTextLeavesTheFieldsOut() {
        let issue = Self.issue("  \n ")
        #expect(issue.url.absoluteString == "https://github.com/db-ol/Orra/issues/new?template=bug_report.yml&version=0.1.1%20%287%29&macos=macOS%2026.0%20%2825A354%29&mac=Mac15%2C6%20Apple%20M3%20Pro")
    }

    @Test(arguments: [
        String(repeating: "The talk key did nothing. ", count: 400),
        String(repeating: "按住说话键以后没有任何反应，", count: 400),
        String(repeating: "👨‍👩‍👧🎙️", count: 400),
        String(repeating: "a中😀", count: 900),
    ])
    func longTextIsCutToFitTheLink(_ text: String) throws {
        let issue = Self.issue(text)
        #expect(issue.wasCut)
        #expect(issue.url.absoluteString.count <= ProblemReport.maximumIssueURLLength)
        let field = try #require(Self.value("what-happened", in: issue.url))
        #expect(field.hasSuffix(ProblemReport.cutMarker))
        let start = String(field.dropLast(ProblemReport.cutMarker.count))
        #expect(start.count > 100)
        #expect(text.hasPrefix(start))
        // Whole characters only: the start ends where a character of the text ends.
        #expect(Array(text).starts(with: Array(start)))
        // One more character would not fit.
        let next = Array(text)[start.count]
        #expect(ProblemReport.encode(start + String(next)).count + ProblemReport.encode(ProblemReport.cutMarker).count > ProblemReport.maximumIssueURLLength - (issue.url.absoluteString.count - ProblemReport.encode(field).count) || next.isWhitespace)
    }

    @Test func percentEncodingMakesChineseAndEmojiLonger() {
        #expect(ProblemReport.encode("a").count == 1)
        #expect(ProblemReport.encode("中").count == 9)
        #expect(ProblemReport.encode("😀").count == 12)
        #expect(ProblemReport.encode("👨‍👩‍👧").count == 54)
        // 1,000 Chinese characters are short as text but too long for the link.
        let issue = Self.issue(String(repeating: "中", count: 1000))
        #expect(issue.wasCut)
        let short = Self.issue(String(repeating: "中", count: 500))
        #expect(!short.wasCut)
        #expect(short.url.absoluteString.count <= ProblemReport.maximumIssueURLLength)
    }

    @Test func textThatFitsExactlyIsNotCut() {
        let empty = Self.issue(title: "T", "x").url.absoluteString.count - 1
        let room = ProblemReport.maximumIssueURLLength - empty
        let fits = Self.issue(title: "T", String(repeating: "x", count: room))
        #expect(!fits.wasCut)
        #expect(fits.url.absoluteString.count == ProblemReport.maximumIssueURLLength)
        #expect(Self.issue(title: "T", String(repeating: "x", count: room + 1)).wasCut)
    }

    @Test func cutKeepsNothingWhenEvenTheMarkerDoesNotFit() {
        #expect(ProblemReport.cut("Hello", toFit: 10) == "")
    }

    @Test func issueFormHasTheFieldsTheURLFills() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml")
        let form = try String(contentsOf: url, encoding: .utf8)
        for id in ["what-happened", "version", "macos", "mac"] {
            #expect(form.contains("    id: \(id)\n"), "\(id)")
        }
    }
}
