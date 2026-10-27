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

    /// A time of day shows without its date, a length of time in its largest unit past a
    /// day, as Excel shows [h]:mm, and a built in format that is a date in Japanese files and
    /// a time in Chinese ones shows a date for whole days.
    @Test(arguments: [false, true])
    func timesShowAsTheirFormatsSay(uses1904: Bool) async throws {
        let styles = Files.styles(
            numberFormats: #"<numFmt numFmtId="164" formatCode="[h]:mm"/><numFmt numFmtId="165" formatCode="[mm]:ss"/>"#
                + #"<numFmt numFmtId="166" formatCode="h:mm AM/PM"/><numFmt numFmtId="167" formatCode="[$-409]mmm d, yyyy"/>"#,
            cellFormats: [46, 164, 165, 20, 166, 34, 34, 167].map { #"<xf numFmtId="\#($0)" fontId="0" fillId="0" applyNumberFormat="1"/>"# })
        let cells = [("1.5", 1), ("1.5", 2), ("0.5", 3), ("45000.75", 4), ("0.75", 5), ("46315.5", 6), ("0.5", 7), ("46315", 8)]
        let row = Files.row(1, cells.enumerated().map { index, cell in Files.cell(Files.reference(index + 1, 1), cell.0, style: cell.1) }.joined())
        let data = try Files.xlsx(
            [Files.Sheet("Times", "<sheetData>\(row)</sheetData>")], styles: styles,
            workbookProperties: uses1904 ? #"<workbookPr date1904="1"/>"# : "<workbookPr/>")
        let text = try #require(try await pages(data, .xlsx).first?.text)
        let day = uses1904 ? "2030-10-21" : "2026-10-20"
        #expect(text == "# Times\n| 36:00:00 | 36:00 | 720:00 | 18:00 | 18:00 | \(day) | 12:00 | \(day) |")
    }

    /// A number keeps at most the 15 significant digits Excel shows, so a sum that binary
    /// arithmetic saved a little off reads as the sheet shows it. Other numbers stay as
    /// written.
    @Test func numbersKeepTheDigitsExcelShows() async throws {
        let values = ["59.970000000000006", "0.30000000000000004", "-1.0000000000000002", "86000", "123456789012345", "1.2345678901234568E+17", "0.1"]
        let text = try #require(try await pages(try Files.xlsx([Files.Sheet("Sums", rows: [values])]), .xlsx).first?.text)
        #expect(text == "# Sums\n| 59.97 | 0.3 | -1 | 86000 | 123456789012345 | 1.2345678901234568E+17 | 0.1 |")
    }

    /// A value whose section of its cell's format is empty shows nothing: every number under
    /// ;;, whose text still shows, and the numbers below 0 under 0;. A zero that shows as
    /// nothing, as when a sheet hides its zeros, is an empty cell, not hidden text. A semicolon
    /// in quotes parts no section. White text on a fill without a pattern is on no fill,
    /// whatever the fill's color says.
    @Test func emptySectionsAndFillsWithoutAPatternHideWhatTheyHide() async throws {
        let styles = Files.styles(
            numberFormats: #"<numFmt numFmtId="164" formatCode=";;"/><numFmt numFmtId="165" formatCode="0;"/><numFmt numFmtId="166" formatCode="&quot;x;;&quot;0"/>"#
                + #"<numFmt numFmtId="167" formatCode="0;-0;;@"/>"#,
            fonts: [#"<font><sz val="11"/><color rgb="FFFFFFFF"/></font>"#],
            fills: [#"<fill><patternFill patternType="none"><fgColor rgb="FF000000"/></patternFill></fill>"#],
            cellFormats: [
                #"<xf numFmtId="164" fontId="0" fillId="0" applyNumberFormat="1"/>"#, #"<xf numFmtId="165" fontId="0" fillId="0" applyNumberFormat="1"/>"#,
                #"<xf numFmtId="166" fontId="0" fillId="0" applyNumberFormat="1"/>"#, #"<xf numFmtId="0" fontId="1" fillId="2"/>"#,
                #"<xf numFmtId="167" fontId="0" fillId="0" applyNumberFormat="1"/>"#,
            ])
        let row = Files.row(1, Files.cell("A1", "Shown") + Files.cell("B1", "86000", style: 1) + Files.cell("C1", "Text under it", style: 1)
            + Files.cell("D1", "12", style: 2) + Files.cell("E1", "-12", style: 2) + Files.cell("F1", "-5", style: 3) + Files.cell("G1", "White", style: 4)
            + Files.cell("H1", "0", style: 5) + Files.cell("I1", "7", style: 5))
        let result = try await read(try Files.xlsx([Files.Sheet("Formats", "<sheetData>\(row)</sheetData>")], styles: styles), .xlsx).get()
        #expect(result.pages.map(\.text) == ["# Formats\n| Shown |  | Text under it | 12 |  | -5 |  |  | 7 |"])
        #expect(result.hiddenRuns == 3)
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

    /// The runs of a rich text cell whose own font is tiny, or white where the cell has no
    /// fill, are dropped and counted, in shared and in inline strings. A cell whose every run
    /// is dropped is a hidden cell, and a white run on a dark fill stays.
    @Test func hiddenRunsOfRichTextCellsAreDroppedAndCounted() async throws {
        let strings = #"<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
            + #"<si><r><t>Visible</t></r><r><rPr><color rgb="FFFFFFFF"/></rPr><t xml:space="preserve"> white words</t></r><r><t xml:space="preserve"> end.</t></r></si>"#
            + #"<si><r><rPr><sz val="1"/></rPr><t>tiny words</t></r><r><t>Shown</t></r></si>"#
            + #"<si><r><rPr><color theme="0"/></rPr><t>All white</t></r></si></sst>"#
        let inline = #"<c r="A4" t="inlineStr"><is><r><rPr><color rgb="FFFFFFFF"/></rPr><t>Inline white</t></r><r><t>Inline shown</t></r></is></c>"#
        let rows = Files.row(1, #"<c r="A1" t="s"><v>0</v></c>"#) + Files.row(2, #"<c r="A2" t="s"><v>1</v></c>"#)
            + Files.row(3, #"<c r="A3" t="s"><v>2</v></c>"#) + Files.row(4, inline) + Files.row(5, #"<c r="A5" s="1" t="s"><v>0</v></c>"#)
        let styles = Files.styles(
            fills: [#"<fill><patternFill patternType="solid"><fgColor rgb="FF1F3864"/></patternFill></fill>"#],
            cellFormats: [#"<xf numFmtId="0" fontId="0" fillId="2"/>"#])
        let data = try Files.xlsx([Files.Sheet("Runs", "<sheetData>\(rows)</sheetData>")], sharedStringsXML: strings, styles: styles)
        let result = try await read(data, .xlsx).get()
        #expect(result.pages.map(\.text) == ["# Runs\n| Visible end. |\n| Shown |\n| Inline shown |\n| Visible white words end. |"])
        #expect(result.hiddenRuns == 4)
    }

    /// A header row too long to head the sheet's chunks stays a row, so none of its text is
    /// lost.
    @Test func aHeaderTooLongForAHeadingStaysARow() async throws {
        let titles = (1...3).map { "Column title number \($0), which goes on for a long while" }
        let data = try Files.xlsx([Files.Sheet("Long", rows: [titles, ["1", "2", "3"]])])
        let text = try #require(try await pages(data, .xlsx).first?.text)
        #expect(text == "# Long\n| " + titles.joined(separator: " | ") + " |\n| 1 | 2 | 3 |")
    }

    /// Styles whose elements stand where Excel never puts them are read without a crash.
    @Test func stylesInTheWrongPlaceNeverCrash() async throws {
        let styles = #"<fonts count="1"><x><font><sz val="2"/></font></x></fonts>"#
            + #"<fills count="1"><x><patternFill patternType="solid"><fgColor rgb="FFFFFFFF"/></patternFill></x></fills>"#
            + #"<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0"/></cellXfs>"#
        let data = try Files.xlsx([Files.Sheet("Data", rows: [["Lamps"]])], styles: styles)
        #expect(try await pages(data, .xlsx).map(\.text) == ["# Data\n| Lamps |"])
    }

    /// Past its characters, a workbook's later rows and sheets are left out, the text it
    /// gives never passes them, and the result says it was cut.
    @Test func aWorkbookIsCutAtItsCharacters() async throws {
        let rows = (1...10).map { ["Row number \($0)"] }
        let data = try Files.xlsx([Files.Sheet("One", rows: rows), Files.Sheet("Two", rows: [["Later sheet"]])])
        var limits = FileTextExtractor.Limits()
        limits.officeCharacters = 60
        let result = try await read(data, .xlsx, limits: limits).get()
        #expect(result.isCut)
        #expect(result.pages.map(\.text) == ["# One\n| Row number 1 |\n| Row number 2 |\n| Row number 3 |"])
        #expect(try await read(data, .xlsx).get().isCut == false)
    }

    /// Text in hidden rows, hidden columns and hidden sheets takes none of the characters,
    /// and the text kept never passes them, bars and empty cells included, as one letter
    /// cells five columns apart would.
    @Test func onlyTextThatShowsCountsAgainstTheCharacters() async throws {
        let secret = String(repeating: "Secret words ", count: 20)
        let cols = #"<cols><col min="2" max="2" hidden="1"/></cols>"#
        let rows = Files.row(1, Files.cell("A1", "Lamps") + Files.cell("B1", secret))
            + Files.row(2, Files.cell("A2", secret), attributes: #" hidden="1""#) + Files.row(3, Files.cell("A3", "Posters"))
        let data = try Files.xlsx([Files.Sheet("Data", cols + "<sheetData>\(rows)</sheetData>")])
        var limits = FileTextExtractor.Limits()
        limits.officeCharacters = 60
        let result = try await read(data, .xlsx, limits: limits).get()
        #expect(result.pages.map(\.text) == ["# Data\n| Lamps |\n| Posters |"])
        #expect(!result.isCut)
        #expect(result.hiddenRuns == 2)

        let sparse = (1...40).map { row in Files.row(row, (0..<8).map { Files.cell(Files.reference($0 * 5 + 1, row), "x") }.joined()) }
        let wide = try Files.xlsx([Files.Sheet("Wide", "<sheetData>\(sparse.joined())</sheetData>")])
        limits.officeCharacters = 500
        let cut = try await read(wide, .xlsx, limits: limits).get()
        #expect(cut.isCut)
        #expect(cut.pages.count == 1)
        #expect((400...500).contains(cut.pages[0].text.count))
    }

    /// A hidden sheet is read after the sheets that show, so it takes none of their
    /// characters or room, wherever it stands in the workbook. It counts once, also when it
    /// no longer fits, since it may hold text.
    @Test func hiddenSheetsNeverTakeTheRoomOfSheetsThatShow() async throws {
        let data = try Files.xlsx([
            Files.Sheet("Lookup", state: "hidden", rows: (1...200).map { ["Lookup value number \($0)"] }),
            Files.Sheet("Summary", rows: [["Item", "Qty"], ["Lobby lamps", "12"]]),
        ])
        var limits = FileTextExtractor.Limits()
        limits.officeCharacters = 100
        let result = try await read(data, .xlsx, limits: limits).get()
        #expect(result.pages.map(\.text) == ["# Summary: Item | Qty\n| Lobby lamps | 12 |"])
        #expect(result.hiddenRuns == 1)
        #expect(!result.isCut)

        // Room for every part but the hidden sheet.
        let sizes = try ZipArchive(data).entries.filter { $0.name != "xl/worksheets/sheet1.xml" }.map { Int64($0.size) }
        limits = FileTextExtractor.Limits()
        limits.officeBytes = sizes.reduce(0, +)
        let tight = try await read(data, .xlsx, limits: limits).get()
        #expect(tight.pages.map(\.sheet) == ["Summary"])
        #expect(tight.hiddenRuns == 1)
        #expect(!tight.isCut)
    }

    /// Out of time among the hidden sheets, which are read after the ones that show, a
    /// workbook keeps the text that shows, and the hidden sheets left count as hidden, since
    /// they may hold text. Each look at the clock moves it 4 s on.
    @Test func hiddenSheetsOutOfTimeKeepTheTextThatShows() async throws {
        let data = try Files.xlsx([
            Files.Sheet("One", state: "hidden", rows: [["Secret one"]]), Files.Sheet("Two", state: "hidden", rows: [["Secret two"]]),
            Files.Sheet("Shown", rows: [["Lobby lamps"]]), Files.Sheet("Three", state: "hidden", rows: [["Secret three"]]),
        ])
        var limits = FileTextExtractor.Limits()
        limits.officeTime = .seconds(22)
        let extractor = FileTextExtractor(limits: limits, now: SteppingClock(step: .seconds(4)).now)
        let result = try await extractor.text(of: data, format: .xlsx, modified: .now).get()
        #expect(result.pages.map(\.text) == ["# Shown\n| Lobby lamps |"])
        #expect(result.hiddenRuns == 3)
    }

    /// A sheet with many hidden column ranges and many cells is laid out in time, since a
    /// cell's column is looked up among the ranges rather than tested against each, which
    /// took minutes here.
    @Test(.timeLimit(.minutes(1))) func manyHiddenColumnRangesAreLookedUpQuickly() async throws {
        let cols = "<cols>" + String(repeating: #"<col min="1" max="1" hidden="1"/>"#, count: 50_000) + "</cols>"
        let row = Files.row(1, String(repeating: "<c><v>1</v></c>", count: 50_000))
        let data = try Files.xlsx([Files.Sheet("Data", cols + "<sheetData>\(row)</sheetData>")])
        let started = ContinuousClock.now
        let result = try await read(data, .xlsx).get()
        #expect(started.duration(to: .now) < .seconds(20))
        #expect(result.hiddenRuns == 1)
        #expect(result.pages.first?.text.hasPrefix("# Data\n| 1 | 1 | 1 |") == true)
    }

    /// Sheets that name a part the package lacks are passed over quickly, however many the
    /// workbook lists and however many parts the package holds, which took minutes here when
    /// each lookup compared every part's name.
    @Test(.timeLimit(.minutes(1))) func manySheetsAndPartsAreLookedUpQuickly() async throws {
        let sheet = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"# + Files.row(1, Files.cell("A1", "Lobby lamps"))
            + "</sheetData></worksheet>"
        let data = try Self.workbook(
            list: String(repeating: #"<sheet name="Gone" sheetId="1" r:id="rId1"/>"#, count: 50_000) + #"<sheet name="Lamps" sheetId="2" r:id="rId2"/>"#,
            targets: ["worksheets/missing.xml", "worksheets/sheet1.xml"],
            parts: [("xl/worksheets/sheet1.xml", sheet)] + (1...5_000).map { ("xl/other/part\($0).xml", "<a/>") })
        let started = ContinuousClock.now
        let result = try await read(data, .xlsx).get()
        #expect(started.duration(to: .now) < .seconds(20))
        #expect(result.pages.map(\.text) == ["# Lamps\n| Lobby lamps |"])
    }

    /// A part in another encoding than UTF-8, in which a declaration could hide from the
    /// check of the part's bytes, is unreadable. UTF-8 with a byte order mark, white space
    /// before the root, or a declaration in any case and quote is read.
    @Test func aPartInAnotherEncodingIsUnreadable() async throws {
        let rows = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"# + Files.row(1, Files.cell("A1", "Lamps"))
            + "</sheetData></worksheet>"
        let dtd = "+ADw-!DOCTYPE worksheet +AFs-+ADw-!ENTITY e +ACI-x+ACI-+AD4-+AF0-+AD4-"
        for (declaration, expected) in [
            (#"<?xml version="1.0" encoding="UTF-8"?>"#, Result<[String], FileSkipReason>.success(["# Data\n| Lamps |"])),
            (#"<?xml version="1.0" encoding="UTF-7"?>"#, .failure(.unreadable)), (#"<?xml version="1.0" encoding="UTF-7"?>"# + dtd, .failure(.unreadable)),
        ] {
            let data = try Self.workbook(list: #"<sheet name="Data" sheetId="1" r:id="rId1"/>"#, targets: ["worksheets/sheet1.xml"], parts: [("xl/worksheets/sheet1.xml", declaration + rows)])
            #expect(await read(data, .xlsx).map { $0.pages.map(\.text) } == expected, "\(declaration)")
        }
        let accepted = [
            #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><a/>"#, "\u{FEFF}<?xml version='1.0' encoding = 'utf-8'?><a/>", "\n <a/>",
            #"<?xml version="1.0"?><a/>"#,
        ]
        for text in accepted {
            #expect(OfficeXMLText.isPlainXML(Data(text.utf8)), "\(text)")
        }
        let refused = [
            #"<?xml version="1.0" encoding="UTF-7"?><a/>"#, #"<?xml version="1.0" encoding="ISO-8859-1"?><a/>"#, "+ADw-a/+AD4-", "",
            #"<?xml version="1.0" encoding=UTF-8?><a/>"#, #"<?xml version="1.0" encoding="UTF-8""#,
        ]
        for text in refused {
            #expect(!OfficeXMLText.isPlainXML(Data(text.utf8)), "\(text)")
        }
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

    /// A run that says nothing of its size or color takes them from its paragraph, then from
    /// its text body's list style for its level, and is dropped when they hide it.
    @Test func runsTakeHiddenStylesFromTheirParagraphAndListStyle() async throws {
        let shape = #"<p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>"#
            + #"<p:spPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></p:spPr><p:txBody><a:bodyPr/>"#
            + #"<a:lstStyle><a:lvl1pPr><a:defRPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></a:defRPr></a:lvl1pPr>"#
            + #"<a:lvl2pPr><a:defRPr><a:solidFill><a:srgbClr val="000000"><a:alpha val="5000"/></a:srgbClr></a:solidFill></a:defRPr></a:lvl2pPr></a:lstStyle>"#
            + "<a:p>" + Files.run("Like the fill by its list style.") + "</a:p>"
            + #"<a:p><a:pPr lvl="1"/>"# + Files.run("Clear by its list style.") + "</a:p>"
            + #"<a:p><a:pPr><a:defRPr sz="200"><a:solidFill><a:srgbClr val="000000"/></a:solidFill></a:defRPr></a:pPr>"# + Files.run("Tiny by its paragraph.") + "</a:p>"
            + "<a:p>" + Files.run("Shown in its own color.", color: "000000") + "</a:p>"
            + "</p:txBody></p:sp>"
        let result = try await read(try Files.pptx([Files.Slide(shape)]), .pptx).get()
        #expect(result.pages.map(\.text) == ["Shown in its own color."])
        #expect(result.hiddenRuns == 1)
    }

    /// A placement at the edge of 64 bit numbers is read without a crash, as a shape off the
    /// slide.
    @Test func placementsAtTheEdgeOfNumbersNeverCrash() async throws {
        let shapes = Files.shape(["Far right."], placement: (x: Int.max, y: 0, width: Int.max, height: 100), id: 2)
            + Files.shape(["Far left."], placement: (x: Int.min, y: 0, width: Int.max, height: 100), id: 3)
            + Files.shape(["On the slide."], placement: (x: 100, y: 100, width: 100, height: 100), id: 4)
        let result = try await read(try Files.pptx([Files.Slide(shapes)]), .pptx).get()
        #expect(result.pages.map(\.text) == ["On the slide."])
        #expect(result.hiddenRuns == 2)
    }

    /// A paragraph level at the edge of 64 bit numbers, or past them, is read without a
    /// crash, as the nearest level there is.
    @Test func paragraphLevelsAtTheEdgeOfNumbersNeverCrash() async throws {
        let levels = ["9223372036854775807", "-9223372036854775808", "99999999999999999999"]
        let paragraphs = levels.map { #"<a:pPr lvl="\#($0)"/>"# + Files.run("Level \($0).") }
        let result = try await read(try Files.pptx([Files.Slide(Files.shape(paragraphs, plain: false))]), .pptx).get()
        #expect(result.pages.map(\.text) == [levels.map { "Level \($0)." }.joined(separator: "\n")])
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

    /// A workbook's parts written whole, stored, so a test can write what Files.xlsx would
    /// not: `list` is the XML inside <sheets>, its rId1 and up name `targets` in xl/, and
    /// `parts` are added as they are.
    private static func workbook(list: String, targets: [String], parts: [(name: String, text: String)]) throws -> Data {
        let head = #"<?xml version="1.0" encoding="UTF-8"?>"#
        let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        let package = head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId1" Type="\#(type)officeDocument" Target="xl/workbook.xml"/></Relationships>"#
        let relationships = head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + targets.enumerated().map { #"<Relationship Id="rId\#($0.offset + 1)" Type="\#(type)worksheet" Target="\#($0.element)"/>"# }.joined()
            + "</Relationships>"
        let workbook = head + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\#(type.dropLast())">"#
            + "<sheets>\(list)</sheets></workbook>"
        return try Files.zip(texts: [("_rels/.rels", package), ("xl/workbook.xml", workbook), ("xl/_rels/workbook.xml.rels", relationships)] + parts, stored: true)
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
