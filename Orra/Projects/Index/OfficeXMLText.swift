import Foundation

/// Reads the text of an Excel workbook (xlsx and xlsm) and of a PowerPoint deck (pptx and
/// ppsx) from the parts of its ZIP archive, see ZipArchive. Nothing in them is run, followed
/// or unpacked besides the parts named below: no macro, no formula, no link, no picture.
///
/// - Every part goes through Foundation's XMLParser. A part that declares a document type or
///   an entity, which no Office part does, is unreadable. So is one in another encoding than
///   UTF-8, which the Office formats do not allow besides UTF-16: one with a NUL byte, as
///   UTF-16 text has, one that does not start with "<" after a byte order mark and white
///   space, and one whose XML declaration names another encoding, such as UTF-7. So that
///   check sees every part's bytes as they are. XMLParser never resolves an external entity
///   by default, and nothing here changes that.
/// - A relationship is followed only inside the package. A target with a scheme, one marked
///   External and one that climbs above the package's root are skipped.
/// - The parts read count against `FileTextExtractor.Limits.officeBytes`, and the text the
///   file gives, hidden text aside, against `officeCharacters`. A sheet or slide that no
///   longer fits is left out with the ones after it, and so are the rows and the text past
///   the characters, and the result says it was cut. Hidden sheets are read last, so they
///   never take the room of a sheet that shows. Every 1,000 elements the parse looks at the
///   clock and at the task, and so does the layout of a sheet every 1,000 rows, and it stops
///   past `officeTime` as too slow, or as cancelled.
/// - Hidden text is dropped and counted, see FileTextResult.hiddenRuns, by the rules of
///   `workbook(_:limits:now:)` and `presentation(_:limits:now:)`.
/// - A sheet's rows and a slide's tables are lines that start and end with " | ", so no row
///   reads as a heading to TextChunker, whatever its first cell holds.
nonisolated enum OfficeXMLText {
    /// The pages that hold text, the hidden runs dropped, and whether text was left out.
    typealias Read = (pages: [FileTextResult.Page], hiddenRuns: Int, isCut: Bool)

    /// The text of a workbook: a page for each sheet, in the order of the workbook, with no
    /// page number and with the sheet's name.
    ///
    /// - A sheet starts with a heading line, "# " and the sheet's name, followed by ": " and
    ///   its header row when the first row with two or more cells among its first 10 rows
    ///   holds only text. TextChunker reads it as the heading of the sheet's chunks. Then a
    ///   line for each row, its cells joined by " | ", aligned on the sheet's first column.
    /// - Cells give shared and inline strings without their phonetic runs, the cached value
    ///   of a formula and never the formula, TRUE or FALSE, and numbers as written, with at
    ///   most the 15 significant digits Excel shows. Where the cell's format says so, a date
    ///   shows as 2026-10-20, a time of day as 18:00, a length of time as 36:00 and a
    ///   percentage as 15%. Errors give nothing.
    /// - Hidden sheets, hidden rows and columns, columns narrower than half a character,
    ///   values whose section of the cell's format is empty (every value under ;;; and every
    ///   number under ;;), fonts under 3 points and white fonts on no fill or a white fill are
    ///   dropped, each sheet, row, column or run of cells counted once, and so are the runs
    ///   of a rich text cell whose own font is that small or white. A zero its format shows
    ///   as nothing is an empty cell. Text in drawings, charts and comments is not read.
    /// - The sheets that show are read first, and only their text counts against the
    ///   characters. A hidden sheet is read after them, only far enough to tell whether it
    ///   holds text. One that no longer fits or has no time left counts as hidden too, since
    ///   it may hold some.
    static func workbook(
        _ archive: ZipArchive, limits: FileTextExtractor.Limits, now: @escaping @Sendable () -> ContinuousClock.Instant
    ) -> Result<Read, FileSkipReason> {
        var package = Package(archive: archive, limits: limits, now: now)
        do {
            let main = try package.mainPart()
            let workbook = WorkbookReader()
            try package.parse(main, with: workbook)
            let relationships = try package.relationships(of: main)
            var styles = CellStyles(uses1904: workbook.uses1904)
            if let part = relationships.values.first(where: { $0.type.hasSuffix("/styles") })?.target {
                let reader = StylesReader()
                try package.parse(part, with: reader)
                styles.read(reader)
            }
            var strings: [[TextRun]] = []
            if let part = relationships.values.first(where: { $0.type.hasSuffix("/sharedStrings") })?.target {
                let reader = SharedStringsReader()
                try package.parse(part, with: reader)
                strings = reader.strings
            }
            func part(of sheet: WorkbookReader.Sheet) -> String? {
                guard let relationship = relationships[sheet.relationship], relationship.type.hasSuffix("/worksheet"),
                      archive.contains(relationship.target) else { return nil }
                return relationship.target
            }
            var read: Read = ([], 0, false)
            var characters = limits.officeCharacters
            for sheet in workbook.sheets where !sheet.isHidden {
                guard let part = part(of: sheet) else { continue }
                guard characters > 0, !read.isCut else {
                    read.isCut = true
                    break
                }
                let reader = SheetReader(strings: strings, styles: styles, characters: characters)
                do {
                    try package.parse(part, with: reader)
                } catch .tooLarge {
                    read.isCut = true
                    break
                }
                let laidOut = try reader.laidOut(name: sheet.name)
                read.hiddenRuns += laidOut.hiddenRuns
                read.isCut = read.isCut || laidOut.isCut
                if let page = laidOut.page {
                    characters -= page.text.count
                    read.pages.append(page)
                }
            }
            let hidden = workbook.sheets.filter(\.isHidden).compactMap(part(of:))
            for (offset, part) in hidden.enumerated() {
                let reader = SheetReader(strings: strings, styles: styles, findsText: true)
                do {
                    try package.parse(part, with: reader)
                    read.hiddenRuns += reader.holdsText ? 1 : 0
                } catch .tooLarge {
                    read.hiddenRuns += 1
                } catch .tooSlow {
                    read.hiddenRuns += hidden.count - offset
                    break
                }
            }
            return .success(read)
        } catch {
            return .failure(error)
        }
    }

    /// The text of a deck: a page for each slide, numbered from 1 in the order of the deck,
    /// so a hidden slide keeps its number as PowerPoint shows it.
    ///
    /// - A slide gives the text of its shapes in the order of the shape tree, a line for
    ///   each paragraph and a blank line between shapes, and a table's rows as lines of
    ///   cells joined by " | ". The title goes first as "# " and its text, so it heads the
    ///   slide's chunks. The speaker notes follow under a line "Notes:", which heads theirs.
    /// - Hidden slides, hidden shapes, shapes wholly outside the slide, text under 3 points,
    ///   text nearly transparent (under 10% opaque) and text colored like its own shape's
    ///   fill are dropped and counted, whether the run says so itself or takes it from its
    ///   paragraph or from its text body's list style. Text colored like the slide's
    ///   background is not caught, since the background may come from the layout, the
    ///   master or a picture, and neither is a size or color the layout or master gives.
    static func presentation(
        _ archive: ZipArchive, limits: FileTextExtractor.Limits, now: @escaping @Sendable () -> ContinuousClock.Instant
    ) -> Result<Read, FileSkipReason> {
        var package = Package(archive: archive, limits: limits, now: now)
        do {
            let main = try package.mainPart()
            let presentation = PresentationReader()
            try package.parse(main, with: presentation)
            let relationships = try package.relationships(of: main)
            var read: Read = ([], 0, false)
            var characters = limits.officeCharacters
            for (index, id) in presentation.slides.enumerated() {
                guard let relationship = relationships[id], relationship.type.hasSuffix("/slide"),
                      package.archive.contains(relationship.target) else { continue }
                guard characters > 0 else {
                    read.isCut = true
                    break
                }
                let slide = SlideReader(size: presentation.size)
                var notes: SlideReader?
                do {
                    try package.parse(relationship.target, with: slide)
                    if let part = try package.relationships(of: relationship.target).values
                        .first(where: { $0.type.hasSuffix("/notesSlide") })?.target, package.archive.contains(part) {
                        let reader = SlideReader(size: nil)
                        try package.parse(part, with: reader)
                        notes = reader
                    }
                } catch .tooLarge {
                    read.isCut = true
                    break
                }
                var text = slide.text
                let notesText = notes?.notes ?? ""
                if !notesText.isEmpty {
                    text += (text.isEmpty ? "" : "\n\n") + "Notes:\n" + notesText
                }
                let hiddenRuns = slide.hiddenRuns + (notes?.hiddenRuns ?? 0)
                guard slide.isShown else {
                    read.hiddenRuns += text.isEmpty ? hiddenRuns : 1
                    continue
                }
                read.hiddenRuns += hiddenRuns
                let kept = String(text.prefix(characters))
                characters -= kept.count
                if kept.count < text.count {
                    read.isCut = true
                }
                if !kept.isEmpty {
                    read.pages.append(FileTextResult.Page(number: index + 1, text: kept, isStandAlone: true))
                }
            }
            return .success(read)
        } catch {
            return .failure(error)
        }
    }

    // MARK: The package

    /// A relationship's type and the part it names.
    fileprivate nonisolated struct Relationship {
        var type: String
        var target: String
    }

    /// The parts of one file and the budget and clock they are read under.
    private nonisolated struct Package {
        let archive: ZipArchive
        var budget: Int64
        let started: ContinuousClock.Instant
        let time: Duration
        let now: @Sendable () -> ContinuousClock.Instant

        init(archive: ZipArchive, limits: FileTextExtractor.Limits, now: @escaping @Sendable () -> ContinuousClock.Instant) {
            self.archive = archive
            budget = min(limits.fileBytes, limits.officeBytes)
            started = now()
            time = limits.officeTime
            self.now = now
        }

        /// The main part, as the package's own relationships name it.
        mutating func mainPart() throws(FileSkipReason) -> String {
            guard let main = try relationships(of: "").values.first(where: { $0.type.hasSuffix("/officeDocument") })?.target,
                  archive.contains(main) else { throw .unreadable }
            return main
        }

        /// Parses a part with `reader`, after the checks of the type's doc.
        mutating func parse(_ part: String, with reader: PartReader) throws(FileSkipReason) {
            let data: Data
            switch archive.data(of: part, budget: &budget) {
            case .success(let found): data = found
            case .failure(let reason): throw reason
            }
            guard OfficeXMLText.isPlainXML(data) else { throw .unreadable }
            let started = started, time = time, now = now
            reader.check = {
                if Task.isCancelled { return .cancelled }
                return started.duration(to: now()) > time ? .tooSlow : nil
            }
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = reader
            let parsed = parser.parse()
            if let reason = reader.stop { throw reason }
            guard parsed || reader.isDone else { throw .unreadable }
            if let reason = reader.check() { throw reason }
        }

        /// The relationships of a part by their ids, from its .rels part, empty when it has
        /// none. "" is the package itself. Only targets inside the package are kept.
        mutating func relationships(of part: String) throws(FileSkipReason) -> [String: Relationship] {
            let folder = (part as NSString).deletingLastPathComponent
            let name = (part as NSString).lastPathComponent
            let rels = (folder.isEmpty ? "" : folder + "/") + "_rels/" + name + ".rels"
            guard archive.contains(rels) else { return [:] }
            let reader = RelationshipsReader()
            try parse(rels, with: reader)
            var relationships: [String: Relationship] = [:]
            for found in reader.relationships where !found.isExternal {
                if let target = OfficeXMLText.part(found.target, from: part) {
                    relationships[found.id] = Relationship(type: found.type, target: target)
                }
            }
            return relationships
        }
    }

    /// Whether the bytes of a part are XML that the parse may read, see the type's doc: UTF-8
    /// with no NUL byte, no document type and no entity, starting with "<" after a byte order
    /// mark and white space, with an XML declaration, if any, that names UTF-8.
    static func isPlainXML(_ data: Data) -> Bool {
        guard !data.contains(0), data.range(of: Data("<!DOCTYPE".utf8)) == nil, data.range(of: Data("<!ENTITY".utf8)) == nil else {
            return false
        }
        // The XML declaration is short, so the start of the part holds it whole.
        var start = data.prefix(512)
        if start.starts(with: [0xEF, 0xBB, 0xBF]) {
            start = start.dropFirst(3)
        }
        let head = Data(start.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
        guard head.first == UInt8(ascii: "<") else { return false }
        guard head.starts(with: Data("<?xml".utf8)) else { return true }
        guard let end = head.range(of: Data("?>".utf8)) else { return false }
        let declaration = String(decoding: head[..<end.lowerBound], as: UTF8.self)
        guard let name = declaration.range(of: "encoding") else { return true }
        let rest = declaration[name.upperBound...].drop(while: \.isWhitespace)
        guard rest.first == "=" else { return false }
        let value = rest.dropFirst().drop(while: \.isWhitespace)
        guard let quote = value.first, quote == "\"" || quote == "'" else { return false }
        return ["utf-8", "utf8"].contains(value.dropFirst().prefix { $0 != quote }.lowercased())
    }

    /// The part a relationship of `source` names, nil when the target leaves the package:
    /// one with a scheme, such as http: or file:, or one that climbs above its root.
    static func part(_ target: String, from source: String) -> String? {
        if let colon = target.firstIndex(of: ":"), !target[..<colon].contains("/") { return nil }
        var parts: [Substring] = target.hasPrefix("/") ? [] : Array(source.split(separator: "/").dropLast())
        for piece in target.split(separator: "/") {
            switch piece {
            case ".":
                continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default:
                parts.append(piece)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    // MARK: Helpers

    /// Whether an attribute of the Office type ST_OnOff is on.
    fileprivate static func isOn(_ value: String?) -> Bool {
        value == "1" || value == "true" || value == "on"
    }

    /// The id of a relationship an element names, such as r:id, whatever its prefix.
    fileprivate static func relationship(_ attributes: [String: String]) -> String? {
        attributes.first { $0.key.hasSuffix(":id") && $0.key != "xml:id" }?.value
    }

    /// A cell's or a run's text on one line.
    fileprivate static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// A row of a sheet or a table as a line, its cells joined by " | ".
    fileprivate static func row(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |"
    }
}

// MARK: - Colors

/// A color of a font, a fill or a run, with the parts that tell whether it is white or like
/// another.
private nonisolated struct OfficeColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    /// A color written as six hex digits, or eight with the alpha first, as Excel writes it.
    init?(hex: String?) {
        guard let hex, hex.count == 6 || hex.count == 8, let value = UInt32(hex.suffix(6), radix: 16) else { return nil }
        red = Double(value >> 16 & 0xFF) / 255
        green = Double(value >> 8 & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    /// Within 0.1 of white in every channel.
    var isWhite: Bool {
        min(red, green, blue) >= 0.9
    }

    /// The largest difference of one channel, from 0 to 1.
    func distance(to other: OfficeColor) -> Double {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
    }

    /// Whether a color of a workbook's styles is white: an RGB value near white, theme
    /// color 0, which Excel draws as the light background, unless a tint darkens it, or one
    /// of the white colors of the old palette.
    static func isWhite(_ attributes: [String: String]) -> Bool {
        if let color = OfficeColor(hex: attributes["rgb"]) { return color.isWhite }
        if attributes["theme"] == "0" { return (Double(attributes["tint"] ?? "") ?? 0) > -0.1 }
        return attributes["indexed"] == "1" || attributes["indexed"] == "9"
    }
}

// MARK: - The readers

/// The events of one part's parse, which a reader for that kind of part takes. Elements
/// inside mc:Fallback are left out, since the mc:Choice before it holds the same content.
private nonisolated class PartReader: NSObject, XMLParserDelegate {
    /// Why the read must stop, asked every 1,000 elements, see Package.
    var check: () -> FileSkipReason? = { nil }
    /// Why the parse stopped early, nil while it runs or once it ended.
    private(set) var stop: FileSkipReason?
    /// Whether the reader has all it reads, so a parse it ended early still counts.
    private(set) var isDone = false
    /// The names of the open elements, the innermost last.
    private(set) var path: [String] = []
    private var elements = 0
    private var fallback = 0

    func start(_ name: String, _ attributes: [String: String]) {}
    func end(_ name: String) {}
    func characters(_ text: String) {}

    /// Ends the parse at the next element.
    func finish() {
        isDone = true
    }

    /// The name of the element `levels` above the innermost one, "" above the root.
    func parent(_ levels: Int = 1) -> String {
        path.count > levels ? path[path.count - 1 - levels] : ""
    }

    final func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        elements += 1
        if isDone {
            parser.abortParsing()
            return
        }
        if elements.isMultiple(of: 1_000), let reason = check() {
            stop = reason
            parser.abortParsing()
            return
        }
        if fallback > 0 || elementName == "Fallback" {
            fallback += 1
            return
        }
        path.append(elementName)
        start(elementName, attributes)
    }

    final func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if fallback > 0 {
            fallback -= 1
            return
        }
        end(elementName)
        if !path.isEmpty {
            path.removeLast()
        }
    }

    final func parser(_ parser: XMLParser, foundCharacters string: String) {
        if fallback == 0 {
            characters(string)
        }
    }

    final func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if fallback == 0 {
            characters(String(decoding: data, as: UTF8.self))
        }
    }
}

/// The relationships of a part: _rels/.rels or one next to it.
private nonisolated final class RelationshipsReader: PartReader {
    struct Found {
        var id: String
        var type: String
        var target: String
        var isExternal: Bool
    }

    private(set) var relationships: [Found] = []

    override func start(_ name: String, _ attributes: [String: String]) {
        guard name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
        relationships.append(Found(id: id, type: attributes["Type"] ?? "", target: target, isExternal: attributes["TargetMode"] == "External"))
    }
}

// MARK: Workbooks

/// The sheets of a workbook in its order, and its date system.
private nonisolated final class WorkbookReader: PartReader {
    struct Sheet {
        var name: String
        var isHidden: Bool
        var relationship: String
    }

    private(set) var sheets: [Sheet] = []
    /// Whether dates count from 1904, as on early Macs, rather than from 1900.
    private(set) var uses1904 = false

    override func start(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "workbookPr":
            uses1904 = OfficeXMLText.isOn(attributes["date1904"])
        case "sheet" where parent() == "sheets":
            guard let id = OfficeXMLText.relationship(attributes) else { return }
            let state = attributes["state"]
            sheets.append(Sheet(name: attributes["name"] ?? "", isHidden: state == "hidden" || state == "veryHidden", relationship: id))
        default:
            break
        }
    }
}

/// A run of a shared or inline string, with what its own font says of it.
private nonisolated struct TextRun {
    var text = ""
    /// Its own font size in points, nil when it takes the cell's.
    var size: Double?
    /// Whether its own font is white.
    var isWhite = false
}

/// Collects the runs of a shared or inline string: its text in <t>, or in <r> runs with
/// their <rPr>, without the phonetic runs in <rPh>.
private nonisolated struct RunCollector {
    private(set) var runs: [TextRun] = []
    private var run: TextRun?
    private var phonetic = 0
    private var inText = false

    mutating func start(_ name: String, _ attributes: [String: String], parent: String) {
        switch name {
        case "r":
            run = TextRun()
        case "rPh":
            phonetic += 1
        case "sz" where parent == "rPr":
            run?.size = Double(attributes["val"] ?? "")
        case "color" where parent == "rPr":
            run?.isWhite = OfficeColor.isWhite(attributes)
        case "t" where phonetic == 0:
            inText = true
            if run == nil {
                runs.append(TextRun())
            }
        default:
            break
        }
    }

    mutating func end(_ name: String) {
        switch name {
        case "r":
            if let run {
                runs.append(run)
            }
            run = nil
        case "rPh":
            phonetic -= 1
        case "t":
            inText = false
        default:
            break
        }
    }

    mutating func characters(_ text: String) {
        guard inText else { return }
        if run != nil {
            run?.text += text
        } else if !runs.isEmpty {
            runs[runs.count - 1].text += text
        }
    }
}

/// The shared strings of a workbook, as runs.
private nonisolated final class SharedStringsReader: PartReader {
    private(set) var strings: [[TextRun]] = []
    private var collector: RunCollector?

    override func start(_ name: String, _ attributes: [String: String]) {
        if name == "si" {
            collector = RunCollector()
        } else {
            collector?.start(name, attributes, parent: parent())
        }
    }

    override func end(_ name: String) {
        if name == "si" {
            strings.append(collector?.runs ?? [])
            collector = nil
        } else {
            collector?.end(name)
        }
    }

    override func characters(_ text: String) {
        collector?.characters(text)
    }
}

/// The number formats, fonts, fills and cell formats of a workbook.
private nonisolated final class StylesReader: PartReader {
    struct Font {
        var size: Double?
        var isWhite = false
    }

    struct Fill {
        /// No fill, or a solid white one, on which white text cannot be seen.
        var isClear = true
        /// A solid fill, the only kind whose foreground color fills the cell.
        var isSolid = false
    }

    struct Format {
        var numberFormat: Int
        var font: Int
        var fill: Int
    }

    private(set) var numberFormats: [Int: String] = [:]
    private(set) var fonts: [Font] = []
    private(set) var fills: [Fill] = []
    private(set) var formats: [Format] = []

    override func start(_ name: String, _ attributes: [String: String]) {
        switch (name, parent()) {
        case ("numFmt", "numFmts"):
            if let id = Int(attributes["numFmtId"] ?? ""), let code = attributes["formatCode"] {
                numberFormats[id] = code
            }
        case ("font", "fonts"):
            fonts.append(Font())
        case ("sz", "font") where parent(2) == "fonts" && !fonts.isEmpty:
            fonts[fonts.count - 1].size = Double(attributes["val"] ?? "")
        case ("color", "font") where parent(2) == "fonts" && !fonts.isEmpty:
            fonts[fonts.count - 1].isWhite = OfficeColor.isWhite(attributes)
        case ("fill", "fills"):
            fills.append(Fill())
        case ("patternFill", "fill") where parent(2) == "fills" && !fills.isEmpty:
            let pattern = attributes["patternType"] ?? "none"
            fills[fills.count - 1].isClear = pattern == "none" || pattern == "solid"
            fills[fills.count - 1].isSolid = pattern == "solid"
        case ("gradientFill", "fill") where parent(2) == "fills" && !fills.isEmpty:
            fills[fills.count - 1].isClear = false
        case ("fgColor", "patternFill") where parent(2) == "fill" && parent(3) == "fills" && !fills.isEmpty:
            // A solid fill is clear only when it is white. Without a pattern Excel draws no
            // fill, whatever its color says.
            if fills[fills.count - 1].isSolid {
                fills[fills.count - 1].isClear = OfficeColor.isWhite(attributes)
            }
        case ("xf", "cellXfs"):
            formats.append(Format(
                numberFormat: Int(attributes["numFmtId"] ?? "") ?? 0, font: Int(attributes["fontId"] ?? "") ?? 0,
                fill: Int(attributes["fillId"] ?? "") ?? 0))
        default:
            break
        }
    }
}

/// How a workbook's cells look, from its styles: whether a cell's text is hidden, and how
/// its number shows.
private nonisolated struct CellStyles {
    enum Number: Equatable {
        case plain
        /// A date, with its time of day where the format has one.
        case date(hasTime: Bool, hasSeconds: Bool)
        /// A time of day without its date, as h:mm shows a date and time.
        case time(hasSeconds: Bool)
        /// A length of time that may run past a day, as [h]:mm shows it, counted in its
        /// largest unit.
        case elapsed(Unit, hasMinutes: Bool, hasSeconds: Bool)
        /// A built in format that is a date in Japanese and Korean files and a time of day in
        /// Chinese ones, such as 34: a date for a number of whole days, else a time.
        case dateOrTime(hasSeconds: Bool)
        case percent(decimals: Int)
    }

    enum Unit: Equatable {
        case hours, minutes, seconds
    }

    /// The values a number format shows as nothing, since their section of the format is
    /// empty: every number under ;; and every value under ;;;.
    struct Empty: OptionSet {
        let rawValue: Int
        static let positive = Empty(rawValue: 1)
        static let negative = Empty(rawValue: 2)
        static let zero = Empty(rawValue: 4)
        static let text = Empty(rawValue: 8)
        static let all: Empty = [.positive, .negative, .zero, .text]
    }

    var uses1904: Bool
    private var formats: [StylesReader.Format] = []
    private var numberFormats: [Int: String] = [:]
    private var fonts: [StylesReader.Font] = []
    private var fills: [StylesReader.Fill] = []

    init(uses1904: Bool) {
        self.uses1904 = uses1904
    }

    mutating func read(_ reader: StylesReader) {
        formats = reader.formats
        numberFormats = reader.numberFormats
        fonts = reader.fonts
        fills = reader.fills
    }

    /// Whether whatever a cell of that style holds cannot be seen: a format whose every
    /// section is empty (;;;), a font under 3 points, or a white font on no fill or a white
    /// fill.
    func isHidden(style: Int) -> Bool {
        guard formats.indices.contains(style) else { return false }
        let format = formats[style]
        if empty(style: style) == .all { return true }
        guard fonts.indices.contains(format.font) else { return false }
        let font = fonts[format.font]
        if let size = font.size, size < 3 { return true }
        return font.isWhite && isClearFill(style: style)
    }

    /// Whether a number shows as nothing in a cell of that style, as every number does
    /// under ;;.
    func hides(_ value: Double, style: Int) -> Bool {
        empty(style: style).contains(value > 0 ? .positive : value < 0 ? .negative : .zero)
    }

    /// Whether text shows as nothing in a cell of that style: its format's fourth section,
    /// the one for text, is empty.
    func hidesText(style: Int) -> Bool {
        empty(style: style).contains(.text)
    }

    private func empty(style: Int) -> Empty {
        guard formats.indices.contains(style), let code = numberFormats[formats[style].numberFormat] else { return [] }
        return Self.empty(code: code)
    }

    /// The values a custom format shows as nothing: one section is for every number, two
    /// are for numbers from 0 and below 0, and three or four for numbers above, below and
    /// at 0, then text. A section of white space only shows nothing. A format with a
    /// condition, such as [>100], or with one empty section, which Excel reads as General,
    /// hides nothing.
    static func empty(code: String) -> Empty {
        let sections = sections(of: code)
        guard sections.count > 1, !sections.contains(where: { $0.contains("[<") || $0.contains("[>") || $0.contains("[=") }) else {
            return []
        }
        let isEmpty = sections.map { $0.allSatisfy(\.isWhitespace) }
        var empty: Empty = []
        if sections.count == 2 {
            if isEmpty[0] { empty.formUnion([.positive, .zero]) }
            if isEmpty[1] { empty.insert(.negative) }
            return empty
        }
        if isEmpty[0] { empty.insert(.positive) }
        if isEmpty[1] { empty.insert(.negative) }
        if isEmpty[2] { empty.insert(.zero) }
        if sections.count > 3, isEmpty[3] { empty.insert(.text) }
        return empty
    }

    /// The sections of a format, apart at each semicolon outside quotes and brackets that no
    /// backslash, underscore or asterisk escapes.
    static func sections(of code: String) -> [Substring] {
        var sections: [Substring] = []
        var start = code.startIndex
        var inQuotes = false, inBrackets = false, skipsNext = false
        for index in code.indices {
            let character = code[index]
            if skipsNext {
                skipsNext = false
            } else if inQuotes {
                inQuotes = character != "\""
            } else if inBrackets {
                inBrackets = character != "]"
            } else {
                switch character {
                case "\"": inQuotes = true
                case "[": inBrackets = true
                case "\\", "_", "*": skipsNext = true
                case ";":
                    sections.append(code[start..<index])
                    start = code.index(after: index)
                default: break
                }
            }
        }
        sections.append(code[start...])
        return sections
    }

    /// Whether white text cannot be seen in a cell of that style: no fill, or a white one.
    func isClearFill(style: Int) -> Bool {
        guard formats.indices.contains(style) else { return true }
        let fill = formats[style].fill
        return fills.indices.contains(fill) ? fills[fill].isClear : true
    }

    /// How a number of a cell of that style shows.
    func number(style: Int) -> Number {
        guard formats.indices.contains(style) else { return .plain }
        let id = formats[style].numberFormat
        if let code = numberFormats[id] { return Self.number(code: code) }
        switch id {
        case 9: return .percent(decimals: 0)
        case 10: return .percent(decimals: 2)
        case 14...17, 27...31, 36, 50, 51, 54, 57, 58: return .date(hasTime: false, hasSeconds: false)
        case 22: return .date(hasTime: true, hasSeconds: false)
        case 18, 20, 32: return .time(hasSeconds: false)
        case 19, 21, 33, 45, 47: return .time(hasSeconds: true)
        case 46: return .elapsed(.hours, hasMinutes: true, hasSeconds: true)
        case 34, 52, 55: return .dateOrTime(hasSeconds: false)
        case 35, 53, 56: return .dateOrTime(hasSeconds: true)
        default: return .plain
        }
    }

    /// How a custom format shows a number, from its first section, outside quotes and
    /// other brackets, such as a color: a length of time where it starts with [h], [m] or
    /// [s], a date where it holds d or y, or an m without an h or s beside it, which is a
    /// month, a time of day where it holds h or s, and a percentage where it holds %.
    static func number(code: String) -> Number {
        let section = Array(sections(of: code)[0])
        var date = false, hours = false, minutes = false, seconds = false, percent = false, afterPoint = false
        var elapsed: Unit?
        var decimals = 0
        var index = 0
        func skip(through end: Character) -> String {
            var skipped = ""
            while index < section.count, section[index] != end {
                skipped.append(section[index])
                index += 1
            }
            index += 1
            return skipped
        }
        func follows(_ text: String) -> Bool {
            let rest = section[(index - 1)...].prefix(text.count)
            return String(rest).lowercased() == text
        }
        while index < section.count {
            let character = section[index]
            index += 1
            switch character.lowercased() {
            case "\"":
                _ = skip(through: "\"")
            case "[":
                let inside = skip(through: "]").lowercased()
                if elapsed == nil, let unit = inside.first, inside.allSatisfy({ $0 == unit }) {
                    elapsed = unit == "h" ? .hours : unit == "m" ? .minutes : unit == "s" ? .seconds : nil
                }
            case "\\", "_", "*":
                index += 1
            case "a" where follows("am/pm"):
                // AM/PM and A/P say nothing of the date, and their m is no minute.
                index += 4
            case "a" where follows("a/p"):
                index += 2
            case "d", "y": date = true
            case "m": minutes = true
            case "h": hours = true
            case "s": seconds = true
            case "%": percent = true
            case ".": afterPoint = true
            case "0", "#", "?": decimals += afterPoint ? 1 : 0
            default: break
            }
        }
        let hasTime = hours || seconds || elapsed != nil
        if date || (minutes && !hasTime) {
            return .date(hasTime: hasTime, hasSeconds: seconds || elapsed == .seconds)
        }
        if let elapsed {
            return .elapsed(elapsed, hasMinutes: minutes || elapsed == .minutes, hasSeconds: seconds)
        }
        if hasTime { return .time(hasSeconds: seconds) }
        return percent ? .percent(decimals: decimals) : .plain
    }

    /// A number as its style shows it: a date as 2026-10-20, with the time where the format
    /// has one, a time of day as 18:00, a length of time as 36:00, or a percentage. Other
    /// numbers stay as written, see `plain(_:_:)`.
    func text(ofNumber raw: String, style: Int) -> String {
        guard let value = Double(raw), value.isFinite else { return raw }
        switch number(style: style) {
        case .plain:
            return Self.plain(raw, value)
        case .percent(let decimals):
            return String(format: "%.\(min(decimals, 10))f%%", value * 100)
        case .date(let hasTime, let hasSeconds):
            return date(value, hasTime: hasTime, hasSeconds: hasSeconds) ?? raw
        case .time(let hasSeconds):
            return Self.time(value, hasSeconds: hasSeconds) ?? raw
        case .elapsed(let unit, let hasMinutes, let hasSeconds):
            return Self.elapsed(value, in: unit, hasMinutes: hasMinutes, hasSeconds: hasSeconds) ?? raw
        case .dateOrTime(let hasSeconds):
            return (value >= 1 ? date(value, hasTime: false, hasSeconds: false) : Self.time(value, hasSeconds: hasSeconds)) ?? raw
        }
    }

    /// A number as written, unless it holds more than the 15 significant digits Excel shows,
    /// as a sum such as 0.1 + 0.2 saved as 0.30000000000000004 does. That one shows rounded
    /// to 15, as 0.3.
    static func plain(_ raw: String, _ value: Double) -> String {
        guard !raw.contains(where: { $0 == "e" || $0 == "E" }),
              raw.drop(while: { !$0.isNumber || $0 == "0" }).filter(\.isNumber).count > 15 else { return raw }
        let rounded = String(format: "%.15g", value)
        return rounded.contains("e") ? raw : rounded
    }

    /// The seconds a date and time or a length of time holds, nil for a number Excel shows
    /// no date or time for: one below 0 or past the year 9999.
    private static func totalSeconds(_ value: Double) -> Int? {
        guard value >= 0, value < 2_958_466 else { return nil }
        return Int((value * 86_400).rounded())
    }

    /// A date as 2026-10-20, with its time as 18:00, or 18:00:05 with seconds.
    private func date(_ value: Double, hasTime: Bool, hasSeconds: Bool) -> String? {
        guard Self.totalSeconds(value) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        // Excel's 1900 system counts a 29 February 1900 that never was.
        let start = uses1904
            ? DateComponents(year: 1904, month: 1, day: 1)
            : value < 60 ? DateComponents(year: 1899, month: 12, day: 31) : DateComponents(year: 1899, month: 12, day: 30)
        let days = value.rounded(.down)
        let seconds = Int(((value - days) * 86_400).rounded())
        guard let base = calendar.date(from: start),
              let day = calendar.date(byAdding: .day, value: Int(days), to: base),
              let moment = calendar.date(byAdding: .second, value: seconds, to: day) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: moment)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard hasTime else { return date }
        return date + " " + Self.clock(parts.hour ?? 0, parts.minute ?? 0, hasSeconds ? parts.second ?? 0 : nil)
    }

    /// The time of day a number holds, whatever its date, as 18:00.
    private static func time(_ value: Double, hasSeconds: Bool) -> String? {
        guard let seconds = totalSeconds(value).map({ $0 % 86_400 }) else { return nil }
        return clock(seconds / 3_600, seconds % 3_600 / 60, hasSeconds ? seconds % 60 : nil)
    }

    /// A length of time in its largest unit, which runs past a day: 1.5 days in hours as
    /// 36:00, in minutes as 2160:00 with seconds, in seconds as 129600.
    private static func elapsed(_ value: Double, in unit: Unit, hasMinutes: Bool, hasSeconds: Bool) -> String? {
        guard let total = totalSeconds(value) else { return nil }
        let two = { (number: Int) in String(format: "%02d", number) }
        switch unit {
        case .hours:
            return "\(total / 3_600)" + (hasMinutes ? ":" + two(total % 3_600 / 60) : "") + (hasSeconds ? ":" + two(total % 60) : "")
        case .minutes:
            return "\(total / 60)" + (hasSeconds ? ":" + two(total % 60) : "")
        case .seconds:
            return "\(total)"
        }
    }

    /// Hours and minutes as 18:00, with seconds when given.
    private static func clock(_ hours: Int, _ minutes: Int, _ seconds: Int?) -> String {
        String(format: "%02d:%02d", hours, minutes) + (seconds.map { String(format: ":%02d", $0) } ?? "")
    }
}

/// The rows of one sheet, read with the workbook's strings and styles. The cells that show
/// are kept as they are read, and the hidden ones only counted, so hidden text takes no
/// room and no characters.
private nonisolated final class SheetReader: PartReader {
    struct Cell {
        var column: Int
        /// The text it shows.
        var text: String
        /// A string, rather than a number, a date or a truth value.
        var isText: Bool
        /// Whether the whole cell is hidden by its style.
        var isHidden: Bool
        /// The runs of hidden text dropped from a cell that shows the rest.
        var hiddenParts = 0
    }

    /// A cell while it is read.
    private struct Reading {
        var column: Int
        var style: Int
        var type: String?
        var value = ""
        var inline: RunCollector?
    }

    /// A row while it is read.
    private struct Row {
        var isHidden: Bool
        /// The cells that show.
        var cells: [Cell] = []
        /// The column of the last cell, with text or not, which the next cell without a
        /// reference follows.
        var lastColumn = 0
        /// Whether a hidden row holds a cell with text.
        var holdsText = false
        var hiddenRuns = 0
        var inHiddenRun = false
    }

    let strings: [[TextRun]]
    let styles: CellStyles
    /// Whether it only looks for text, in a hidden sheet, and stops at the first cell that
    /// holds some.
    private let findsText: Bool
    /// The characters of text that shows it may still give, see Limits.officeCharacters.
    private let allowed: Int
    /// The characters of the cells that show.
    private var characters = 0
    /// Whether rows that show were left out past `allowed`.
    private var isCut = false
    /// Whether a row holds a cell with text, shown or hidden.
    private(set) var holdsText = false
    /// The rows that show text, each with the cells that show.
    private var shown: [[Cell]] = []
    private var hiddenRuns = 0
    /// The hidden columns as <cols> gives them before the rows, where Excel writes it.
    private var hiddenColumnRanges: [ClosedRange<Int>] = []
    /// The same sorted, with those that overlap made one, from the first row on.
    private var hiddenColumns: [ClosedRange<Int>]?
    /// The hidden columns that hold text in a row that shows, each counted once.
    private var columnsWithText = Set<Int>()
    private var row: Row?
    private var cell: Reading?
    private var readsValue = false

    init(strings: [[TextRun]], styles: CellStyles, characters: Int = 0, findsText: Bool = false) {
        self.strings = strings
        self.styles = styles
        allowed = characters
        self.findsText = findsText
    }

    override func start(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "col" where parent() == "cols" && hiddenColumns == nil && !findsText:
            guard let first = Int(attributes["min"] ?? ""), let last = Int(attributes["max"] ?? ""), first <= last else { return }
            if OfficeXMLText.isOn(attributes["hidden"]) || (Double(attributes["width"] ?? "") ?? 1) < 0.5 {
                hiddenColumnRanges.append(first...last)
            }
        case "row":
            if hiddenColumns == nil {
                hiddenColumns = Self.merged(hiddenColumnRanges)
                hiddenColumnRanges = []
            }
            row = Row(isHidden: OfficeXMLText.isOn(attributes["hidden"]))
        case "c":
            let column = attributes["r"].flatMap(Self.column(of:)) ?? ((row?.lastColumn ?? 0) + 1)
            row?.lastColumn = column
            cell = Reading(column: column, style: Int(attributes["s"] ?? "") ?? 0, type: attributes["t"])
        case "v":
            readsValue = cell != nil
        case "is":
            cell?.inline = RunCollector()
        default:
            cell?.inline?.start(name, attributes, parent: parent())
        }
    }

    override func end(_ name: String) {
        switch name {
        case "v":
            readsValue = false
        case "c":
            if let reading = cell, row != nil, let made = made(reading) {
                holdsText = true
                if findsText {
                    finish()
                } else {
                    take(made)
                    if characters > allowed {
                        isCut = true
                        endRow()
                        finish()
                    }
                }
            }
            cell = nil
        case "row":
            endRow()
        case "sheetData":
            finish()
        default:
            cell?.inline?.end(name)
        }
    }

    override func characters(_ text: String) {
        if readsValue {
            cell?.value += text
        } else {
            cell?.inline?.characters(text)
        }
    }

    /// Keeps a cell that shows in the row, and counts one that is hidden: a hidden row once,
    /// a hidden column once in the sheet, and a run of hidden cells once.
    private func take(_ made: Cell) {
        guard let isHiddenRow = row?.isHidden else { return }
        if isHiddenRow {
            row?.holdsText = true
        } else if isHiddenColumn(made.column) {
            columnsWithText.insert(made.column)
        } else if made.isHidden {
            if row?.inHiddenRun == false {
                row?.hiddenRuns += 1
            }
            row?.inHiddenRun = true
        } else {
            row?.cells.append(made)
            row?.hiddenRuns += made.hiddenParts
            row?.inHiddenRun = false
            characters += made.text.count
        }
    }

    private func endRow() {
        guard let row else { return }
        self.row = nil
        if row.isHidden {
            hiddenRuns += row.holdsText ? 1 : 0
        } else {
            hiddenRuns += row.hiddenRuns
            if !row.cells.isEmpty {
                shown.append(row.cells)
            }
        }
    }

    /// Whether a column is hidden, by a search of the sorted ranges.
    private func isHiddenColumn(_ column: Int) -> Bool {
        guard let ranges = hiddenColumns, !ranges.isEmpty else { return false }
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].upperBound < column {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < ranges.count && ranges[low].contains(column)
    }

    /// The ranges sorted, with those that overlap made one, so they neither overlap nor
    /// fall out of order.
    private static func merged(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var merged: [ClosedRange<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// A cell's text as it shows, nil for a cell that holds none.
    private func made(_ cell: Reading) -> Cell? {
        let text: String
        var isText = true
        var isHidden = styles.isHidden(style: cell.style)
        switch cell.type {
        case "s":
            guard let index = Int(cell.value.trimmingCharacters(in: .whitespaces)), strings.indices.contains(index) else { return nil }
            return made(strings[index], in: cell)
        case "inlineStr":
            return made(cell.inline?.runs ?? [], in: cell)
        case "str":
            text = cell.value
            isHidden = isHidden || styles.hidesText(style: cell.style)
        case "b":
            text = cell.value.trimmingCharacters(in: .whitespaces) == "1" ? "TRUE" : "FALSE"
            isText = false
        case "e":
            return nil
        case "d":
            let raw = cell.value.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            text = raw
            isText = false
        default:
            let raw = cell.value.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            if let value = Double(raw), value.isFinite, styles.hides(value, style: cell.style) {
                // A zero its format shows as nothing, as when a sheet hides its zeros, holds
                // nothing to hide, so it is an empty cell. Any other number is hidden.
                guard value != 0 else { return nil }
                isHidden = true
            }
            text = styles.text(ofNumber: raw, style: cell.style)
            isText = false
        }
        let line = OfficeXMLText.oneLine(text)
        guard !line.isEmpty else { return nil }
        return Cell(column: cell.column, text: line, isText: isText, isHidden: isHidden)
    }

    /// A string cell from its runs: a run whose own font is under 3 points, or white where
    /// the cell has no fill or a white one, is dropped and counted, runs next to each other
    /// once. A cell whose every run is dropped is hidden.
    private func made(_ runs: [TextRun], in cell: Reading) -> Cell? {
        let isClear = styles.isClearFill(style: cell.style)
        var text = ""
        var hiddenParts = 0
        var inHiddenRun = false
        for run in runs {
            if run.text.allSatisfy(\.isWhitespace) {
                text += run.text
            } else if (run.size ?? 11) < 3 || (run.isWhite && isClear) {
                if !inHiddenRun {
                    hiddenParts += 1
                }
                inHiddenRun = true
            } else {
                text += run.text
                inHiddenRun = false
            }
        }
        let line = OfficeXMLText.oneLine(text)
        guard !line.isEmpty else {
            return hiddenParts > 0 ? Cell(column: cell.column, text: "", isText: true, isHidden: true) : nil
        }
        let isHidden = styles.isHidden(style: cell.style) || styles.hidesText(style: cell.style)
        return Cell(column: cell.column, text: line, isText: true, isHidden: isHidden, hiddenParts: hiddenParts)
    }

    /// The column of a cell reference such as AB12, from 1.
    static func column(of reference: String) -> Int? {
        var column = 0
        var letters = 0
        for scalar in reference.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A: column = column * 26 + Int(scalar.value - 0x40)
            case 0x61...0x7A: column = column * 26 + Int(scalar.value - 0x60)
            default: return (1...3).contains(letters) ? column : nil
            }
            letters += 1
            if letters > 3 { return nil }
        }
        return (1...3).contains(letters) ? column : nil
    }

    /// The sheet as a page, nil when it shows no text, with the hidden runs it dropped and
    /// whether rows were left out. The page holds the rows whose lines fit in the
    /// characters it may still give, and looks at the clock and the task every 1,000 rows.
    func laidOut(name: String) throws(FileSkipReason) -> (page: FileTextResult.Page?, hiddenRuns: Int, isCut: Bool) {
        let hiddenRuns = self.hiddenRuns + columnsWithText.count
        guard !shown.isEmpty else { return (nil, hiddenRuns, isCut) }
        let first = shown.compactMap(\.first?.column).min() ?? 1
        let sheet = OfficeXMLText.oneLine(name)
        var heading = "# " + sheet
        // The first row with two or more cells among the first 10 is the header when it
        // holds only text, and when the heading line with it is still one TextChunker reads
        // as a heading. Else it stays a row, so none of its text is lost.
        var header = shown.prefix(10).firstIndex { $0.count >= 2 }.flatMap { shown[$0].allSatisfy(\.isText) ? $0 : nil }
        if let found = header, let start = shown[found].first?.column {
            let withHeader = heading + ": " + Self.aligned(shown[found], from: start).joined(separator: " | ")
            if withHeader.count <= TextChunker.maximumHeadingCharacters && withHeader.utf8.count <= TextChunker.maximumHeadingBytes {
                heading = withHeader
            } else {
                header = nil
            }
        }
        var count = heading.count
        guard count <= allowed else { return (nil, hiddenRuns, true) }
        var isCut = self.isCut
        var lines = [heading]
        for (index, cells) in shown.enumerated() where index != header {
            if index > 0, index.isMultiple(of: 1_000), let reason = check() { throw reason }
            let line = OfficeXMLText.row(Self.aligned(cells, from: first))
            count += 1 + line.count
            guard count <= allowed else {
                isCut = true
                break
            }
            lines.append(line)
        }
        let page = FileTextResult.Page(number: nil, text: lines.joined(separator: "\n"), sheet: sheet.isEmpty ? nil : sheet, isStandAlone: true)
        return (page, hiddenRuns, isCut)
    }

    /// A row's texts in their columns from `first`, an empty cell for each column between.
    /// A gap of more than 5 columns shows as one empty cell, so a sparse row stays short.
    private static func aligned(_ cells: [Cell], from first: Int) -> [String] {
        var texts: [String] = []
        var column = first
        for cell in cells {
            let gap = cell.column - column
            texts += Array(repeating: "", count: gap > 5 ? 1 : max(0, gap))
            texts.append(cell.text)
            column = cell.column + 1
        }
        return texts
    }
}

// MARK: Decks

/// The slides of a deck in its order, and the size of a slide.
private nonisolated final class PresentationReader: PartReader {
    private(set) var slides: [String] = []
    private(set) var size: (width: Int64, height: Int64)?

    override func start(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "sldId" where parent() == "sldIdLst":
            if let id = OfficeXMLText.relationship(attributes) {
                slides.append(id)
            }
        case "sldSz":
            if let width = Int64(attributes["cx"] ?? ""), let height = Int64(attributes["cy"] ?? ""), width > 0, height > 0 {
                size = (width, height)
            }
        default:
            break
        }
    }
}

/// The text of a slide or of a notes page.
private nonisolated final class SlideReader: PartReader {
    /// A shape, a group or a frame such as a table, while it is read.
    private struct Shape {
        var isGroup: Bool
        var isHidden: Bool
        /// The type of its placeholder, nil when it is none.
        var placeholder: String?
        var fill: OfficeColor?
        var x: Int64?
        var y: Int64?
        var width: Int64?
        var height: Int64?
        var lines: [String] = []
        var hiddenRuns = 0
    }

    /// The size, color and opacity a run has, or that a paragraph or a list style gives the
    /// runs that say nothing of their own.
    private struct RunStyle {
        /// In hundredths of a point.
        var size: Int?
        var color: OfficeColor?
        /// In thousandths of a percent.
        var alpha: Int?

        /// This style, with what it leaves open taken from `other`.
        func over(_ other: RunStyle) -> RunStyle {
            RunStyle(size: size ?? other.size, color: color ?? other.color, alpha: alpha ?? other.alpha)
        }
    }

    /// Where a <defRPr> being read gives its style.
    private enum DefaultsTarget {
        case paragraph
        case list(level: Int)
    }

    /// The size of a slide, nil for a notes page.
    let size: (width: Int64, height: Int64)?
    /// Whether the slide shows in the slide show: false for a hidden slide.
    private(set) var isShown = true
    private(set) var hiddenRuns = 0
    private var title: String?
    private var blocks: [String] = []
    /// The text of a notes page's body placeholders, which hold the speaker notes.
    private var body: [String] = []
    /// The text of a notes page's other shapes, besides its slide image, header, footer,
    /// date and page number, for a notes page without a body placeholder.
    private var otherNotes: [String] = []
    private var shapes: [Shape] = []
    private var paragraph = ""
    private var run: (text: String, style: RunStyle)?
    /// The style a paragraph gives its runs, and its list level from 1.
    private var paragraphStyle = RunStyle()
    private var paragraphLevel = 1
    /// The styles the list style of the text body being read gives each level.
    private var listStyles: [Int: RunStyle] = [:]
    private var defaultsTarget: DefaultsTarget?
    private var inText = false
    private var inHiddenRun = false
    /// The cells of the table row and the paragraphs of the cell being read.
    private var tableRow: [String]?
    private var cell: [String]?

    init(size: (width: Int64, height: Int64)?) {
        self.size = size
    }

    /// The slide's text: its title, then its shapes, a blank line between them.
    var text: String {
        ((title.map { ["# " + $0] } ?? []) + blocks).joined(separator: "\n\n")
    }

    /// The text of a notes page: its body, the speaker notes.
    var notes: String {
        (body.isEmpty ? otherNotes : body).joined(separator: "\n\n")
    }

    private static let shapeNames: Set<String> = ["sp", "grpSp", "graphicFrame", "cxnSp", "pic"]

    override func start(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "sld":
            isShown = !(attributes["show"] == "0" || attributes["show"] == "false")
        case _ where Self.shapeNames.contains(name) && path.contains("spTree"):
            let parent = shapes.last
            shapes.append(Shape(isGroup: name == "grpSp", isHidden: parent?.isHidden == true))
        case "cNvPr" where !shapes.isEmpty:
            if OfficeXMLText.isOn(attributes["hidden"]) {
                shapes[shapes.count - 1].isHidden = true
            }
        case "ph" where !shapes.isEmpty:
            shapes[shapes.count - 1].placeholder = attributes["type"] ?? "obj"
        case "off" where isPlacement && !shapes.isEmpty:
            shapes[shapes.count - 1].x = Int64(attributes["x"] ?? "")
            shapes[shapes.count - 1].y = Int64(attributes["y"] ?? "")
        case "ext" where isPlacement && !shapes.isEmpty:
            shapes[shapes.count - 1].width = Int64(attributes["cx"] ?? "")
            shapes[shapes.count - 1].height = Int64(attributes["cy"] ?? "")
            hideIfOutside()
        case "srgbClr" where parent() == "solidFill" && parent(2) == "spPr" && !shapes.isEmpty:
            shapes[shapes.count - 1].fill = OfficeColor(hex: attributes["val"])
        case "srgbClr" where parent() == "solidFill" && parent(2) == "rPr":
            run?.style.color = OfficeColor(hex: attributes["val"])
        case "alpha" where parent(2) == "solidFill" && parent(3) == "rPr":
            run?.style.alpha = Int(attributes["val"] ?? "")
        case "srgbClr" where parent() == "solidFill" && parent(2) == "defRPr":
            setDefaults { $0.color = OfficeColor(hex: attributes["val"]) }
        case "alpha" where parent(2) == "solidFill" && parent(3) == "defRPr":
            setDefaults { $0.alpha = Int(attributes["val"] ?? "") }
        case "txBody":
            listStyles = [:]
        case "p" where parent() == "txBody":
            paragraph = ""
            paragraphStyle = RunStyle()
            paragraphLevel = 1
        case "pPr" where parent() == "p":
            // A level runs from 0 to 8, and is clamped before it counts from 1, since a file
            // may give any number.
            paragraphLevel = min(max(Int(attributes["lvl"] ?? "") ?? 0, 0), 8) + 1
        case "defRPr" where parent() == "pPr":
            defaultsTarget = .paragraph
            paragraphStyle.size = Int(attributes["sz"] ?? "")
        case "defRPr" where parent(2) == "lstStyle" && parent().hasPrefix("lvl") && parent().hasSuffix("pPr"):
            let level = Int(parent().dropFirst(3).dropLast(3)) ?? 1
            defaultsTarget = .list(level: level)
            listStyles[level, default: RunStyle()].size = Int(attributes["sz"] ?? "")
        case "r", "fld":
            run = ("", RunStyle())
        case "rPr" where run != nil:
            run?.style.size = Int(attributes["sz"] ?? "")
        case "t" where run != nil:
            inText = true
        case "br" where parent() == "p":
            paragraph += "\n"
        case "tr":
            tableRow = []
        case "tc":
            cell = []
        default:
            break
        }
    }

    override func end(_ name: String) {
        switch name {
        case "t":
            inText = false
        case "defRPr":
            defaultsTarget = nil
        case "r", "fld":
            endRun()
        case "p" where parent() == "txBody":
            if cell != nil {
                cell?.append(OfficeXMLText.oneLine(paragraph))
            } else if !shapes.isEmpty {
                shapes[shapes.count - 1].lines.append(paragraph)
            }
            paragraph = ""
        case "tc":
            tableRow?.append((cell ?? []).filter { !$0.isEmpty }.joined(separator: " "))
            cell = nil
        case "tr":
            if let tableRow, tableRow.contains(where: { !$0.isEmpty }), !shapes.isEmpty {
                shapes[shapes.count - 1].lines.append(OfficeXMLText.row(tableRow))
            }
            tableRow = nil
        case _ where Self.shapeNames.contains(name) && !shapes.isEmpty && path.dropLast().contains("spTree"):
            endShape(shapes.removeLast())
        default:
            break
        }
    }

    override func characters(_ text: String) {
        if inText {
            run?.text += text
        }
    }

    /// Whether the open element is the off or ext of a shape's or a group's placement.
    private var isPlacement: Bool {
        parent() == "xfrm" && ["spPr", "grpSpPr", "graphicFrame"].contains(parent(2))
    }

    /// Hides a shape or group on the slide's top level whose placement lies wholly outside
    /// the slide. A shape inside a group is placed in the group's own space, so only the
    /// group is measured.
    private func hideIfOutside() {
        guard let size, shapes.count == 1, let shape = shapes.last,
              let x = shape.x, let y = shape.y, let width = shape.width, let height = shape.height else { return }
        // In Double, since a file may give any 64 bit value, whose sum would overflow.
        let (left, top) = (Double(x), Double(y))
        if left >= Double(size.width) || top >= Double(size.height) || left + Double(width) <= 0 || top + Double(height) <= 0 {
            shapes[shapes.count - 1].isHidden = true
        }
    }

    /// Changes the style the <defRPr> being read gives.
    private func setDefaults(_ change: (inout RunStyle) -> Void) {
        switch defaultsTarget {
        case .paragraph?: change(&paragraphStyle)
        case .list(let level)?: change(&listStyles[level, default: RunStyle()])
        case nil: break
        }
    }

    private func endRun() {
        guard let run else { return }
        self.run = nil
        guard !run.text.allSatisfy(\.isWhitespace) else {
            paragraph += run.text
            return
        }
        // What the run leaves open comes from its paragraph, then from the list style.
        let style = run.style.over(paragraphStyle).over(listStyles[paragraphLevel] ?? RunStyle())
        let isTiny = (style.size ?? 1_800) < 300
        let isClear = (style.alpha ?? 100_000) < 10_000
        let isLikeFill = style.color.flatMap { color in shapes.last?.fill.map { color.distance(to: $0) < 0.1 } } ?? false
        if isTiny || isClear || isLikeFill {
            if !inHiddenRun, !shapes.isEmpty {
                shapes[shapes.count - 1].hiddenRuns += 1
            }
            inHiddenRun = true
        } else {
            paragraph += run.text
            inHiddenRun = false
        }
    }

    private func endShape(_ shape: Shape) {
        let lines = shape.lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shape.isHidden else {
            hiddenRuns += text.isEmpty && shape.hiddenRuns == 0 ? 0 : 1
            return
        }
        hiddenRuns += shape.hiddenRuns
        guard !text.isEmpty else { return }
        switch shape.placeholder {
        case "title"?, "ctrTitle"?:
            let line = OfficeXMLText.oneLine(text)
            if title == nil {
                title = line
            } else {
                blocks.append(text)
            }
        case "body"?:
            body.append(text)
            blocks.append(text)
        case "sldImg"?, "hdr"?, "ftr"?, "dt"?, "sldNum"?:
            blocks.append(text)
        default:
            otherNotes.append(text)
            blocks.append(text)
        }
    }
}
