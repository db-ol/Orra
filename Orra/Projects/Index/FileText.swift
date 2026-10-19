import AppKit
import Foundation
import PDFKit

/// Why a file in a project folder gives no text for the index. FolderWalk skips a file or a
/// folder for one of the reasons up to `noAccess` before anything opens it.
/// FileTextExtractor checks a file's reasons again before it reads, and adds the last four.
/// The raw values stay the same from release to release, so the index can store them.
nonisolated enum FileSkipReason: String, Error, Sendable, Codable, CaseIterable {
    /// A name that starts with a period, or a file Finder hides.
    case hidden
    /// An app, a library or another package, which Finder shows as one file.
    case package
    /// A .git folder.
    case gitFolder
    /// A node_modules folder.
    case nodeModules
    /// A zip file, a disk image or another archive. Archives are never opened.
    case archive
    /// A symbolic link, which is never followed.
    case symbolicLink
    /// A Finder alias, which is never followed.
    case alias
    /// A path that leads out of the added folder once resolved.
    case outsideFolder
    /// A file over its size limit, see `FolderWalk.maximumFileSize` and
    /// `FileTextExtractor.Limits`.
    case tooLarge
    /// A file or folder whose data is not on this Mac, such as an iCloud file removed to
    /// save space. Reading it would download it.
    case dataless
    /// An iCloud file whose newest version is not downloaded.
    case notDownloaded
    /// A format Projects does not read.
    case unsupportedFormat
    /// An Excel or PowerPoint file (xlsx or pptx). Reading them needs a ZIP reader, which
    /// Orra does not have.
    case spreadsheetOrSlides
    /// A file or folder Orra may not read, or one that went away.
    case noAccess
    /// Content that does not match the file's extension, or that its reader cannot read.
    case unreadable
    /// A PDF that needs a password.
    case locked
    /// A PDF that took longer than its time limit to read.
    case tooSlow
    /// A file without text, such as a scanned PDF.
    case noText
}

/// The text of one file, page by page.
nonisolated struct FileTextResult: Sendable, Equatable {
    nonisolated struct Page: Sendable, Equatable {
        /// The page number in a PDF, from 1. Nil for the other formats, which have no
        /// fixed pages.
        var number: Int?
        var text: String
    }

    /// The pages that hold text, in order.
    var pages: [Page]
    /// How many runs of hidden text were dropped: text colored like what lies behind it,
    /// nearly transparent text, and text in a tiny font. The text itself is gone. The
    /// count lets Projects tell the user that the file holds hidden text.
    var hiddenRuns: Int
    /// The file's modification date when it was read.
    var modified: Date
    /// Whether pages past `FileTextExtractor.Limits.pdfPages` were left out.
    var isCut: Bool
}

/// Reads the text of one file in a project folder: PDF, docx, doc, rtf, odt, md and txt.
///
/// The files may come from anyone and are read in Orra's own process, so:
/// - A file is read only after a check of its type, flags and size, through a descriptor
///   that does not follow a symbolic link, with macOS told not to download a dataless file.
/// - An Office file goes to `NSAttributedString` only when its first bytes match its
///   extension, and always with the document type of that extension. Never with automatic
///   detection and never as HTML, so a .doc that holds HTML is unreadable and never reaches
///   WebKit.
/// - One call reads an Office or text file whole and cannot be stopped, so their size is
///   capped before the call. A PDF is read page by page, with the time checked after each
///   page and the number of pages capped.
/// - Hidden text is dropped and counted, see `FileTextResult.hiddenRuns`.
nonisolated struct FileTextExtractor: Sendable {
    /// The formats it reads.
    nonisolated enum Format: Sendable, CaseIterable {
        case pdf, docx, doc, rtf, odt
        /// md and txt.
        case text
    }

    /// The limits for one file. All of them are guesses.
    nonisolated struct Limits: Sendable {
        /// Any file, the same as FolderWalk's.
        var fileBytes = FolderWalk.maximumFileSize
        /// docx, doc, rtf and odt.
        var officeBytes: Int64 = 20_000_000
        /// md and txt.
        var textBytes: Int64 = 10_000_000
        /// The pages read from a PDF. Later pages are left out.
        var pdfPages = 2_000
        /// The time a PDF may take. A PDF over it is skipped as `tooSlow`.
        var pdfTime: Duration = .seconds(10)
    }

    let limits: Limits
    /// The clock that times a PDF. Tests pass a stand in.
    let now: @Sendable () -> ContinuousClock.Instant
    /// The stat flags of a path, see `FolderWalk.statFlags(_:)`. Tests pass a stand in.
    let flags: @Sendable (String) -> UInt32?

    init(
        limits: Limits = Limits(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        flags: @escaping @Sendable (String) -> UInt32? = FolderWalk.statFlags
    ) {
        self.limits = limits
        self.now = now
        self.flags = flags
    }

    /// The text of `file`, or why it gives none. Off the main actor, since PDFKit and the
    /// Office readers take a while and the keyboard tap runs on the main thread.
    @concurrent
    func text(of file: URL) async -> Result<FileTextResult, FileSkipReason> {
        read(file)
    }

    /// What a file extension means: the format to read, or why such a file is skipped.
    static func format(ofExtension fileExtension: String) -> Result<Format, FileSkipReason> {
        switch fileExtension.lowercased() {
        case "pdf": .success(.pdf)
        case "docx": .success(.docx)
        case "doc": .success(.doc)
        case "rtf": .success(.rtf)
        case "odt": .success(.odt)
        case "md", "txt": .success(.text)
        case "xlsx", "pptx": .failure(.spreadsheetOrSlides)
        case let other where archiveExtensions.contains(other): .failure(.archive)
        default: .failure(.unsupportedFormat)
        }
    }

    private static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "lz", "lzma", "cab",
        "cpgz", "jar", "xip", "pkg", "dmg", "iso", "sparseimage",
    ]

    private func read(_ file: URL) -> Result<FileTextResult, FileSkipReason> {
        let format: Format
        switch Self.format(ofExtension: file.pathExtension) {
        case .success(let found): format = found
        case .failure(let reason): return .failure(reason)
        }
        let limit = switch format {
        case .pdf: limits.fileBytes
        case .text: min(limits.fileBytes, limits.textBytes)
        case .docx, .doc, .rtf, .odt: min(limits.fileBytes, limits.officeBytes)
        }
        let data: Data
        let modified: Date
        switch contents(of: file.path, limit: limit) {
        case .success(let contents): (data, modified) = contents
        case .failure(let reason): return .failure(reason)
        }

        var pages: [FileTextResult.Page]
        var hiddenRuns = 0
        var isCut = false
        switch format {
        case .pdf:
            switch pdfText(data) {
            case .success(let read): (pages, hiddenRuns, isCut) = read
            case .failure(let reason): return .failure(reason)
            }
        case .docx, .doc, .rtf, .odt:
            switch Self.officeText(data, format: format) {
            case .success(let read):
                pages = [FileTextResult.Page(number: nil, text: read.text)]
                hiddenRuns = read.hiddenRuns
            case .failure(let reason): return .failure(reason)
            }
        case .text:
            guard let text = Self.decoded(data) else { return .failure(.unreadable) }
            pages = [FileTextResult.Page(number: nil, text: text)]
        }

        pages = pages.map { FileTextResult.Page(number: $0.number, text: Self.normalized($0.text)) }
            .filter { !$0.text.allSatisfy(\.isWhitespace) }
        guard !pages.isEmpty else { return .failure(.noText) }
        return .success(FileTextResult(pages: pages, hiddenRuns: hiddenRuns, modified: modified, isCut: isCut))
    }

    // MARK: Reading the bytes

    /// The bytes of a regular file of at most `limit` bytes, and its modification date.
    private func contents(of path: String, limit: Int64) -> Result<(Data, Date), FileSkipReason> {
        var checked = stat()
        guard lstat(path, &checked) == 0 else { return .failure(.noAccess) }
        if let reason = Self.skipReason(checked, flags: flags(path) ?? checked.st_flags, limit: limit) {
            return .failure(reason)
        }
        // macOS downloads a dataless file when something reads it. That is turned off for this
        // thread while it reads, in case the file went dataless after the check. Nothing
        // here suspends, so the thread stays the same until the policy is restored.
        let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if policy >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy)
            }
        }
        // O_NONBLOCK keeps a file that turned into a named pipe from blocking the open.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return .failure(errno == ELOOP ? .symbolicLink : errno == EDEADLK ? .dataless : .noAccess)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == checked.st_dev, opened.st_ino == checked.st_ino else {
            return .failure(.noAccess)
        }
        if let reason = Self.skipReason(opened, flags: opened.st_flags, limit: limit) {
            return .failure(reason)
        }
        do {
            let data = try handle.read(upToCount: Int(limit) + 1) ?? Data()
            guard data.count <= limit else { return .failure(.tooLarge) }
            return .success((data, FolderWalk.date(of: opened)))
        } catch {
            return .failure((error as NSError).code == Int(EDEADLK) ? .dataless : .noAccess)
        }
    }

    private static func skipReason(_ info: stat, flags: UInt32, limit: Int64) -> FileSkipReason? {
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFLNK: return .symbolicLink
        default: return .unsupportedFormat
        }
        if flags & UInt32(SF_DATALESS) != 0 { return .dataless }
        if Int64(info.st_size) > limit { return .tooLarge }
        return nil
    }

    // MARK: PDF

    private func pdfText(_ data: Data) -> Result<([FileTextResult.Page], Int, Bool), FileSkipReason> {
        let start = now()
        guard let document = PDFDocument(data: data) else { return .failure(.unreadable) }
        guard !document.isLocked else { return .failure(.locked) }
        let count = min(document.pageCount, limits.pdfPages)
        var pages: [FileTextResult.Page] = []
        var hiddenRuns = 0
        for index in 0..<count {
            let read: (text: String, hiddenRuns: Int)? = autoreleasepool {
                document.page(at: index).map(Self.visibleText(of:))
            }
            if let read {
                pages.append(FileTextResult.Page(number: index + 1, text: read.text))
                hiddenRuns += read.hiddenRuns
            }
            if start.duration(to: now()) > limits.pdfTime { return .failure(.tooSlow) }
        }
        return .success((pages, hiddenRuns, document.pageCount > count))
    }

    /// The text of a PDF page without its hidden runs. PDFKit gives the color and the size
    /// of each run, but not what lies behind it, and slides often put white text on a dark
    /// box. So a page with light text is drawn, and light text counts as hidden only where
    /// it does not stand out from what lies under it. PDFKit reports transparent text as
    /// opaque, so that is not found.
    private static func visibleText(of page: PDFPage) -> (text: String, hiddenRuns: Int) {
        guard let document = page.attributedString else { return (page.string ?? "", 0) }
        var drawing: PageDrawing?
        var drawn = false
        return visible(document) { attributes, range in
            if isTiny(attributes) { return true }
            guard let color = RGB(attributes[.foregroundColor] as? NSColor ?? .black) else { return false }
            if color.isTransparent { return true }
            guard color.isLight else { return false }
            if !drawn {
                drawing = PageDrawing(page)
                drawn = true
            }
            guard let drawing, let box = page.selection(for: range)?.bounds(for: page) else { return false }
            return !drawing.standsOut(color, in: box)
        }
    }

    /// A PDF page drawn at up to one pixel a point, to see what lies under light text.
    private struct PageDrawing {
        private let pixels: [UInt8]
        private let width: Int
        private let height: Int
        private let scale: CGFloat
        private let origin: CGPoint

        init?(_ page: PDFPage) {
            let box = page.bounds(for: .mediaBox)
            guard let pageReference = page.pageRef, box.width > 0, box.height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            // At most 1,600 pixels a side, so a poster stays small.
            let scale = min(1, 1_600 / max(box.width, box.height))
            let width = max(1, Int((box.width * scale).rounded(.up)))
            let height = max(1, Int((box.height * scale).rounded(.up)))
            // White and opaque, as a page with nothing drawn on it.
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                // Drawn without the page's rotation, in the space PDFKit's selection bounds use.
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -box.minX, y: -box.minY)
                context.drawPDFPage(pageReference)
                return true
            }
            guard drawn else { return nil }
            self.pixels = pixels
            self.width = width
            self.height = height
            self.scale = scale
            self.origin = box.origin
        }

        /// Whether more than 2% of the pixels in `box`, in page space, differ clearly from
        /// `color`. Text in a box with no such pixel matches what lies under it, so no one
        /// can see it. A box off the page counts as standing out, so its text is kept.
        func standsOut(_ color: RGB, in box: CGRect) -> Bool {
            let left = max(0, Int(((box.minX - origin.x) * scale).rounded(.down)))
            let right = min(width, Int(((box.maxX - origin.x) * scale).rounded(.up)))
            let bottom = max(0, Int(((box.minY - origin.y) * scale).rounded(.down)))
            let top = min(height, Int(((box.maxY - origin.y) * scale).rounded(.up)))
            guard left < right, bottom < top else { return true }
            var differing = 0
            for y in bottom..<top {
                // The first row in memory is the top of the drawing.
                let row = (height - 1 - y) * width
                for x in left..<right {
                    let pixel = (row + x) * 4
                    let pixelColor = RGB(
                        red: Double(pixels[pixel]) / 255, green: Double(pixels[pixel + 1]) / 255,
                        blue: Double(pixels[pixel + 2]) / 255, alpha: 1)
                    if pixelColor.distance(to: color) > 0.25 { differing += 1 }
                }
            }
            return differing * 50 > (right - left) * (top - bottom)
        }
    }

    // MARK: Office

    private static func officeText(_ data: Data, format: Format) -> Result<(text: String, hiddenRuns: Int), FileSkipReason> {
        let signature: [UInt8]
        let documentType: NSAttributedString.DocumentType
        switch format {
        case .docx: (signature, documentType) = (zipSignature, .officeOpenXML)
        case .odt: (signature, documentType) = (zipSignature, .openDocument)
        case .doc: (signature, documentType) = ([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], .docFormat)
        case .rtf: (signature, documentType) = (Array(#"{\rtf"#.utf8), .rtf)
        case .pdf, .text: return .failure(.unsupportedFormat)
        }
        guard data.starts(with: signature) else { return .failure(.unreadable) }
        var attributes: NSDictionary?
        guard let document = try? NSAttributedString(
            data: data, options: [.documentType: documentType], documentAttributes: &attributes
        ) else { return .failure(.unreadable) }
        let page = attributes?[NSAttributedString.DocumentAttributeKey.backgroundColor.rawValue] as? NSColor
        return .success(visible(document) { attributes, _ in isHidden(attributes, onPage: page) })
    }

    private static let zipSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// Whether an Office run is hidden: a tiny font, nearly transparent, or colored like
    /// what lies behind it, which is the run's own background, the table cell's, the page's
    /// or white.
    private static func isHidden(_ attributes: [NSAttributedString.Key: Any], onPage page: NSColor?) -> Bool {
        if isTiny(attributes) { return true }
        guard let color = RGB(attributes[.foregroundColor] as? NSColor ?? .black) else { return false }
        if color.isTransparent { return true }
        var behind: [NSColor?] = [attributes[.backgroundColor] as? NSColor]
        let blocks = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks ?? []
        behind += blocks.reversed().map(\.backgroundColor)
        behind.append(page)
        let background = behind.lazy.compactMap { $0.flatMap(RGB.init) }.first { !$0.isTransparent } ?? .white
        return color.distance(to: background) < 0.1
    }

    /// Text under 3 points.
    private static func isTiny(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        guard let font = attributes[.font] as? NSFont else { return false }
        return font.pointSize < 3
    }

    /// The text of `document` without its hidden runs, and how many there were. Each run is
    /// judged line by line, since PDFKit joins lines of the same color and size into one run
    /// whatever lies behind each. White space is kept and never counts, so the words around
    /// dropped text stay apart. Hidden lines and runs next to each other count once.
    private static func visible(
        _ document: NSAttributedString,
        isHidden: (_ attributes: [NSAttributedString.Key: Any], _ range: NSRange) -> Bool
    ) -> (text: String, hiddenRuns: Int) {
        let string = document.string as NSString
        var text = ""
        var hiddenRuns = 0
        var inHiddenRun = false
        document.enumerateAttributes(in: NSRange(location: 0, length: document.length)) { attributes, run, _ in
            var start = run.location
            while start < NSMaxRange(run) {
                let rest = NSRange(location: start, length: NSMaxRange(run) - start)
                let lineBreak = string.rangeOfCharacter(from: .newlines, options: [], range: rest)
                let line = NSRange(location: start, length: (lineBreak.location == NSNotFound ? NSMaxRange(run) : lineBreak.location) - start)
                let lineText = string.substring(with: line)
                if lineText.allSatisfy(\.isWhitespace) {
                    text += lineText
                } else if isHidden(attributes, line) {
                    if !inHiddenRun { hiddenRuns += 1 }
                    inHiddenRun = true
                } else {
                    text += lineText
                    inHiddenRun = false
                }
                guard lineBreak.location != NSNotFound else { break }
                text += string.substring(with: lineBreak)
                start = NSMaxRange(lineBreak)
            }
        }
        return (text, hiddenRuns)
    }

    /// A color in sRGB.
    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        static let white = RGB(red: 1, green: 1, blue: 1, alpha: 1)

        init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// Nil for a pattern, and for a system color, which follows light and dark mode
        /// and so never hides text.
        init?(_ color: NSColor) {
            guard color.type != .catalog, let converted = color.usingColorSpace(.sRGB) else { return nil }
            self.init(
                red: Double(converted.redComponent), green: Double(converted.greenComponent),
                blue: Double(converted.blueComponent), alpha: Double(converted.alphaComponent))
        }

        var isTransparent: Bool { alpha < 0.1 }
        var isLight: Bool { min(red, green, blue) >= 0.85 }

        /// The largest difference of one channel, from 0 to 1.
        func distance(to other: RGB) -> Double {
            max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
        }
    }

    // MARK: Text

    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// The text of an md or txt file: UTF-8 when the bytes are valid UTF-8, or else the
    /// encoding macOS finds for them, with GB18030 suggested. macOS alone reads some GB18030
    /// text as broken UTF-8. Nil for a file that looks binary: NUL bytes without a UTF-16 or
    /// UTF-32 byte order mark, or more than 1% control characters.
    private static func decoded(_ data: Data) -> String? {
        let marks: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF], [0x00, 0x00, 0xFE, 0xFF]]
        if data.contains(0), !marks.contains(where: { data.starts(with: $0) }) { return nil }
        var text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            var converted: NSString?
            var lossy: ObjCBool = false
            let encoding = NSString.stringEncoding(
                for: data,
                encodingOptions: [
                    .suggestedEncodingsKey: [gb18030.rawValue],
                    .disallowedEncodingsKey: [String.Encoding.utf8.rawValue],
                    .allowLossyKey: false,
                ],
                convertedString: &converted, usedLossyConversion: &lossy)
            guard encoding != 0, let converted, !lossy.boolValue else { return nil }
            text = converted as String
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let allowed: Set<Unicode.Scalar> = ["\t", "\n", "\r", "\u{0C}"]
        let controls = text.unicodeScalars.count(where: { $0.properties.generalCategory == .control && !allowed.contains($0) })
        return controls * 100 > text.unicodeScalars.count ? nil : text
    }

    /// Line breaks as "\n", a page break as a blank line, and no NUL or stand in for a
    /// picture (U+FFFC). PDFKit returns Kangxi radicals for some fonts, such as ⼯ for 工,
    /// which NFKC turns into the characters they stand for. NFKC changes only those, so full
    /// width punctuation stays as written.
    static func normalized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var afterCarriageReturn = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r", "\u{2028}", "\u{2029}":
                scalars.append("\n")
            case "\n":
                if !afterCarriageReturn { scalars.append("\n") }
            case "\u{0C}":
                scalars.append(contentsOf: "\n\n".unicodeScalars)
            case "\u{0}", "\u{FFFC}":
                break
            case "\u{2E80}"..."\u{2EFF}", "\u{2F00}"..."\u{2FDF}":
                scalars.append(contentsOf: String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars)
            default:
                scalars.append(scalar)
            }
            afterCarriageReturn = scalar == "\r"
        }
        return String(scalars)
    }
}
