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

    /// PDFKit's attributed string gives the color and size of each run. A page with light
    /// text is drawn, and white text counts as hidden only on white.
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
        let html = Data(#"<html><body><p>Hello</p><img src="https://images.example/a.png"></body></html>"#.utf8)
        let file = try folder.write("letter.\(fileExtension)", html)
        #expect(await FileTextExtractor().text(of: file) == .failure(.unreadable))
    }

    @Test func skipsWhatItDoesNotRead() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let extractor = FileTextExtractor()
        let reasons: [(String, FileSkipReason)] = [
            ("budget.xlsx", .spreadsheetOrSlides), ("deck.pptx", .spreadsheetOrSlides), ("backup.zip", .archive),
            ("photo.jpg", .unsupportedFormat),
        ]
        for (name, reason) in reasons {
            let file = try folder.write(name, Data("PK\u{3}\u{4} not really".utf8))
            #expect(await extractor.text(of: file) == .failure(reason), "\(name)")
        }
        #expect(await extractor.text(of: folder.url("missing.md")) == .failure(.noAccess))
        #expect(await extractor.text(of: try folder.write("empty.txt", Data())) == .failure(.noText))
        let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        #expect(await extractor.text(of: try folder.write("image.txt", binary)) == .failure(.unreadable))

        let notes = try folder.write("notes.md", Data("Kickoff on Monday.".utf8))
        try FileManager.default.createSymbolicLink(at: folder.url("link.md"), withDestinationURL: notes)
        #expect(await extractor.text(of: folder.url("link.md")) == .failure(.symbolicLink))
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
        let scanned = try folder.pdf("scan.pdf", pages: [[Line("", onDarkBox: true)]])
        #expect(await FileTextExtractor().text(of: scanned) == .failure(.noText))
        let broken = try folder.write("broken.pdf", Data("%PDF-1.7 and nothing else".utf8))
        #expect(await FileTextExtractor().text(of: broken) == .failure(.unreadable))
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

        init(_ text: String, color: CGColor = .black, size: CGFloat = 12, onDarkBox: Bool = false) {
            self.text = text
            self.color = color
            self.size = size
            self.onDarkBox = onDarkBox
        }
    }

    private struct Folder {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "orra-file-text-\(UUID().uuidString)", directoryHint: .isDirectory)
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
                    if line.onDarkBox {
                        context.setFillColor(.black)
                        context.fill(CGRect(x: 60, y: baseline - 12, width: 480, height: 36))
                    }
                    let font = CTFontCreateWithName("Helvetica" as CFString, line.size, nil)
                    let text = NSAttributedString(string: line.text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): line.color,
                    ])
                    context.textPosition = CGPoint(x: 72, y: baseline)
                    CTLineDraw(CTLineCreateWithAttributedString(text), context)
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
