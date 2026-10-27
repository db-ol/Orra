import AppKit
import CoreText
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Orra

/// The first sweep of a large synthetic project folder with every kind of file, and how its
/// sheets, slides and file names are found. Only when asked for, never in CI, and in a
/// Release build, with TEST_RUNNER_ORRA_INDEX_BENCH set to a folder:
///
///     TEST_RUNNER_ORRA_INDEX_BENCH=<folder> xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES -testLanguage en -testRegion US test-without-building -only-testing:OrraTests/FolderIndexMeasurementTests
///
/// The first run makes the folder there from a fixed seed, with files the tests build, and
/// never reads a real file. At TEST_RUNNER_ORRA_INDEX_BENCH_SCALE 1, the default, its folder
/// 060 holds 1,500 PDFs of 1 to 30 pages with text drawn with Core Text, in Chinese, English
/// or both, 300 docx and 200 md and txt files, 1,000 files known by name only (dwg, dxf, zip,
/// mp4 and skp of random bytes) and 2,000 PNG images, 600 of them with text. Its folder new
/// holds 200 xlsx of 1 to 3 sheets with 10 to 5,000 rows, 150 pptx of 5 to 40 slides with
/// notes, and 100 csv files. Folders go up to 6 deep, with Chinese and English names, and no
/// two files share a name. Each xlsx and pptx holds a code and a Chinese term no other file
/// holds, on a random sheet, slide or note.
///
/// It sweeps 060 and new together and checks:
/// - Every term planted in a sheet or a slide finds its file among the first 6 hits of
///   ChunkSearch.
/// - Every file's name without its extension finds that file first with FileNameSearch, in
///   Chinese and in English.
/// - With the sweeps of 060 that FolderSweepMeasurementTests timed on a build that reads only
///   the 0.6.0 formats, labeled main, and on this one, labeled branch, in turns, the fastest
///   here takes at most 1.15 times as long as the fastest there, which the names of the files
///   Orra 0.6.0 skipped may cost.
/// - With store-main, the store the last of those runs on main kept, a copy opened here moves
///   to step 6, and its sweep reads no file again and leaves no row without its name entry.
///
/// So the order is: this test, which makes the folder, then FolderSweepMeasurementTests on
/// main and here in turns, then this test again. It writes index-bench.json there, with
/// counts, times and bytes, and up to 20 of the made up terms and names it did not find.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_INDEX_BENCH"] != nil))
@MainActor
struct FolderIndexMeasurementTests {
    typealias Sweep = FolderSweepMeasurementTests

    /// A term planted in a sheet or a slide, and the name of its file.
    struct Planted: Codable {
        var term: String
        var file: String
    }

    /// What the folder holds that the checks need.
    struct Truth: Codable {
        var planted: [Planted] = []
        /// The name of every file, with its extension.
        var names: [String] = []
        /// The files of each extension.
        var files: [String: Int] = [:]
    }

    struct Report: Codable {
        var scale: Double
        var files: [String: Int]
        var sweepAll: Sweep.Result
        /// Rows of the sweep of every kind known by name only, and images that wait for text
        /// recognition.
        var nameOnly = 0
        var waiting = 0
        /// The sweeps of 060 that FolderSweepMeasurementTests timed on main and here.
        var sweepMain: Sweep.Result?
        var sweepBranch: Sweep.Result?
        var timesMain: Double?
        var plantedFound = 0
        var planted = 0
        var plantedMissed: [String] = []
        var namesFirst = 0
        var names = 0
        var namesMissed: [String] = []
        var searchSeconds = 0.0
        var update: Update?
    }

    /// A store of main's sweep of 060, opened and swept here as an update would.
    struct Update: Codable {
        var stepSeconds: Double
        var sweepSeconds: Double
        var rows: Int
        var read: Int
        /// Reads of files in the formats Orra 0.6.0 reads, which it read already.
        var readAgain: Int
        var rowsWithoutName: Int
    }

    /// The paths of the files a sweep read.
    final class Reads: Sendable {
        let paths = Mutex<[String]>([])
    }

    @Test func sweepsEveryKindAndFindsSheetsSlidesAndNames() async throws {
        let root = Sweep.folder(scale: Sweep.scale)
        let truth = try Self.makeFolder(at: root)
        let old = root.appending(path: "060", directoryHint: .isDirectory)
        let new = root.appending(path: "new", directoryHint: .isDirectory)

        var found = 0, first = 0, nameOnly = 0, waiting = 0
        var missed: [String] = [], namesMissed: [String] = []
        var searchSeconds = 0.0
        let sweepAll = try await Sweep.sweep([old, new], label: "branch, every kind", rounds: 1) { database in
            let started = ContinuousClock.now
            let chunks = ChunkSearch(database: database)
            for item in truth.planted {
                let hits = try await chunks.search(item.term, in: [Sweep.project])
                if hits.prefix(6).contains(where: { $0.file.lastPathComponent == item.file }) {
                    found += 1
                } else {
                    missed.append(item.term)
                }
            }
            let names = FileNameSearch(database: database)
            for name in truth.names {
                let hits = try await names.search((name as NSString).deletingPathExtension, in: [Sweep.project], limit: 3)
                if hits.first?.url.lastPathComponent == name {
                    first += 1
                } else {
                    namesMissed.append(name + " → " + hits.map(\.url.lastPathComponent).joined(separator: ", "))
                }
            }
            searchSeconds = started.duration(to: .now) / .seconds(1)
            nameOnly = Int(try await database.run(
                "SELECT count(*) FROM index_files WHERE skip IS NOT NULL AND skip != 'waitsForRecognition'").first?.first?.integer ?? -1)
            waiting = Int(try await database.run("SELECT count(*) FROM index_files WHERE skip = 'waitsForRecognition'").first?.first?.integer ?? -1)
        }
        var report = Report(
            scale: Sweep.scale, files: truth.files, sweepAll: sweepAll, nameOnly: nameOnly, waiting: waiting,
            plantedFound: found, planted: truth.planted.count, plantedMissed: Array(missed.prefix(20)), namesFirst: first,
            names: truth.names.count, namesMissed: Array(namesMissed.prefix(20)), searchSeconds: searchSeconds)

        if let main = Sweep.result("main"), let branch = Sweep.result("branch") {
            report.sweepMain = main
            report.sweepBranch = branch
            report.timesMain = branch.seconds / main.seconds
            #expect(branch.seconds <= 1.15 * main.seconds)
            #expect(branch.indexed == main.indexed && branch.chunks == main.chunks)
        }
        let mainStore = Sweep.bench.appending(path: "store-main", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: mainStore.path) {
            report.update = try await Self.update(from: mainStore, folder: old)
        }
        try Sweep.write(report, to: "index-bench.json")

        #expect(found == truth.planted.count, "\(missed.prefix(5))")
        #expect(first == truth.names.count, "\(namesMissed.prefix(5))")
        if let update = report.update {
            #expect(update.readAgain == 0)
            #expect(update.rowsWithoutName == 0)
        }
    }

    /// Opens a copy of a store main wrote, which moves it to step 6, and sweeps it, noting
    /// what it reads and whether every row has its name entry.
    static func update(from store: URL, folder: URL) async throws -> Update {
        let copy = Sweep.temporaryStore()
        try FileManager.default.copyItem(at: store, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        var started = ContinuousClock.now
        let database = try await ProjectsDatabase.open(in: ProjectsStorage(root: copy))
        let stepSeconds = started.duration(to: .now) / .seconds(1)
        let reads = Reads()
        let index = FolderIndex(
            database: database, isDictating: { false },
            readText: { url in
                reads.paths.withLock { $0.append(url.path) }
                return await FileTextExtractor().text(of: url)
            },
            watch: { _, _, _ in {} })
        started = ContinuousClock.now
        index.start(project: Sweep.project, folders: [folder])
        await index.waitUntilIdle()
        let sweepSeconds = started.duration(to: .now) / .seconds(1)
        func count(_ sql: String) async throws -> Int {
            Int(try await database.run(sql).first?.first?.integer ?? -1)
        }
        let rows = try await count("SELECT count(*) FROM index_files")
        let withoutName = try await count(
            "SELECT count(*) FROM index_files WHERE folder IS NULL OR id NOT IN (SELECT rowid FROM index_file_names)")
        index.stopAll()
        await database.close()
        let read = reads.paths.withLock { $0 }
        let formats060: Set<String> = ["pdf", "docx", "doc", "rtf", "odt", "md", "txt"]
        return Update(
            stepSeconds: stepSeconds, sweepSeconds: sweepSeconds, rows: rows, read: read.count,
            readAgain: read.count { formats060.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }, rowsWithoutName: withoutName)
    }

    // MARK: The folder

    /// The folder at `root`, made from a fixed seed the first time, with its truth file
    /// beside it, which is written last, so a folder whose truth file is there is whole.
    static func makeFolder(at root: URL) throws -> Truth {
        let truthFile = root.deletingLastPathComponent().appending(path: root.lastPathComponent + "-truth.json")
        if let data = try? Data(contentsOf: truthFile) {
            return try JSONDecoder().decode(Truth.self, from: data)
        }
        try? FileManager.default.removeItem(at: root)
        var maker = Maker(root: root, scale: Sweep.scale)
        try maker.make()
        try JSONEncoder().encode(maker.truth).write(to: truthFile)
        return maker.truth
    }

    enum MakerError: Error {
        case cannotDraw
    }

    /// Makes the files of the folder from a fixed seed.
    struct Maker {
        enum Language: CaseIterable {
            case english, chinese, mixed
        }

        let root: URL
        let scale: Double
        var truth = Truth()
        private var random = TalkKeyDetectorTests.SplitMix(state: 0x0D06_1DE7)
        private var serial = 0
        private var codes = Set<Int>()
        private var oldFolders: [String] = []
        private var newFolders: [String] = []
        private let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        private let large = CTFontCreateWithName("Helvetica" as CFString, 28, nil)

        init(root: URL, scale: Double) {
            self.root = root
            self.scale = scale
        }

        mutating func make() throws {
            oldFolders = makeFolders(under: "060")
            newFolders = makeFolders(under: "new")
            for _ in 0..<count(1_500) {
                try pdf()
            }
            for _ in 0..<count(300) {
                try docx()
            }
            for _ in 0..<count(200) {
                try plainText()
            }
            for _ in 0..<count(1_000) {
                try nameOnly()
            }
            for index in 0..<count(2_000) {
                try image(withText: index % 10 < 3)
            }
            for _ in 0..<count(200) {
                try workbook()
            }
            for _ in 0..<count(150) {
                try deck()
            }
            for _ in 0..<count(100) {
                try csv()
            }
        }

        // MARK: Kinds

        private mutating func pdf() throws {
            let language = pick(Language.allCases)
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                throw MakerError.cannotDraw
            }
            for _ in 0..<(1 + below(30)) {
                context.beginPDFPage(nil)
                for row in 0..<22 {
                    let limit = language == .english ? 85 : language == .chinese ? 45 : 60
                    context.textPosition = CGPoint(x: 54, y: 740 - CGFloat(row) * 32)
                    CTLineDraw(drawn(line(language, limit: limit), font: font), context)
                }
                context.endPDFPage()
            }
            context.closePDF()
            try write(data as Data, extension: "pdf", in: oldFolders)
        }

        private mutating func docx() throws {
            let language = pick(Language.allCases)
            var body = ""
            for _ in 0..<(10 + below(50)) {
                body += OfficeTestFiles.paragraph(OfficeTestFiles.escaped(paragraph(language)))
            }
            try write(try OfficeTestFiles.docx(body: body), extension: "docx", in: oldFolders)
        }

        private mutating func plainText() throws {
            let language = pick(Language.allCases)
            let isMarkdown = chance(0.5)
            var text = isMarkdown ? "# " + line(language, limit: 40) + "\n\n" : ""
            var paragraphs: [String] = []
            for _ in 0..<(5 + below(40)) {
                paragraphs.append(paragraph(language))
            }
            text += paragraphs.joined(separator: "\n\n")
            try write(Data(text.utf8), extension: isMarkdown ? "md" : "txt", in: oldFolders)
        }

        private mutating func nameOnly() throws {
            let size = 1_024 + below(64 * 1_024)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(size + 8)
            while bytes.count < size {
                withUnsafeBytes(of: random.next()) { bytes += $0 }
            }
            try write(Data(bytes.prefix(size)), extension: pick(["dwg", "dxf", "zip", "mp4", "skp"]), in: oldFolders)
        }

        private mutating func image(withText: Bool) throws {
            let width = 640, height = 400
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw MakerError.cannotDraw }
            let shade = 0.85 + Double(below(15)) / 100
            context.setFillColor(CGColor(red: shade, green: shade, blue: shade - 0.05, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if withText {
                let language = pick(Language.allCases)
                for row in 0..<3 {
                    context.textPosition = CGPoint(x: 30, y: 300 - CGFloat(row) * 60)
                    CTLineDraw(drawn(line(language, limit: language == .english ? 30 : 15), font: large), context)
                }
            }
            let data = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
            else { throw MakerError.cannotDraw }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw MakerError.cannotDraw }
            try write(data as Data, extension: "png", in: oldFolders)
        }

        private mutating func workbook() throws {
            let (code, term) = plantedTerms(prefix: "XL")
            let sheetCount = 1 + below(3)
            let plantedSheet = below(sheetCount)
            var sheets: [OfficeTestFiles.Sheet] = []
            for index in 0..<sheetCount {
                // Most sheets are short, a few run to 5,000 rows.
                let rowCount = 10 + Int(pow(unit(), 3) * 4_990)
                let plantedRow = 1 + below(rowCount)
                var rows = [["Item", "Qty", "Price", "Note"]]
                for row in 1...rowCount {
                    var cells = [item(), String(1 + below(500)), price(), chance(0.3) ? line(.mixed, limit: 40) : ""]
                    if index == plantedSheet, row == plantedRow {
                        cells[0] = code
                        cells[3] = term
                    }
                    rows.append(cells)
                }
                sheets.append(OfficeTestFiles.Sheet(chance(0.5) ? "Sheet\(index + 1)" : pick(Self.chineseWords) + "\(index + 1)", rows: rows))
            }
            let file = try write(try OfficeTestFiles.xlsx(sheets), extension: "xlsx", in: newFolders)
            truth.planted += [Planted(term: code, file: file), Planted(term: term, file: file)]
        }

        private mutating func deck() throws {
            let (code, term) = plantedTerms(prefix: "PP")
            let slideCount = 5 + below(36)
            let plantedSlide = below(slideCount)
            let inNotes = chance(0.5)
            var slides: [OfficeTestFiles.Slide] = []
            for index in 0..<slideCount {
                let language = pick(Language.allCases)
                var body: [String] = []
                for _ in 0..<(2 + below(4)) {
                    body.append(line(language, limit: 70))
                }
                var notes = chance(0.5) ? paragraph(language) : nil
                if index == plantedSlide {
                    if inNotes {
                        notes = (notes.map { $0 + " " } ?? "") + code + " " + term
                    } else {
                        body.append(code + " " + term)
                    }
                }
                let shapes = OfficeTestFiles.shape([line(language, limit: 40)], placeholder: "title", id: 2) + OfficeTestFiles.shape(body, id: 3)
                slides.append(OfficeTestFiles.Slide(shapes, notes: notes))
            }
            let file = try write(try OfficeTestFiles.pptx(slides), extension: "pptx", in: newFolders)
            truth.planted += [Planted(term: code, file: file), Planted(term: term, file: file)]
        }

        private mutating func csv() throws {
            var rows = ["Item,Qty,Price"]
            for _ in 0..<(10 + below(500)) {
                rows.append("\(item()),\(1 + below(500)),\(price())")
            }
            try write(Data(rows.joined(separator: "\n").utf8), extension: "csv", in: newFolders)
        }

        // MARK: Names and text

        /// Writes a file under a name no other file has, in one of `folders`, and gives
        /// the name.
        @discardableResult
        private mutating func write(_ data: Data, extension fileExtension: String, in folders: [String]) throws -> String {
            serial += 1
            let number = String(format: "%04d", serial)
            var words: [String] = []
            let isChinese = chance(0.5)
            for _ in 0..<(2 + below(2)) {
                words.append(isChinese ? pick(Self.chineseWords) : pick(Self.englishWords))
            }
            let name = (isChinese ? words.joined() + number : (words + [number]).joined(separator: pick(["-", "_", " "]))) + "." + fileExtension
            let folder = root.appending(path: pick(folders), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: name))
            truth.names.append(name)
            truth.files[fileExtension, default: 0] += 1
            return name
        }

        /// Folders up to 6 deep under `top`, with Chinese and English names.
        private mutating func makeFolders(under top: String) -> [String] {
            var folders = [top]
            for _ in 0..<40 {
                let parent = pick(folders)
                guard parent.split(separator: "/").count <= 6 else { continue }
                let name = chance(0.5) ? pick(Self.englishFolders) : pick(Self.chineseFolders)
                if !folders.contains(parent + "/" + name) {
                    folders.append(parent + "/" + name)
                }
            }
            return folders
        }

        /// A code and a Chinese term no other file holds.
        private mutating func plantedTerms(prefix: String) -> (code: String, term: String) {
            var number = 100_000 + below(900_000)
            while !codes.insert(number).inserted {
                number = 100_000 + below(900_000)
            }
            return ("\(prefix)-\(number)", pick(Self.chineseWords) + pick(Self.chineseWords) + "型号\(number)")
        }

        private mutating func item() -> String {
            pick(Self.englishWords) + " " + pick(Self.englishWords)
        }

        private mutating func price() -> String {
            "\(1 + below(9_999)).\(String(format: "%02d", below(100)))"
        }

        /// A line in English, Chinese or both, under `limit` characters.
        private mutating func line(_ language: Language, limit: Int) -> String {
            var text = ""
            while true {
                let isChinese = language == .chinese || (language == .mixed && chance(0.5))
                let word = chance(0.06) ? String(100 + below(9_900)) : isChinese ? pick(Self.chineseWords) : pick(Self.englishWords)
                let joinsWithoutSpace = text.last.map { !$0.isASCII } == true && word.first.map { !$0.isASCII } == true
                let next = text.isEmpty ? word : text + (joinsWithoutSpace ? "" : " ") + word
                guard next.count < limit else { break }
                text = next
            }
            return text + (language == .english ? "." : "。")
        }

        private mutating func paragraph(_ language: Language) -> String {
            var sentences: [String] = []
            for _ in 0..<(1 + below(5)) {
                sentences.append(line(language, limit: 120))
            }
            return sentences.joined(separator: language == .english ? " " : "")
        }

        private func drawn(_ text: String, font: CTFont) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        }

        // MARK: Chance

        private func count(_ full: Int) -> Int {
            max(1, Int((Double(full) * scale).rounded()))
        }

        private mutating func below(_ bound: Int) -> Int {
            Int(random.next() % UInt64(bound))
        }

        private mutating func unit() -> Double {
            Double(random.next() >> 11) / Double(1 << 53)
        }

        private mutating func chance(_ probability: Double) -> Bool {
            unit() < probability
        }

        private mutating func pick<Item>(_ items: [Item]) -> Item {
            items[below(items.count)]
        }

        static let englishWords = [
            "lobby", "lamp", "brass", "quote", "invoice", "delivery", "schedule", "harbor", "hotel", "ceiling", "panel", "fixture",
            "drawing", "revision", "contract", "budget", "supplier", "install", "wiring", "marble", "floor", "glass", "door", "frame",
            "paint", "sample", "approval", "site", "visit", "meeting", "minutes", "payment", "deposit", "balance", "warranty", "order",
            "carpet", "chair", "table", "reception", "elevator", "signage", "acoustic", "lighting", "socket", "switch", "cable", "steel",
            "timber", "oak", "walnut", "fabric", "curtain", "shade", "mirror", "basin", "tile", "grout", "sealant", "permit",
            "inspection", "fire", "exit", "alarm", "sprinkler", "duct", "vent", "cooling", "heating", "pump", "valve", "pipe", "plan",
            "section", "detail", "elevation", "phase", "stage", "week", "month", "deadline", "change", "request", "variation", "cost",
            "estimate", "tender", "bid", "award", "crew", "team", "architect", "engineer", "client", "owner", "manager", "designer",
            "vendor", "factory", "shipping", "crate", "pallet", "storage", "warehouse", "customs", "freight", "port",
        ]

        static let chineseWords = [
            "大堂", "灯具", "黄铜", "报价", "发票", "交货", "进度", "港湾", "酒店", "吊顶", "面板", "灯饰", "图纸", "修订", "合同", "预算",
            "供应商", "安装", "布线", "大理石", "地面", "玻璃", "门框", "油漆", "样品", "审批", "现场", "巡查", "会议", "纪要", "付款", "定金",
            "尾款", "保修", "订单", "地毯", "座椅", "前台", "电梯", "标识", "声学", "照明", "插座", "开关", "电缆", "钢材", "木材", "橡木",
            "胡桃木", "面料", "窗帘", "镜子", "台盆", "瓷砖", "填缝", "密封胶", "许可", "验收", "消防", "出口", "报警", "喷淋", "风管", "通风",
            "制冷", "供暖", "水泵", "阀门", "管道", "平面", "剖面", "节点", "立面", "一期", "二期", "本周", "本月", "截止", "变更", "申请",
            "签证", "成本", "估算", "招标", "投标", "中标", "班组", "团队", "建筑师", "工程师", "业主", "经理", "设计师", "厂家", "工厂", "物流",
            "木箱", "托盘", "仓储", "仓库", "清关", "货运", "码头",
        ]

        static let englishFolders = [
            "Harbor Hotel", "Lobby", "Drawings", "Quotes", "Contracts", "Site Photos", "Phase 2", "2026", "Archive", "Suppliers",
            "Lighting", "Meetings", "Old", "Revisions", "Approvals",
        ]

        static let chineseFolders = ["大堂改造", "图纸", "报价单", "合同", "现场照片", "二期", "供应商", "灯具", "会议纪要", "归档", "修订版", "审批", "付款", "样品"]
    }
}
