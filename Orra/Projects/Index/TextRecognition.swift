import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Synchronization
import Vision

/// A file whose text recognition reads, and how far: one job of the folder index, see
/// TextRecognizer.
nonisolated struct RecognitionJob: Sendable, Equatable {
    nonisolated enum Kind: Sendable, Equatable {
        /// A PDF, whose pages without a text layer are read.
        case pdf
        /// An image, see `FileTextExtractor.Kind.image`.
        case image
    }

    var file: URL
    var kind: Kind
    /// The size and modification date, in seconds since 1970, of the file as the index holds
    /// it. A file that differs changed after the sweep, and the job reads nothing.
    var size: Int64
    var modified: Double
    /// The pages tried before, by number, 0 for an image of one frame.
    var done: Set<Int> = []
    /// The most pages this job reads.
    var pages: Int
}

/// How the recognition of one page went, as the index keeps it, see
/// `FolderIndex.fileTypesMigration`.
nonisolated enum RecognitionOutcome: String, Sendable, Equatable {
    /// The page gave text.
    case text
    /// The page gave no text, or only hidden text.
    case blank
    /// The page took longer than `TextRecognizer.Limits.pageTime`.
    case timedOut
    /// The page could not be drawn or read.
    case failed
}

/// What one job read.
nonisolated struct RecognitionResult: Sendable, Equatable {
    /// The text of the pages that gave text, in order, each marked as recognized. An image of
    /// one frame gives a page without a number.
    var pages: [FileTextResult.Page] = []
    /// Each page the job tried, with how it went. A page under way when the job stopped is
    /// not among them, so it is tried again.
    var tried: [Int: RecognitionOutcome] = [:]
    /// Runs of text dropped as hidden, see `TextRecognizer.text(of:ink:)`.
    var hiddenRuns = 0
    /// Whether no page of the file is left to try after this job.
    var isDone = false
    /// Whether the file differs from the job's size and date, so the job read nothing.
    var fileChanged = false
}

/// Recognizes the text of images and of PDF pages without a text layer, with Vision on this
/// Mac. Vision is no language model, sends nothing and downloads nothing.
///
/// - The bytes come from `FileTextExtractor.checkedContents`, the one read of a file in a
///   project folder, so no link is followed and no file that is not on this Mac is
///   downloaded. A file whose size or date differs from the job's is not read further.
/// - Images: ImageIO, which must find the type the extension names. The pixels of every
///   frame are capped from the image's properties before anything is decoded. Each frame is
///   decoded at most `longestSide` on its longest side, upright. A TIFF with several pages
///   gives each page, numbered from 1, and any other image its main frame, page 0.
/// - PDFs: PDFKit. The pages whose text layer holds fewer than
///   `FileTextExtractor.textLayerCharacters` letters or digits, such as scans, are drawn on
///   white at `dotsPerInch`, upright, as a reader shows them.
/// - At most `pagesPerFile` pages a file are tried, the first ones, and at most the job's
///   pages in one job. Before every page the job asks `mayGoOn`, so it stops between pages
///   for a dictation, Live Captions, a request of the user or a sweep. Cancelling the job's
///   task stops the read of the page under way at once, and a page being drawn once its
///   drawing ends, since drawing cannot be stopped. That page counts as not tried.
/// - A page's time, `pageTime`, runs from the start of its drawing. A read still under way
///   when it ends is stopped, and the page counts as timed out. A page whose drawing alone
///   took that long is not read and counts as timed out, also when the job was stopped
///   meanwhile, so a page too slow to draw is not drawn again and again. A job whose every
///   page timed out ends the file as `tooSlow`.
/// - The lines Vision finds are put in reading order, also on a scan turned a little, and
///   text that shows no ink on the image Vision read is dropped and counted as hidden, as on
///   a PDF page. A page that gives fewer than two letters or digits counts as blank.
/// - Languages, `languages`: Chinese, simplified and traditional, and English, read by
///   Vision's Chinese model, which reads English too. Japanese and Spanish are not asked
///   for: the first language decides the model, so adding them after Chinese changes
///   nothing, a Japanese one first reads Chinese worse, and letting Vision detect the
///   language reads the Chinese words of an English page as Latin letters (measured on
///   synthetic pages on 2026-10-26). Kanji are read, kana often not, and Spanish without
///   its accents, which search ignores anyway.
nonisolated struct TextRecognizer: Sendable {
    /// The limits of recognition. All of them are guesses, see the measurement in
    /// TextRecognitionMeasurementTests.
    nonisolated struct Limits: Sendable, Equatable {
        /// The pixels of an image frame, width times height, read from its properties.
        var pixels = 50_000_000
        /// The longest side of what Vision reads, in pixels.
        var longestSide = 4_096
        /// The resolution a PDF page is drawn at.
        var dotsPerInch: CGFloat = 300
        /// The pages tried in one file, the first ones.
        var pagesPerFile = 100
        /// The time one page may take, its drawing and its read.
        var pageTime: Duration = .seconds(20)
        /// Vision's minimum height of text, relative to the height of the image. 0 reads the
        /// image at its full size, see VNRecognizeTextRequest.h.
        var minimumTextHeight: Float = 0
    }

    /// A line of text Vision found: its best reading and where it lies, normalized, with the
    /// origin at the bottom left of the image.
    nonisolated struct Observation: Sendable, Equatable {
        var text: String
        /// The box that holds it, upright.
        var box: CGRect
        /// The middles of its left and right edges, which follow its line when a scan is
        /// turned a little, where the box of a long line reaches into the lines next to it.
        var start: CGPoint
        var end: CGPoint
        /// The height of its text across the line, at its left edge.
        var height: CGFloat

        /// An observation whose text runs straight across, at its box.
        init(text: String, box: CGRect) {
            self.init(
                text: text, box: box, start: CGPoint(x: box.minX, y: box.midY), end: CGPoint(x: box.maxX, y: box.midY),
                height: box.height)
        }

        init(text: String, box: CGRect, start: CGPoint, end: CGPoint, height: CGFloat) {
            self.text = text
            self.box = box
            self.start = start
            self.end = end
            self.height = height
        }
    }

    /// How reading one image ended.
    nonisolated enum Read: Sendable, Equatable {
        case observations([Observation])
        case failed
        case cancelled
    }

    /// The languages Vision reads, in order, see the type's documentation.
    static let languages = ["zh-Hans", "zh-Hant", "en-US"]

    /// The letters and digits a page gives at least to count as text, since a shape alone
    /// can read as one character, such as a rectangle read as 门.
    static let fewestCharacters = 2

    let limits: Limits
    /// Reads the text of one image, Vision on this Mac by default. Cancelling the calling
    /// task stops it. Tests pass a stand in.
    let read: @Sendable (CGImage) async -> Read
    /// Waits for a time, for `Limits.pageTime`. Tests pass a stand in.
    let sleep: @Sendable (Duration) async throws -> Void
    /// The stat flags of a path, see `FolderWalk.statFlags(_:)`. Tests pass a stand in.
    let flags: @Sendable (String) -> UInt32?

    init(
        limits: Limits = Limits(),
        read: (@Sendable (CGImage) async -> Read)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        flags: @escaping @Sendable (String) -> UInt32? = FolderWalk.statFlags
    ) {
        self.limits = limits
        let minimumTextHeight = limits.minimumTextHeight
        self.read = read ?? { image in
            await VisionText.read(image, languages: TextRecognizer.languages, minimumTextHeight: minimumTextHeight)
        }
        self.sleep = sleep
        self.flags = flags
    }

    /// Recognizes the text of up to `job.pages` pages of the job's file that it did not try
    /// before. Off the main actor, since drawing a page and reading it take a while.
    /// `mayGoOn` is asked before every page, and the job stops when it says no. Fails only
    /// for the whole file: unreadable, too large, locked, too slow, or a reason of the
    /// checked read, such as no access.
    @concurrent
    func recognize(_ job: RecognitionJob, mayGoOn: @escaping @Sendable () async -> Bool) async -> Result<RecognitionResult, FileSkipReason> {
        guard !Task.isCancelled else { return .success(RecognitionResult()) }
        let data: Data
        switch FileTextExtractor.checkedContents(of: job.file.path, limit: FolderWalk.maximumFileSize, flags: flags) {
        case .success(let contents):
            guard Int64(contents.data.count) == job.size, contents.modified.timeIntervalSince1970 == job.modified else {
                return .success(RecognitionResult(fileChanged: true))
            }
            data = contents.data
        case .failure(.tooLarge):
            // The walk lists no image or PDF over this size, so the file grew after it.
            return .success(RecognitionResult(fileChanged: true))
        case .failure(let reason):
            return .failure(reason)
        }
        switch job.kind {
        case .pdf: return await recognizePDF(data, job: job, mayGoOn: mayGoOn)
        case .image: return await recognizeImage(data, job: job, mayGoOn: mayGoOn)
        }
    }

    // MARK: PDFs

    private func recognizePDF(_ data: Data, job: RecognitionJob, mayGoOn: @escaping @Sendable () async -> Bool) async -> Result<RecognitionResult, FileSkipReason> {
        guard let document = PDFDocument(data: data) else { return .failure(.unreadable) }
        guard !document.isLocked else { return .failure(.locked) }
        // The pages without a text layer, the first `pagesPerFile` of them. Their text layer
        // is only counted, never read into the index again. A PDF whose layers take longer
        // than a page may to count is too slow.
        var candidates: [Int] = []
        let started = ContinuousClock.now
        for index in 0..<min(document.pageCount, FileTextExtractor.Limits().pdfPages) {
            guard candidates.count < limits.pagesPerFile else { break }
            guard !Task.isCancelled else { return .success(RecognitionResult()) }
            guard started.duration(to: .now) <= limits.pageTime else { return .failure(.tooSlow) }
            let layer = autoreleasepool {
                (document.page(at: index)?.string ?? "").count { $0.isLetter || $0.isNumber }
            }
            if layer < FileTextExtractor.textLayerCharacters {
                candidates.append(index + 1)
            }
        }
        return await recognize(candidates, of: job, mayGoOn: mayGoOn) { number in
            autoreleasepool {
                document.page(at: number - 1).flatMap(drawing(of:))
            }
        }
    }

    /// A PDF page drawn on white at `dotsPerInch`, at most `longestSide` on its longest side,
    /// turned as the page says, as a reader shows it.
    private func drawing(of page: PDFPage) -> Drawing? {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(limits.dotsPerInch / 72, CGFloat(limits.longestSide) / max(size.width, size.height))
        return Drawing(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded())) { context in
            context.interpolationQuality = .high
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
        }
    }

    // MARK: Images

    private func recognizeImage(_ data: Data, job: RecognitionJob, mayGoOn: @escaping @Sendable () async -> Bool) async -> Result<RecognitionResult, FileSkipReason> {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              Self.imageTypes(ofExtension: job.file.pathExtension).contains(type)
        else { return .failure(.unreadable) }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return .failure(.unreadable) }
        // The frames to read, by page: each page of a TIFF with several, else the main frame.
        let frames: [(page: Int, index: Int)]
        if type == "public.tiff", count > 1 {
            frames = (0..<min(count, limits.pagesPerFile)).map { (page: $0 + 1, index: $0) }
        } else {
            frames = [(page: 0, index: CGImageSourceGetPrimaryImageIndex(source))]
        }
        // Every frame's pixels, before anything is decoded.
        for frame in frames {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, frame.index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0
            else { return .failure(.unreadable) }
            let pixels = width.multipliedReportingOverflow(by: height)
            guard !pixels.overflow, pixels.partialValue <= limits.pixels else { return .failure(.tooLarge) }
        }
        let indexes = Dictionary(uniqueKeysWithValues: frames.map { ($0.page, $0.index) })
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.longestSide,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return await recognize(frames.map(\.page), of: job, mayGoOn: mayGoOn) { page in
            autoreleasepool {
                guard let index = indexes[page], let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { return nil }
                // On white, as a viewer shows a transparent image, and in gray, as the PDF
                // pages are.
                return Drawing(width: image.width, height: image.height) { context in
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
            }
        }
    }

    /// The types ImageIO must find for an extension, so a file never reaches a decoder of
    /// another format than its name says.
    static func imageTypes(ofExtension fileExtension: String) -> Set<String> {
        switch fileExtension.lowercased() {
        case "png": ["public.png"]
        case "jpg", "jpeg": ["public.jpeg"]
        case "heic", "heif": ["public.heic", "public.heif"]
        case "tif", "tiff": ["public.tiff"]
        case "gif": ["com.compuserve.gif"]
        case "bmp": ["com.microsoft.bmp"]
        case "webp": ["org.webmproject.webp"]
        default: []
        }
    }

    // MARK: Pages

    /// A page drawn in gray for Vision, and its pixels for the ink test.
    private struct Drawing {
        let image: CGImage
        let ink: InkMap

        /// Draws on white with `draw`, or nil when the size is empty or too large.
        init?(width: Int, height: Int, draw: (CGContext) -> Void) {
            guard width > 0, height > 0, width <= 1 << 15, height <= 1 << 15 else { return nil }
            let space = CGColorSpaceCreateDeviceGray()
            var pixels = [UInt8](repeating: 255, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                draw(context)
                return true
            }
            guard drawn, let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            self.image = image
            ink = InkMap(pixels: pixels, width: width, height: height, bytesPerPixel: 1)
        }
    }

    /// How one page ended, between Vision and the clock.
    private enum PageEnd: Sendable {
        case read(Read)
        case timeUp
    }

    /// Tries the pages of `candidates` that the job did not try before, in order, up to the
    /// job's pages, drawing each with `draw`.
    private func recognize(
        _ candidates: [Int], of job: RecognitionJob, mayGoOn: @escaping @Sendable () async -> Bool, draw: (Int) -> Drawing?
    ) async -> Result<RecognitionResult, FileSkipReason> {
        var result = RecognitionResult()
        var stopped = false
        for page in candidates where !job.done.contains(page) {
            guard result.tried.count < job.pages else { break }
            guard !Task.isCancelled, await mayGoOn(), !Task.isCancelled else {
                stopped = true
                break
            }
            // The page's time runs from the start of its drawing, which cannot be stopped.
            // A page whose drawing took all of it is not read, and counts as timed out also
            // when the job was stopped meanwhile, so it is not drawn again and again.
            let started = ContinuousClock.now
            guard let drawing = draw(page) else {
                result.tried[page] = .failed
                continue
            }
            let left = limits.pageTime - started.duration(to: .now)
            if left <= .zero {
                result.tried[page] = .timedOut
            }
            // A stop that came while the page was drawn ends the job before Vision starts.
            if Task.isCancelled {
                stopped = true
                break
            }
            guard left > .zero else { continue }
            switch await readPage(drawing.image, within: left) {
            case .read(.observations(let observations)):
                let read = Self.text(of: observations, ink: drawing.ink)
                result.hiddenRuns += read.hiddenRuns
                let text = FileTextExtractor.normalized(read.text)
                if text.count(where: { $0.isLetter || $0.isNumber }) < Self.fewestCharacters {
                    result.tried[page] = .blank
                } else {
                    result.tried[page] = .text
                    result.pages.append(FileTextResult.Page(number: page == 0 ? nil : page, text: text, isRecognized: true))
                }
            case .read(.failed):
                result.tried[page] = .failed
            case .read(.cancelled):
                // The job's task was cancelled, so the page is tried again later. A cancel
                // that came from elsewhere fails the page, so it is not tried forever.
                if Task.isCancelled {
                    stopped = true
                } else {
                    result.tried[page] = .failed
                }
            case .timeUp:
                result.tried[page] = .timedOut
            }
            if stopped { break }
        }
        result.isDone = !candidates.contains { !job.done.contains($0) && result.tried[$0] == nil }
        if !stopped, !result.tried.isEmpty, result.tried.values.allSatisfy({ $0 == .timedOut }) {
            return .failure(.tooSlow)
        }
        return .success(result)
    }

    /// Reads one image, stopped once `time` passed, what is left of the page's time. The
    /// read under way ends before this returns, also when the time ran out or the task was
    /// cancelled, so no page runs on behind the next one.
    private func readPage(_ image: CGImage, within time: Duration) async -> PageEnd {
        let read = self.read
        let sleep = self.sleep
        return await withTaskGroup(of: PageEnd?.self) { group in
            group.addTask {
                .read(await read(image))
            }
            group.addTask {
                do {
                    try await sleep(time)
                } catch {
                    return nil
                }
                return Task.isCancelled ? nil : .timeUp
            }
            var first: PageEnd?
            for await end in group {
                guard let end, first == nil else { continue }
                first = end
                group.cancelAll()
            }
            return first ?? .read(.cancelled)
        }
    }

    // MARK: Text

    /// A line of text: observations whose lines meet the left edge of the image within half
    /// a line's height of its first one, and that lie side by side, never above each other,
    /// so the long lines of a turned scan stay apart and the parts of one line stay together.
    private struct Line {
        var observations: [Observation]
        /// Where the line of its first observation meets the left edge of the image.
        let level: CGFloat
        var height: CGFloat

        init(_ observation: Observation, level: CGFloat) {
            observations = [observation]
            self.level = level
            height = observation.height
        }

        func holds(_ observation: Observation, level: CGFloat) -> Bool {
            abs(level - self.level) <= max(height, observation.height) / 2
                && !observations.contains { other in
                    let overlap = min(other.box.maxX, observation.box.maxX) - max(other.box.minX, observation.box.minX)
                    return overlap > min(other.box.width, observation.box.width) / 2
                }
        }

        mutating func add(_ observation: Observation) {
            observations.append(observation)
            height = max(height, observation.height)
        }
    }

    /// The text of a page's observations in reading order, and the runs of hidden text left
    /// out. A turned scan turns all its lines alike, so each observation's line is followed
    /// to the left edge of the image with the page's slope, the middle one of its longer
    /// observations. Lines go from the top by where they meet that edge, and their
    /// observations from the left. A gap of more than 1.5 lines between two lines gives a
    /// blank line, so TextChunker cuts there. An observation whose box shows no ink on `ink`, the image Vision read, is
    /// hidden, such as text nearly the color of what lies behind it. Hidden observations next
    /// to each other count as one run. Internal for tests.
    static func text(of observations: [Observation], ink: InkMap?) -> (text: String, hiddenRuns: Int) {
        let kept = observations.filter { !$0.text.allSatisfy(\.isWhitespace) }
        let slopes = kept.filter { $0.end.x - $0.start.x > 0.1 }.map { ($0.end.y - $0.start.y) / ($0.end.x - $0.start.x) }.sorted()
        let slope = slopes.isEmpty ? 0 : slopes[slopes.count / 2]
        func level(_ observation: Observation) -> CGFloat {
            observation.start.y - observation.start.x * slope
        }
        var lines: [Line] = []
        let sorted = kept.sorted {
            level($0) != level($1) ? level($0) > level($1) : $0.box.minX < $1.box.minX
        }
        for observation in sorted {
            if let last = lines.indices.last, lines[last].holds(observation, level: level(observation)) {
                lines[last].add(observation)
            } else {
                lines.append(Line(observation, level: level(observation)))
            }
        }
        var text = ""
        var hiddenRuns = 0
        var inHiddenRun = false
        var above: Line?
        for line in lines {
            var visible: [String] = []
            for observation in line.observations.enumerated().sorted(by: { ($0.element.box.minX, $0.offset) < ($1.element.box.minX, $1.offset) }).map(\.element) {
                if let ink, !showsInk(observation, on: ink) {
                    if !inHiddenRun { hiddenRuns += 1 }
                    inHiddenRun = true
                } else {
                    visible.append(observation.text)
                    inHiddenRun = false
                }
            }
            guard !visible.isEmpty else { continue }
            if let above {
                let gap = above.level - line.level - (above.height + line.height) / 2
                text += gap > 1.5 * max(above.height, line.height) ? "\n\n" : "\n"
            }
            text += visible.joined(separator: " ")
            above = line
        }
        return (text, hiddenRuns)
    }

    /// Whether an observation's box shows the ink of its letters and digits, by InkMap's
    /// measure with the height of its text as the size of a character, not the height of its
    /// box, which a turned line makes taller. Punctuation alone leaves too little ink to
    /// judge, and hides nothing.
    private static func showsInk(_ observation: Observation, on ink: InkMap) -> Bool {
        let characters = observation.text.count { $0.isLetter || $0.isNumber }
        guard characters > 0 else { return true }
        let width = CGFloat(ink.width)
        let height = CGFloat(ink.height)
        let box = CGRect(
            x: observation.box.minX * width, y: observation.box.minY * height,
            width: observation.box.width * width, height: observation.box.height * height)
        return ink.showsInk(inPixels: box, characters: characters, size: Double(observation.height * height))
    }
}

/// Vision's text recognition of one image, on a queue of its own at background priority,
/// so the wait for it holds no thread of Swift's own pool.
nonisolated enum VisionText {
    private static let queue = DispatchQueue(label: "io.github.db-ol.Orra.projects-text-recognition", qos: .background)

    /// The lines Vision finds in `image`. Cancelling the calling task cancels the request.
    static func read(_ image: CGImage, languages: [String], minimumTextHeight: Float) async -> TextRecognizer.Read {
        let call = Call(languages: languages, minimumTextHeight: minimumTextHeight)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: call.read(image))
                }
            }
        } onCancel: {
            call.cancel()
        }
    }

    /// The languages Vision reads in the accurate level of revision 3 on this Mac, nil when
    /// it cannot say.
    static func supportedLanguages() -> [String]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequestRevision3
        return try? request.supportedRecognitionLanguages()
    }

    /// One request, which another thread may cancel. Vision's `cancel()` stops a request
    /// that another thread performs (VNRequest.h). A cancel that comes before Vision begins
    /// would be lost, since Vision runs such a request to its end, so the progress handler,
    /// which Vision calls while it works, cancels it again once Vision runs.
    private final class Call: @unchecked Sendable {
        private let request: VNRecognizeTextRequest
        private let isCancelled: Flag

        /// A flag both threads read. A class of its own, since the request holds the progress
        /// handler that reads it.
        private final class Flag: Sendable {
            let value = Mutex(false)
        }

        init(languages: [String], minimumTextHeight: Float) {
            let flag = Flag()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true
            request.minimumTextHeight = minimumTextHeight
            request.preferBackgroundProcessing = true
            request.progressHandler = { request, _, _ in
                if flag.value.withLock({ $0 }) {
                    request.cancel()
                }
            }
            self.request = request
            isCancelled = flag
        }

        func cancel() {
            isCancelled.value.withLock { $0 = true }
            request.cancel()
        }

        /// Runs the request on this thread and waits for it.
        func read(_ image: CGImage) -> TextRecognizer.Read {
            guard !isCancelled.value.withLock({ $0 }) else { return .cancelled }
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return isCancelled.value.withLock({ $0 }) ? .cancelled : .failed
            }
            guard !isCancelled.value.withLock({ $0 }) else { return .cancelled }
            let observations = (request.results ?? []).compactMap { observation -> TextRecognizer.Observation? in
                guard let best = observation.topCandidates(1).first else { return nil }
                let left = (top: observation.topLeft, bottom: observation.bottomLeft)
                let right = (top: observation.topRight, bottom: observation.bottomRight)
                return TextRecognizer.Observation(
                    text: best.string, box: observation.boundingBox,
                    start: CGPoint(x: (left.top.x + left.bottom.x) / 2, y: (left.top.y + left.bottom.y) / 2),
                    end: CGPoint(x: (right.top.x + right.bottom.x) / 2, y: (right.top.y + right.bottom.y) / 2),
                    height: abs(left.top.y - left.bottom.y))
            }
            return .observations(observations)
        }
    }
}
