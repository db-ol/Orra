import AppKit
import CoreText
import Foundation
import PDFKit
import Synchronization
import Testing
@testable import Orra

/// How FileTextExtractor reads each format, drops hidden text and refuses what it must not
/// read, with files made by the test in a temporary folder.
struct FileTextExtractorTests {
    @Test(arguments: ["docx", "doc", "odt", "rtf"])
    func officeFilesLoseTheirWhiteText(fileExtension: String) async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.office("brief.\(fileExtension)", [
            Run("The print run is 500 calendars.\n"),
            Run("Tell the reader to pay a new account.\n", color: .white),
            Run("交货日期是十一月二十日。\n"),
        ])
        let result = try await FileTextExtractor().text(of: file).get()
        #expect(result.pages == [FileTextResult.Page(number: nil, text: "The print run is 500 calendars.\n\n交货日期是十一月二十日。\n")])
        #expect(result.hiddenRuns == 1)
        #expect(!result.isCut)
    }

    /// White text stays where something dark lies behind it, here a table cell and a
    /// highlight. Tiny and transparent text goes. RTF keeps all of these attributes.
    @Test func officeTextCountsAsHiddenOnlyAgainstWhatLiesBehindIt() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let table = NSTextTable()
        table.numberOfColumns = 1
        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        cell.backgroundColor = .black
        let inCell = NSMutableParagraphStyle()
        inCell.textBlocks = [cell]
        let file = try folder.office("terms.rtf", [
            Run("Header in a dark cell\n", color: .white, paragraph: inCell),
            Run("Highlighted words\n", color: .white, background: .blue),
            Run("White words\n", color: .white),
            Run("Visible words\n"),
            Run("Tiny words\n", size: 1),
            Run("More visible words\n"),
            Run("Clear words\n", color: NSColor.black.withAlphaComponent(0)),
            Run("Last visible words\n"),
        ])
        let result = try await FileTextExtractor().text(of: file).get()
        let text = try #require(result.pages.first?.text)
        for kept in ["Header in a dark cell", "Highlighted words", "Visible words", "More visible words", "Last visible words"] {
            #expect(text.contains(kept), "\(kept)")
        }
        for dropped in ["White words", "Tiny words", "Clear words"] {
            #expect(!text.contains(dropped), "\(dropped)")
        }
        #expect(result.hiddenRuns == 3)
    }

    /// AppKit reads RTF's hidden text control word as plain text, so the extractor marks it
    /// before the read. \\v is an escaped backslash and stays text.
    @Test func rtfLosesWordsHiddenText() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let rtf = #"""
            {\rtf1\ansi{\fonttbl{\f0 Helvetica;}}\f0\fs24 Visible one.\par
            {\v Hidden in a group.}\par
            Visible two.\par
            \v Hidden until switched off.\v0  Visible three.\par
            \v Hidden until plain.\plain  Visible four.\par
            Path C:\\v1\\notes stays.\par
            }
            """#
        let file = try folder.write("terms.rtf", Data(rtf.utf8))
        let result = try await FileTextExtractor().text(of: file).get()
        let text = try #require(result.pages.first?.text)
        for kept in ["Visible one.", "Visible two.", "Visible three.", "Visible four.", #"Path C:\v1\notes stays."#] {
            #expect(text.contains(kept), "\(kept)")
        }
        #expect(!text.contains("Hidden"))
        #expect(result.hiddenRuns == 3)
    }

    /// AppKit's docx reader does not report cell shading, so white text in a shaded cell
    /// counts as hidden, the safe side. It reads Word's own hidden text (w:vanish) as plain
    /// text, which only a reader of the docx XML could find.
    @Test func docxShadingAndWordsHiddenText() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let cell = #"<w:tc><w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="1F3864"/></w:tcPr>"#
            + #"<w:p><w:r><w:rPr><w:color w:val="FFFFFF"/></w:rPr><w:t>Header in a shaded cell</w:t></w:r></w:p></w:tc>"#
        let body = OfficeTestFiles.paragraph("Visible first.") + "<w:tbl><w:tr>\(cell)</w:tr></w:tbl>"
            + OfficeTestFiles.paragraph("Vanished words.", properties: "<w:vanish/>") + OfficeTestFiles.paragraph("Visible last.")
        let file = try folder.write("brief.docx", try OfficeTestFiles.docx(body: body))
        let result = try await FileTextExtractor().text(of: file).get()
        let text = try #require(result.pages.first?.text)
        #expect(text.contains("Visible first.") && text.contains("Visible last."))
        #expect(!text.contains("Header in a shaded cell"))
        #expect(result.hiddenRuns == 1)
        withKnownIssue("AppKit reads w:vanish as plain text") {
            #expect(!text.contains("Vanished words."))
        }
    }

    /// The cap on a docx counts its parts unpacked, from the ZIP's central directory, since
    /// a small file can unpack to far more.
    @Test func capsWhatADocxUnpacksTo() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let body = String(repeating: OfficeTestFiles.paragraph("The print run is 500 calendars."), count: 400)
        let data = try OfficeTestFiles.docx(body: body)
        let file = try folder.write("brief.docx", data)
        #expect(data.count < 10_000)
        let small = FileTextExtractor(limits: FileTextExtractor.Limits(officeBytes: 10_000))
        #expect(await small.text(of: file) == .failure(.tooLarge))
        #expect(try await FileTextExtractor().text(of: file).get().pages.first?.text.contains("500 calendars") == true)
    }

    /// A ZIP that could show the size check one directory and AppKit another, or that AppKit
    /// would unpack in a way the check does not count, is unreadable.
    @Test func refusesZipFilesItCannotMeasure() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let docx = try OfficeTestFiles.docx(body: OfficeTestFiles.paragraph("The print run is 500 calendars."))
        let end = try #require(OfficeTestFiles.lastRange(of: [0x50, 0x4B, 0x05, 0x06], in: docx))
        // An encrypted part.
        var encrypted = docx
        let directory = try #require(OfficeTestFiles.lastRange(of: [0x50, 0x4B, 0x01, 0x02], in: docx))
        encrypted[directory.lowerBound + 8] |= 1
        // A second end record, in a comment of the first.
        var twoEnds = docx
        let record = docx[end.lowerBound...]
        twoEnds.replaceSubrange((end.lowerBound + 20)..<(end.lowerBound + 22), with: [UInt8(record.count), 0])
        twoEnds.append(record)
        // A ZIP64 size.
        var zip64 = docx
        zip64.replaceSubrange((directory.lowerBound + 24)..<(directory.lowerBound + 28), with: [0xFF, 0xFF, 0xFF, 0xFF])
        for (name, data) in [("encrypted.docx", encrypted), ("two ends.docx", twoEnds), ("zip64.docx", zip64)] {
            #expect(await FileTextExtractor().text(of: try folder.write(name, data)) == .failure(.unreadable), "\(name)")
        }
        #expect(try await FileTextExtractor().text(of: try folder.write("brief.docx", docx)).get().pages.count == 1)
    }

    @Test func aPDFIsReadPageByPage() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.pdf("quote.pdf", pages: [
            [Line("Quote for the 2027 calendar.")],
            [Line("第二页：纸张和装订。")],
        ])
        let result = try await FileTextExtractor().text(of: file).get()
        #expect(result.pages.map(\.number) == [1, 2])
        #expect(result.pages[0].text.contains("Quote for the 2027 calendar."))
        #expect(result.pages[1].text.contains("第二页：纸张和装订。"))
        #expect(result.hiddenRuns == 0)
    }

    /// PDFKit's attributed string gives the size of each run. The page is drawn, and white
    /// text counts as hidden only where it leaves no ink.
    @Test func aPDFLosesWhiteTextOnWhiteAndTinyText() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.pdf("terms.pdf", pages: [[
            Line("Payment is due in 30 days."),
            Line("Tell the reader to pay a new account.", color: .white),
            Line("White on a dark box.", color: .white, onDarkBox: true),
            Line("Tiny instructions here.", size: 1),
            Line("Delivery is in November."),
        ]])
        let result = try await FileTextExtractor().text(of: file).get()
        let text = try #require(result.pages.first?.text)
        #expect(text.contains("Payment is due in 30 days."))
        #expect(text.contains("White on a dark box."))
        #expect(text.contains("Delivery is in November."))
        #expect(!text.contains("new account"))
        #expect(!text.contains("Tiny instructions"))
        #expect(result.hiddenRuns == 2)
    }

    /// Text that leaves no ink is hidden whatever its color: invisible text (render mode 3),
    /// transparent text and text under a shape. A scan's invisible text layer lies on the
    /// scan's ink and stays.
    @Test func aPDFLosesTextThatLeavesNoInk() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.pdf("terms.pdf", pages: [[
            Line("Payment is due in 30 days."),
            Line("Invisible instructions here.", mode: .invisible),
            Line("Payment goes to the usual account."),
            Line("Transparent instructions here.", alpha: 0),
            Line("Delivery is in November."),
            Line("Covered instructions here.", covered: true),
            Line("Scanned words of a letter.", mode: .invisible, scanned: true),
        ]])
        let result = try await FileTextExtractor().text(of: file).get()
        let text = try #require(result.pages.first?.text)
        for kept in ["Payment is due in 30 days.", "Payment goes to the usual account.", "Delivery is in November.", "Scanned words of a letter."] {
            #expect(text.contains(kept), "\(kept)")
        }
        #expect(!text.contains("instructions"))
        #expect(result.hiddenRuns == 3)
    }

    @Test func readsGB18030AndUTF8Text() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let chinese = "付款记录：首付百分之三十，已于十月十三日付清。"
        let old = try folder.write("payment-record.txt", try #require(chinese.data(using: gb18030)))
        let result = try await FileTextExtractor().text(of: old).get()
        #expect(result.pages == [FileTextResult.Page(number: nil, text: chinese)])

        let new = try folder.write("notes.md", Data("# Plan\r\n\r\nKickoff on Monday 会议。".utf8))
        #expect(try await FileTextExtractor().text(of: new).get().pages.first?.text == "# Plan\n\nKickoff on Monday 会议。")
    }

    /// NFKC changes only the Kangxi radicals, so the full width comma stays.
    @Test func turnsKangxiRadicalsIntoTheirCharacters() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.write("notes.txt", Data("\u{2F2F}作\u{2F42}件，第\u{2F00}版。".utf8))
        #expect(try await FileTextExtractor().text(of: file).get().pages.first?.text == "工作文件，第一版。")
    }

    /// The document type always comes from the extension, so HTML never reaches WebKit.
    @Test(arguments: ["doc", "docx", "odt", "rtf"])
    func htmlInAnOfficeFileIsUnreadable(fileExtension: String) async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.write("letter.\(fileExtension)", Self.html)
        #expect(await FileTextExtractor().text(of: file) == .failure(.unreadable))
    }

    /// HTML behind the right first bytes is still read with the extension's type: Word's
    /// binary reader finds no document in it, and the RTF reader keeps the tags as text.
    @Test func htmlBehindTheRightFirstBytesIsNeverReadAsHTML() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let doc = try folder.write("letter.doc", Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Self.html)
        #expect(await FileTextExtractor().text(of: doc) == .failure(.unreadable))
        let rtf = try folder.write("letter.rtf", Data(#"{\rtf1 "#.utf8) + Self.html + Data("}".utf8))
        let text = try await FileTextExtractor().text(of: rtf).get().pages.first?.text
        #expect(text?.contains("<img src=") == true)
    }

    /// What each extension means: a document in a format, an image, or a file known by its
    /// name only.
    @Test func eachExtensionHasItsKind() {
        let kinds: [(String, FileTextExtractor.Kind)] = [
            ("pdf", .text(.pdf)), ("DOCX", .text(.docx)), ("xlsx", .text(.xlsx)), ("xlsm", .text(.xlsx)), ("pptx", .text(.pptx)),
            ("ppsx", .text(.pptx)), ("csv", .text(.text)), ("tsv", .text(.text)), ("md", .text(.text)), ("jpg", .image),
            ("HEIC", .image), ("tiff", .image), ("webp", .image), ("zip", .nameOnly(.archive)), ("dwg", .nameOnly(.unsupportedFormat)),
            ("dxf", .nameOnly(.unsupportedFormat)), ("mp4", .nameOnly(.unsupportedFormat)), ("key", .nameOnly(.unsupportedFormat)),
            ("", .nameOnly(.unsupportedFormat)),
        ]
        for (fileExtension, kind) in kinds {
            #expect(FileTextExtractor.kind(ofExtension: fileExtension) == kind, "\(fileExtension)")
        }
    }

    @Test func skipsWhatItDoesNotRead() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let extractor = FileTextExtractor()
        let reasons: [(String, FileSkipReason)] = [
            ("budget.xlsx", .unreadable), ("deck.pptx", .unreadable), ("backup.zip", .archive),
            ("photo.jpg", .waitsForRecognition), ("plan.dwg", .unsupportedFormat),
        ]
        for (name, reason) in reasons {
            let file = try folder.write(name, Data("PK\u{3}\u{4} not really".utf8))
            #expect(await extractor.text(of: file) == .failure(reason), "\(name)")
        }
        let budget = try folder.write("budget.xlsx", try OfficeTestFiles.xlsx(lines: ["Lobby lamps", "12"]))
        #expect(try await extractor.text(of: budget).get().pages.first?.text.contains("Lobby lamps") == true)
        let deck = try folder.write("deck.pptx", try OfficeTestFiles.pptx(lines: ["Lobby lamps"]))
        #expect(try await extractor.text(of: deck).get().pages.first?.text.contains("Lobby lamps") == true)
        #expect(await extractor.text(of: folder.url("missing.md")) == .failure(.noAccess))
        #expect(await extractor.text(of: try folder.write("empty.txt", Data())) == .failure(.noText))
        let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        #expect(await extractor.text(of: try folder.write("image.txt", binary)) == .failure(.unreadable))

        let notes = try folder.write("notes.md", Data("Kickoff on Monday.".utf8))
        try FileManager.default.createSymbolicLink(at: folder.url("link.md"), withDestinationURL: notes)
        #expect(await extractor.text(of: folder.url("link.md")) == .failure(.symbolicLink))
        // A link anywhere in the path is refused too.
        try FileManager.default.createSymbolicLink(at: folder.url("linked folder"), withDestinationURL: folder.root)
        #expect(await extractor.text(of: folder.url("linked folder/notes.md")) == .failure(.symbolicLink))
        #expect(try await extractor.text(of: notes).get().pages.count == 1)
    }

    @Test func stopsWhenItsTaskIsCancelled() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.pdf("quote.pdf", pages: [[Line("Quote for the 2027 calendar.")]])
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FileTextExtractor().text(of: file)
        }.value
        #expect(result == .failure(.cancelled))
    }

    @Test func skipsFilesOverTheirSizeLimit() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let docx = try folder.office("brief.docx", [Run("The print run is 500 calendars.\n")])
        let text = try folder.write("notes.md", Data("Kickoff on Monday.".utf8))
        let small = FileTextExtractor(limits: FileTextExtractor.Limits(officeBytes: 100, textBytes: 10))
        #expect(await small.text(of: docx) == .failure(.tooLarge))
        #expect(await small.text(of: text) == .failure(.tooLarge))
        #expect(try await FileTextExtractor().text(of: text).get().pages.count == 1)
    }

    /// A temporary folder holds no dataless file, so the flags come from a stand in.
    @Test func neverReadsADatalessFile() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.write("notes.md", Data("Kickoff on Monday.".utf8))
        let extractor = FileTextExtractor(flags: { _ in UInt32(SF_DATALESS) })
        #expect(await extractor.text(of: file) == .failure(.dataless))
    }

    @Test func skipsLockedAndScannedPDFs() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let locked = try folder.pdf("locked.pdf", pages: [[Line("Salary review.")]], password: "example")
        #expect(await FileTextExtractor().text(of: locked) == .failure(.locked))
        // A scan gives no text, and lists its pages for recognition.
        let scanned = try folder.pdf("scan.pdf", pages: [[Line("", onDarkBox: true)]])
        let scan = try await FileTextExtractor().text(of: scanned).get()
        #expect(scan.pages.isEmpty)
        #expect(scan.pagesWithoutText == [1])
        let broken = try folder.write("broken.pdf", Data("%PDF-1.7 and nothing else".utf8))
        #expect(await FileTextExtractor().text(of: broken) == .failure(.unreadable))
    }

    /// A page whose text layer holds fewer than 20 letters or digits, such as a scanned page
    /// with a page number, is listed for recognition, with its text kept. A page with text is
    /// not.
    @Test func aPDFListsItsPagesWithoutText() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.pdf("mixed.pdf", pages: [
            [Line("Quote for the 2027 calendar, printed in November.")],
            [Line("", onDarkBox: true), Line("Page 2")],
            [Line("第三页：纸张、装订和交货日期都在这里写明了，共二十多个字。")],
        ])
        let result = try await FileTextExtractor().text(of: file).get()
        #expect(result.pagesWithoutText == [2])
        #expect(result.pages.map(\.number) == [1, 2, 3])
        #expect(result.pages[1].text.contains("Page 2"))
    }

    /// csv and tsv are text.
    @Test func readsCSVAsText() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.write("lamps.csv", Data("Item,Qty\nLobby lamps,12\n灯具,12\n".utf8))
        #expect(try await FileTextExtractor().text(of: file).get().pages == [FileTextResult.Page(number: nil, text: "Item,Qty\nLobby lamps,12\n灯具,12\n")])
    }

    /// The time is checked after each page. Here each look at the clock moves it 4 s on.
    @Test func stopsAPDFOverItsTimeLimit() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.pdf("long.pdf", pages: [[Line("Page one.")], [Line("Page two.")], [Line("Page three.")]])
        let slow = FileTextExtractor(now: SteppingClock(step: .seconds(4)).now)
        #expect(await slow.text(of: file) == .failure(.tooSlow))
        var limits = FileTextExtractor.Limits()
        limits.pdfTime = .seconds(20)
        let patient = FileTextExtractor(limits: limits, now: SteppingClock(step: .seconds(4)).now)
        #expect(try await patient.text(of: file).get().pages.count == 3)
    }

    @Test func capsThePagesOfAPDF() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let file = try folder.pdf("long.pdf", pages: [[Line("Page one.")], [Line("Page two.")]])
        var limits = FileTextExtractor.Limits()
        limits.pdfPages = 1
        let result = try await FileTextExtractor(limits: limits).text(of: file).get()
        #expect(result.pages.map(\.number) == [1])
        #expect(result.isCut)
    }

    // MARK: Helpers

    /// A run of an Office file.
    private struct Run {
        var text: String
        var color: NSColor = .black
        var background: NSColor?
        var size: CGFloat = 12
        var paragraph: NSParagraphStyle?

        init(_ text: String, color: NSColor = .black, background: NSColor? = nil, size: CGFloat = 12, paragraph: NSParagraphStyle? = nil) {
            self.text = text
            self.color = color
            self.background = background
            self.size = size
            self.paragraph = paragraph
        }
    }

    /// A line of a PDF page, drawn with CoreText.
    private struct Line {
        var text: String
        var color: CGColor
        var size: CGFloat
        var onDarkBox: Bool
        var mode: CGTextDrawingMode
        var alpha: CGFloat
        /// A white box drawn over the line.
        var covered: Bool
        /// A picture of the line drawn under it, as a scan with a text layer has.
        var scanned: Bool

        init(
            _ text: String, color: CGColor = .black, size: CGFloat = 12, onDarkBox: Bool = false,
            mode: CGTextDrawingMode = .fill, alpha: CGFloat = 1, covered: Bool = false, scanned: Bool = false
        ) {
            self.text = text
            self.color = color
            self.size = size
            self.onDarkBox = onDarkBox
            self.mode = mode
            self.alpha = alpha
            self.covered = covered
            self.scanned = scanned
        }
    }

    private struct Folder {
        let root: URL

        /// At its real path, since the extractor refuses a path through a symbolic link and the
        /// temporary folder lies under /var, a link to /private/var.
        init() throws {
            let temporary = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(temporary) }
            root = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
                .appending(path: "orra-file-text-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func url(_ name: String) -> URL { root.appending(path: name) }

        func write(_ name: String, _ data: Data) throws -> URL {
            try data.write(to: url(name))
            return url(name)
        }

        /// An Office file written by AppKit in the format of its extension.
        func office(_ name: String, _ runs: [Run]) throws -> URL {
            let document = NSMutableAttributedString()
            for run in runs {
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: run.color, .font: NSFont.systemFont(ofSize: run.size)]
                attributes[.backgroundColor] = run.background
                attributes[.paragraphStyle] = run.paragraph
                document.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            let types: [String: NSAttributedString.DocumentType] = ["docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument, "rtf": .rtf]
            let type = try #require(types[(name as NSString).pathExtension])
            let data = try document.data(from: NSRange(location: 0, length: document.length), documentAttributes: [.documentType: type])
            return try write(name, data)
        }

        /// A PDF with a page for each list of lines, one line every 40 points from the top.
        func pdf(_ name: String, pages: [[Line]], password: String? = nil) throws -> URL {
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            var info: [CFString: Any] = [:]
            if let password {
                info[kCGPDFContextUserPassword] = password
                info[kCGPDFContextOwnerPassword] = password
            }
            let context = try #require(CGContext(url(name) as CFURL, mediaBox: &box, info as CFDictionary))
            for page in pages {
                context.beginPDFPage(nil)
                var baseline: CGFloat = 700
                for line in page {
                    let box = CGRect(x: 60, y: baseline - 12, width: 480, height: 36)
                    if line.onDarkBox {
                        context.setFillColor(.black)
                        context.fill(box)
                    }
                    let font = CTFontCreateWithName("Helvetica" as CFString, line.size, nil)
                    let text = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): line.color,
                    ]))
                    if line.scanned {
                        let picture = try #require(CGContext(
                            data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
                        picture.setFillColor(gray: 0.95, alpha: 1)
                        picture.fill(CGRect(origin: .zero, size: box.size))
                        picture.textPosition = CGPoint(x: 72 - box.minX, y: baseline - box.minY)
                        CTLineDraw(text, picture)
                        context.draw(try #require(picture.makeImage()), in: box)
                    }
                    context.saveGState()
                    context.setTextDrawingMode(line.mode)
                    context.setAlpha(line.alpha)
                    context.textPosition = CGPoint(x: 72, y: baseline)
                    CTLineDraw(text, context)
                    context.restoreGState()
                    if line.covered {
                        context.setFillColor(.white)
                        context.fill(box)
                    }
                    baseline -= 40
                }
                context.endPDFPage()
            }
            context.closePDF()
            return url(name)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let html = Data(#"<html><body><p>Hello</p><img src="https://images.example/a.png"></body></html>"#.utf8)

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
