import Foundation
import Testing
@testable import Orra

/// Orra's read only ZIP reader, on archives the tests make, among them archives that break
/// its rules, and on thousands of broken xlsx and pptx files from fixed seeds.
struct ZipArchiveTests {
    private static let parts = [("xl/a.xml", "<a>one</a>"), ("xl/sub/b.xml", "<b>两个部分</b>")]

    @Test(arguments: [false, true])
    func readsStoredAndDeflatedParts(stored: Bool) throws {
        let archive = try ZipArchive(try OfficeTestFiles.zip(texts: Self.parts, stored: stored))
        #expect(archive.entries.map(\.name) == ["xl/a.xml", "xl/sub/b.xml"])
        #expect(archive.entries.map(\.method) == (stored ? [0, 0] : [8, 8]))
        #expect(archive.unpackedSize == Int64("<a>one</a>".utf8.count + "<b>两个部分</b>".utf8.count))
        var budget: Int64 = 1_000
        #expect(try archive.data(of: "xl/sub/b.xml", budget: &budget).get() == Data("<b>两个部分</b>".utf8))
        #expect(budget == 1_000 - Int64("<b>两个部分</b>".utf8.count))
        // Office compares part names without case, and a relationship may start with a slash.
        #expect(try archive.data(of: "/XL/A.xml", budget: &budget).get() == Data("<a>one</a>".utf8))
        #expect(archive.contains("xl/A.XML"))
        #expect(!archive.contains("xl/c.xml"))
        #expect(archive.data(of: "xl/c.xml", budget: &budget) == .failure(.unreadable))
    }

    /// The size of a part comes from the budget before it is unpacked.
    @Test func aPartOverTheBudgetIsTooLarge() throws {
        let archive = try ZipArchive(try OfficeTestFiles.zip(texts: Self.parts))
        var budget: Int64 = 5
        #expect(archive.data(of: "xl/a.xml", budget: &budget) == .failure(.tooLarge))
        #expect(budget == 5)
        budget = 10
        #expect(try archive.data(of: "xl/a.xml", budget: &budget).get().count == 10)
        #expect(budget == 0)
    }

    /// A part never unpacks to more or less than its entry says, and its CRC-32 must match.
    @Test func aPartMustUnpackToWhatItsEntrySays() throws {
        let data = try OfficeTestFiles.zip(texts: [("big.xml", String(repeating: "<row>lamps</row>", count: 200))])
        let entry = try #require(OfficeTestFiles.lastRange(of: [0x50, 0x4B, 0x01, 0x02], in: data))
        let size = Int(data[entry.lowerBound + 24]) | Int(data[entry.lowerBound + 25]) << 8
        for declared in [size - 1, size + 1, 1] {
            var changed = data
            changed.replaceSubrange((entry.lowerBound + 24)..<(entry.lowerBound + 28), with: withUnsafeBytes(of: UInt32(declared).littleEndian) { Data($0) })
            var budget: Int64 = 1_000_000
            #expect(try ZipArchive(changed).data(of: "big.xml", budget: &budget) == .failure(.unreadable), "\(declared)")
        }
        var otherCRC = data
        otherCRC[entry.lowerBound + 16] ^= 0xFF
        var budget: Int64 = 1_000_000
        #expect(try ZipArchive(otherCRC).data(of: "big.xml", budget: &budget) == .failure(.unreadable))
        #expect(try ZipArchive(data).data(of: "big.xml", budget: &budget).get().count == size)
    }

    /// Archives the reader cannot measure as their directory says, or that could show two
    /// readers two different parts, are unreadable.
    @Test func refusesArchivesThatBreakItsRules() throws {
        let data = try OfficeTestFiles.zip(texts: Self.parts)
        let end = try #require(OfficeTestFiles.lastRange(of: [0x50, 0x4B, 0x05, 0x06], in: data))
        let first = try #require(data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        var cases: [(String, Data)] = []
        var encrypted = data
        encrypted[first + 8] |= 1
        cases.append(("encrypted", encrypted))
        var zip64 = data
        zip64.replaceSubrange((first + 20)..<(first + 24), with: [0xFF, 0xFF, 0xFF, 0xFF])
        cases.append(("ZIP64 size", zip64))
        var otherMethod = data
        otherMethod[first + 10] = 12
        cases.append(("bzip2", otherMethod))
        var twoEnds = data
        let record = data[end.lowerBound...]
        twoEnds.replaceSubrange((end.lowerBound + 20)..<(end.lowerBound + 22), with: [UInt8(record.count), 0])
        twoEnds.append(record)
        cases.append(("two end records", twoEnds))
        var twoDisks = data
        twoDisks[end.lowerBound + 4] = 1
        cases.append(("two disks", twoDisks))
        var outside = data
        outside.replaceSubrange((end.lowerBound + 16)..<(end.lowerBound + 20), with: [0xFF, 0xFF, 0xFF, 0x00])
        cases.append(("directory outside", outside))
        cases.append(("cut", data.prefix(data.count - 30)))
        cases.append(("empty", Data()))
        for (name, broken) in cases {
            #expect(throws: FileSkipReason.unreadable, "\(name)") { try ZipArchive(broken) }
        }
    }

    @Test func refusesMoreThanItsEntries() throws {
        let many = (0...ZipArchive.maximumEntries).map { ("part\($0).xml", "") }
        #expect(throws: FileSkipReason.unreadable) { try ZipArchive(try OfficeTestFiles.zip(texts: many, stored: true)) }
        let most = Array(many.dropLast())
        #expect(try ZipArchive(try OfficeTestFiles.zip(texts: most, stored: true)).entries.count == ZipArchive.maximumEntries)
    }

    /// A part whose local header names another part, or lies past the directory, or whose
    /// name is there twice, is unreadable, while the others stay readable.
    @Test func checksEachPartsLocalHeader() throws {
        let data = try OfficeTestFiles.zip(texts: Self.parts)
        var renamed = data
        renamed[30] = UInt8(ascii: "y")
        var budget: Int64 = 1_000
        #expect(try ZipArchive(renamed).data(of: "xl/a.xml", budget: &budget) == .failure(.unreadable))
        #expect(try ZipArchive(renamed).data(of: "xl/sub/b.xml", budget: &budget).get().count > 0)

        let first = try #require(data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        var pastDirectory = data
        pastDirectory.replaceSubrange((first + 42)..<(first + 46), with: withUnsafeBytes(of: UInt32(first).littleEndian) { Data($0) })
        #expect(try ZipArchive(pastDirectory).data(of: "xl/a.xml", budget: &budget) == .failure(.unreadable))

        let twice = try ZipArchive(try OfficeTestFiles.zip(texts: Self.parts + [("XL/A.xml", "<a>two</a>")]))
        #expect(twice.data(of: "xl/a.xml", budget: &budget) == .failure(.unreadable))
    }

    // MARK: Broken files

    /// Random changes to a valid xlsx and pptx, from fixed seeds: bytes of the archive
    /// changed, cut, repeated or dropped, and bytes of a part's XML changed before it is
    /// packed again with a valid CRC, so the XML reader meets them too. Each read ends,
    /// without a crash, in a result or a reason, within a second.
    @Test(arguments: [FileTextExtractor.Format.xlsx, .pptx])
    func brokenOfficeFilesNeverCrashTheReader(format: FileTextExtractor.Format) async throws {
        let valid = format == .xlsx ? try Self.workbook() : try Self.deck()
        let archive = try ZipArchive(valid)
        var budget = Int64.max
        let parts = try archive.entries.map { entry in (entry.name, try archive.data(of: entry.name, budget: &budget).get()) }
        var random = TalkKeyDetectorTests.SplitMix(state: format == .xlsx ? 0x5EED_0001 : 0x5EED_0002)
        func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(random.next() % UInt64(range.count))
        }
        let snippets = ["<!DOCTYPE x>", "<", "&", "\u{0}", "]]>", "<row>", "</c>", "r:id=\"rId9\"", "../../", "t=\"s\"", "<v>99999</v>",
                        "<a:t>", "show=\"0\"", "sz=\"1\"", String(repeating: "<x>", count: 300)]
        var slowest: Duration = .zero
        var outcomes: [String: Int] = [:]
        for round in 0..<2_000 {
            var bytes: Data
            if round.isMultiple(of: 2) {
                bytes = valid
                for _ in 0..<int(1...8) {
                    let index = int(0...(bytes.count - 1))
                    switch int(0...4) {
                    case 0: bytes[index] = UInt8(truncatingIfNeeded: random.next())
                    case 1: bytes = bytes.prefix(index) + bytes.suffix(from: min(bytes.count, index + int(1...64)))
                    case 2: bytes.insert(contentsOf: bytes[index..<min(bytes.count, index + int(1...64))], at: index)
                    case 3: bytes = bytes.prefix(max(22, index))
                    default: bytes[index] ^= 1 << UInt8(int(0...7))
                    }
                    if bytes.isEmpty { break }
                }
            } else {
                var changed = parts
                let part = int(0...(changed.count - 1))
                var text = [UInt8](changed[part].1)
                for _ in 0..<int(1...6) {
                    let index = int(0...max(0, text.count - 1))
                    switch int(0...2) {
                    case 0: text.insert(contentsOf: Array(snippets[int(0...(snippets.count - 1))].utf8), at: min(index, text.count))
                    case 1: if !text.isEmpty { text.removeSubrange(index..<min(text.count, index + int(1...40))) }
                    default: if !text.isEmpty { text[index] = UInt8(truncatingIfNeeded: random.next()) }
                    }
                }
                changed[part].1 = Data(text)
                bytes = try OfficeTestFiles.zip(changed)
            }
            let started = ContinuousClock.now
            let result = await FileTextExtractor().text(of: bytes, format: format, modified: .now)
            slowest = max(slowest, started.duration(to: .now))
            switch result {
            case .success: outcomes["read", default: 0] += 1
            case .failure(let reason): outcomes[reason.rawValue, default: 0] += 1
            }
        }
        #expect(slowest < .seconds(1), "\(slowest)")
        #expect((outcomes["read"] ?? 0) > 0)
        #expect((outcomes[FileSkipReason.unreadable.rawValue] ?? 0) > 0)
    }

    private static func workbook() throws -> Data {
        try OfficeTestFiles.xlsx(
            [
                OfficeTestFiles.Sheet("Lamps", rows: [["Item", "Qty", "Price"], ["Lobby lamps", "12", "86000"], ["灯具", "12", "TRUE"]]),
                OfficeTestFiles.Sheet("Hidden", state: "hidden", rows: [["Secret"]]),
            ],
            sharedStrings: ["Lobby", "灯具清单"])
    }

    private static func deck() throws -> Data {
        try OfficeTestFiles.pptx([
            OfficeTestFiles.Slide(
                OfficeTestFiles.shape(["Lobby lamps"], placeholder: "title") + OfficeTestFiles.shape(["12 lamps", "灯具清单"])
                    + OfficeTestFiles.table([["Item", "Qty"], ["Lamps", "12"]]),
                notes: "Ask about delivery."),
            OfficeTestFiles.Slide(OfficeTestFiles.shape(["Hidden slide"]), isShown: false),
        ])
    }
}
