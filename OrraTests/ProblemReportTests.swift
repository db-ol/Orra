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

    @Test func issueURLFillsTheFormFields() {
        let url = ProblemReport.issueURL(version: "0.1.1 (7)", macOS: "macOS 26.0 (25A354)", mac: "Mac15,6 Apple M3+Pro&x")
        #expect(url.absoluteString == "https://github.com/db-ol/Orra/issues/new?template=bug_report.yml&version=0.1.1%20%287%29&macos=macOS%2026.0%20%2825A354%29&mac=Mac15%2C6%20Apple%20M3%2BPro%26x")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "mac" }?.value == "Mac15,6 Apple M3+Pro&x")
    }

    @Test func issueFormHasTheFieldsTheURLFills() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml")
        let form = try String(contentsOf: url, encoding: .utf8)
        for id in ["version", "macos", "mac"] {
            #expect(form.contains("    id: \(id)\n"), "\(id)")
        }
    }
}
