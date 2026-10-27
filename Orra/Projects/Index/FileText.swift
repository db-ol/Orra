import AppKit
import Foundation
import PDFKit

/// Why a file in a project folder gives no text for the index. FolderWalk skips a file or a
/// folder for one of the reasons up to `noAccess` before anything opens it, except an
/// archive, a file of a format Projects does not read and a file over its size limit, which
/// it lists by name only. FileTextExtractor checks a file's reasons again before it reads,
/// and adds the reasons from `noAccess` to `cancelled`. The index adds the last three.
///
/// A row of the index holds no reason when it holds the file's text, else one of: archive,
/// tooLarge, unsupportedFormat, unreadable, locked, tooSlow, noText, waitsForRecognition,
/// imageWithoutText and overFileLimit. The raw values stay the same from release to
/// release, so the index can store them.
nonisolated enum FileSkipReason: String, Error, Sendable, Codable, CaseIterable {
    /// A name that starts with a period, or a file Finder hides.
    case hidden
    /// An app, a library or another package, which Finder shows as one file.
    case package
    /// A .git folder.
    case gitFolder
    /// A node_modules folder.
    case nodeModules
    /// A zip file, a disk image or another archive, known by its name only. Archives are
    /// never opened.
    case archive
    /// A symbolic link, which is never followed.
    case symbolicLink
    /// A Finder alias, which is never followed.
    case alias
    /// A path that leads out of the added folder once resolved.
    case outsideFolder
    /// A disk mounted inside the folder, such as /System/Volumes/Data or a disk in /Volumes.
    case volume
    /// A folder the walk never enters: the home folder, ~/Library, Desktop, Documents,
    /// Downloads or Mail's data, reached through a second path, or a copy of Mail's data
    /// such as one in a backup.
    case protectedFolder
    /// A file over its size limit, see `FolderWalk.maximumFileSize` and
    /// `FileTextExtractor.Limits`.
    case tooLarge
    /// A file or folder whose data is not on this Mac, such as an iCloud file removed to
    /// save space. Reading it would download it.
    case dataless
    /// An iCloud file whose newest version is not downloaded.
    case notDownloaded
    /// A format Projects does not read, such as a drawing or a video, known by its name
    /// only. Also anything that is not a regular file, such as a named pipe.
    case unsupportedFormat
    /// A file or folder Orra may not read, or one that went away.
    case noAccess
    /// Content that does not match the file's extension, or that its reader cannot read.
    case unreadable
    /// A PDF that needs a password.
    case locked
    /// A PDF that took longer than its time limit to read.
    case tooSlow
    /// A file without text, such as a PDF whose only text is hidden, or a scan whose pages
    /// gave no text when they were recognized.
    case noText
    /// The read stopped because its task was cancelled, so nothing is known about the file.
    /// The index does not store this reason.
    case cancelled
    /// An image, or a PDF whose pages hold no text layer, whose text has not been
    /// recognized yet.
    case waitsForRecognition
    /// An image in which recognition found no text.
    case imageWithoutText
    /// A document or an image past the number of files the index reads for a project,
    /// known by its name only, see FolderIndex.Limits.
    case overFileLimit
}

/// The text of one file, page by page.
nonisolated struct FileTextResult: Sendable, Equatable {
    nonisolated struct Page: Sendable, Equatable {
        /// The page number in a PDF and the slide number in a deck, from 1. Nil for the
        /// other formats, which have no fixed pages.
        var number: Int?
        var text: String
        /// The name of the sheet in a workbook, which is a page with no number.
        var sheet: String? = nil
        /// Whether the text was recognized in an image or on a scanned page, so its words
        /// and numbers may be wrong.
        var isRecognized = false
        /// Whether the page stands alone, as a slide or a sheet does, so its chunks take
        /// no heading from the pages before it, see TextChunker.
        var isStandAlone = false
    }

    /// The pages that hold text, in order. None only for bytes whose only text was hidden,
    /// see `FileTextExtractor.text(of:format:modified:)`.
    var pages: [Page]
    /// How many runs of hidden text were dropped: text colored like what lies behind it,
    /// nearly transparent text, text in a tiny font, Word's hidden text in RTF, and text
    /// that leaves no ink on a PDF page. The text itself is gone. The count lets Projects
    /// tell the user that the file may hold hidden text. Light text on a docx's cell shading,
    /// run shading or highlight counts too, since AppKit does not report them.
    var hiddenRuns: Int
    /// The file's modification date when it was read.
    var modified: Date
    /// Whether pages past `FileTextExtractor.Limits.pdfPages` were left out, or the later
    /// sheets, cells or slides of an xlsx or pptx.
    var isCut: Bool
    /// The PDF pages whose text layer holds fewer than `FileTextExtractor.textLayerCharacters`
    /// letters or digits, such as scanned pages, whose text only recognition can read.
    var pagesWithoutText: [Int] = []
}

/// Reads the text of one file in a project folder: PDF, docx, doc, rtf, odt, xlsx, pptx, md,
/// txt, csv and tsv. MailAttachment reads the bytes of an email's attachments with it too.
///
/// The files may come from anyone and are read in Orra's own process, so:
/// - A file is read only after a check of its type, flags and size, through a descriptor
///   that does not follow a symbolic link, with macOS told not to download a dataless file.
/// - An Office file goes to `NSAttributedString` only when its first bytes match its
///   extension, and always with the document type of that extension. Never with automatic
///   detection and never as HTML, so a .doc that holds HTML is unreadable and never reaches
///   WebKit.
/// - One call reads a Word, RTF, OpenDocument or text file whole and cannot be stopped, so
///   their size is capped before the call. For docx and odt, which are ZIP files, the sizes
///   their parts unpack to are capped too. A PDF is read page by page, with the time and
///   cancellation checked after each page and the number of pages capped. An xlsx or pptx
///   is read part by part with ZipArchive and OfficeXMLText, never by AppKit, with the time
///   and cancellation checked as it goes.
/// - Hidden text is dropped and counted, see `FileTextResult.hiddenRuns`.
nonisolated struct FileTextExtractor: Sendable {
    /// The formats it reads.
    nonisolated enum Format: Sendable, CaseIterable {
        case pdf, docx, doc, rtf, odt
        /// xlsx and xlsm.
        case xlsx
        /// pptx and ppsx.
        case pptx
        /// md, txt, csv and tsv.
        case text
    }

    /// What the index does with a file, by its extension.
    nonisolated enum Kind: Sendable, Equatable {
        /// A document whose text it reads in this format.
        case text(Format)
        /// An image, whose text only recognition can read.
        case image
        /// A file it knows by its name only, and why.
        case nameOnly(FileSkipReason)
    }

    /// The letters and digits a PDF page's text layer holds at least, below which the page
    /// may be a scan whose text only recognition can read.
    static let textLayerCharacters = 20

    /// The limits for one file. All of them are guesses.
    nonisolated struct Limits: Sendable {
        /// Any file, the same as FolderWalk's.
        var fileBytes = FolderWalk.maximumFileSize
        /// docx, doc, rtf and odt. For docx and odt it also caps the sizes of their parts
        /// unpacked, added up, since AppKit unpacks them in memory, and for xlsx and pptx the
        /// parts read, see OfficeXMLText.
        var officeBytes: Int64 = 20_000_000
        /// md and txt.
        var textBytes: Int64 = 10_000_000
        /// The pages read from a PDF. Later pages are left out.
        var pdfPages = 2_000
        /// The time a PDF may take. A PDF over it is skipped as `tooSlow`.
        var pdfTime: Duration = .seconds(10)
        /// The time an xlsx or pptx may take, whose parts are read in steps that can stop.
        var officeTime: Duration = .seconds(10)
        /// The characters read from an xlsx or pptx. Later cells and slides are left out.
        var officeCharacters = 1_000_000
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

    /// The text of the bytes of a file in `format` that came from elsewhere, such as an
    /// email's attachment, with the same limits and checks as a file in a folder, or why
    /// they give none. `modified` is the date the result carries. Bytes whose only text is
    /// hidden give a result without pages, so the hidden runs are not lost with the text.
    @concurrent
    func text(of data: Data, format: Format, modified: Date) async -> Result<FileTextResult, FileSkipReason> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard Int64(data.count) <= limit(of: format) else { return .failure(.tooLarge) }
        return extract(data, format: format, modified: modified, keepsHiddenOnly: true)
    }

    /// What a file extension means: a document to read in a format, an image, or a file
    /// known by its name only.
    static func kind(ofExtension fileExtension: String) -> Kind {
        switch fileExtension.lowercased() {
        case "pdf": .text(.pdf)
        case "docx": .text(.docx)
        case "doc": .text(.doc)
        case "rtf": .text(.rtf)
        case "odt": .text(.odt)
        case "xlsx", "xlsm": .text(.xlsx)
        case "pptx", "ppsx": .text(.pptx)
        case "md", "txt", "csv", "tsv": .text(.text)
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp": .image
        case let other where archiveExtensions.contains(other): .nameOnly(.archive)
        default: .nameOnly(.unsupportedFormat)
        }
    }

    private static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "lz", "lzma", "cab",
        "cpgz", "jar", "xip", "pkg", "dmg", "iso", "sparseimage",
    ]

    private func read(_ file: URL) -> Result<FileTextResult, FileSkipReason> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let format: Format
        switch Self.kind(ofExtension: file.pathExtension) {
        case .text(let found): format = found
        case .image: return .failure(.waitsForRecognition)
        case .nameOnly(let reason): return .failure(reason)
        }
        let data: Data
        let modified: Date
        switch contents(of: file.path, limit: limit(of: format)) {
        case .success(let contents): (data, modified) = contents
        case .failure(let reason): return .failure(reason)
        }
        return extract(data, format: format, modified: modified)
    }

    /// The most bytes a file of the format may have.
    private func limit(of format: Format) -> Int64 {
        switch format {
        // A deck is mostly pictures, which are never unpacked, so an xlsx or pptx may be as
        // large as any file. The parts it reads are capped.
        case .pdf, .xlsx, .pptx: limits.fileBytes
        case .text: min(limits.fileBytes, limits.textBytes)
        case .docx, .doc, .rtf, .odt: min(limits.fileBytes, limits.officeBytes)
        }
    }

    /// The text of a file's bytes, read as `format`. Without visible text it gives `noText`,
    /// or with `keepsHiddenOnly` a result without pages when hidden runs were dropped. A PDF
    /// with pages whose text layer is empty gives a result that lists them, with or without
    /// pages, since recognition may read them.
    private func extract(_ data: Data, format: Format, modified: Date, keepsHiddenOnly: Bool = false) -> Result<FileTextResult, FileSkipReason> {
        var pages: [FileTextResult.Page]
        var hiddenRuns = 0
        var isCut = false
        var pagesWithoutText: [Int] = []
        switch format {
        case .pdf:
            switch pdfText(data) {
            case .success(let read): (pages, hiddenRuns, isCut, pagesWithoutText) = read
            case .failure(let reason): return .failure(reason)
            }
        case .docx, .doc, .rtf, .odt:
            switch officeText(data, format: format) {
            case .success(let read):
                pages = [FileTextResult.Page(number: nil, text: read.text)]
                hiddenRuns = read.hiddenRuns
            case .failure(let reason): return .failure(reason)
            }
        case .xlsx, .pptx:
            guard data.starts(with: Self.zipSignature) else { return .failure(.unreadable) }
            let archive: ZipArchive
            do {
                archive = try ZipArchive(data)
            } catch {
                return .failure(error)
            }
            let read = format == .xlsx
                ? OfficeXMLText.workbook(archive, limits: limits, now: now)
                : OfficeXMLText.presentation(archive, limits: limits, now: now)
            switch read {
            case .success(let read): (pages, hiddenRuns, isCut) = read
            case .failure(let reason): return .failure(reason)
            }
        case .text:
            guard let text = Self.decoded(data) else { return .failure(.unreadable) }
            pages = [FileTextResult.Page(number: nil, text: text)]
        }

        pages = pages.map { page in
            var page = page
            page.text = Self.normalized(page.text)
            return page
        }
        .filter { !$0.text.allSatisfy(\.isWhitespace) }
        guard !pages.isEmpty || (keepsHiddenOnly && hiddenRuns > 0) || !pagesWithoutText.isEmpty else { return .failure(.noText) }
        return .success(FileTextResult(pages: pages, hiddenRuns: hiddenRuns, modified: modified, isCut: isCut, pagesWithoutText: pagesWithoutText))
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
        // O_NOFOLLOW_ANY refuses a symbolic link anywhere in the path, in case a folder was
        // swapped for one after the walk. O_NONBLOCK keeps a file that turned into a named
        // pipe from blocking the open.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
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
            // FileHandle reports the POSIX error under NSUnderlyingErrorKey.
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            let isDataless = underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EDEADLK)
            return .failure(isDataless ? .dataless : .noAccess)
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

    private func pdfText(_ data: Data) -> Result<([FileTextResult.Page], Int, Bool, [Int]), FileSkipReason> {
        let start = now()
        guard let document = PDFDocument(data: data) else { return .failure(.unreadable) }
        guard !document.isLocked else { return .failure(.locked) }
        let count = min(document.pageCount, limits.pdfPages)
        var pages: [FileTextResult.Page] = []
        var hiddenRuns = 0
        var pagesWithoutText: [Int] = []
        for index in 0..<count {
            let read: (text: String, hiddenRuns: Int, layer: Int)? = autoreleasepool {
                document.page(at: index).map(Self.visibleText(of:))
            }
            if let read {
                pages.append(FileTextResult.Page(number: index + 1, text: read.text))
                hiddenRuns += read.hiddenRuns
            }
            if (read?.layer ?? 0) < Self.textLayerCharacters {
                pagesWithoutText.append(index + 1)
            }
            if Task.isCancelled { return .failure(.cancelled) }
            if start.duration(to: now()) > limits.pdfTime { return .failure(.tooSlow) }
        }
        return .success((pages, hiddenRuns, document.pageCount > count, pagesWithoutText))
    }

    /// The text of a PDF page without its hidden runs, and the letters and digits of its
    /// whole text layer, hidden runs included. PDFKit gives the size of each run but not
    /// whether it is drawn: it reports transparent text as opaque, and says nothing of
    /// invisible text (render mode 3) or of a shape drawn over text. So the page is drawn,
    /// and a line counts as hidden where it leaves no ink. A scan's invisible text layer lies
    /// on the scan's ink and is kept. Text drawn over other text is not found.
    private static func visibleText(of page: PDFPage) -> (text: String, hiddenRuns: Int, layer: Int) {
        guard let document = page.attributedString else {
            let text = page.string ?? ""
            return (text, 0, lettersAndDigits(in: text))
        }
        let layer = lettersAndDigits(in: document.string)
        guard let drawing = PageDrawing(page) else {
            // Without a drawing, light and transparent text counts as hidden.
            let read = visible(document) { attributes, _ in
                if isTiny(attributes) { return true }
                guard let color = RGB(attributes[.foregroundColor] as? NSColor ?? .black) else { return false }
                return color.isTransparent || color.isLight
            }
            return (read.text, read.hiddenRuns, layer)
        }
        let string = document.string as NSString
        let read = visible(document) { attributes, range in
            if isTiny(attributes) { return true }
            guard let box = page.selection(for: range)?.bounds(for: page) else { return false }
            // Punctuation alone leaves too little ink to judge, and hides nothing.
            let characters = string.substring(with: range).count { $0.isLetter || $0.isNumber }
            guard characters > 0 else { return false }
            let size = (attributes[.font] as? NSFont)?.pointSize ?? box.height
            return !drawing.showsInk(in: box, characters: characters, size: size)
        }
        return (read.text, read.hiddenRuns, layer)
    }

    private static func lettersAndDigits(in text: String) -> Int {
        text.count { $0.isLetter || $0.isNumber }
    }

    /// A PDF page drawn at up to one pixel a point, to see where text leaves ink.
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

        /// Whether `box`, in page space, shows the ink of `characters` letters or digits of
        /// `size` points: for each, ink on at least 2% of a square of that size. Ink is a
        /// pixel that differs by more than 16 levels (1 in 16) in a channel from the box's
        /// most common color, so text lighter than about 15/16 gray on white shows none. The
        /// ink is counted per character, not per area, since PDFKit's box for a line can
        /// reach far past its last character. A box off the page counts as showing ink, so
        /// its text is kept.
        func showsInk(in box: CGRect, characters: Int, size: CGFloat) -> Bool {
            let left = max(0, Int(((box.minX - origin.x) * scale).rounded(.down)))
            let right = min(width, Int(((box.maxX - origin.x) * scale).rounded(.up)))
            let bottom = max(0, Int(((box.minY - origin.y) * scale).rounded(.down)))
            let top = min(height, Int(((box.maxY - origin.y) * scale).rounded(.up)))
            guard left < right, bottom < top else { return true }
            return pixels.withUnsafeBufferPointer { pixels in
                // The most common color is the average of the fullest bin, with bins of 32
                // levels a channel. The first row in memory is the top of the drawing.
                var counts = [Int](repeating: 0, count: 512)
                var sums = [Int](repeating: 0, count: 512 * 3)
                var common = 0
                for y in bottom..<top {
                    let row = (height - 1 - y) * width
                    for x in left..<right {
                        let pixel = (row + x) * 4
                        let red = Int(pixels[pixel]), green = Int(pixels[pixel + 1]), blue = Int(pixels[pixel + 2])
                        let bin = (red >> 5) << 6 | (green >> 5) << 3 | blue >> 5
                        counts[bin] += 1
                        sums[bin * 3] += red
                        sums[bin * 3 + 1] += green
                        sums[bin * 3 + 2] += blue
                        if counts[bin] > counts[common] { common = bin }
                    }
                }
                let red = sums[common * 3] / counts[common]
                let green = sums[common * 3 + 1] / counts[common]
                let blue = sums[common * 3 + 2] / counts[common]
                var ink = 0
                for y in bottom..<top {
                    let row = (height - 1 - y) * width
                    for x in left..<right {
                        let pixel = (row + x) * 4
                        if abs(Int(pixels[pixel]) - red) > 16 || abs(Int(pixels[pixel + 1]) - green) > 16
                            || abs(Int(pixels[pixel + 2]) - blue) > 16 {
                            ink += 1
                        }
                    }
                }
                let side = Double(size * scale)
                return ink >= max(1, Int(Double(characters) * side * side / 50))
            }
        }
    }

    // MARK: Office

    private func officeText(_ data: Data, format: Format) -> Result<(text: String, hiddenRuns: Int), FileSkipReason> {
        let signature: [UInt8]
        let documentType: NSAttributedString.DocumentType
        switch format {
        case .docx: (signature, documentType) = (Self.zipSignature, .officeOpenXML)
        case .odt: (signature, documentType) = (Self.zipSignature, .openDocument)
        case .doc: (signature, documentType) = ([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], .docFormat)
        case .rtf: (signature, documentType) = (Array(#"{\rtf"#.utf8), .rtf)
        case .pdf, .xlsx, .pptx, .text: return .failure(.unsupportedFormat)
        }
        guard data.starts(with: signature) else { return .failure(.unreadable) }
        if signature == Self.zipSignature {
            // AppKit unpacks each part in memory, at the size the ZIP's central directory
            // gives for it, and fails on a part that unpacks larger (local test), so those
            // sizes added up cap what it unpacks. A ZIP whose directory could show this check
            // one thing and AppKit another is unreadable, see ZipArchive.
            let archive: ZipArchive
            do {
                archive = try ZipArchive(data)
            } catch {
                return .failure(error)
            }
            if archive.unpackedSize > min(limits.fileBytes, limits.officeBytes) { return .failure(.tooLarge) }
        }
        let readable = format == .rtf ? Self.markingHiddenText(inRTF: data) : data
        var attributes: NSDictionary?
        guard let document = try? NSAttributedString(
            data: readable, options: [.documentType: documentType], documentAttributes: &attributes
        ) else { return .failure(.unreadable) }
        let page = attributes?[NSAttributedString.DocumentAttributeKey.backgroundColor.rawValue] as? NSColor
        return .success(Self.visible(document) { attributes, _ in Self.isHidden(attributes, onPage: page) })
    }

    private static let zipSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// The kerning that marks Word's hidden text in RTF, in points. No real document uses it.
    private static let hiddenKerning = -1_000.0

    /// `rtf` with Word's hidden text marked in a way AppKit keeps. AppKit reads the hidden
    /// text control word `\v` as plain text, so `\v` becomes a kerning of -1,000 points
    /// (`\expndtw-20000`) and `\v0` a kerning of 0. The kerning lost this way changes
    /// nothing in the text. Control symbols such as `\\` and the bytes of `\bin` are skipped.
    private static func markingHiddenText(inRTF rtf: Data) -> Data {
        let bytes = [UInt8](rtf)
        var marked = Data(capacity: bytes.count)
        var copied = 0
        var index = 0
        func isLetter(_ index: Int) -> Bool { index < bytes.count && (bytes[index] | 0x20) >= 0x61 && (bytes[index] | 0x20) <= 0x7A }
        func isDigit(_ index: Int) -> Bool { index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39 }
        while index < bytes.count {
            guard bytes[index] == 0x5C else {
                index += 1
                continue
            }
            var end = index + 1
            while isLetter(end) { end += 1 }
            guard end > index + 1 else {
                // A control symbol, such as \\ or \'e4.
                index += 2
                continue
            }
            let name = bytes[(index + 1)..<end]
            var parameterEnd = end
            if parameterEnd < bytes.count, bytes[parameterEnd] == 0x2D, isDigit(parameterEnd + 1) { parameterEnd += 1 }
            while isDigit(parameterEnd) { parameterEnd += 1 }
            let parameter = Int(String(decoding: bytes[end..<parameterEnd], as: UTF8.self))
            if name.elementsEqual("v".utf8) {
                marked.append(contentsOf: bytes[copied..<index])
                marked.append(contentsOf: (parameter == 0 ? #"\expndtw0"# : #"\expndtw-20000"#).utf8)
                copied = parameterEnd
            } else if name.elementsEqual("bin".utf8), let parameter, parameter > 0 {
                // Raw bytes follow the space after the control word.
                let start = parameterEnd < bytes.count && bytes[parameterEnd] == 0x20 ? parameterEnd + 1 : parameterEnd
                index = min(bytes.count, start + parameter)
                continue
            }
            index = parameterEnd
        }
        marked.append(contentsOf: bytes[copied...])
        return marked
    }

    /// Whether an Office run is hidden: a tiny font, nearly transparent, Word's hidden text
    /// marked in RTF, or colored like what lies behind it, which is the run's own background,
    /// the table cell's, the page's or white. AppKit does not report a docx's cell shading,
    /// run shading or highlight, so light text on them counts as hidden too.
    private static func isHidden(_ attributes: [NSAttributedString.Key: Any], onPage page: NSColor?) -> Bool {
        if isTiny(attributes) { return true }
        if let kerning = attributes[.kern] as? Double, kerning <= hiddenKerning { return true }
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
