import CoreGraphics
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Orra

/// TextRecognizer with a stand in for Vision, on images and PDFs made by the test: which
/// pages it reads and how it draws them, the caps it checks before it decodes, the order and
/// the hidden text of what it reads, the page time and cancellation. Vision itself is never
/// called here, see VisionTextRecognitionTests.
@Suite(.timeLimit(.minutes(1)))
struct TextRecognitionTests {
    // MARK: Stand ins

    /// Vision's stand in: answers each image with the next answer, holding the read until it
    /// is cancelled where told to, and keeps the size of every image it got.
    final class StandIn: Sendable {
        enum Answer: Sendable {
            case lines([TextRecognizer.Observation])
            /// One line of this text, in the box of the dark pixels of the image, as Vision
            /// would find it. None on an image without them.
            case ink(String)
            case failed
            /// Waits until the read is cancelled, as a slow page does.
            case hold
            /// A cancel that did not come from the job, as Vision may report.
            case cancelledElsewhere
        }

        private struct State {
            var answers: [Answer]
            var sizes: [CGSize] = []
            var images: [CGImage] = []
        }

        private let state: Mutex<State>
        let hold = Hold()
        /// What a read answers once the scripted answers are used up.
        let otherwise: Answer

        init(_ answers: [Answer] = [], otherwise: Answer = .lines([])) {
            state = Mutex(State(answers: answers))
            self.otherwise = otherwise
        }

        var sizes: [CGSize] {
            state.withLock { $0.sizes }
        }

        var images: [CGImage] {
            state.withLock { $0.images }
        }

        func read(_ image: CGImage) async -> TextRecognizer.Read {
            let answer = state.withLock { state -> Answer in
                state.sizes.append(CGSize(width: image.width, height: image.height))
                state.images.append(image)
                return state.answers.isEmpty ? otherwise : state.answers.removeFirst()
            }
            switch answer {
            case .lines(let observations): return .observations(observations)
            case .ink(let text): return .observations(Self.box(of: image).map { [TextRecognizer.Observation(text: text, box: $0)] } ?? [])
            case .failed: return .failed
            case .cancelledElsewhere: return .cancelled
            case .hold:
                await hold.untilCancelled()
                return .cancelled
            }
        }

        /// The box of the pixels darker than mid gray, normalized from the bottom left.
        static func box(of image: CGImage) -> CGRect? {
            guard let pixels = try? RecognitionTestFiles.grayPixels(of: image) else { return nil }
            var rows: ClosedRange<Int>?
            var columns: ClosedRange<Int>?
            for row in 0..<image.height {
                for column in 0..<image.width where pixels[row * image.width + column] < 128 {
                    rows = rows.map { min($0.lowerBound, row)...max($0.upperBound, row) } ?? row...row
                    columns = columns.map { min($0.lowerBound, column)...max($0.upperBound, column) } ?? column...column
                }
            }
            guard let rows, let columns else { return nil }
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            return CGRect(
                x: CGFloat(columns.lowerBound) / width, y: CGFloat(image.height - 1 - rows.upperBound) / height,
                width: CGFloat(columns.count) / width, height: CGFloat(rows.count) / height)
        }
    }

    /// A wait that ends when its task is cancelled, and tells the test when one began and how
    /// many were cancelled.
    final class Hold: Sendable {
        private struct State {
            var held: CheckedContinuation<Void, Never>?
            var began = 0
            var cancelled = 0
            var arrivals: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        }

        private let state = Mutex(State())

        var cancelled: Int {
            state.withLock { $0.cancelled }
        }

        var hasBegun: Bool {
            state.withLock { $0.began > 0 }
        }

        func untilCancelled() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let (now, arrived) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                        state.began += 1
                        let arrived = state.arrivals.filter { $0.count <= state.began }.map(\.continuation)
                        state.arrivals.removeAll { $0.count <= state.began }
                        guard !Task.isCancelled else { return (true, arrived) }
                        state.held = continuation
                        return (false, arrived)
                    }
                    for arrival in arrived {
                        arrival.resume()
                    }
                    if now {
                        continuation.resume()
                    }
                }
            } onCancel: {
                let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
                    state.cancelled += 1
                    defer { state.held = nil }
                    return state.held
                }
                held?.resume()
            }
        }

        /// Returns once `count` waits began.
        func untilBegun(_ count: Int = 1) async {
            await withCheckedContinuation { continuation in
                let now = state.withLock { state in
                    guard state.began < count else { return true }
                    state.arrivals.append((count, continuation))
                    return false
                }
                if now {
                    continuation.resume()
                }
            }
        }
    }

    /// A clock for the page time that never runs out, unless `runsOut` is set, and then only
    /// once a read holds, so a read that answers always comes first and the outcome never
    /// depends on time.
    final class PageClock: Sendable {
        let standIn: StandIn
        let runsOut: Bool

        init(_ standIn: StandIn, runsOut: Bool = false) {
            self.standIn = standIn
            self.runsOut = runsOut
        }

        func sleep(_ duration: Duration) async throws {
            guard runsOut else {
                try await Task.sleep(for: .seconds(3_600))
                return
            }
            while !standIn.hold.hasBegun {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    /// A temporary folder for the files of one test, at its real path, as the walk gives it,
    /// since the checked read refuses a link anywhere in a path, such as /var.
    struct Folder {
        let url: URL

        init() throws {
            let made = FileManager.default.temporaryDirectory.appendingPathComponent("TextRecognitionTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            url = try #require(made.path.withCString { realpath($0, nil) }.map { pointer in
                defer { free(pointer) }
                return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
            })
        }

        /// Writes a file, and gives the job for it as the index would make it.
        func job(_ name: String, _ data: Data, done: Set<Int> = [], pages: Int = 10) throws -> RecognitionJob {
            let file = url.appendingPathComponent(name)
            try data.write(to: file)
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw RecognitionTestFiles.Failure() }
            let kind: RecognitionJob.Kind = file.pathExtension.lowercased() == "pdf" ? .pdf : .image
            return RecognitionJob(
                file: file, kind: kind, size: Int64(info.st_size), modified: FolderWalk.date(of: info).timeIntervalSince1970,
                done: done, pages: pages)
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func recognizer(_ standIn: StandIn, limits: TextRecognizer.Limits = TextRecognizer.Limits(), clock: PageClock? = nil) -> TextRecognizer {
        let clock = clock ?? PageClock(standIn)
        return TextRecognizer(limits: limits, read: { await standIn.read($0) }, sleep: { try await clock.sleep($0) })
    }

    private static func line(_ text: String, x: CGFloat = 0.1, top: CGFloat, width: CGFloat = 0.5, height: CGFloat = 0.05) -> TextRecognizer.Observation {
        TextRecognizer.Observation(text: text, box: CGRect(x: x, y: top - height, width: width, height: height))
    }

    // MARK: Text

    /// Lines go from the top, the parts of a line from the left, and a gap of more than one
    /// and a half lines leaves a blank line, where TextChunker cuts.
    @Test func linesGoInReadingOrderWithABlankLineAtAGap() {
        let observations = [
            Self.line("Twelve brass lamps", x: 0.1, top: 0.80),
            Self.line("week 47", x: 0.6, top: 0.795, width: 0.2),
            Self.line("Quote HR-558120", top: 0.90),
            Self.line("报价单", x: 0.1, top: 0.50, width: 0.2),
            Self.line("   ", top: 0.40),
            Self.line("Delivery to the lobby", top: 0.73),
        ]
        let read = TextRecognizer.text(of: observations, ink: nil)
        #expect(read.text == "Quote HR-558120\nTwelve brass lamps week 47\nDelivery to the lobby\n\n报价单")
        #expect(read.hiddenRuns == 0)
    }

    /// The long lines of a scan turned a little have boxes that reach into the lines next to
    /// them. They stay apart and in order, and the parts of one line, which start higher the
    /// further right they lie, stay together.
    @Test func theLinesOfATurnedScanStayApartAndInOrder() {
        // The page rises 1 for every 15 across, so a part 0.6 wide rises 0.04, twice the 0.02
        // between two lines.
        let slope: CGFloat = 1.0 / 15
        func turned(_ text: String, line: CGFloat, from left: CGFloat, width: CGFloat) -> TextRecognizer.Observation {
            let start = CGPoint(x: left, y: line + left * slope)
            let end = CGPoint(x: left + width, y: start.y + width * slope)
            return TextRecognizer.Observation(
                text: text, box: CGRect(x: left, y: start.y - 0.008, width: width, height: end.y - start.y + 0.016), start: start, end: end,
                height: 0.016)
        }
        let observations = [
            turned("third line", line: 0.86, from: 0.09, width: 0.6),
            turned("HR-558120", line: 0.88, from: 0.75, width: 0.15),
            turned("first line", line: 0.90, from: 0.09, width: 0.6),
            turned("second line", line: 0.88, from: 0.09, width: 0.6),
            turned("最后一行的", line: 0.84, from: 0.09, width: 0.3),
            turned("后半", line: 0.84, from: 0.45, width: 0.3),
        ]
        #expect(TextRecognizer.text(of: observations, ink: nil).text == "first line\nsecond line HR-558120\nthird line\n最后一行的 后半")
    }

    /// Text that leaves no ink on the image Vision read is dropped, a run of such lines
    /// counts once, and punctuation alone is kept, since it hides nothing.
    @Test func textWithoutInkIsDroppedAndCounted() throws {
        let image = try RecognitionTestFiles.image(["Quote HR-558120"], width: 800, height: 400, points: 40)
        let pixels = try RecognitionTestFiles.grayPixels(of: image)
        let ink = InkMap(pixels: pixels, width: 800, height: 400, bytesPerPixel: 1)
        // The drawn line lies near the top. The rest is white, as text lighter than 1/16
        // gray would leave it.
        let drawn = try #require(StandIn.box(of: image))
        let observations = [
            TextRecognizer.Observation(text: "Quote HR-558120", box: drawn),
            TextRecognizer.Observation(text: "Pay the new account", box: CGRect(x: 0.04, y: 0.5, width: 0.6, height: 0.1)),
            TextRecognizer.Observation(text: "today", box: CGRect(x: 0.04, y: 0.38, width: 0.3, height: 0.1)),
            TextRecognizer.Observation(text: "•", box: CGRect(x: 0.04, y: 0.2, width: 0.05, height: 0.1)),
        ]
        let read = TextRecognizer.text(of: observations, ink: ink)
        #expect(read.text == "Quote HR-558120\n\n•")
        #expect(read.hiddenRuns == 1)
    }

    /// A long line of a scan turned a little has a box much taller than its text. Its ink is
    /// judged by the height of its text, so the line is kept, where the box's height would
    /// make it read as hidden.
    @Test func aTurnedLineIsJudgedByTheHeightOfItsText() throws {
        let text = "Quote for the lobby lamps in week 47 HR-558120 and the brass pendants for the hall"
        // Six empty lines first, so the line, turned 5 degrees about the middle, stays inside.
        let image = try RecognitionTestFiles.image(Array(repeating: "", count: 6) + [text], width: 2_400, height: 800, points: 40, degrees: 5)
        let ink = InkMap(pixels: try RecognitionTestFiles.grayPixels(of: image), width: 2_400, height: 800, bytesPerPixel: 1)
        let box = try #require(StandIn.box(of: image))
        // The text is about 48 pixels high, and the line rises far more than that.
        let height = 48.0 / 800
        #expect(box.height > 3 * height)
        let turned = TextRecognizer.Observation(
            text: text, box: box, start: CGPoint(x: box.minX, y: box.minY + height / 2), end: CGPoint(x: box.maxX, y: box.maxY - height / 2),
            height: height)
        #expect(TextRecognizer.text(of: [turned], ink: ink) == (text, 0))
        #expect(TextRecognizer.text(of: [TextRecognizer.Observation(text: text, box: box)], ink: ink).hiddenRuns == 1)
    }

    /// An image of one frame is one page without a number. Its text is normalized as any
    /// file's, and marked as recognized.
    @Test func anImageIsOnePageOfNormalizedText() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn([.ink("⼯程 Lobby\r\nlamps")])
        let image = try RecognitionTestFiles.image(["Lobby lamps"])
        let job = try folder.job("sign.png", try RecognitionTestFiles.data([image], type: .png))
        let result = try await recognizer(standIn).recognize(job, mayGoOn: { true }).get()
        #expect(result.pages == [FileTextResult.Page(number: nil, text: "工程 Lobby\nlamps", isRecognized: true)])
        #expect(result.tried == [0: .text])
        #expect(result.isDone && !result.fileChanged)
        #expect(standIn.sizes == [CGSize(width: 1_200, height: 300)])
    }

    /// A page that gives fewer than two letters or digits is blank, such as a shape that
    /// Vision reads as one character.
    @Test func aStrayCharacterIsNoText() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn([.ink("门")])
        let job = try folder.job("shapes.png", try RecognitionTestFiles.data([try RecognitionTestFiles.image(["L"])], type: .png))
        let result = try await recognizer(standIn).recognize(job, mayGoOn: { true }).get()
        #expect(result.tried == [0: .blank])
        #expect(result.pages.isEmpty)
    }

    // MARK: Images

    /// The pixels are read from the image's properties before anything is decoded, so an
    /// image too large never reaches the decoder or Vision.
    @Test func tooManyPixelsAreRefusedBeforeAnyDecode() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn()
        let job = try folder.job("poster.png", try RecognitionTestFiles.data([try RecognitionTestFiles.image(["Poster"])], type: .png))
        var limits = TextRecognizer.Limits()
        limits.pixels = 1_200 * 300 - 1
        #expect(await recognizer(standIn, limits: limits).recognize(job, mayGoOn: { true }) == .failure(.tooLarge))
        #expect(standIn.sizes.isEmpty)
    }

    /// An image must be of the type its name says, so a PNG named .jpg never reaches a
    /// decoder of another format. Bytes that are no image at all are unreadable too.
    @Test func anImageOfAnotherTypeThanItsNameIsUnreadable() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn()
        let png = try RecognitionTestFiles.data([try RecognitionTestFiles.image(["Lamps"])], type: .png)
        #expect(await recognizer(standIn).recognize(try folder.job("photo.jpg", png), mayGoOn: { true }) == .failure(.unreadable))
        #expect(await recognizer(standIn).recognize(try folder.job("photo.png", Data("photo".utf8)), mayGoOn: { true }) == .failure(.unreadable))
        let jpeg = try RecognitionTestFiles.data([try RecognitionTestFiles.image(["Lamps"])], type: .jpeg)
        #expect(try await recognizer(standIn).recognize(try folder.job("photo.JPEG", jpeg), mayGoOn: { true }).get().tried == [0: .blank])
        #expect(standIn.sizes.count == 1)
    }

    /// A TIFF with several pages gives each page with its number, at most the job's pages
    /// at once, and the next job goes on after the pages done.
    @Test func eachPageOfATIFFIsReadInJobs() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pages = try (1...3).map { try RecognitionTestFiles.image(["Page \($0) of the plan"]) }
        let data = try RecognitionTestFiles.data(pages, type: .tiff)
        let standIn = StandIn(otherwise: .ink("Plan"))
        let first = try await recognizer(standIn).recognize(try folder.job("plan.tif", data, pages: 2), mayGoOn: { true }).get()
        #expect(first.tried == [1: .text, 2: .text])
        #expect(first.pages.map(\.number) == [1, 2])
        #expect(!first.isDone)
        let second = try await recognizer(standIn).recognize(try folder.job("plan.tif", data, done: [1, 2], pages: 2), mayGoOn: { true }).get()
        #expect(second.tried == [3: .text])
        #expect(second.isDone)
    }

    /// A link is never followed, and a file whose size or date is not the job's changed
    /// after the sweep, so nothing of it is read.
    @Test func theCheckedReadFollowsNoLinkAndSeesAChangedFile() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn()
        let png = try RecognitionTestFiles.data([try RecognitionTestFiles.image(["Lamps"])], type: .png)
        var job = try folder.job("sign.png", png)
        let link = folder.url.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: job.file)
        var linked = job
        linked.file = link
        #expect(await recognizer(standIn).recognize(linked, mayGoOn: { true }) == .failure(.symbolicLink))
        job.size += 1
        #expect(try await recognizer(standIn).recognize(job, mayGoOn: { true }).get() == RecognitionResult(fileChanged: true))
        job.size -= 1
        job.modified -= 1
        #expect(try await recognizer(standIn).recognize(job, mayGoOn: { true }).get() == RecognitionResult(fileChanged: true))
        #expect(standIn.sizes.isEmpty)
    }

    // MARK: PDFs

    /// Only the pages whose text layer holds fewer than 20 letters or digits are read: a
    /// scan, a page with a short label, and a page with no text at all. A page with a text
    /// layer is not, and its text is never read again.
    @Test func onlyThePagesWithoutATextLayerAreRead() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let scan = try RecognitionTestFiles.image(["Scanned quote HR-558120"], width: 850, height: 1_100, points: 30)
        let data = try RecognitionTestFiles.pdf([
            .text(["The print run is 500 calendars, delivered in week 47."]),
            .scan(scan),
            .text(["Page 3"]),
            .mark,
        ])
        let standIn = StandIn([.ink("Scanned quote HR-558120"), .ink("Page 3"), .lines([])])
        let result = try await recognizer(standIn).recognize(try folder.job("quote.pdf", data), mayGoOn: { true }).get()
        #expect(result.tried == [2: .text, 3: .text, 4: .blank])
        #expect(result.pages == [
            FileTextResult.Page(number: 2, text: "Scanned quote HR-558120", isRecognized: true),
            FileTextResult.Page(number: 3, text: "Page 3", isRecognized: true),
        ])
        #expect(result.isDone)
        // US letter at 300 dots per inch.
        #expect(standIn.sizes == Array(repeating: CGSize(width: 2_550, height: 3_300), count: 3))
    }

    /// A page is drawn as a reader shows it: turned as the page says, and no larger than
    /// `longestSide`.
    @Test func aTurnedPageIsDrawnUpright() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn()
        var limits = TextRecognizer.Limits()
        limits.dotsPerInch = 72
        _ = try await recognizer(standIn, limits: limits).recognize(try folder.job("turned.pdf", try RecognitionTestFiles.pdf([.mark], rotation: 90)), mayGoOn: { true }).get()
        let image = try #require(standIn.images.first)
        #expect(image.width == 792 && image.height == 612)
        // The mark at the top left of the page lies at the top right once turned clockwise.
        let pixels = try RecognitionTestFiles.grayPixels(of: image)
        #expect(pixels[50 * 792 + 792 - 50] < 64)
        #expect(pixels[50 * 792 + 50] > 192)

        limits.dotsPerInch = 300
        limits.longestSide = 1_000
        _ = try await recognizer(standIn, limits: limits).recognize(try folder.job("small.pdf", try RecognitionTestFiles.pdf([.mark])), mayGoOn: { true }).get()
        #expect(standIn.sizes.last.map { max($0.width, $0.height) } == 1_000)
    }

    /// A file gives at most `pagesPerFile` pages, the first ones, and is done after them.
    @Test func aFileGivesAtMostItsPages() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn()
        var limits = TextRecognizer.Limits()
        limits.pagesPerFile = 2
        let data = try RecognitionTestFiles.pdf([.mark, .mark, .mark])
        let result = try await recognizer(standIn, limits: limits).recognize(try folder.job("scan.pdf", data), mayGoOn: { true }).get()
        #expect(result.tried == [1: .blank, 2: .blank])
        #expect(result.isDone)
    }

    // MARK: Stopping

    /// The job asks before every page whether it may go on, and stops when told no. The
    /// pages it did not reach are left for the next job.
    @Test func theJobAsksBeforeEveryPage() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn()
        let asked = Mutex(0)
        let result = try await recognizer(standIn).recognize(try folder.job("scan.pdf", try RecognitionTestFiles.pdf([.mark, .mark, .mark])), mayGoOn: {
            asked.withLock { asked in
                asked += 1
                return asked < 3
            }
        }).get()
        #expect(asked.withLock { $0 } == 3)
        #expect(result.tried == [1: .blank, 2: .blank])
        #expect(!result.isDone)
    }

    /// Cancelling the job's task reaches the read under way, which is then not counted as
    /// tried, so the page is read again later.
    @Test func aCancelReachesTheReadUnderWay() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn([.lines([]), .hold])
        let job = try folder.job("scan.pdf", try RecognitionTestFiles.pdf([.mark, .mark, .mark]))
        let recognizer = recognizer(standIn)
        let task = Task { await recognizer.recognize(job, mayGoOn: { true }) }
        await standIn.hold.untilBegun()
        task.cancel()
        let result = try await task.value.get()
        #expect(standIn.hold.cancelled == 1)
        #expect(result.tried == [1: .blank])
        #expect(!result.isDone)
    }

    /// A page that runs out of time counts as timed out and the job goes on. A job whose
    /// every page ran out of time ends the file as too slow.
    @Test func aPageThatRunsOutOfTimeTimesOut() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let mixed = StandIn([.ink("Lamps"), .hold])
        let scan = try RecognitionTestFiles.image(["Lamps"], width: 850, height: 1_100, points: 60)
        let job = try folder.job("scan.pdf", try RecognitionTestFiles.pdf([.scan(scan), .mark]))
        // The clock runs out only once a read holds, which only the second page does.
        let result = try await recognizer(mixed, clock: PageClock(mixed, runsOut: true)).recognize(job, mayGoOn: { true }).get()
        #expect(result.tried == [1: .text, 2: .timedOut])
        #expect(result.isDone)
        #expect(mixed.hold.cancelled == 1)

        let slow = StandIn([.hold])
        let image = try folder.job("sign.png", try RecognitionTestFiles.data([try RecognitionTestFiles.image(["Lamps"])], type: .png))
        #expect(await recognizer(slow, clock: PageClock(slow, runsOut: true)).recognize(image, mayGoOn: { true }) == .failure(.tooSlow))
    }

    /// A page's time runs from the start of its drawing, which cannot be stopped, so a page
    /// whose drawing takes all of it is never read and times out. Here every drawing takes
    /// longer than the page's time of a nanosecond.
    @Test func theDrawingCountsTowardThePageTime() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn()
        var limits = TextRecognizer.Limits()
        limits.pageTime = .nanoseconds(1)
        let image = try folder.job("sign.png", try RecognitionTestFiles.data([try RecognitionTestFiles.image(["Lamps"])], type: .png))
        #expect(await recognizer(standIn, limits: limits).recognize(image, mayGoOn: { true }) == .failure(.tooSlow))
        #expect(standIn.sizes.isEmpty)
    }

    /// A page Vision cannot read fails, and so does one that Vision reports cancelled when
    /// nobody cancelled the job, so such a page is not tried again and again.
    @Test func aPageVisionCannotReadFails() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let standIn = StandIn([.failed, .cancelledElsewhere])
        let result = try await recognizer(standIn).recognize(try folder.job("scan.pdf", try RecognitionTestFiles.pdf([.mark, .mark])), mayGoOn: { true }).get()
        #expect(result.tried == [1: .failed, 2: .failed])
        #expect(result.isDone)
    }

    /// The languages Vision is asked for: Chinese, simplified and traditional, and English,
    /// in that order, since the first one decides the model, see TextRecognizer.
    @Test func recognitionReadsChineseAndEnglish() {
        #expect(TextRecognizer.languages == ["zh-Hans", "zh-Hant", "en-US"])
        #expect(TextRecognizer.imageTypes(ofExtension: "JPG") == ["public.jpeg"])
        #expect(TextRecognizer.imageTypes(ofExtension: "dwg").isEmpty)
    }
}
