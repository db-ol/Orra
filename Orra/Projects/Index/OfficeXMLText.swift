import Foundation

/// Reads the text of an Excel workbook (xlsx and xlsm) and of a PowerPoint deck (pptx and
/// ppsx) from the parts of its ZIP archive, see ZipArchive. Nothing in them is run, followed
/// or unpacked besides the parts named below: no macro, no formula, no link, no picture.
///
/// - Every part goes through Foundation's XMLParser. A part that declares a document type or
///   an entity, which no Office part does, is unreadable, and so is one with a NUL byte, as
///   UTF-16 text has, so that check sees every part's bytes as they are. XMLParser never
///   resolves an external entity by default, and nothing here changes that.
/// - A relationship is followed only inside the package. A target with a scheme, one marked
///   External and one that climbs above the package's root are skipped.
/// - The parts read count against `FileTextExtractor.Limits.officeBytes`. A sheet or slide
///   that no longer fits is left out with the ones after it, and so is the text past
///   `officeCharacters`, and the result says it was cut. Every 1,000 elements the parse
///   looks at the clock and at the task, and it stops past `officeTime` as too slow, or as
///   cancelled.
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
    ///   of a formula and never the formula, TRUE or FALSE, and numbers as written, a date
    ///   as 2026-10-20 and a percentage as 15% where the cell's format says so. Errors give
    ///   nothing.
    /// - Hidden sheets, hidden rows and columns, columns narrower than half a character,
    ///   cells whose format shows nothing (;;;), fonts under 3 points and white fonts on no
    ///   fill or a white fill are dropped, each sheet, row, column or run of cells counted
    ///   once. Text in drawings, charts and comments is not read.
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
            var strings: [String] = []
            if let part = relationships.values.first(where: { $0.type.hasSuffix("/sharedStrings") })?.target {
                let reader = SharedStringsReader()
                try package.parse(part, with: reader)
                strings = reader.strings
            }
            var read: Read = ([], 0, false)
            var characters = limits.officeCharacters
            for sheet in workbook.sheets {
                guard let relationship = relationships[sheet.relationship], relationship.type.hasSuffix("/worksheet"),
                      package.archive.contains(relationship.target) else { continue }
                guard characters > 0 else {
                    read.isCut = true
                    break
                }
                let reader = SheetReader(strings: strings, styles: styles, characters: characters)
                do {
                    try package.parse(relationship.target, with: reader)
                } catch .tooLarge {
                    read.isCut = true
                    break
                }
                characters -= reader.characters
                read.isCut = read.isCut || reader.isCut
                let laidOut = reader.laidOut(name: sheet.name)
                if sheet.isHidden {
                    read.hiddenRuns += laidOut.page == nil ? laidOut.hiddenRuns : 1
                } else {
                    read.hiddenRuns += laidOut.hiddenRuns
                    if let page = laidOut.page {
                        read.pages.append(page)
                    }
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
    ///   fill are dropped and counted. Text colored like the slide's background is not
    ///   caught, since the background may come from the layout, the master or a picture.
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
            guard !data.contains(0), data.range(of: Data("<!DOCTYPE".utf8)) == nil,
                  data.range(of: Data("<!ENTITY".utf8)) == nil else { throw .unreadable }
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

/// The shared strings of a workbook, without their phonetic runs.
private nonisolated final class SharedStringsReader: PartReader {
    private(set) var strings: [String] = []
    private var current: String?
    private var phonetic = 0
    private var inText = false

    override func start(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "si": current = ""
        case "rPh": phonetic += 1
        case "t": inText = current != nil && phonetic == 0
        default: break
        }
    }

    override func end(_ name: String) {
        switch name {
        case "si":
            strings.append(current ?? "")
            current = nil
        case "rPh": phonetic -= 1
        case "t": inText = false
        default: break
        }
    }

    override func characters(_ text: String) {
        if inText {
            current? += text
        }
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
        case ("sz", "font") where parent(2) == "fonts":
            fonts[fonts.count - 1].size = Double(attributes["val"] ?? "")
        case ("color", "font") where parent(2) == "fonts":
            fonts[fonts.count - 1].isWhite = OfficeColor.isWhite(attributes)
        case ("fill", "fills"):
            fills.append(Fill())
        case ("patternFill", "fill") where parent(2) == "fills":
            let pattern = attributes["patternType"] ?? "none"
            fills[fills.count - 1].isClear = pattern == "none" || pattern == "solid"
        case ("gradientFill", "fill") where parent(2) == "fills":
            fills[fills.count - 1].isClear = false
        case ("fgColor", "patternFill") where parent(3) == "fills":
            // A solid fill is clear only when it is white.
            if fills[fills.count - 1].isClear {
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
        case date(hasDate: Bool, hasTime: Bool, hasSeconds: Bool)
        case percent(decimals: Int)
        /// A format with no section that shows anything, such as ;;;.
        case nothing
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

    /// Whether the text of a cell of that style cannot be seen: a format that shows nothing,
    /// a font under 3 points, or a white font on no fill or a white fill.
    func isHidden(style: Int) -> Bool {
        guard formats.indices.contains(style) else { return false }
        let format = formats[style]
        if number(style: style) == .nothing { return true }
        guard fonts.indices.contains(format.font) else { return false }
        let font = fonts[format.font]
        if let size = font.size, size < 3 { return true }
        let isClear = fills.indices.contains(format.fill) ? fills[format.fill].isClear : true
        return font.isWhite && isClear
    }

    /// How a number of a cell of that style shows.
    func number(style: Int) -> Number {
        guard formats.indices.contains(style) else { return .plain }
        let id = formats[style].numberFormat
        if let code = numberFormats[id] { return Self.number(code: code) }
        switch id {
        case 9: return .percent(decimals: 0)
        case 10: return .percent(decimals: 2)
        case 14...17, 22, 27...31, 36, 50...54, 57, 58: return .date(hasDate: true, hasTime: id == 22, hasSeconds: false)
        case 18, 20, 32, 34, 55: return .date(hasDate: false, hasTime: true, hasSeconds: false)
        case 19, 21, 33, 35, 45...47, 56: return .date(hasDate: false, hasTime: true, hasSeconds: true)
        default: return .plain
        }
    }

    /// How a custom format shows a number: a date where its first section holds d, m, y, h
    /// or s outside quotes and brackets, a percentage where it holds %.
    static func number(code: String) -> Number {
        let sections = code.split(separator: ";", omittingEmptySubsequences: false)
        if sections.count >= 4, sections.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) { return .nothing }
        var inQuotes = false, inBrackets = false, skipsNext = false, afterPoint = false
        var date = false, time = false, seconds = false, percent = false, minutes = false
        var decimals = 0
        for character in code {
            if skipsNext {
                skipsNext = false
                continue
            }
            if inQuotes {
                inQuotes = character != "\""
                continue
            }
            if inBrackets {
                inBrackets = character != "]"
                continue
            }
            switch character.lowercased() {
            case "\"": inQuotes = true
            case "[": inBrackets = true
            case "\\", "_", "*": skipsNext = true
            case ";": break
            case "d", "y": date = true
            case "m": minutes = true
            case "h": time = true
            case "s":
                time = true
                seconds = true
            case "%": percent = true
            case ".": afterPoint = true
            case "0", "#": decimals += afterPoint ? 1 : 0
            default: break
            }
            if character == ";" { break }
        }
        if date || time || minutes {
            // m alone, as in mmm, is a month.
            return .date(hasDate: date || !time, hasTime: time, hasSeconds: seconds)
        }
        return percent ? .percent(decimals: decimals) : .plain
    }

    /// A number as its style shows it: a date as 2026-10-20, with the time where the format
    /// has one, or a percentage. Other numbers stay as written.
    func text(ofNumber raw: String, style: Int) -> String {
        guard let value = Double(raw), value.isFinite else { return raw }
        switch number(style: style) {
        case .plain, .nothing:
            return raw
        case .percent(let decimals):
            return String(format: "%.\(min(decimals, 10))f%%", value * 100)
        case .date(let hasDate, let hasTime, let hasSeconds):
            guard value >= 0, value < 2_958_466 else { return raw }
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
                  let moment = calendar.date(byAdding: .second, value: seconds, to: day) else { return raw }
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: moment)
            let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            var time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            if hasSeconds {
                time += String(format: ":%02d", parts.second ?? 0)
            }
            if hasDate && hasTime { return date + " " + time }
            return hasDate || value >= 1 ? date : time
        }
    }
}

/// The rows of one sheet, read with the workbook's strings and styles.
private nonisolated final class SheetReader: PartReader {
    struct Cell {
        var column: Int
        var text: String
        /// A string, rather than a number, a date or a truth value.
        var isText: Bool
        var isHidden: Bool
    }

    struct Row {
        var cells: [Cell]
        var isHidden: Bool
    }

    let strings: [String]
    let styles: CellStyles
    /// The characters it may still read, see Limits.officeCharacters.
    private let allowed: Int
    /// The characters of cell text it read.
    private(set) var characters = 0
    private(set) var isCut = false
    private var rows: [Row] = []
    private var hiddenColumns: [ClosedRange<Int>] = []
    private var row: Row?
    private var cell: (column: Int, style: Int, type: String?, value: String, inline: String)?
    private var reading: Reading?
    private var phonetic = 0

    private enum Reading {
        case value, inline
    }

    init(strings: [String], styles: CellStyles, characters: Int) {
        self.strings = strings
        self.styles = styles
        allowed = characters
    }

    override func start(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "col":
            guard let first = Int(attributes["min"] ?? ""), let last = Int(attributes["max"] ?? ""), first <= last else { return }
            if OfficeXMLText.isOn(attributes["hidden"]) || (Double(attributes["width"] ?? "") ?? 1) < 0.5 {
                hiddenColumns.append(first...last)
            }
        case "row":
            row = Row(cells: [], isHidden: OfficeXMLText.isOn(attributes["hidden"]))
        case "c":
            let column = attributes["r"].flatMap(Self.column(of:)) ?? ((row?.cells.last?.column ?? 0) + 1)
            cell = (column, Int(attributes["s"] ?? "") ?? 0, attributes["t"], "", "")
        case "v":
            reading = cell == nil ? nil : .value
        case "rPh":
            phonetic += 1
        case "t" where cell != nil && phonetic == 0 && path.contains("is"):
            reading = .inline
        case "f":
            reading = nil
        default:
            break
        }
    }

    override func end(_ name: String) {
        switch name {
        case "v", "t":
            reading = nil
        case "rPh":
            phonetic -= 1
        case "c":
            if let cell, let made = made(cell) {
                characters += made.text.count
                row?.cells.append(made)
            }
            cell = nil
            if characters > allowed {
                isCut = true
                if let row {
                    rows.append(row)
                }
                row = nil
                finish()
            }
        case "row":
            if let row {
                rows.append(row)
            }
            row = nil
        case "sheetData":
            finish()
        default:
            break
        }
    }

    override func characters(_ text: String) {
        switch reading {
        case .value?: cell?.value += text
        case .inline?: cell?.inline += text
        case nil: break
        }
    }

    /// A cell's text as it shows, nil for a cell that shows none.
    private func made(_ cell: (column: Int, style: Int, type: String?, value: String, inline: String)) -> Cell? {
        let text: String
        var isText = true
        switch cell.type {
        case "s":
            guard let index = Int(cell.value.trimmingCharacters(in: .whitespaces)), strings.indices.contains(index) else { return nil }
            text = strings[index]
        case "inlineStr":
            text = cell.inline
        case "str":
            text = cell.value
        case "b":
            text = cell.value.trimmingCharacters(in: .whitespaces) == "1" ? "TRUE" : "FALSE"
            isText = false
        case "e":
            return nil
        default:
            let raw = cell.value.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            text = cell.type == "d" ? raw : styles.text(ofNumber: raw, style: cell.style)
            isText = false
        }
        let line = OfficeXMLText.oneLine(text)
        guard !line.isEmpty else { return nil }
        return Cell(column: cell.column, text: line, isText: isText, isHidden: styles.isHidden(style: cell.style))
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

    /// The sheet as a page, nil when it shows no text, and the hidden runs it dropped.
    func laidOut(name: String) -> (page: FileTextResult.Page?, hiddenRuns: Int) {
        var hiddenRuns = 0
        var columnsWithText = Set<Int>()
        var shown: [[Cell]] = []
        for row in rows where !row.cells.isEmpty {
            if row.isHidden {
                hiddenRuns += 1
                continue
            }
            var cells: [Cell] = []
            var inHiddenRun = false
            for cell in row.cells {
                if hiddenColumns.contains(where: { $0.contains(cell.column) }) {
                    columnsWithText.insert(cell.column)
                } else if cell.isHidden {
                    if !inHiddenRun {
                        hiddenRuns += 1
                    }
                    inHiddenRun = true
                } else {
                    cells.append(cell)
                    inHiddenRun = false
                }
            }
            if !cells.isEmpty {
                shown.append(cells)
            }
        }
        hiddenRuns += columnsWithText.count
        guard !shown.isEmpty else { return (nil, hiddenRuns) }
        let first = shown.compactMap(\.first?.column).min() ?? 1
        // The first row with two or more cells among the first 10 is the header when it
        // holds only text.
        let header = shown.prefix(10).firstIndex { $0.count >= 2 }.flatMap { $0 < shown.count && shown[$0].allSatisfy(\.isText) ? $0 : nil }
        var heading = "# " + OfficeXMLText.oneLine(name)
        if let header {
            heading += ": " + Self.aligned(shown[header], from: first).joined(separator: " | ")
        }
        var lines = [Self.cut(heading)]
        for (index, cells) in shown.enumerated() where index != header {
            lines.append(OfficeXMLText.row(Self.aligned(cells, from: first)))
        }
        let sheet = OfficeXMLText.oneLine(name)
        return (FileTextResult.Page(number: nil, text: lines.joined(separator: "\n"), sheet: sheet.isEmpty ? nil : sheet, isStandAlone: true), hiddenRuns)
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

    /// A heading line cut to what TextChunker reads as a heading.
    private static func cut(_ line: String) -> String {
        var cut = String(line.prefix(TextChunker.maximumHeadingCharacters))
        while cut.utf8.count > TextChunker.maximumHeadingBytes {
            cut.removeLast()
        }
        return cut
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
    private var run: (text: String, size: Int?, alpha: Int?, color: OfficeColor?)?
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
            run?.color = OfficeColor(hex: attributes["val"])
        case "alpha" where parent(2) == "solidFill" && parent(3) == "rPr":
            run?.alpha = Int(attributes["val"] ?? "")
        case "p" where parent() == "txBody":
            paragraph = ""
        case "r", "fld":
            run = ("", nil, nil, nil)
        case "rPr" where run != nil:
            run?.size = Int(attributes["sz"] ?? "")
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
        if x >= size.width || y >= size.height || x + width <= 0 || y + height <= 0 {
            shapes[shapes.count - 1].isHidden = true
        }
    }

    private func endRun() {
        guard let run else { return }
        self.run = nil
        guard !run.text.allSatisfy(\.isWhitespace) else {
            paragraph += run.text
            return
        }
        let isTiny = (run.size ?? 1_800) < 300
        let isClear = (run.alpha ?? 100_000) < 10_000
        let isLikeFill = run.color.flatMap { color in shapes.last?.fill.map { color.distance(to: $0) < 0.1 } } ?? false
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
