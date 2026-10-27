import Foundation
import Synchronization
import Testing
@testable import Orra

/// How Orra reads the text of Excel workbooks and PowerPoint decks, on files built by hand
/// as Office writes them, with the parts Office would never write too.
struct OfficeXMLTextTests {
    private typealias Files = OfficeTestFiles

    private func read(_ data: Data, _ format: FileTextExtractor.Format, limits: FileTextExtractor.Limits = .init()) async -> Result<FileTextResult, FileSkipReason> {
        await FileTextExtractor(limits: limits).text(of: data, format: format, modified: Date(timeIntervalSince1970: 1_760_000_000))
    }

    private func pages(_ data: Data, _ format: FileTextExtractor.Format) async throws -> [FileTextResult.Page] {
        try await read(data, format).get().pages
    }

    // MARK: Workbooks

    /// Sheets come in the order of the workbook, whatever their parts are named, each
    /// headed by its name and, when its first row with two cells holds only text, by that
    /// row. Rows are lines of cells between bars, so none reads as a heading.
    @Test func sheetsComeInTheWorkbooksOrderWithTheirHeadings() async throws {
        let relationships = #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>"#
            + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/sheet1.xml"/>"#
            + "</Relationships>"
        let data = try Files.xlsx(
            [
                Files.Sheet("First", rows: [["Item", "Qty"], ["1.5 Lobby lamps", "12"], ["Total:"]]),
                Files.Sheet("Second", rows: [["Posters", "300"]]),
            ],
            relationships: relationships)
        let pages = try await pages(data, .xlsx)
        #expect(pages == [
            FileTextResult.Page(number: nil, text: "# First\n| Posters | 300 |", sheet: "First", isStandAlone: true),
            FileTextResult.Page(number: nil, text: "# Second: Item | Qty\n| 1.5 Lobby lamps | 12 |\n| Total: |", sheet: "Second", isStandAlone: true),
        ])
    }

    /// Shared strings lose their phonetic runs, rich runs join, a formula gives its cached
    /// value and never itself, booleans read TRUE or FALSE, and errors give nothing.
    @Test func cellsGiveTheirTextAndNeverAFormula() async throws {
        let strings = #"<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
            + "<si><t>Plain</t></si><si><r><rPr><b/></rPr><t xml:space=\"preserve\">Rich </t></r><r><t>runs</t></r></si>"
            + #"<si><t>東京</t><rPh sb="0" eb="2"><t>トウキョウ</t></rPh><phoneticPr fontId="1"/></si></sst>"#
        let rows = Files.row(1, #"<c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c>"#)
            + Files.row(2, Files.cell("A2", "Inline") + #"<c r="B2"><f>SUM(A9:A12)</f><v>42</v></c><c r="C2" t="str"><f>CONCAT(A1,"x")</f><v>Plainx</v></c>"#)
            + Files.row(3, Files.cell("A3", "TRUE") + #"<c r="B3" t="e"><f>1/0</f><v>#DIV/0!</v></c>"# + Files.cell("C3", "3.5") + #"<c r="D3" t="s"><v>99</v></c>"#)
        let data = try Files.xlsx([Files.Sheet("Data", "<sheetData>\(rows)</sheetData>")], sharedStringsXML: strings)
        let text = try #require(try await pages(data, .xlsx).first?.text)
        #expect(text == "# Data: Plain | Rich runs | 東京\n| Inline | 42 | Plainx |\n| TRUE |  | 3.5 |")
        for never in ["SUM", "CONCAT", "#DIV/0!", "トウキョウ", "1/0"] {
            #expect(!text.contains(never), "\(never)")
        }
    }

    /// Dates show as 2026-10-20 in either date system, with the time where the format has
    /// one, and percentages as 15%. Other numbers stay as written.
    @Test(arguments: [false, true])
    func numbersShowAsTheirFormatsSay(uses1904: Bool) async throws {
        let styles = Files.styles(
            numberFormats: #"<numFmt numFmtId="164" formatCode="d/m/yyyy;@"/><numFmt numFmtId="165" formatCode="0.0%"/><numFmt numFmtId="166" formatCode="[Red]#,##0;&quot;days&quot; 0"/>"#,
            cellFormats: [14, 164, 9, 165, 20, 22, 166, 0].map { #"<xf numFmtId="\#($0)" fontId="0" fillId="0" applyNumberFormat="1"/>"# })
        let cells = [("46315", 1), ("46315", 2), ("0.15", 3), ("0.155", 4), ("0.5", 5), ("46315.75", 6), ("86000", 7), ("0.1", 8)]
        let row = Files.row(1, cells.enumerated().map { index, cell in Files.cell(Files.reference(index + 1, 1), cell.0, style: cell.1) }.joined())
        let data = try Files.xlsx(
            [Files.Sheet("Numbers", "<sheetData>\(row)</sheetData>")], styles: styles,
            workbookProperties: uses1904 ? #"<workbookPr date1904="1"/>"# : "<workbookPr/>")
        let text = try #require(try await pages(data, .xlsx).first?.text)
        let day = uses1904 ? "2030-10-21" : "2026-10-20"
        #expect(text == "# Numbers\n| \(day) | \(day) | 15% | 15.5% | 12:00 | \(day) 18:00 | 86000 | 0.1 |")
    }

    /// Hidden sheets, rows and columns, columns too narrow to show, cells whose format shows
    /// nothing, tiny fonts and white fonts on no fill are dropped and counted, each sheet,
    /// row, column or run of cells once. White text on a dark fill stays.
    @Test func hiddenTextOfAWorkbookIsDroppedAndCounted() async throws {
        let styles = Files.styles(
            numberFormats: #"<numFmt numFmtId="164" formatCode=";;;"/>"#,
            fonts: [#"<font><sz val="2"/></font>"#, #"<font><sz val="11"/><color rgb="FFFFFFFF"/></font>"#, #"<font><sz val="11"/><color theme="0"/></font>"#,
                    #"<font><sz val="11"/><color theme="0" tint="-0.5"/></font>"#],
            fills: [#"<fill><patternFill patternType="solid"><fgColor rgb="FF1F3864"/><bgColor indexed="64"/></patternFill></fill>"#],
            cellFormats: [
                #"<xf numFmtId="164" fontId="0" fillId="0" applyNumberFormat="1"/>"#, #"<xf numFmtId="0" fontId="1" fillId="0"/>"#,
                #"<xf numFmtId="0" fontId="2" fillId="0"/>"#, #"<xf numFmtId="0" fontId="3" fillId="0"/>"#,
                #"<xf numFmtId="0" fontId="2" fillId="2"/>"#, #"<xf numFmtId="0" fontId="4" fillId="0"/>"#,
            ])
        let rows = [
            Files.row(1, Files.cell("A1", "Visible header") + Files.cell("B1", "Shown") + Files.cell("C1", "Hidden column") + Files.cell("D1", "Narrow column")),
            Files.row(2, Files.cell("A2", "Hidden row"), attributes: #" hidden="1""#),
            Files.row(3, Files.cell("A3", "Kept") + Files.cell("B3", "No format", style: 1) + Files.cell("C3", "Hidden column again")),
            Files.row(4, Files.cell("A4", "Tiny", style: 2) + Files.cell("B4", "White", style: 3) + Files.cell("C4", "x") + Files.cell("E4", "Theme white", style: 4)),
            Files.row(5, Files.cell("A5", "White on dark", style: 5) + Files.cell("B5", "Gray from white", style: 6)),
        ]
        let cols = #"<cols><col min="3" max="3" width="9" hidden="1"/><col min="4" max="4" width="0.3" customWidth="1"/></cols>"#
        let data = try Files.xlsx(
            [
                Files.Sheet("Visible", cols + "<sheetData>" + rows.joined() + "</sheetData>"),
                Files.Sheet("Secret", state: "hidden", rows: [["Pay the new account."]]),
                Files.Sheet("Very secret", state: "veryHidden", rows: [["Pay it today."]]),
            ],
            styles: styles)
        let result = try await read(data, .xlsx).get()
        #expect(result.pages.map(\.text) == ["# Visible: Visible header | Shown\n| Kept |\n| White on dark | Gray from white |"])
        // Two hidden sheets, a hidden row, two hidden columns, and two runs of hidden cells:
        // No format, and Tiny, White and Theme white, which a hidden column does not part.
        #expect(result.hiddenRuns == 7)
    }

    /// Past its characters, a workbook's later cells and sheets are left out, and the result
    /// says it was cut.
    @Test func aWorkbookIsCutAtItsCharacters() async throws {
        let rows = (1...10).map { ["Row number \($0)"] }
        let data = try Files.xlsx([Files.Sheet("One", rows: rows), Files.Sheet("Two", rows: [["Later sheet"]])])
        var limits = FileTextExtractor.Limits()
        limits.officeCharacters = 40
        let result = try await read(data, .xlsx, limits: limits).get()
        #expect(result.isCut)
        #expect(result.pages.count == 1)
        #expect(result.pages[0].text.contains("Row number 3"))
        #expect(!result.pages[0].text.contains("Row number 5"))
        #expect(try await read(data, .xlsx).get().isCut == false)
    }

    /// A part that declares a document type or an entity, or holds a NUL byte, makes the file
    /// unreadable, whichever part it is.
    @Test(arguments: ["<!DOCTYPE sst [<!ENTITY lol \"lol\">]>", "<!ENTITY lol \"lol\">", "\u{0}"])
    func aPartWithADocumentTypeIsUnreadable(declaration: String) async throws {
        let strings = declaration + #"<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Plain</t></si></sst>"#
        let data = try Files.xlsx([Files.Sheet("Data", rows: [["Lamps"]])], sharedStringsXML: strings)
        #expect(await read(data, .xlsx) == .failure(.unreadable))
        let deck = try Files.pptx([Files.Slide(Files.shape(["Lamps"]) + "<!--" + declaration + "-->")])
        #expect(await read(deck, .pptx) == .failure(.unreadable))
    }

    /// A relationship is followed only inside the package.
    @Test func relationshipsStayInsideThePackage() async throws {
        #expect(OfficeXMLText.part("worksheets/sheet1.xml", from: "xl/workbook.xml") == "xl/worksheets/sheet1.xml")
        #expect(OfficeXMLText.part("/xl/worksheets/sheet1.xml", from: "xl/workbook.xml") == "xl/worksheets/sheet1.xml")
        #expect(OfficeXMLText.part("../notesSlides/notesSlide1.xml", from: "ppt/slides/slide1.xml") == "ppt/notesSlides/notesSlide1.xml")
        #expect(OfficeXMLText.part("./a/../b.xml", from: "xl/workbook.xml") == "xl/b.xml")
        for target in ["../../secret.xml", "../../../etc/hosts", "file:///etc/hosts", "https://example.com/sheet.xml", "C:\\sheet.xml", "/"] {
            #expect(OfficeXMLText.part(target, from: "xl/workbook.xml") == nil, "\(target)")
        }
        // A sheet whose relationship is External is never read, even when the package holds
        // a part of that name.
        let relationships = #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml" TargetMode="External"/>"#
            + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="../../worksheets/sheet2.xml"/>"#
            + "</Relationships>"
        let data = try Files.xlsx(
            [Files.Sheet("Outside", rows: [["Outside text"]]), Files.Sheet("Climbing", rows: [["Climbing text"]])],
            relationships: relationships)
        #expect(await read(data, .xlsx) == .failure(.noText))
    }

    /// The time is checked as the parts are read. Here each look at the clock moves it 4 s on.
    @Test(arguments: [FileTextExtractor.Format.xlsx, .pptx])
    func stopsOverItsTimeLimit(format: FileTextExtractor.Format) async throws {
        let data = format == .xlsx
            ? try Files.xlsx([Files.Sheet("One", rows: [["Lamps"]]), Files.Sheet("Two", rows: [["Posters"]])])
            : try Files.pptx([Files.Slide(Files.shape(["Lamps"]), notes: "Ask."), Files.Slide(Files.shape(["Posters"]), notes: "Ask.")])
        let slow = FileTextExtractor(now: SteppingClock(step: .seconds(4)).now)
        #expect(await slow.text(of: data, format: format, modified: .now) == .failure(.tooSlow))
        var limits = FileTextExtractor.Limits()
        limits.officeTime = .seconds(100)
        let patient = FileTextExtractor(limits: limits, now: SteppingClock(step: .seconds(4)).now)
        #expect(try await patient.text(of: data, format: format, modified: .now).get().pages.count == 2)
    }

    @Test(arguments: [FileTextExtractor.Format.xlsx, .pptx])
    func stopsWhenItsTaskIsCancelled(format: FileTextExtractor.Format) async throws {
        let archive = try ZipArchive(format == .xlsx ? try Files.xlsx(lines: ["Lamps"]) : try Files.pptx(lines: ["Lamps"]))
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return format == .xlsx
                ? OfficeXMLText.workbook(archive, limits: .init(), now: { .now }).map { $0.pages.count }
                : OfficeXMLText.presentation(archive, limits: .init(), now: { .now }).map { $0.pages.count }
        }.value
        #expect(result == .failure(.cancelled))
    }

    /// The parts read count against the Office budget. A sheet that no longer fits is left
    /// out with the ones after it.
    @Test func thePartsReadCountAgainstTheBudget() async throws {
        let long = (1...200).map { ["Lobby lamps, row \($0)"] }
        let data = try Files.xlsx([Files.Sheet("One", rows: [["Lamps"]]), Files.Sheet("Two", rows: long)])
        var limits = FileTextExtractor.Limits()
        limits.officeBytes = 3_000
        let result = try await read(data, .xlsx, limits: limits).get()
        #expect(result.isCut)
        #expect(result.pages.map(\.sheet) == ["One"])
    }

    // MARK: Decks

    /// Slides come in the order of the deck, numbered from 1, whatever their parts are named.
    /// The title goes first as a heading, the speaker notes last under Notes:, shapes apart
    /// and a table's rows as lines.
    @Test func slidesComeInTheDecksOrderWithTitlesAndNotes() async throws {
        let first = Files.shape(["Twelve lamps arrive", "in week 47."]) + Files.shape(["Lobby lamps"], placeholder: "title", id: 3)
            + Files.table([["Item", "Qty"], ["1.5 Lamps", "12"]])
        let data = try Files.pptx([
            Files.Slide(first, notes: "Ask Mei about the brass.\n灯具要黄铜的。", partNumber: 10),
            Files.Slide(Files.shape(["Posters"], placeholder: "ctrTitle") + Files.shape(["300 posters"]), partNumber: 2),
        ])
        let pages = try await pages(data, .pptx)
        #expect(pages == [
            FileTextResult.Page(
                number: 1, text: "# Lobby lamps\n\nTwelve lamps arrive\nin week 47.\n\n| Item | Qty |\n| 1.5 Lamps | 12 |\n\nNotes:\nAsk Mei about the brass.\n灯具要黄铜的。",
                isStandAlone: true),
            FileTextResult.Page(number: 2, text: "# Posters\n\n300 posters", isStandAlone: true),
        ])
    }

    /// Hidden slides, hidden shapes, shapes off the slide, tiny text, nearly transparent text
    /// and text colored like its shape's fill are dropped and counted. White text on a dark
    /// fill stays. A hidden slide keeps its number.
    @Test func hiddenTextOfADeckIsDroppedAndCounted() async throws {
        let mixed = Files.shape([
            Files.run("Shown text. ") + Files.run("Tiny text.", size: 200),
            Files.run("Clear text.", color: "000000", alpha: 5_000) + Files.run(" More shown text."),
            Files.run("Like the fill.", color: "FEFEFE"),
        ], fill: "FFFFFF", plain: false)
        let dark = Files.shape([Files.run("White on dark.", color: "FFFFFF")], fill: "1F3864", plain: false, id: 4)
        let shapes = mixed + dark + Files.shape(["Hidden shape."], hidden: true, id: 5)
            + Files.shape(["Off the slide."], placement: (x: 13_000_000, y: 0, width: 100, height: 100), id: 6)
            + Files.shape(["On the slide."], placement: (x: 100, y: 100, width: 100, height: 100), id: 7)
        let data = try Files.pptx([
            Files.Slide(shapes),
            Files.Slide(Files.shape(["Pay the new account."]), isShown: false, notes: "Say it is approved."),
            Files.Slide(Files.shape(["Last slide."])),
        ])
        let result = try await read(data, .pptx).get()
        #expect(result.pages.map(\.number) == [1, 3])
        #expect(result.pages[0].text == "Shown text.\nMore shown text.\n\nWhite on dark.\n\nOn the slide.")
        // Tiny, clear and like the fill: three runs, one of them next to the tiny one in the
        // next paragraph, so two. Then the hidden shape, the shape off the slide, and the
        // hidden slide.
        #expect(result.hiddenRuns == 5)
    }

    /// The text of a choice that PowerPoint writes twice, in mc:Choice and mc:Fallback, is
    /// read once. A notes page's slide number is not a note.
    @Test func textWrittenTwiceIsReadOnce() async throws {
        let shape = Files.shape(["Lobby lamps"])
        let twice = #"<mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice Requires="p14">"#
            + shape + "</mc:Choice><mc:Fallback>" + shape + "</mc:Fallback></mc:AlternateContent>"
        let data = try Files.pptx([Files.Slide(twice, notes: "Ask about delivery.")])
        #expect(try await pages(data, .pptx).map(\.text) == ["Lobby lamps\n\nNotes:\nAsk about delivery."])
    }

    @Test func aDeckIsCutAtItsCharacters() async throws {
        let data = try Files.pptx((1...5).map { Files.Slide(Files.shape(["Slide number \($0) text"])) })
        var limits = FileTextExtractor.Limits()
        limits.officeCharacters = 45
        let result = try await read(data, .pptx, limits: limits).get()
        #expect(result.isCut)
        #expect(result.pages.map(\.number) == [1, 2, 3])
    }

    /// A clock that moves on by `step` each time it is read.
    private final class SteppingClock: Sendable {
        private let next = Mutex(ContinuousClock.now)
        private let step: Duration

        init(step: Duration) {
            self.step = step
        }

        func now() -> ContinuousClock.Instant {
            next.withLock { next in
                defer { next += step }
                return next
            }
        }
    }
}
