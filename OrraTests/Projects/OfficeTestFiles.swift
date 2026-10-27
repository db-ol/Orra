import Foundation

/// ZIP, docx, xlsx and pptx files built by hand for the tests, with their parts deflated as
/// Office writes them, so a test can put in what Office writes and what it never would.
enum OfficeTestFiles {
    // MARK: ZIP

    /// A ZIP file of the parts in order, deflated, or stored when `stored` is true.
    static func zip(_ parts: [(name: String, data: Data)], stored: Bool = false) throws -> Data {
        func bytes<Number: FixedWidthInteger>(_ number: Number) -> Data {
            withUnsafeBytes(of: number.littleEndian) { Data($0) }
        }
        var file = Data()
        var directory = Data()
        for part in parts {
            let packed = stored ? part.data : try (part.data as NSData).compressed(using: .zlib) as Data
            let name = Data(part.name.utf8)
            // Version 2.0, no flags, the method, no time, the CRC and both sizes.
            let fields = bytes(UInt16(20)) + bytes(UInt16(0)) + bytes(UInt16(stored ? 0 : 8)) + bytes(UInt32(0)) + bytes(crc32(part.data))
                + bytes(UInt32(packed.count)) + bytes(UInt32(part.data.count)) + bytes(UInt16(name.count)) + bytes(UInt16(0))
            directory += bytes(UInt32(0x0201_4B50)) + bytes(UInt16(20)) + fields + bytes(UInt16(0)) + bytes(UInt16(0))
                + bytes(UInt16(0)) + bytes(UInt32(0)) + bytes(UInt32(file.count)) + name
            file += bytes(UInt32(0x0403_4B50)) + fields + name + packed
        }
        let start = file.count
        file += directory
        file += bytes(UInt32(0x0605_4B50)) + bytes(UInt32(0)) + bytes(UInt16(parts.count)) + bytes(UInt16(parts.count))
            + bytes(UInt32(directory.count)) + bytes(UInt32(start)) + bytes(UInt16(0))
        return file
    }

    /// A ZIP file of text parts.
    static func zip(texts parts: [(name: String, text: String)], stored: Bool = false) throws -> Data {
        try zip(parts.map { ($0.name, Data($0.text.utf8)) }, stored: stored)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// The range of the last match of `pattern` in `data`.
    static func lastRange(of pattern: [UInt8], in data: Data) -> Range<Int>? {
        data.lastRange(of: Data(pattern)).map { $0.lowerBound..<$0.upperBound }
    }

    private static let xmlHead = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

    private static func relationships(_ items: [(id: String, type: String, target: String)], external: Set<String> = []) -> String {
        xmlHead + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + items.map { item in
                let mode = external.contains(item.id) ? #" TargetMode="External""# : ""
                return #"<Relationship Id="\#(item.id)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/\#(item.type)" Target="\#(item.target)"\#(mode)/>"#
            }.joined()
            + "</Relationships>"
    }

    private static func contentTypes(_ main: String, _ type: String) -> String {
        xmlHead + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
            + #"<Default Extension="xml" ContentType="application/xml"/><Override PartName="/\#(main)" ContentType="\#(type)"/></Types>"#
    }

    /// XML text with its five special characters escaped.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: docx

    /// A Word paragraph with one run.
    static func paragraph(_ text: String, properties: String = "") -> String {
        "<w:p><w:r><w:rPr>\(properties)</w:rPr><w:t>\(text)</w:t></w:r></w:p>"
    }

    /// A docx built by hand, with its parts deflated as Word does, since AppKit's writer
    /// cannot write cell shading or Word's hidden text.
    static func docx(body: String) throws -> Data {
        let document = xmlHead + #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
            + "<w:body>\(body)</w:body></w:document>"
        return try zip(texts: [
            ("[Content_Types].xml", contentTypes("word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")),
            ("_rels/.rels", relationships([("rId1", "officeDocument", "word/document.xml")])),
            ("word/document.xml", document),
        ])
    }

    // MARK: xlsx

    /// A sheet of a workbook: its name, its state such as hidden, and the XML of its
    /// worksheet part inside <worksheet>, such as <cols> and <sheetData>.
    struct Sheet {
        var name: String
        var state: String?
        var xml: String

        init(_ name: String, state: String? = nil, _ xml: String) {
            self.name = name
            self.state = state
            self.xml = xml
        }

        /// A sheet whose rows are given cell by cell, each an inline string, a number or a
        /// boolean as `cell(_:_:)` writes it.
        init(_ name: String, state: String? = nil, rows: [[String]]) {
            self.init(name, state: state, "<sheetData>" + rows.enumerated().map { index, cells in
                OfficeTestFiles.row(index + 1, cells.enumerated().map { column, value in
                    OfficeTestFiles.cell(OfficeTestFiles.reference(column + 1, index + 1), value)
                }.joined())
            }.joined() + "</sheetData>")
        }
    }

    /// The reference of a cell, such as B3.
    static func reference(_ column: Int, _ row: Int) -> String {
        var letters = ""
        var column = column
        while column > 0 {
            letters = String(UnicodeScalar(UInt8(65 + (column - 1) % 26))) + letters
            column = (column - 1) / 26
        }
        return letters + String(row)
    }

    /// A row with its cells' XML.
    static func row(_ number: Int, _ cells: String, attributes: String = "") -> String {
        #"<row r="\#(number)"\#(attributes)>\#(cells)</row>"#
    }

    /// A cell: a number when the value is one, TRUE or FALSE as a boolean, empty as no
    /// cell, else an inline string.
    static func cell(_ reference: String, _ value: String, style: Int? = nil) -> String {
        let style = style.map { #" s="\#($0)""# } ?? ""
        if value.isEmpty { return "" }
        if Double(value) != nil { return #"<c r="\#(reference)"\#(style)><v>\#(value)</v></c>"# }
        if value == "TRUE" || value == "FALSE" { return #"<c r="\#(reference)"\#(style) t="b"><v>\#(value == "TRUE" ? 1 : 0)</v></c>"# }
        return #"<c r="\#(reference)"\#(style) t="inlineStr"><is><t>\#(escaped(value))</t></is></c>"#
    }

    /// A workbook built by hand as Excel writes one: [Content_Types].xml, the package's
    /// relationships, the workbook with its relationships, the sheets, and the shared
    /// strings and styles when given. `relationships` replaces the workbook's own.
    static func xlsx(
        _ sheets: [Sheet], sharedStrings: [String]? = nil, sharedStringsXML: String? = nil, styles: String? = nil,
        workbookProperties: String = "", relationships replaced: String? = nil, extraParts: [(name: String, text: String)] = []
    ) throws -> Data {
        var parts: [(name: String, text: String)] = [
            ("[Content_Types].xml", contentTypes("xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml")),
            ("_rels/.rels", relationships([("rId1", "officeDocument", "xl/workbook.xml")])),
        ]
        var rels: [(id: String, type: String, target: String)] = []
        var list = ""
        for (index, sheet) in sheets.enumerated() {
            let id = "rId\(index + 1)"
            rels.append((id, "worksheet", "worksheets/sheet\(index + 1).xml"))
            let state = sheet.state.map { #" state="\#($0)""# } ?? ""
            list += #"<sheet name="\#(escaped(sheet.name))" sheetId="\#(index + 1)"\#(state) r:id="\#(id)"/>"#
            parts.append(("xl/worksheets/sheet\(index + 1).xml", xmlHead
                + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
                + sheet.xml + "</worksheet>"))
        }
        if let sharedStrings = sharedStringsXML ?? sharedStrings.map({ strings in
            #"<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\#(strings.count)" uniqueCount="\#(strings.count)">"#
                + strings.map { "<si><t xml:space=\"preserve\">\(escaped($0))</t></si>" }.joined() + "</sst>"
        }) {
            rels.append(("rId\(sheets.count + 1)", "sharedStrings", "sharedStrings.xml"))
            parts.append(("xl/sharedStrings.xml", xmlHead + sharedStrings))
        }
        if let styles {
            rels.append(("rId\(sheets.count + 2)", "styles", "styles.xml"))
            parts.append(("xl/styles.xml", xmlHead + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"# + styles + "</styleSheet>"))
        }
        parts.append(("xl/_rels/workbook.xml.rels", replaced ?? relationships(rels)))
        parts.append(("xl/workbook.xml", xmlHead
            + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
            + workbookProperties + "<sheets>\(list)</sheets></workbook>"))
        return try zip(texts: parts + extraParts)
    }

    /// Styles with the default font and fill first, as Excel writes them, then the fonts,
    /// fills, number formats and cell formats given, each a run of XML elements.
    static func styles(numberFormats: String = "", fonts: [String] = [], fills: [String] = [], cellFormats: [String]) -> String {
        let allFonts = [#"<font><sz val="11"/><color theme="1"/><name val="Calibri"/></font>"#] + fonts
        let allFills = [#"<fill><patternFill patternType="none"/></fill>"#, #"<fill><patternFill patternType="gray125"/></fill>"#] + fills
        return (numberFormats.isEmpty ? "" : "<numFmts>\(numberFormats)</numFmts>")
            + #"<fonts count="\#(allFonts.count)">\#(allFonts.joined())</fonts>"#
            + #"<fills count="\#(allFills.count)">\#(allFills.joined())</fills>"#
            + #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0"/></cellStyleXfs>"#
            + #"<cellXfs count="\#(cellFormats.count + 1)"><xf numFmtId="0" fontId="0" fillId="0" xfId="0"/>\#(cellFormats.joined())</cellXfs>"#
    }

    /// A workbook of one sheet with a row for each line, in which a line that starts with
    /// "[white text] " is white on no fill, without the mark.
    static func xlsx(lines: [String], sheet: String = "Sheet1") throws -> Data {
        let mark = "[white text] "
        let rows = lines.enumerated().map { index, line in
            line.hasPrefix(mark)
                ? row(index + 1, cell("A\(index + 1)", String(line.dropFirst(mark.count)), style: 1))
                : row(index + 1, cell("A\(index + 1)", line))
        }
        return try xlsx(
            [Sheet(sheet, "<sheetData>" + rows.joined() + "</sheetData>")],
            styles: styles(fonts: [#"<font><sz val="11"/><color rgb="FFFFFFFF"/></font>"#], cellFormats: [#"<xf numFmtId="0" fontId="1" fillId="0" applyFont="1"/>"#]))
    }

    // MARK: pptx

    /// A slide of a deck: the XML of its shape tree, whether it shows, and its speaker
    /// notes, if any.
    struct Slide {
        var shapes: String
        var isShown = true
        var notes: String?
        /// The slide part's number in its name, slide<number>.xml, by default its place.
        var partNumber: Int?

        init(_ shapes: String, isShown: Bool = true, notes: String? = nil, partNumber: Int? = nil) {
            self.shapes = shapes
            self.isShown = isShown
            self.notes = notes
            self.partNumber = partNumber
        }
    }

    /// A run of a paragraph with its properties: a size in hundredths of a point, an RGB
    /// color, and an alpha in thousandths of a percent.
    static func run(_ text: String, size: Int? = nil, color: String? = nil, alpha: Int? = nil) -> String {
        let size = size.map { #" sz="\#($0)""# } ?? ""
        var fill = ""
        if let color {
            let alpha = alpha.map { #"<a:alpha val="\#($0)"/>"# } ?? ""
            fill = #"<a:solidFill><a:srgbClr val="\#(color)">\#(alpha)</a:srgbClr></a:solidFill>"#
        }
        return #"<a:r><a:rPr lang="en-US"\#(size)>\#(fill)</a:rPr><a:t>\#(escaped(text))</a:t></a:r>"#
    }

    /// A text shape with its paragraphs, each a run of runs' XML or plain text.
    static func shape(
        _ paragraphs: [String], placeholder: String? = nil, hidden: Bool = false, placement: (x: Int, y: Int, width: Int, height: Int)? = nil,
        fill: String? = nil, plain: Bool = true, id: Int = 2
    ) -> String {
        let hidden = hidden ? #" hidden="1""# : ""
        let placeholder = placeholder.map { #"<p:nvPr><p:ph type="\#($0)"/></p:nvPr>"# } ?? "<p:nvPr/>"
        let xfrm = placement.map { #"<a:xfrm><a:off x="\#($0.x)" y="\#($0.y)"/><a:ext cx="\#($0.width)" cy="\#($0.height)"/></a:xfrm>"# } ?? ""
        let fill = fill.map { #"<a:solidFill><a:srgbClr val="\#($0)"/></a:solidFill>"# } ?? ""
        let body = paragraphs.map { "<a:p>" + (plain ? run($0) : $0) + "</a:p>" }.joined()
        return #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="Shape \#(id)"\#(hidden)/><p:cNvSpPr/>\#(placeholder)</p:nvSpPr>"#
            + "<p:spPr>\(xfrm)\(fill)</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>\(body)</p:txBody></p:sp>"
    }

    /// A table in a frame, with a row of cells for each list.
    static func table(_ rows: [[String]]) -> String {
        #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="9" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>"#
            + #"<p:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl>"#
            + rows.map { cells in
                "<a:tr h=\"100\">" + cells.map { "<a:tc><a:txBody><a:bodyPr/><a:p>\(run($0))</a:p></a:txBody><a:tcPr/></a:tc>" }.joined() + "</a:tr>"
            }.joined()
            + "</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }

    private static let presentationNamespaces = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#

    /// A deck built by hand as PowerPoint writes one, with its slides in order, each slide's
    /// notes in a notes slide of its own, and the slide size given.
    static func pptx(_ slides: [Slide], size: (width: Int, height: Int) = (12_192_000, 6_858_000)) throws -> Data {
        var parts: [(name: String, text: String)] = [
            ("[Content_Types].xml", contentTypes("ppt/presentation.xml", "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml")),
            ("_rels/.rels", relationships([("rId1", "officeDocument", "ppt/presentation.xml")])),
        ]
        var rels: [(id: String, type: String, target: String)] = []
        var list = ""
        for (index, slide) in slides.enumerated() {
            let number = slide.partNumber ?? index + 1
            let id = "rId\(index + 2)"
            rels.append((id, "slide", "slides/slide\(number).xml"))
            list += #"<p:sldId id="\#(256 + index)" r:id="\#(id)"/>"#
            let show = slide.isShown ? "" : #" show="0""#
            parts.append(("ppt/slides/slide\(number).xml", xmlHead + #"<p:sld \#(presentationNamespaces)\#(show)><p:cSld><p:spTree>"#
                + #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"#
                + slide.shapes + "</p:spTree></p:cSld></p:sld>"))
            var slideRels: [(id: String, type: String, target: String)] = [("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]
            if let notes = slide.notes {
                slideRels.append(("rId2", "notesSlide", "../notesSlides/notesSlide\(number).xml"))
                parts.append(("ppt/notesSlides/notesSlide\(number).xml", xmlHead + #"<p:notes \#(presentationNamespaces)><p:cSld><p:spTree>"#
                    + #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"#
                    + shape(["\(number)"], placeholder: "sldNum", id: 4)
                    + shape(notes.components(separatedBy: "\n"), placeholder: "body", id: 3)
                    + "</p:spTree></p:cSld></p:notes>"))
            }
            parts.append(("ppt/slides/_rels/slide\(number).xml.rels", relationships(slideRels)))
        }
        parts.append(("ppt/_rels/presentation.xml.rels", relationships(rels)))
        parts.append(("ppt/presentation.xml", xmlHead + #"<p:presentation \#(presentationNamespaces)>"#
            + "<p:sldIdLst>\(list)</p:sldIdLst>"
            + #"<p:sldSz cx="\#(size.width)" cy="\#(size.height)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#))
        return try zip(texts: parts)
    }

    /// A deck of one slide with a paragraph for each line, in which a line that starts with
    /// "[white text] " is white on the shape's white fill, without the mark.
    static func pptx(lines: [String]) throws -> Data {
        let mark = "[white text] "
        let paragraphs = lines.map { line in
            line.hasPrefix(mark) ? run(String(line.dropFirst(mark.count)), color: "FFFFFF") : run(line, color: "000000")
        }
        return try pptx([Slide(shape(paragraphs, fill: "FFFFFF", plain: false))])
    }
}
