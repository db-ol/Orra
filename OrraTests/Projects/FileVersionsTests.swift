import Foundation
import Testing
@testable import Orra

struct FileVersionsTests {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func file(_ name: String, day: Int = 0, head: String = "") -> FileVersions.File {
        FileVersions.File(url: url(name), modified: Self.start.addingTimeInterval(Double(day) * 86_400), head: head)
    }

    /// A file of the project's folder, or of a subfolder when the name holds a slash.
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Projects/Harbor/" + name)
    }

    private func statuses(_ files: [FileVersions.File]) -> [String: String] {
        let versions = FileVersions(files)
        var result: [String: String] = [:]
        for file in files {
            let name = file.url.lastPathComponent
            switch versions.status(of: file.url) {
            case .current: result[name] = "current"
            case .replaced(by: let newer): result[name] = newer.lastPathComponent
            case .earlier(than: let newer): result[name] = "earlier than " + newer.lastPathComponent
            }
        }
        return result
    }

    // MARK: Names

    @Test func aHigherVersionReplacesALowerOneInAnyFormat() {
        #expect(statuses([file("estimate-v1-2026-08-30.pdf", day: 9), file("estimate-v2-2026-09-21.docx")]) == [
            "estimate-v1-2026-08-30.pdf": "estimate-v2-2026-09-21.docx",
            "estimate-v2-2026-09-21.docx": "current",
        ])
    }

    @Test func aChainEndsAtTheNewest() {
        #expect(statuses([file("brief-v1.md"), file("brief-v2.md"), file("brief-v3.md")]) == [
            "brief-v1.md": "brief-v3.md", "brief-v2.md": "brief-v3.md", "brief-v3.md": "current",
        ])
    }

    @Test func marksRankFiles() {
        #expect(statuses([file("signage.txt"), file("signage-change-2026-10-02.md")])["signage.txt"] == "signage-change-2026-10-02.md")
        #expect(statuses([file("program-2026-09-01.txt"), file("program-update-2026-10-05.md")])["program-2026-09-01.txt"] == "program-update-2026-10-05.md")
        #expect(statuses([file("letter-draft.docx", day: 3), file("letter.docx")])["letter-draft.docx"] == "letter.docx")
        #expect(statuses([file("layout-v5.pdf", day: 3), file("layout-final.pdf")])["layout-v5.pdf"] == "layout-final.pdf")
        #expect(statuses([file("budget-old.xlsx", day: 3), file("budget.xlsx")])["budget-old.xlsx"] == "budget.xlsx")
    }

    @Test func chineseNamesRankToo() {
        let result = statuses([file("报价单.docx"), file("报价单-修订版.docx"), file("合同第二版.docx"), file("合同第三版.docx"), file("方案v5.pdf"), file("方案（终稿）.pdf")])
        #expect(result["报价单.docx"] == "报价单-修订版.docx")
        #expect(result["合同第二版.docx"] == "合同第三版.docx")
        #expect(result["方案v5.pdf"] == "方案（终稿）.pdf")
        #expect(result["合同第三版.docx"] == "current")
    }

    @Test func filesThatDifferOnlyByDateAreEarlierAndNotReplaced() {
        // Invoices of two months and the notes of two meetings both hold values of their own.
        #expect(statuses([file("invoice-2026-10-01.pdf"), file("invoice-2026-11-01.pdf")]) == [
            "invoice-2026-10-01.pdf": "earlier than invoice-2026-11-01.pdf",
            "invoice-2026-11-01.pdf": "current",
        ])
        #expect(statuses([file("minutes-2026-09-01.md"), file("minutes-2026-09-15.md"), file("minutes-2026-09-29.md")])["minutes-2026-09-01.md"] == "earlier than minutes-2026-09-29.md")
        #expect(statuses([file("quote.pdf", day: 1), file("quote.docx", day: 2)])["quote.pdf"] == "earlier than quote.docx")
        // A version among the dates still replaces.
        #expect(statuses([file("plan-2026-09-01.md"), file("plan-v2-2026-08-01.md")])["plan-2026-09-01.md"] == "plan-v2-2026-08-01.md")
    }

    @Test func filesInOtherFoldersAreOtherDocuments() {
        let versions = FileVersions([file("client-a/contract.md", day: 1), file("client-b/contract.md", day: 2), file("client-b/contract-v2.md")])
        #expect(versions.status(of: url("client-a/contract.md")) == .current)
        #expect(versions.status(of: url("client-b/contract.md")) == .replaced(by: url("client-b/contract-v2.md")))
        // A line names the version of its own folder's document.
        let stated = FileVersions([file("client-a/terms-v1.md"), file("client-b/terms-v1.md"), file("client-b/terms.md", head: "替代 v1")])
        #expect(stated.status(of: url("client-a/terms-v1.md")) == .current)
        #expect(stated.status(of: url("client-b/terms-v1.md")) == .replaced(by: url("client-b/terms.md")))
    }

    @Test func differentDocumentsStayCurrent() {
        let result = statuses([file("resume-ana-ruiz.pdf"), file("resume-kai-holt.docx"), file("offer-draft-ana.docx"), file("talk-outline-v3.md"), file("v2.md"), file("v3.md")])
        #expect(Set(result.values) == ["current"])
    }

    @Test func namesSayWhatTheyHold() {
        let name = FileVersions.Name("report_final_v2.1 (1) 2026-10-11.docx")
        #expect(name.family == "report")
        #expect(name.isFinal)
        #expect(name.version == [2, 1])
        #expect(name.date == 20261011)
        #expect(FileVersions.Name("合同第十二版.docx").version == [12])
        #expect(FileVersions.Name("plan_20260915.md").date == 20260915)
        #expect(FileVersions.Name("schedule-update.md").mark == 1)
        #expect(FileVersions.Name("schedule-草稿.md").mark == -1)
        #expect(FileVersions.Name("v2.md").family == nil)
    }

    // MARK: Lines in the files

    @Test func aLineNamesTheVersionItReplaces() {
        // The modification dates and the name order alone would keep the older text.
        let result = statuses([
            file("terms-a.md", day: 5, head: "Terms\nVersion A"),
            file("terms-b.md", day: 1, head: "# Terms (replaces terms-a.md)"),
        ])
        #expect(result["terms-a.md"] == "terms-b.md")
        #expect(result["terms-b.md"] == "current")
    }

    @Test func aLineNamesAnotherDocumentByNameOrDate() {
        #expect(statuses([file("notes.md", head: "This replaces seating-plan.md."), file("seating-plan.md", day: 2)])["seating-plan.md"] == "notes.md")
        // A name in another folder counts when the file's own folder has none.
        let elsewhere = FileVersions([file("final/plan.md", head: "Replaces drafts/plan-old.md"), file("drafts/plan-old.md", day: 2)])
        #expect(elsewhere.status(of: url("drafts/plan-old.md")) == .replaced(by: url("final/plan.md")))
        #expect(statuses([file("agenda-2026-09-15.txt", day: 2), file("program-update.md", head: "取代 2026-09-15 的 agenda。")])["agenda-2026-09-15.txt"] == "program-update.md")
    }

    @Test func aChineseLineNamesTheVersionAndBeatsTheNames() {
        // By the names alone, the file named v2 would be the current one.
        let result = statuses([
            file("展板制作合同.docx", head: "展板制作合同（v3，替代 v2）\n签订日期：2026-10-02"),
            file("展板制作合同-v2.docx", day: 5),
        ])
        #expect(result == ["展板制作合同-v2.docx": "展板制作合同.docx", "展板制作合同.docx": "current"])
    }

    @Test func linesThatPointBothWaysNeverLoop() {
        let result = statuses([
            file("map-a.md", day: 1, head: "This replaces map-b.md"),
            file("map-b.md", day: 2, head: "This replaces map-a.md"),
        ])
        #expect(result.values.filter { $0 == "current" }.count == 1)
        let ring = statuses((0..<5).map { file("part-\($0).md", day: $0, head: "This replaces part-\(($0 + 1) % 5).md") })
        #expect(ring.values.filter { $0 == "current" }.count == 1)
        #expect(Set(ring.values).count == 2)
    }

    @Test func aLongChainOfLinesEndsAtItsStart() {
        let files = (0..<300).map { file("step-\($0).md", day: $0, head: $0 == 0 ? "" : "This replaces step-\($0 - 1).md") }
        let versions = FileVersions(files)
        #expect(versions.status(of: url("step-0.md")) == .replaced(by: url("step-299.md")))
        #expect(versions.status(of: url("step-299.md")) == .current)
    }

    @Test func aFileNotGivenIsCurrent() {
        #expect(FileVersions([file("brief-v1.md"), file("brief-v2.md")]).status(of: url("other.md")) == .current)
        #expect(FileVersions([]).replaced.isEmpty)
    }
}
