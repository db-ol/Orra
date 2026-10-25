import Foundation

/// The text a reader sees in an email, as plain text, and the text the email hides from
/// them.
///
/// HTML is read by a parser of its own, never by WebKit and never as an NSAttributedString,
/// so nothing loads and nothing runs. It builds the tree a browser builds, by the rules of
/// the HTML standard for misnested tags, tables, lists, selects and forms, so text lands
/// under the same elements and styles as in Mail.
///
/// It drops scripts, styles, comments and images, and text that a style hides: display
/// none, visibility hidden, content visibility hidden, a position off screen, clipped,
/// masked or scaled to nothing, a font under 3 points, an opacity or color alpha under 0.1,
/// and text in the color of what lies behind it, the page white unless a color is set. A
/// closed details element, a dialog that is not open, and the options of a select that it
/// does not show hide their text too.
///
/// The email's style sheets count with their full selectors, custom properties and math
/// functions such as calc(). Some rules only add hiding and never show text another rule
/// hides: rules for small screens, dark mode and other conditions, rules whose selector this
/// reader cannot match exactly, and animations. So text that any of them hides counts as
/// hidden. Their colors are not checked, except for a rule for the first line or letter,
/// which always applies to part of the text. Styles that Orra cannot see, from a
/// linked style sheet, @import or a web font, count as a hiddenStyle finding without a
/// piece. Links become their text, and quoted mail in a blockquote gets "> " in front of
/// its lines, as in plain text mail.
///
/// Each piece of hidden text is kept as a `Hidden` of its kind, so the window can show the
/// user what the email hides. Hidden text never goes into `text`. Comments and the alt or
/// title text of images are reported only when they hold at least four words, or for an
/// image of two pixels or less, since most emails carry short ones such as "Logo". SVG and
/// MathML text and the fallback text of objects are dropped without a finding. Plain text
/// bodies pass as they are. PromptHygiene finds what plain text hides.
nonisolated struct VisibleText: Sendable, Equatable {
    /// A piece of text the email hides, cut to `Limits.maximumHiddenLength` characters.
    nonisolated struct Hidden: Sendable, Equatable {
        var kind: ProjectsHiddenText
        var text: String
    }

    nonisolated struct Limits: Sendable, Equatable {
        /// Markup past this many bytes is not read.
        var maximumMarkupBytes = 4 << 20
        /// Elements nested deeper than this end the reading.
        var maximumDepth = 256
        /// Style rules past this many are not read.
        var maximumRules = 2_000
        /// Declarations past this many, over all style rules, are not read.
        var maximumDeclarations = 20_000
        /// Text past this many bytes is cut.
        var maximumTextBytes = 1 << 20
        /// Hidden pieces past this many are counted in `findings` but not kept.
        var maximumHiddenPieces = 20
        var maximumHiddenLength = 300
        /// Reading stops after this many steps: one per byte of markup, per token, per open
        /// element looked at, per node of the tree and per selector part tried, 4 per style
        /// rule that may apply to an element and 8 per declaration applied, which take
        /// longer. A hostile email so stops within about two seconds.
        var maximumSteps = 64 << 20
    }

    var text: String
    var hidden: [Hidden]
    /// The kinds of hidden text found, each once, in the order first found.
    var findings: [ProjectsHiddenText]
    /// Whether text was left out at a limit, here or in the message.
    var isCut: Bool
    var steps: Int

    /// The visible text of an HTML body.
    init(markup: String, limits: Limits = Limits()) {
        var reader = Reader(limits: limits)
        reader.read(markup)
        self.init(reader)
    }

    /// The visible text of every body of the message, in order, with a blank line between
    /// them.
    init(_ message: MIMEMessage, limits: Limits = Limits()) {
        var reader = Reader(limits: limits)
        for body in message.bodies {
            reader.output.breakLines(2)
            switch body.format {
            case .markup: reader.read(body.text)
            case .plain: reader.output.addPlain(body.text)
            }
        }
        if message.isCut { reader.isCut = true }
        self.init(reader)
    }

    /// Reads off the main actor, since a large newsletter takes a while and the keyboard
    /// tap runs on the main thread.
    @concurrent
    static func reading(_ message: MIMEMessage, limits: Limits = Limits()) async -> VisibleText {
        VisibleText(message, limits: limits)
    }

    private init(_ reader: Reader) {
        var reader = reader
        reader.hiddenText.finish()
        text = reader.output.finished
        hidden = reader.hiddenText.pieces
        findings = reader.hiddenText.findings
        isCut = reader.isCut || reader.output.isFull
        steps = reader.budget.steps
    }
}

// MARK: Reading

nonisolated extension VisibleText {
    /// The work a reading may take, in steps.
    private struct Budget {
        let maximum: Int
        private(set) var steps = 0
        private(set) var isSpent = false

        init(maximum: Int) {
            self.maximum = maximum
        }

        /// Counts work, and says false once there was too much.
        mutating func spend(_ count: Int = 1) -> Bool {
            steps += count
            if steps > maximum { isSpent = true }
            return !isSpent
        }
    }

    private struct Reader {
        let limits: Limits
        var output: Output
        var hiddenText: HiddenText
        var budget: Budget
        var isCut = false

        init(limits: Limits) {
            self.limits = limits
            output = Output(maximumBytes: limits.maximumTextBytes)
            hiddenText = HiddenText(maximumPieces: limits.maximumHiddenPieces, maximumLength: limits.maximumHiddenLength)
            budget = Budget(maximum: limits.maximumSteps)
        }

        /// Builds the tree of the markup, reads its style sheets and walks the tree.
        mutating func read(_ markup: String) {
            var bytes = Array(markup.utf8)
            if bytes.count > limits.maximumMarkupBytes {
                bytes.removeSubrange(limits.maximumMarkupBytes...)
                isCut = true
            }
            guard budget.spend(bytes.count) else {
                isCut = true
                return
            }
            var builder = TreeBuilder(bytes: bytes, limits: limits, budget: budget)
            builder.build()
            budget = builder.budget
            if builder.isCut { isCut = true }
            let document = builder.document

            var sheet = StyleSheet(limits: limits, quirks: document.quirks)
            for node in document.nodes.indices where document.nodes[node].kind == .element && document.nodes[node].name == "style" {
                let media = document.nodes[node].attributes["media"].map(MediaQuery.applies) ?? .always
                sheet.add(document.textContent(of: node), when: media)
            }
            if sheet.isCut { isCut = true }
            if document.loadsStyles || sheet.loadsStyles { hiddenText.flag(.hiddenStyle) }

            var renderer = Renderer(document: document, sheet: sheet, budget: budget)
            renderer.render(into: &output, hiddenText: &hiddenText)
            budget = renderer.budget
            if renderer.isCut { isCut = true }
        }
    }
}

// MARK: Output

nonisolated extension VisibleText {
    /// Plain text built from what the reader sees. White space collapses as in a browser,
    /// blocks start new lines, and every <br> is one line break, so a long run of them
    /// stays a long run of blank lines for PromptHygiene to find.
    private struct Output {
        let maximumBytes: Int
        private(set) var text = ""
        private(set) var isFull = false
        private var byteCount = 0
        private var lineHasText = false
        private var pendingSpace = false
        private var pendingBreaks = 0
        /// The text of the line so far while it is short, to keep the space of a "-- "
        /// signature line that white space collapsing would drop.
        private var shortLine: String? = ""

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        /// The text with spaces at the ends of lines and blank lines at its ends removed. A
        /// signature line "-- " keeps its space.
        var finished: String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    guard line != Self.signatureLine else { return line }
                    var line = line
                    while line.last == " " { line.removeLast() }
                    return line
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
        }

        static let signatureLine = "-- "

        static func isCollapsible(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case " ", "\t", "\n", "\r", "\u{0C}", "\u{A0}": true
            default: false
            }
        }

        /// At least `count` line breaks before the next text.
        mutating func breakLines(_ count: Int) {
            guard !text.isEmpty else { return }
            endLine()
            pendingBreaks = max(pendingBreaks, count)
            pendingSpace = false
        }

        /// A <br>: it ends a line with text, and makes an empty line after one without.
        mutating func lineBreak() {
            guard !text.isEmpty else { return }
            endLine()
            pendingBreaks = lineHasText && pendingBreaks == 0 ? 1 : min(pendingBreaks + 1, Self.maximumBreaks)
            pendingSpace = false
        }

        mutating func space() {
            if lineHasText, pendingBreaks == 0 { pendingSpace = true }
        }

        mutating func addCollapsing(_ text: String, quoteDepth: Int) {
            var segment = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                if Self.isCollapsible(scalar) {
                    add(String(segment), quoteDepth: quoteDepth)
                    segment.removeAll(keepingCapacity: true)
                    space()
                } else {
                    segment.append(scalar)
                }
            }
            add(String(segment), quoteDepth: quoteDepth)
        }

        mutating func addPreformatted(_ text: String, quoteDepth: Int) {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() {
                if number > 0 { forceBreak() }
                add(String(line), quoteDepth: quoteDepth)
            }
        }

        /// A plain text body, kept as it is.
        mutating func addPlain(_ text: String) {
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if number > 0 { forceBreak() }
                add(String(line), quoteDepth: 0)
            }
        }

        private mutating func forceBreak() {
            if text.isEmpty { return }
            endLine()
            pendingBreaks = min(pendingBreaks + 1, Self.maximumBreaks)
            pendingSpace = false
        }

        /// Keeps the space of a line that reads "-- " before it ends.
        private mutating func endLine() {
            if pendingSpace, pendingBreaks == 0, shortLine == "--", byteCount < maximumBytes {
                text += " "
                byteCount += 1
                shortLine = nil
            }
        }

        private mutating func add(_ segment: String, quoteDepth: Int) {
            guard !segment.isEmpty, !isFull else { return }
            var piece = ""
            if pendingBreaks > 0 {
                piece += String(repeating: "\n", count: pendingBreaks)
                pendingBreaks = 0
                lineHasText = false
                shortLine = ""
            } else if pendingSpace, lineHasText {
                piece += " "
                shortLine = nil
            }
            if !lineHasText, quoteDepth > 0 {
                piece += String(repeating: "> ", count: min(quoteDepth, 20))
                shortLine = nil
            }
            piece += segment
            let pieceBytes = piece.utf8.count
            if byteCount + pieceBytes > maximumBytes {
                isFull = true
                return
            }
            text += piece
            byteCount += pieceBytes
            lineHasText = true
            pendingSpace = false
            if let line = shortLine {
                shortLine = line.utf8.count + segment.utf8.count <= 2 ? line + segment : nil
            }
        }

        /// Line breaks in a row past this many count as this many. It is far more than
        /// PromptHygiene needs to see a long run.
        private static let maximumBreaks = 200
    }

    /// The pieces of hidden text and the kinds found.
    private struct HiddenText {
        let maximumPieces: Int
        let maximumLength: Int
        private(set) var pieces: [Hidden] = []
        private(set) var findings: [ProjectsHiddenText] = []
        private var current: (kind: ProjectsHiddenText, text: String)?

        init(maximumPieces: Int, maximumLength: Int) {
            self.maximumPieces = maximumPieces
            self.maximumLength = maximumLength
        }

        /// Hidden text from the markup. Pieces of one kind in a row join.
        mutating func add(_ kind: ProjectsHiddenText, _ text: String) {
            if current?.kind != kind {
                finish()
                current = (kind, "")
            }
            guard var piece = current?.text, piece.utf8.count < maximumLength * 8 else { return }
            if let last = piece.unicodeScalars.last, !Output.isCollapsible(last) { piece += " " }
            piece += text
            current?.text = piece
        }

        mutating func finish() {
            guard let piece = current else { return }
            current = nil
            report(piece.kind, piece.text, minimumWords: 1)
        }

        /// Keeps the text as a finding when it holds at least this many words.
        mutating func report(_ kind: ProjectsHiddenText, _ text: String, minimumWords: Int) {
            let words = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard Self.wordCount(words) >= minimumWords else { return }
            if !findings.contains(kind) { findings.append(kind) }
            if pieces.count < maximumPieces {
                pieces.append(Hidden(kind: kind, text: String(words.prefix(maximumLength))))
            }
        }

        /// A finding without a piece, for text that may be hidden in a way Orra cannot see.
        mutating func flag(_ kind: ProjectsHiddenText) {
            if !findings.contains(kind) { findings.append(kind) }
        }

        /// Words in other scripts, plus one for every two Chinese characters.
        static func wordCount(_ text: String) -> Int {
            var words = 0
            var chinese = 0
            var inWord = false
            for scalar in text.unicodeScalars {
                if ChineseText.isHan(scalar) {
                    chinese += 1
                    inWord = false
                } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                    if !inWord { words += 1 }
                    inWord = true
                } else {
                    inWord = false
                }
            }
            return words + (chinese + 1) / 2
        }
    }
}

// MARK: Tokens

nonisolated extension VisibleText {
    private struct Tag {
        var name: String
        /// By lowercase name. The first of a name counts, as in a browser.
        var attributes: [String: String] = [:]
        /// The attributes whose value holds a named character reference this reader does
        /// not know, so their value may differ from the one Mail reads.
        var unknownReferences: Set<String> = []
        var selfClosing = false
    }

    private enum Token {
        case text(Range<Int>)
        case start(Tag)
        case end(String)
        case comment(Range<Int>)
        case doctype(Range<Int>)
        /// The content of an element whose text is not markup, such as a script or a style.
        /// Its end follows as `rawEnd`.
        case raw(Range<Int>)
        case rawEnd
    }

    /// How the content of a raw element ends.
    private enum RawKind {
        /// At its end tag: style, xmp, iframe, noembed and noframes.
        case text
        /// At its end tag, with character references: title and textarea.
        case replaceable
        /// At its end tag outside the escaped parts that <!-- starts.
        case script
        /// Never: plaintext runs to the end.
        case plaintext
    }

    /// Splits markup into tokens as a browser's tokenizer does. The tree builder says when
    /// an element's content is raw text, as the HTML standard has it. Anything that is not
    /// a tag, a comment or a declaration is text, and a tag cut off by the end of the input
    /// is dropped.
    private struct Tokenizer {
        let bytes: [UInt8]
        private var index = 0
        private var raw: (name: [UInt8], kind: RawKind)?
        private var rawEndPending = false

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        /// Makes the next token the raw content of the element just started.
        mutating func readRaw(_ name: String, as kind: RawKind) {
            raw = (Array(name.utf8), kind)
        }

        mutating func next() -> Token? {
            if rawEndPending {
                rawEndPending = false
                return .rawEnd
            }
            if let pending = raw {
                raw = nil
                let start = index
                let end: (content: Int, resume: Int)
                switch pending.kind {
                case .plaintext: end = (bytes.count, bytes.count)
                case .script: end = Self.scriptEnd(bytes, from: index)
                case .text, .replaceable: end = Self.rawEnd(bytes, name: pending.name, from: index)
                }
                index = end.resume
                rawEndPending = true
                return .raw(start..<end.content)
            }
            let count = bytes.count
            while index < count {
                let textStart = index
                var cursor = index
                var markupStart: Int?
                while cursor < count, let open = bytes[cursor...].firstIndex(of: 0x3C) {
                    if Self.startsMarkup(bytes, at: open) {
                        markupStart = open
                        break
                    }
                    cursor = open + 1
                }
                guard let open = markupStart else {
                    index = count
                    return .text(textStart..<count)
                }
                if open > textStart {
                    index = open
                    return .text(textStart..<open)
                }
                if let token = markup(at: open) { return token }
                // Markup that makes no token, such as </>, or a tag the input ends inside.
            }
            return nil
        }

        /// Whether the < at `open` starts a tag, an end tag, a comment or a declaration.
        static func startsMarkup(_ bytes: [UInt8], at open: Int) -> Bool {
            guard open + 1 < bytes.count else { return false }
            let next = bytes[open + 1]
            if next == 0x21 || next == 0x3F || isLetter(next) { return true }
            return next == 0x2F && open + 2 < bytes.count
        }

        private mutating func markup(at open: Int) -> Token? {
            let count = bytes.count
            switch bytes[open + 1] {
            case 0x21:
                if Self.starts(bytes, at: open, with: "<!--") {
                    let contentStart = open + 4
                    if Self.starts(bytes, at: contentStart, with: ">") {
                        index = contentStart + 1
                        return .comment(contentStart..<contentStart)
                    }
                    if Self.starts(bytes, at: contentStart, with: "->") {
                        index = contentStart + 2
                        return .comment(contentStart..<contentStart)
                    }
                    let end = Self.commentEnd(bytes, from: contentStart)
                    index = end.resume
                    return .comment(contentStart..<end.content)
                }
                let end = Self.upTo(0x3E, in: bytes, from: open + 2)
                index = end.resume
                if Self.startsIgnoringCase(bytes, at: open + 2, with: "doctype") {
                    return .doctype(min(open + 9, end.content)..<end.content)
                }
                // CDATA and other declarations are bogus comments.
                return .comment((open + 2)..<end.content)
            case 0x3F:
                let end = Self.upTo(0x3E, in: bytes, from: open + 1)
                index = end.resume
                return .comment((open + 1)..<end.content)
            case 0x2F:
                let nameStart = open + 2
                if bytes[nameStart] == 0x3E {
                    index = nameStart + 1
                    return nil
                }
                guard Self.isLetter(bytes[nameStart]) else {
                    let end = Self.upTo(0x3E, in: bytes, from: nameStart)
                    index = end.resume
                    return .comment(nameStart..<end.content)
                }
                let nameEnd = Self.nameEnd(bytes, from: nameStart)
                // An end tag reads its attributes too, so a ">" in a quoted value does not
                // end it.
                guard let found = Self.attributes(bytes, from: nameEnd, keep: false) else {
                    index = count
                    return nil
                }
                index = found.end
                return .end(Self.lowercased(bytes[nameStart..<nameEnd]))
            default:
                let nameEnd = Self.nameEnd(bytes, from: open + 1)
                guard let found = Self.attributes(bytes, from: nameEnd, keep: true) else {
                    index = count
                    return nil
                }
                index = found.end
                return .start(Tag(
                    name: Self.lowercased(bytes[(open + 1)..<nameEnd]), attributes: found.attributes,
                    unknownReferences: found.unknown, selfClosing: found.selfClosing))
            }
        }

        static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
        }

        static func isLetter(_ byte: UInt8) -> Bool {
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }

        static func lowercasedByte(_ byte: UInt8) -> UInt8 {
            (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
        }

        static func lowercased(_ bytes: ArraySlice<UInt8>) -> String {
            String(decoding: bytes.map(lowercasedByte), as: UTF8.self)
        }

        static func starts(_ bytes: [UInt8], at index: Int, with text: StaticString) -> Bool {
            let pattern = UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount)
            guard index >= 0, index + pattern.count <= bytes.count else { return false }
            return bytes[index..<(index + pattern.count)].elementsEqual(pattern)
        }

        static func startsIgnoringCase(_ bytes: [UInt8], at index: Int, with text: StaticString) -> Bool {
            let pattern = UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount)
            guard index >= 0, index + pattern.count <= bytes.count else { return false }
            return bytes[index..<(index + pattern.count)].map(lowercasedByte).elementsEqual(pattern)
        }

        /// Where a tag name that starts at `start` ends.
        static func nameEnd(_ bytes: [UInt8], from start: Int) -> Int {
            var index = start
            while index < bytes.count, !isSpace(bytes[index]), bytes[index] != 0x2F, bytes[index] != 0x3E { index += 1 }
            return index
        }

        /// The end of the content up to the next `byte`, and the index after that byte, or
        /// the end of the input twice.
        static func upTo(_ byte: UInt8, in bytes: [UInt8], from start: Int) -> (content: Int, resume: Int) {
            guard start < bytes.count, let found = bytes[start...].firstIndex(of: byte) else { return (bytes.count, bytes.count) }
            return (found, found + 1)
        }

        /// A comment ends at --> or --!>, or else at the end of the input.
        static func commentEnd(_ bytes: [UInt8], from start: Int) -> (content: Int, resume: Int) {
            var index = start
            while index + 2 < bytes.count, let dash = bytes[index...].firstIndex(of: 0x2D) {
                guard dash + 2 < bytes.count else { break }
                if bytes[dash + 1] == 0x2D {
                    if bytes[dash + 2] == 0x3E { return (dash, dash + 3) }
                    if bytes[dash + 2] == 0x21, dash + 3 < bytes.count, bytes[dash + 3] == 0x3E { return (dash, dash + 4) }
                }
                index = dash + 1
            }
            return (bytes.count, bytes.count)
        }

        /// Reads the attributes of a tag from `start`, just after its name, to the ">" that
        /// ends it, as a browser does: quoted values may hold ">", and the first attribute
        /// of a name counts. Nil when the input ends inside the tag.
        static func attributes(_ bytes: [UInt8], from start: Int, keep: Bool)
            -> (attributes: [String: String], unknown: Set<String>, selfClosing: Bool, end: Int)?
        {
            let count = bytes.count
            var index = start
            var attributes: [String: String] = [:]
            var unknown: Set<String> = []
            var selfClosing = false
            while true {
                while index < count, isSpace(bytes[index]) { index += 1 }
                guard index < count else { return nil }
                if bytes[index] == 0x3E { return (attributes, unknown, selfClosing, index + 1) }
                if bytes[index] == 0x2F {
                    index += 1
                    selfClosing = index < count && bytes[index] == 0x3E
                    continue
                }
                selfClosing = false
                let nameStart = index
                index += 1
                while index < count, !isSpace(bytes[index]), bytes[index] != 0x2F, bytes[index] != 0x3E, bytes[index] != 0x3D { index += 1 }
                let nameEnd = index
                while index < count, isSpace(bytes[index]) { index += 1 }
                var value: Range<Int>?
                if index < count, bytes[index] == 0x3D {
                    index += 1
                    while index < count, isSpace(bytes[index]) { index += 1 }
                    guard index < count else { return nil }
                    let quote = bytes[index]
                    if quote == 0x22 || quote == 0x27 {
                        guard let close = bytes[(index + 1)...].firstIndex(of: quote) else { return nil }
                        value = (index + 1)..<close
                        index = close + 1
                    } else {
                        let valueStart = index
                        while index < count, !isSpace(bytes[index]), bytes[index] != 0x3E { index += 1 }
                        value = valueStart..<index
                    }
                }
                guard keep, attributes.count < maximumAttributes else { continue }
                let name = lowercased(bytes[nameStart..<nameEnd])
                guard attributes[name] == nil else { continue }
                if let value {
                    let decoded = Entities.decoded(bytes[value.lowerBound..<min(value.upperBound, value.lowerBound + maximumValueBytes)], inAttribute: true)
                    attributes[name] = decoded.text
                    if decoded.hasUnknown { unknown.insert(name) }
                } else {
                    attributes[name] = ""
                }
            }
        }

        private static let maximumAttributes = 64
        private static let maximumValueBytes = 64 << 10

        /// Where the end tag of `name` that starts at `open` ends, or nil when none starts
        /// there. The end of the input ends an end tag that is cut off.
        static func endTag(_ bytes: [UInt8], at open: Int, name: [UInt8]) -> Int? {
            let nameStart = open + 2
            let nameEnd = nameStart + name.count
            guard nameEnd < bytes.count, bytes[open + 1] == 0x2F else { return nil }
            for offset in 0..<name.count where lowercasedByte(bytes[nameStart + offset]) != name[offset] { return nil }
            let delimiter = bytes[nameEnd]
            guard isSpace(delimiter) || delimiter == 0x2F || delimiter == 0x3E else { return nil }
            return attributes(bytes, from: nameEnd, keep: false)?.end ?? bytes.count
        }

        /// Where the content of a raw element ends, at its end tag, and the index after that
        /// tag. Without an end tag the content runs to the end.
        static func rawEnd(_ bytes: [UInt8], name: [UInt8], from start: Int) -> (content: Int, resume: Int) {
            var index = start
            while index < bytes.count, let open = bytes[index...].firstIndex(of: 0x3C) {
                if let end = endTag(bytes, at: open, name: name) { return (open, end) }
                index = open + 1
            }
            return (bytes.count, bytes.count)
        }

        /// Where a script ends, by the script states of the HTML standard: <!-- starts an
        /// escaped part, in which <script> starts a part that only </script> ends, so
        /// "<!--<script></script>" does not end the script.
        static func scriptEnd(_ bytes: [UInt8], from start: Int) -> (content: Int, resume: Int) {
            let name = Array("script".utf8)
            let count = bytes.count
            func isNamed(_ index: Int) -> Bool {
                guard index + name.count < count else { return false }
                for offset in 0..<name.count where lowercasedByte(bytes[index + offset]) != name[offset] { return false }
                let delimiter = bytes[index + name.count]
                return isSpace(delimiter) || delimiter == 0x2F || delimiter == 0x3E
            }
            var state = 0 // 0 plain, 1 escaped, 2 double escaped
            var dashes = 0
            var index = start
            while index < count {
                let byte = bytes[index]
                if byte == 0x2D {
                    dashes += 1
                    index += 1
                    continue
                }
                if byte == 0x3E {
                    if state != 0, dashes >= 2 { state = 0 }
                    dashes = 0
                    index += 1
                    continue
                }
                dashes = 0
                guard byte == 0x3C else {
                    index += 1
                    continue
                }
                switch state {
                case 0:
                    if let end = endTag(bytes, at: index, name: name) { return (index, end) }
                    if starts(bytes, at: index, with: "<!--") {
                        state = 1
                        dashes = 2
                        index += 4
                        continue
                    }
                case 1:
                    if let end = endTag(bytes, at: index, name: name) { return (index, end) }
                    if isNamed(index + 1) {
                        state = 2
                        index += 1 + name.count
                        continue
                    }
                default:
                    if index + 1 < count, bytes[index + 1] == 0x2F, isNamed(index + 2) {
                        state = 1
                        index += 2 + name.count
                        continue
                    }
                }
                index += 1
            }
            return (count, count)
        }
    }

    /// HTML character references: numeric ones, the Latin-1 names, every name of an ASCII
    /// character and the common typographic ones.
    private enum Entities {
        static func text(_ bytes: ArraySlice<UInt8>) -> String {
            decoded(bytes).text
        }

        /// The text with its references decoded. In an attribute, a name without its
        /// semicolon stays as it is before = or a letter or digit, as in a browser.
        /// `hasUnknown` says whether a name with a semicolon that this reader does not know
        /// stayed in the text, which a browser may know.
        static func decoded(_ bytes: ArraySlice<UInt8>, inAttribute: Bool = false) -> (text: String, hasUnknown: Bool) {
            guard bytes.contains(0x26) else { return (String(decoding: bytes, as: UTF8.self), false) }
            var result: [UInt8] = []
            result.reserveCapacity(bytes.count)
            var hasUnknown = false
            var index = bytes.startIndex
            while index < bytes.endIndex {
                guard bytes[index] == 0x26 else {
                    result.append(bytes[index])
                    index += 1
                    continue
                }
                let found = reference(bytes, at: index, inAttribute: inAttribute)
                if found.unknown { hasUnknown = true }
                if let text = found.text {
                    result += text.utf8
                    index = found.end
                } else {
                    result.append(bytes[index])
                    index += 1
                }
            }
            return (String(decoding: result, as: UTF8.self), hasUnknown)
        }

        private static func reference(_ bytes: ArraySlice<UInt8>, at start: Int, inAttribute: Bool) -> (text: String?, end: Int, unknown: Bool) {
            var index = start + 1
            guard index < bytes.endIndex else { return (nil, start, false) }
            if bytes[index] == 0x23 {
                index += 1
                let hex = index < bytes.endIndex && bytes[index] | 0x20 == 0x78
                if hex { index += 1 }
                var value: UInt32 = 0
                var digits = 0
                while index < bytes.endIndex {
                    let byte = bytes[index]
                    let digit: UInt32
                    switch byte {
                    case 0x30...0x39: digit = UInt32(byte - 0x30)
                    case 0x61...0x66 where hex: digit = UInt32(byte - 0x61 + 10)
                    case 0x41...0x46 where hex: digit = UInt32(byte - 0x41 + 10)
                    default: digit = 99
                    }
                    guard digit != 99 else { break }
                    // Past the last code point the value only needs to stay too large.
                    value = min(value * (hex ? 16 : 10) + digit, 0x110000)
                    digits += 1
                    index += 1
                }
                guard digits > 0 else { return (nil, start, false) }
                if index < bytes.endIndex, bytes[index] == 0x3B { index += 1 }
                return (String(scalar(value)), index, false)
            }
            let nameStart = index
            while index < bytes.endIndex, index - nameStart < 40,
                  Tokenizer.isLetter(bytes[index]) || (0x30...0x39).contains(bytes[index]) { index += 1 }
            guard index > nameStart else { return (nil, start, false) }
            let name = String(decoding: bytes[nameStart..<index], as: UTF8.self)
            let hasSemicolon = index < bytes.endIndex && bytes[index] == 0x3B
            if hasSemicolon, let value = named[name] { return (value, index + 1, false) }
            let unknown = hasSemicolon
            // The longest name a browser reads without its semicolon.
            for length in stride(from: min(name.utf8.count, 6), through: 2, by: -1) {
                let prefix = String(name.prefix(length))
                guard legacy.contains(prefix), let value = named[prefix] else { continue }
                let after = nameStart + length
                if inAttribute, after < bytes.endIndex {
                    let next = bytes[after]
                    if next == 0x3D || Tokenizer.isLetter(next) || (0x30...0x39).contains(next) { return (nil, start, unknown) }
                }
                return (value, after, unknown)
            }
            return (nil, start, unknown)
        }

        /// The character a numeric reference names, as a browser reads it.
        private static func scalar(_ value: UInt32) -> Unicode.Scalar {
            if (0x80...0x9F).contains(value), let mapped = windows1252[value], let scalar = Unicode.Scalar(mapped) { return scalar }
            guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
            return scalar
        }

        /// What numeric references from 0x80 to 0x9F name: the Windows-1252 characters.
        private static let windows1252: [UInt32: UInt32] = [
            0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
            0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
            0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
            0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
        ]

        /// The Latin-1 names, which a browser also reads without the semicolon.
        private static let latin1 = """
            nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 \
            acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde \
            Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc \
            Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml \
            aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute ocirc \
            otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
            """.split(separator: " ")

        private static let legacy: Set<String> = Set(latin1.map(String.init)).union(["amp", "lt", "gt", "quot", "AMP", "LT", "GT", "QUOT", "COPY", "REG"])

        private static let named: [String: String] = {
            var table: [String: String] = [:]
            // U+00A0 to U+00FF in order.
            for (offset, name) in latin1.enumerated() {
                table[String(name)] = String(Unicode.Scalar(UInt8(0xA0 + offset)))
            }
            let others = """
                Tab 9 NewLine 10 excl 33 quot 34 QUOT 34 num 35 dollar 36 percnt 37 amp 38 AMP 38 apos 39 lpar 40 \
                rpar 41 ast 42 midast 42 plus 43 comma 44 period 46 sol 47 colon 58 semi 59 lt 60 LT 60 equals 61 \
                gt 62 GT 62 quest 63 commat 64 lsqb 91 lbrack 91 bsol 92 rsqb 93 rbrack 93 Hat 94 lowbar 95 \
                UnderBar 95 grave 96 DiacriticalGrave 96 lcub 123 lbrace 123 verbar 124 vert 124 VerticalLine 124 \
                rcub 125 rbrace 125 COPY 169 REG 174 NonBreakingSpace 160 \
                OElig 338 oelig 339 Scaron 352 scaron 353 Yuml 376 fnof 402 circ 710 \
                tilde 732 ensp 8194 emsp 8195 emsp13 8196 emsp14 8197 numsp 8199 puncsp 8200 thinsp 8201 \
                ThinSpace 8201 hairsp 8202 VeryThinSpace 8202 ZeroWidthSpace 8203 NegativeVeryThinSpace 8203 \
                NegativeThinSpace 8203 NegativeMediumSpace 8203 NegativeThickSpace 8203 zwnj 8204 zwj 8205 \
                lrm 8206 rlm 8207 hyphen 8208 dash 8208 ndash 8211 mdash 8212 \
                lsquo 8216 rsquo 8217 sbquo 8218 ldquo 8220 rdquo 8221 bdquo 8222 dagger 8224 Dagger 8225 bull 8226 \
                nldr 8229 hellip 8230 permil 8240 prime 8242 Prime 8243 lsaquo 8249 rsaquo 8250 oline 8254 \
                frasl 8260 MediumSpace 8287 NoBreak 8288 af 8289 ApplyFunction 8289 it 8290 InvisibleTimes 8290 \
                ic 8291 InvisibleComma 8291 euro 8364 \
                trade 8482 larr 8592 uarr 8593 rarr 8594 darr 8595 harr 8596 minus 8722 infin 8734 ne 8800 le 8804 \
                ge 8805 hearts 9829 check 10003
                """.split(separator: " ")
            for pair in stride(from: 0, to: others.count - 1, by: 2) {
                if let value = UInt32(others[pair + 1]), let scalar = Unicode.Scalar(value) {
                    table[String(others[pair])] = String(scalar)
                }
            }
            table["fjlig"] = "fj"
            return table
        }()
    }
}

// MARK: Tree

nonisolated extension VisibleText {
    private struct Node {
        enum Kind: UInt8 {
            case element
            /// Text with character references still in it.
            case text
            /// The content of a raw element, as it is.
            case rawText
            case comment
        }

        var kind: Kind
        var name = ""
        var attributes: [String: String] = [:]
        var unknownReferences: Set<String> = []
        /// The class names, as written and in lowercase.
        var classes: [String] = []
        var lowercaseClasses: [String] = []
        var range: Range<Int> = 0..<0
        var parent: Int32 = -1
        var first: Int32 = -1
        var last: Int32 = -1
        var next: Int32 = -1
        var previous: Int32 = -1
        /// In SVG or MathML, outside an element that holds HTML.
        var isForeign = false
        /// On the stack of open elements.
        var isOpen = false

        init(kind: Kind) {
            self.kind = kind
        }

        init(element tag: Tag, isForeign: Bool = false) {
            kind = .element
            name = tag.name
            attributes = tag.attributes
            unknownReferences = tag.unknownReferences
            self.isForeign = isForeign
            classes = Self.classes(attributes["class"])
            lowercaseClasses = classes.map { $0.lowercased() }
        }

        static func classes(_ value: String?) -> [String] {
            value.map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0C}" }).map(String.init) } ?? []
        }

        var tag: Tag {
            Tag(name: name, attributes: attributes, unknownReferences: unknownReferences)
        }
    }

    /// The tree of an HTML body: the html element at 0 with its head at 1 and body at 2.
    private struct Document {
        let bytes: [UInt8]
        var nodes: [Node] = []
        /// Quirks mode, as for markup without a doctype, which most email is.
        var quirks = true
        /// A linked style sheet, which Orra never loads but Mail may.
        var loadsStyles = false

        static let root = 0
        static let head = 1
        static let body = 2

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func add(_ node: Node) -> Int {
            nodes.append(node)
            return nodes.count - 1
        }

        func parent(_ node: Int) -> Int? {
            let parent = nodes[node].parent
            return parent < 0 ? nil : Int(parent)
        }

        mutating func append(_ child: Int, to parent: Int) {
            detach(child)
            let last = nodes[parent].last
            nodes[child].parent = Int32(parent)
            nodes[child].previous = last
            nodes[child].next = -1
            if last >= 0 { nodes[Int(last)].next = Int32(child) } else { nodes[parent].first = Int32(child) }
            nodes[parent].last = Int32(child)
        }

        mutating func insert(_ child: Int, before sibling: Int) {
            guard let parent = parent(sibling) else { return }
            detach(child)
            let previous = nodes[sibling].previous
            nodes[child].parent = Int32(parent)
            nodes[child].previous = previous
            nodes[child].next = Int32(sibling)
            nodes[sibling].previous = Int32(child)
            if previous >= 0 { nodes[Int(previous)].next = Int32(child) } else { nodes[parent].first = Int32(child) }
        }

        mutating func detach(_ node: Int) {
            guard let parent = parent(node) else { return }
            let previous = nodes[node].previous
            let next = nodes[node].next
            if previous >= 0 { nodes[Int(previous)].next = next } else { nodes[parent].first = next }
            if next >= 0 { nodes[Int(next)].previous = previous } else { nodes[parent].last = previous }
            nodes[node].parent = -1
            nodes[node].previous = -1
            nodes[node].next = -1
        }

        /// Moves every child of one node to the end of another, and says how many moved.
        mutating func moveChildren(of source: Int, to target: Int) -> Int {
            var moved = 0
            while nodes[source].first >= 0 {
                append(Int(nodes[source].first), to: target)
                moved += 1
            }
            return moved
        }

        func isElement(_ node: Int, _ name: String) -> Bool {
            nodes[node].kind == .element && !nodes[node].isForeign && nodes[node].name == name
        }

        func parentElement(_ node: Int) -> Int? {
            guard let parent = parent(node), nodes[parent].kind == .element else { return nil }
            return parent
        }

        func previousElement(_ node: Int) -> Int? {
            var sibling = nodes[node].previous
            while sibling >= 0 {
                if nodes[Int(sibling)].kind == .element { return Int(sibling) }
                sibling = nodes[Int(sibling)].previous
            }
            return nil
        }

        func nextElement(_ node: Int) -> Int? {
            var sibling = nodes[node].next
            while sibling >= 0 {
                if nodes[Int(sibling)].kind == .element { return Int(sibling) }
                sibling = nodes[Int(sibling)].next
            }
            return nil
        }

        /// The text of a text node, with its references decoded, or of raw content.
        func text(of node: Int, decodingRaw: Bool = false) -> String {
            let slice = bytes[nodes[node].range]
            return nodes[node].kind == .text || decodingRaw ? Entities.text(slice) : String(decoding: slice, as: UTF8.self)
        }

        /// The text of an element's descendants, as a style element holds its style sheet.
        func textContent(of element: Int) -> String {
            var result = ""
            var pending = [element]
            var visited = 0
            while let node = pending.popLast(), visited < Self.maximumContentNodes {
                visited += 1
                switch nodes[node].kind {
                case .text, .rawText: result += text(of: node)
                case .comment: break
                case .element:
                    var child = nodes[node].last
                    while child >= 0 {
                        pending.append(Int(child))
                        child = nodes[Int(child)].previous
                    }
                }
            }
            return result
        }

        private static let maximumContentNodes = 10_000
    }

    /// Builds the tree a browser builds from the tokens, by the tree construction rules of
    /// the HTML standard: the stack of open elements and its scopes, the active formatting
    /// elements and the adoption agency for misnested tags, implied end tags, tables and
    /// their foster parenting, selects, and the attributes of later html and body tags.
    /// Head and template rules are simpler, since nothing in them shows.
    private struct TreeBuilder {
        private(set) var document: Document
        private(set) var budget: Budget
        private(set) var isCut = false
        private var tokenizer: Tokenizer
        private let limits: Limits
        private var stack: [Int] = []
        /// The active formatting elements, with `marker` between the scopes of cells,
        /// captions, applets, marquees, objects and templates.
        private var active: [Int] = []
        private var mode = Mode.beforeBody
        /// The modes of the open templates, whose content may hold table parts.
        private var templateModes: [Mode] = []
        private var formElement: Int?
        private var fosterParenting = false
        private var skipNewline = false
        private var sawContent = false
        private var inHeadNoscript = false
        private var stopped = false

        private enum Mode {
            case beforeBody, inBody, inTable, inTableBody, inRow, inCell, inCaption, inColumnGroup, inSelect, inSelectInTable
            case inTemplate
        }

        private static let marker = -1

        init(bytes: [UInt8], limits: Limits, budget: Budget) {
            document = Document(bytes: bytes)
            tokenizer = Tokenizer(bytes: bytes)
            self.limits = limits
            self.budget = budget
            let root = document.add(Node(element: Tag(name: "html")))
            let head = document.add(Node(element: Tag(name: "head")))
            let body = document.add(Node(element: Tag(name: "body")))
            document.append(head, to: root)
            document.append(body, to: root)
            push(root)
        }

        var bytes: [UInt8] { document.bytes }

        mutating func build() {
            while !stopped {
                guard budget.spend() else {
                    cut()
                    break
                }
                guard let token = tokenizer.next() else { break }
                let skip = skipNewline
                skipNewline = false
                process(token, skipNewline: skip)
            }
            if stopped { readStylesAfterCut() }
        }

        private mutating func cut() {
            isCut = true
            stopped = true
        }

        /// After a cut, the rest of the markup is only read for its style elements and for
        /// the attributes of html and body, which style text before the cut too.
        private mutating func readStylesAfterCut() {
            while let token = tokenizer.next() {
                if case .raw(let range) = token, let current, document.isElement(current, "style") {
                    var content = Node(kind: .rawText)
                    content.range = range
                    document.append(document.add(content), to: current)
                }
                guard case .start(let tag) = token else { continue }
                switch tag.name {
                case "html": mergeAttributes(tag, into: Document.root)
                case "body": mergeAttributes(tag, into: Document.body)
                case "link": noteStyleSheet(tag)
                case "style":
                    tokenizer.readRaw(tag.name, as: .text)
                    if case .raw(let range) = tokenizer.next() {
                        let style = document.add(Node(element: tag))
                        var content = Node(kind: .rawText)
                        content.range = range
                        document.append(document.add(content), to: style)
                    }
                case "script": tokenizer.readRaw(tag.name, as: .script)
                case "title", "textarea": tokenizer.readRaw(tag.name, as: .replaceable)
                case "xmp", "iframe", "noembed", "noframes": tokenizer.readRaw(tag.name, as: .text)
                case "plaintext": return
                default: break
                }
            }
        }

        // MARK: Dispatch

        private mutating func process(_ token: Token, skipNewline: Bool = false) {
            switch token {
            case .raw(let range):
                var range = range
                if let current, document.isElement(current, "textarea"), range.first.map({ bytes[$0] == 0x0A }) == true {
                    range = (range.lowerBound + 1)..<range.upperBound
                }
                insertText(range, kind: .rawText)
                return
            case .rawEnd:
                pop()
                return
            case .doctype(let range):
                if mode == .beforeBody, !sawContent { document.quirks = Self.isQuirks(bytes[range]) }
                return
            default:
                break
            }
            if mode != .beforeBody, isForeignContext(for: token) {
                foreignContent(token)
                return
            }
            switch mode {
            case .beforeBody: beforeBody(token)
            case .inBody: inBody(token, skipNewline: skipNewline)
            case .inTable: inTable(token)
            case .inTableBody: inTableBody(token)
            case .inRow: inRow(token)
            case .inCell: inCell(token)
            case .inCaption: inCaption(token)
            case .inColumnGroup: inColumnGroup(token)
            case .inSelect: inSelect(token)
            case .inSelectInTable: inSelectInTable(token)
            case .inTemplate: inTemplate(token)
            }
        }

        private var current: Int? { stack.last }

        private func currentIs(_ name: String) -> Bool {
            current.map { document.isElement($0, name) } ?? false
        }

        private func isAllSpace(_ range: Range<Int>) -> Bool {
            !bytes[range].contains { !Tokenizer.isSpace($0) }
        }

        // MARK: Before the body

        private mutating func beforeBody(_ token: Token) {
            switch token {
            case .text(let range):
                guard let first = range.first(where: { !Tokenizer.isSpace(bytes[$0]) }) else { return }
                startBody()
                process(.text(first..<range.upperBound))
            case .comment(let range):
                insertComment(range)
            case .start(let tag):
                sawContent = true
                if inHeadNoscript, !["link", "meta", "noframes", "style", "basefont", "bgsound"].contains(tag.name) { inHeadNoscript = false }
                switch tag.name {
                case "html": mergeAttributes(tag, into: Document.root)
                case "head": break
                case "base", "basefont", "bgsound", "link", "meta":
                    noteStyleSheet(tag)
                    document.append(document.add(Node(element: tag)), to: Document.head)
                case "title": insertInHead(tag, raw: .replaceable)
                case "style", "noframes": insertInHead(tag, raw: .text)
                case "script": insertInHead(tag, raw: .script)
                case "noscript" where !inHeadNoscript:
                    // Mail runs no scripts, so a noscript in the head holds head elements,
                    // and anything else ends it.
                    document.append(document.add(Node(element: tag)), to: Document.head)
                    inHeadNoscript = true
                case "template":
                    let node = document.add(Node(element: tag))
                    document.append(node, to: Document.head)
                    push(node)
                    active.append(Self.marker)
                    mode = .inTemplate
                    templateModes.append(.inTemplate)
                case "body":
                    startBody()
                    mergeAttributes(tag, into: Document.body)
                default:
                    startBody()
                    process(token)
                }
            case .end(let name):
                sawContent = true
                if name == "noscript" { inHeadNoscript = false }
                if ["body", "html", "br"].contains(name) {
                    startBody()
                    process(token)
                }
            default:
                break
            }
        }

        private mutating func insertInHead(_ tag: Tag, raw: RawKind) {
            let node = document.add(Node(element: tag))
            document.append(node, to: Document.head)
            push(node)
            tokenizer.readRaw(tag.name, as: raw)
        }

        private mutating func startBody() {
            while stack.count > 1 { pop() }
            push(Document.body)
            mode = .inBody
        }

        // MARK: In body

        private mutating func inBody(_ token: Token, skipNewline: Bool = false) {
            switch token {
            case .text(var range):
                if skipNewline, bytes[range.lowerBound] == 0x0A {
                    range = (range.lowerBound + 1)..<range.upperBound
                } else if skipNewline, bytes[range.lowerBound] == 0x0D {
                    let after = range.lowerBound + 1
                    range = (after < range.upperBound && bytes[after] == 0x0A ? after + 1 : after)..<range.upperBound
                }
                guard !range.isEmpty else { return }
                reconstructFormatting()
                insertText(range, kind: .text)
            case .comment(let range):
                insertComment(range)
            case .start(let tag):
                startTagInBody(tag)
            case .end(let name):
                endTagInBody(name)
            default:
                break
            }
        }

        private mutating func startTagInBody(_ tag: Tag) {
            let name = tag.name
            switch name {
            case "html":
                mergeAttributes(tag, into: Document.root)
            case "base", "basefont", "bgsound", "link", "meta":
                noteStyleSheet(tag)
                insertVoid(tag)
            case "style", "noframes", "script", "title", "template":
                headElement(tag)
            case "body":
                if stack.count > 1, stack[1] == Document.body, !stackHas("template") { mergeAttributes(tag, into: Document.body) }
            case "frameset", "caption", "col", "colgroup", "frame", "head", "tbody", "td", "tfoot", "th", "thead", "tr":
                break
            case _ where Self.closesParagraph.contains(name):
                closeParagraphInButtonScope()
                insertElement(tag)
            case _ where Self.headings.contains(name):
                closeParagraphInButtonScope()
                if let current, Self.headings.contains(document.nodes[current].name), !document.nodes[current].isForeign { pop() }
                insertElement(tag)
            case "pre", "listing":
                closeParagraphInButtonScope()
                insertElement(tag)
                skipNewline = true
            case "form":
                if formElement != nil, !stackHas("template") { return }
                closeParagraphInButtonScope()
                if let node = insertElement(tag), !stackHas("template") { formElement = node }
            case "li", "dd", "dt":
                let names: Set<String> = name == "li" ? ["li"] : ["dd", "dt"]
                for index in stack.indices.reversed() {
                    guard budget.spend() else { return cut() }
                    let node = stack[index]
                    if !document.nodes[node].isForeign, names.contains(document.nodes[node].name) {
                        let found = document.nodes[node].name
                        generateImpliedEndTags(except: found)
                        popUntil(found)
                        break
                    }
                    if isSpecial(node), !["address", "div", "p"].contains(document.nodes[node].name) { break }
                }
                closeParagraphInButtonScope()
                insertElement(tag)
            case "plaintext":
                closeParagraphInButtonScope()
                if insertElement(tag) != nil { tokenizer.readRaw(name, as: .plaintext) }
            case "button":
                if inScope("button") {
                    generateImpliedEndTags()
                    popUntil("button")
                }
                reconstructFormatting()
                insertElement(tag)
            case "a":
                if let index = lastFormatting(named: "a") {
                    let element = active[index]
                    if !adoptionAgency("a") { anyOtherEndTag("a") }
                    if let left = active.firstIndex(of: element) { active.remove(at: left) }
                    if let open = stack.firstIndex(of: element) { removeFromStack(at: open) }
                }
                reconstructFormatting()
                insertFormatting(tag)
            case "nobr":
                reconstructFormatting()
                if inScope("nobr") {
                    if !adoptionAgency("nobr") { anyOtherEndTag("nobr") }
                    reconstructFormatting()
                }
                insertFormatting(tag)
            case _ where Self.formatting.contains(name):
                reconstructFormatting()
                insertFormatting(tag)
            case "applet", "marquee", "object":
                reconstructFormatting()
                if insertElement(tag) != nil { active.append(Self.marker) }
            case "table":
                if !document.quirks { closeParagraphInButtonScope() }
                if insertElement(tag) != nil { mode = .inTable }
            case "area", "br", "embed", "img", "keygen", "wbr", "input":
                reconstructFormatting()
                insertVoid(tag)
            case "image":
                reconstructFormatting()
                var image = tag
                image.name = "img"
                insertVoid(image)
            case "param", "source", "track":
                insertVoid(tag)
            case "hr":
                closeParagraphInButtonScope()
                insertVoid(tag)
            case "textarea":
                if insertElement(tag) != nil { tokenizer.readRaw(name, as: .replaceable) }
            case "xmp":
                closeParagraphInButtonScope()
                reconstructFormatting()
                if insertElement(tag) != nil { tokenizer.readRaw(name, as: .text) }
            case "iframe", "noembed":
                if insertElement(tag) != nil { tokenizer.readRaw(name, as: .text) }
            case "select":
                reconstructFormatting()
                if insertElement(tag) != nil {
                    switch mode {
                    case .inTable, .inCaption, .inTableBody, .inRow, .inCell: mode = .inSelectInTable
                    default: mode = .inSelect
                    }
                }
            case "optgroup", "option":
                if currentIs("option") { pop() }
                reconstructFormatting()
                insertElement(tag)
            case "rb", "rtc":
                if inScope("ruby") { generateImpliedEndTags() }
                insertElement(tag)
            case "rp", "rt":
                if inScope("ruby") { generateImpliedEndTags(except: "rtc") }
                insertElement(tag)
            case "math", "svg":
                reconstructFormatting()
                if insertElement(tag, isForeign: true) != nil, tag.selfClosing { pop() }
            default:
                reconstructFormatting()
                insertElement(tag)
            }
        }

        /// Elements the head may hold, wherever they start.
        private mutating func headElement(_ tag: Tag) {
            switch tag.name {
            case "template":
                guard insertElement(tag) != nil else { return }
                active.append(Self.marker)
                mode = .inTemplate
                templateModes.append(.inTemplate)
            case "script":
                if insertElement(tag) != nil { tokenizer.readRaw(tag.name, as: .script) }
            case "title":
                if insertElement(tag) != nil { tokenizer.readRaw(tag.name, as: .replaceable) }
            default:
                if insertElement(tag) != nil { tokenizer.readRaw(tag.name, as: .text) }
            }
        }

        private mutating func endTagInBody(_ name: String) {
            switch name {
            case "template":
                endTemplate()
            case "body", "html":
                // The body stays open for any text that follows, as in a browser.
                break
            case _ where Self.blockEnds.contains(name):
                guard inScope(name) else { return }
                generateImpliedEndTags()
                popUntil(name)
            case "form":
                if stackHas("template") {
                    guard inScope("form") else { return }
                    generateImpliedEndTags()
                    popUntil("form")
                    return
                }
                let node = formElement
                formElement = nil
                guard let node, inScope(element: node) else { return }
                generateImpliedEndTags()
                if let index = stack.lastIndex(of: node) { removeFromStack(at: index) }
            case "p":
                if !inScope("p", .button) { insertElement(Tag(name: "p")) }
                closeParagraph()
            case "li":
                guard inScope("li", .listItem) else { return }
                generateImpliedEndTags(except: "li")
                popUntil("li")
            case "dd", "dt":
                guard inScope(name) else { return }
                generateImpliedEndTags(except: name)
                popUntil(name)
            case _ where Self.headings.contains(name):
                guard Self.headings.contains(where: { inScope($0) }) else { return }
                generateImpliedEndTags()
                while stack.count > 1, let node = current {
                    pop()
                    if !document.nodes[node].isForeign, Self.headings.contains(document.nodes[node].name) { break }
                }
            case _ where Self.formatting.contains(name) || name == "a" || name == "nobr":
                if !adoptionAgency(name) { anyOtherEndTag(name) }
            case "applet", "marquee", "object":
                guard inScope(name) else { return }
                generateImpliedEndTags()
                popUntil(name)
                clearFormattingToMarker()
            case "br":
                reconstructFormatting()
                insertVoid(Tag(name: "br"))
            default:
                anyOtherEndTag(name)
            }
        }

        /// An end tag closes the nearest open element of its name, unless an element such as
        /// a div or a cell stands between them. Then the tag is ignored.
        private mutating func anyOtherEndTag(_ name: String) {
            var index = stack.count - 1
            while index > 0 {
                guard budget.spend() else { return cut() }
                let node = stack[index]
                if document.isElement(node, name) {
                    generateImpliedEndTags(except: name)
                    while stack.count > index { pop() }
                    return
                }
                if isSpecial(node) { return }
                index -= 1
            }
        }

        private mutating func endTemplate() {
            guard stackHas("template") else { return }
            generateImpliedEndTags(thoroughly: true)
            popUntil("template")
            clearFormattingToMarker()
            if !templateModes.isEmpty { templateModes.removeLast() }
            resetMode()
            if !document.nodes[Document.body].isOpen { mode = .beforeBody }
        }

        /// Template content may start with table parts, which set the mode it is read in.
        private mutating func inTemplate(_ token: Token) {
            switch token {
            case .text, .comment:
                inBody(token)
            case .start(let tag):
                let next: Mode
                switch tag.name {
                case "base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "template", "title":
                    startTagInBody(tag)
                    return
                case "caption", "colgroup", "tbody", "tfoot", "thead": next = .inTable
                case "col": next = .inColumnGroup
                case "tr": next = .inTableBody
                case "td", "th": next = .inRow
                default: next = .inBody
                }
                if !templateModes.isEmpty { templateModes.removeLast() }
                templateModes.append(next)
                mode = next
                process(token)
            case .end("template"):
                endTemplate()
            default:
                break
            }
        }

        // MARK: Tables

        private mutating func inTable(_ token: Token) {
            switch token {
            case .text(let range):
                if let current, ["table", "tbody", "tfoot", "thead", "tr"].contains(where: { document.isElement(current, $0) }) {
                    if isAllSpace(range) {
                        insertText(range, kind: .text)
                    } else {
                        // Text in a table but not in a cell goes before the table.
                        fosterParenting = true
                        inBody(token)
                        fosterParenting = false
                    }
                } else {
                    fosterParenting = true
                    inBody(token)
                    fosterParenting = false
                }
            case .comment(let range):
                insertComment(range)
            case .start(let tag):
                switch tag.name {
                case "caption":
                    clearStack(backTo: ["table", "template", "html"])
                    active.append(Self.marker)
                    if insertElement(tag) != nil { mode = .inCaption }
                case "colgroup":
                    clearStack(backTo: ["table", "template", "html"])
                    if insertElement(tag) != nil { mode = .inColumnGroup }
                case "col":
                    clearStack(backTo: ["table", "template", "html"])
                    guard insertElement(Tag(name: "colgroup")) != nil else { return }
                    mode = .inColumnGroup
                    process(token)
                case "tbody", "tfoot", "thead":
                    clearStack(backTo: ["table", "template", "html"])
                    if insertElement(tag) != nil { mode = .inTableBody }
                case "td", "th", "tr":
                    clearStack(backTo: ["table", "template", "html"])
                    guard insertElement(Tag(name: "tbody")) != nil else { return }
                    mode = .inTableBody
                    process(token)
                case "table":
                    guard inScope("table", .table) else { return }
                    popUntil("table")
                    resetMode()
                    process(token)
                case "style", "script", "template":
                    headElement(tag)
                case "input" where tag.attributes["type"]?.lowercased() == "hidden":
                    insertVoid(tag)
                case "form":
                    // As WebKit does, a form in a template's table is kept.
                    let inTemplate = stackHas("template")
                    guard formElement == nil || inTemplate, let node = insertElement(tag) else { return }
                    if !inTemplate { formElement = node }
                    pop()
                default:
                    fosterParenting = true
                    startTagInBody(tag)
                    fosterParenting = false
                }
            case .end(let name):
                switch name {
                case "table":
                    guard inScope("table", .table) else { return }
                    popUntil("table")
                    resetMode()
                case "body", "caption", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr":
                    break
                case "template":
                    endTemplate()
                default:
                    fosterParenting = true
                    endTagInBody(name)
                    fosterParenting = false
                }
            default:
                break
            }
        }

        private mutating func inTableBody(_ token: Token) {
            switch token {
            case .start(let tag) where tag.name == "tr":
                clearStack(backTo: ["tbody", "tfoot", "thead", "template", "html"])
                if insertElement(tag) != nil { mode = .inRow }
            case .start(let tag) where tag.name == "th" || tag.name == "td":
                clearStack(backTo: ["tbody", "tfoot", "thead", "template", "html"])
                guard insertElement(Tag(name: "tr")) != nil else { return }
                mode = .inRow
                process(token)
            case .end(let name) where ["tbody", "tfoot", "thead"].contains(name):
                guard inScope(name, .table) else { return }
                clearStack(backTo: ["tbody", "tfoot", "thead", "template", "html"])
                pop()
                mode = .inTable
            case .start(let tag) where ["caption", "col", "colgroup", "tbody", "tfoot", "thead"].contains(tag.name):
                endTableBody(then: token)
            case .end("table"):
                endTableBody(then: token)
            case .end(let name) where ["body", "caption", "col", "colgroup", "html", "td", "th", "tr"].contains(name):
                break
            default:
                inTable(token)
            }
        }

        private mutating func endTableBody(then token: Token) {
            guard ["tbody", "thead", "tfoot"].contains(where: { inScope($0, .table) }) else { return }
            clearStack(backTo: ["tbody", "tfoot", "thead", "template", "html"])
            pop()
            mode = .inTable
            process(token)
        }

        private mutating func inRow(_ token: Token) {
            switch token {
            case .start(let tag) where tag.name == "th" || tag.name == "td":
                clearStack(backTo: ["tr", "template", "html"])
                guard insertElement(tag) != nil else { return }
                mode = .inCell
                active.append(Self.marker)
            case .end("tr"):
                guard inScope("tr", .table) else { return }
                clearStack(backTo: ["tr", "template", "html"])
                pop()
                mode = .inTableBody
            case .start(let tag) where ["caption", "col", "colgroup", "tbody", "tfoot", "thead", "tr"].contains(tag.name):
                endRow(then: token)
            case .end("table"):
                endRow(then: token)
            case .end(let name) where ["tbody", "tfoot", "thead"].contains(name):
                guard inScope(name, .table) else { return }
                endRow(then: token)
            case .end(let name) where ["body", "caption", "col", "colgroup", "html", "td", "th"].contains(name):
                break
            default:
                inTable(token)
            }
        }

        private mutating func endRow(then token: Token) {
            guard inScope("tr", .table) else { return }
            clearStack(backTo: ["tr", "template", "html"])
            pop()
            mode = .inTableBody
            process(token)
        }

        private mutating func inCell(_ token: Token) {
            switch token {
            case .end(let name) where name == "td" || name == "th":
                guard inScope(name, .table) else { return }
                generateImpliedEndTags()
                popUntil(name)
                clearFormattingToMarker()
                mode = .inRow
            case .start(let tag) where ["caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"].contains(tag.name):
                guard inScope("td", .table) || inScope("th", .table) else { return }
                closeCell()
                process(token)
            case .end(let name) where ["body", "caption", "col", "colgroup", "html"].contains(name):
                break
            case .end(let name) where ["table", "tbody", "tfoot", "thead", "tr"].contains(name):
                guard inScope(name, .table) else { return }
                closeCell()
                process(token)
            default:
                inBody(token)
            }
        }

        private mutating func closeCell() {
            generateImpliedEndTags()
            while stack.count > 1, let node = current {
                pop()
                if document.isElement(node, "td") || document.isElement(node, "th") { break }
            }
            clearFormattingToMarker()
            mode = .inRow
        }

        private mutating func inCaption(_ token: Token) {
            switch token {
            case .end("caption"):
                endCaption()
            case .start(let tag) where ["caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"].contains(tag.name):
                if endCaption() { process(token) }
            case .end("table"):
                if endCaption() { process(token) }
            case .end(let name) where ["body", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr"].contains(name):
                break
            default:
                inBody(token)
            }
        }

        @discardableResult
        private mutating func endCaption() -> Bool {
            guard inScope("caption", .table) else { return false }
            generateImpliedEndTags()
            popUntil("caption")
            clearFormattingToMarker()
            mode = .inTable
            return true
        }

        private mutating func inColumnGroup(_ token: Token) {
            switch token {
            case .text(let range) where isAllSpace(range):
                insertText(range, kind: .text)
            case .comment(let range):
                insertComment(range)
            case .start(let tag) where tag.name == "col":
                insertVoid(tag)
            case .end("colgroup"):
                guard currentIs("colgroup") else { return }
                pop()
                mode = .inTable
            case .end("col"):
                break
            case .start(let tag) where tag.name == "template":
                headElement(tag)
            case .end("template"):
                endTemplate()
            default:
                guard currentIs("colgroup") else { return }
                pop()
                mode = .inTable
                process(token)
            }
        }

        // MARK: Selects

        private mutating func inSelect(_ token: Token) {
            switch token {
            case .text(let range):
                insertText(range, kind: .text)
            case .comment(let range):
                insertComment(range)
            case .start(let tag):
                switch tag.name {
                case "option":
                    if currentIs("option") { pop() }
                    insertElement(tag)
                case "optgroup":
                    if currentIs("option") { pop() }
                    if currentIs("optgroup") { pop() }
                    insertElement(tag)
                case "hr":
                    if currentIs("option") { pop() }
                    if currentIs("optgroup") { pop() }
                    insertVoid(tag)
                case "select":
                    guard inScope("select", .select) else { return }
                    popUntil("select")
                    resetMode()
                case "input", "keygen", "textarea":
                    guard inScope("select", .select) else { return }
                    popUntil("select")
                    resetMode()
                    process(token)
                case "script", "template":
                    headElement(tag)
                default:
                    break
                }
            case .end(let name):
                switch name {
                case "optgroup":
                    if currentIs("option"), stack.count > 1, document.isElement(stack[stack.count - 2], "optgroup") { pop() }
                    if currentIs("optgroup") { pop() }
                case "option":
                    if currentIs("option") { pop() }
                case "select":
                    guard inScope("select", .select) else { return }
                    popUntil("select")
                    resetMode()
                case "template":
                    endTemplate()
                default:
                    break
                }
            default:
                break
            }
        }

        private mutating func inSelectInTable(_ token: Token) {
            let tableNames = ["caption", "table", "tbody", "tfoot", "thead", "tr", "td", "th"]
            switch token {
            case .start(let tag) where tableNames.contains(tag.name):
                popUntil("select")
                resetMode()
                process(token)
            case .end(let name) where tableNames.contains(name):
                guard inScope(name, .table) else { return }
                popUntil("select")
                resetMode()
                process(token)
            default:
                inSelect(token)
            }
        }

        // MARK: Foreign content

        /// Whether the token goes by the rules for SVG and MathML: inside them, except for
        /// start tags and text in an element that holds HTML.
        private func isForeignContext(for token: Token) -> Bool {
            guard let current, document.nodes[current].isForeign else { return false }
            switch token {
            case .start, .text: return !Self.holdsHTML(document.nodes[current].name)
            default: return true
            }
        }

        private mutating func foreignContent(_ token: Token) {
            switch token {
            case .text(let range):
                insertText(range, kind: .text)
            case .comment(let range):
                insertComment(range)
            case .start(let tag):
                if Self.breakout.contains(tag.name)
                    || (tag.name == "font" && ["color", "face", "size"].contains(where: { tag.attributes[$0] != nil })) {
                    popForeign()
                    process(token)
                    return
                }
                if insertElement(tag, isForeign: true) != nil, tag.selfClosing { pop() }
            case .end(let name):
                if name == "br" || name == "p" {
                    popForeign()
                    process(token)
                    return
                }
                var index = stack.count - 1
                while index > 0 {
                    let node = stack[index]
                    if document.nodes[node].name == name {
                        while stack.count > index { pop() }
                        return
                    }
                    index -= 1
                    if !document.nodes[stack[index]].isForeign {
                        switch mode {
                        case .beforeBody: beforeBody(token)
                        case .inBody: inBody(token)
                        case .inTable: inTable(token)
                        case .inTableBody: inTableBody(token)
                        case .inRow: inRow(token)
                        case .inCell: inCell(token)
                        case .inCaption: inCaption(token)
                        case .inColumnGroup: inColumnGroup(token)
                        case .inSelect: inSelect(token)
                        case .inSelectInTable: inSelectInTable(token)
                        case .inTemplate: inTemplate(token)
                        }
                        return
                    }
                }
            default:
                break
            }
        }

        private mutating func popForeign() {
            while let current, document.nodes[current].isForeign, !Self.holdsHTML(document.nodes[current].name) { pop() }
        }

        // MARK: The stack of open elements

        private enum Scope {
            case normal, listItem, button, table, select
        }

        private mutating func push(_ node: Int) {
            stack.append(node)
            document.nodes[node].isOpen = true
        }

        private mutating func pop() {
            guard stack.count > 1, let node = stack.popLast() else { return }
            document.nodes[node].isOpen = false
        }

        private mutating func removeFromStack(at index: Int) {
            guard index > 0 else { return }
            document.nodes[stack[index]].isOpen = false
            stack.remove(at: index)
        }

        /// Pops elements until one of the name is popped.
        private mutating func popUntil(_ name: String) {
            while stack.count > 1, let node = current {
                pop()
                if document.isElement(node, name) { return }
            }
        }

        private mutating func clearStack(backTo names: Set<String>) {
            while stack.count > 1, let node = current, document.nodes[node].isForeign || !names.contains(document.nodes[node].name) { pop() }
        }

        private func stackHas(_ name: String) -> Bool {
            stack.contains { document.isElement($0, name) }
        }

        private mutating func inScope(_ name: String, _ scope: Scope = .normal) -> Bool {
            for node in stack.reversed() {
                guard budget.spend() else { return false }
                if document.isElement(node, name) { return true }
                if isScopeBoundary(node, scope) { return false }
            }
            return false
        }

        private mutating func inScope(element target: Int) -> Bool {
            for node in stack.reversed() {
                guard budget.spend() else { return false }
                if node == target { return true }
                if isScopeBoundary(node, .normal) { return false }
            }
            return false
        }

        private func isScopeBoundary(_ node: Int, _ scope: Scope) -> Bool {
            let element = document.nodes[node]
            if element.isForeign { return scope != .table && scope != .select && Self.holdsHTML(element.name) }
            switch scope {
            case .normal: return Self.scopeBoundaries.contains(element.name)
            case .listItem: return Self.scopeBoundaries.contains(element.name) || element.name == "ol" || element.name == "ul"
            case .button: return Self.scopeBoundaries.contains(element.name) || element.name == "button"
            case .table: return ["html", "table", "template"].contains(element.name)
            case .select: return element.name != "optgroup" && element.name != "option"
            }
        }

        private func isSpecial(_ node: Int) -> Bool {
            let element = document.nodes[node]
            return element.isForeign ? Self.holdsHTML(element.name) : Self.special.contains(element.name)
        }

        private mutating func generateImpliedEndTags(except name: String? = nil, thoroughly: Bool = false) {
            let names = thoroughly ? Self.impliedEndTags.union(["caption", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"]) : Self.impliedEndTags
            while let current, !document.nodes[current].isForeign, names.contains(document.nodes[current].name),
                  document.nodes[current].name != name { pop() }
        }

        private mutating func closeParagraphInButtonScope() {
            if inScope("p", .button) { closeParagraph() }
        }

        private mutating func closeParagraph() {
            generateImpliedEndTags(except: "p")
            popUntil("p")
        }

        private mutating func resetMode() {
            for index in stack.indices.reversed() {
                let node = stack[index]
                guard !document.nodes[node].isForeign else { continue }
                let isLast = index == 0
                switch document.nodes[node].name {
                case "select":
                    let inTable = stack[..<index].contains { document.isElement($0, "table") }
                    mode = inTable ? .inSelectInTable : .inSelect
                    return
                case "td", "th":
                    guard !isLast else { break }
                    mode = .inCell
                    return
                case "tr":
                    mode = .inRow
                    return
                case "tbody", "thead", "tfoot":
                    mode = .inTableBody
                    return
                case "caption":
                    mode = .inCaption
                    return
                case "colgroup":
                    mode = .inColumnGroup
                    return
                case "table":
                    mode = .inTable
                    return
                case "template":
                    mode = templateModes.last ?? .inBody
                    return
                case "head", "body", "frameset", "html":
                    mode = .inBody
                    return
                default:
                    break
                }
            }
            mode = .inBody
        }

        // MARK: Inserting

        /// Adds an element where the next node goes and opens it. Nil once the tree is as
        /// deep as the limit, which ends the reading, so no style below it can be missed.
        @discardableResult
        private mutating func insertElement(_ tag: Tag, isForeign: Bool = false) -> Int? {
            guard stack.count < limits.maximumDepth else {
                cut()
                return nil
            }
            let parentIsForeign = current.map { document.nodes[$0].isForeign && !Self.holdsHTML(document.nodes[$0].name) } ?? false
            let node = document.add(Node(element: tag, isForeign: isForeign || parentIsForeign))
            insertAtAppropriatePlace(node)
            push(node)
            return node
        }

        private mutating func insertVoid(_ tag: Tag) {
            if insertElement(tag) != nil { pop() }
        }

        private mutating func insertText(_ range: Range<Int>, kind: Node.Kind) {
            guard !range.isEmpty else { return }
            var text = Node(kind: kind)
            text.range = range
            insertAtAppropriatePlace(document.add(text))
        }

        private mutating func insertComment(_ range: Range<Int>) {
            var comment = Node(kind: .comment)
            comment.range = range
            let node = document.add(comment)
            document.append(node, to: current ?? Document.root)
        }

        /// The current node, or with foster parenting in a table, the place before the table.
        private mutating func insertAtAppropriatePlace(_ node: Int, in override: Int? = nil) {
            let target = override ?? current ?? Document.root
            guard fosterParenting, ["table", "tbody", "tfoot", "thead", "tr"].contains(where: { document.isElement(target, $0) }) else {
                document.append(node, to: target)
                return
            }
            let lastTable = stack.lastIndex { document.isElement($0, "table") }
            let lastTemplate = stack.lastIndex { document.isElement($0, "template") }
            if let lastTemplate, lastTable.map({ lastTemplate > $0 }) ?? true {
                document.append(node, to: stack[lastTemplate])
                return
            }
            guard let lastTable else {
                document.append(node, to: stack[0])
                return
            }
            let table = stack[lastTable]
            if document.parent(table) != nil {
                document.insert(node, before: table)
            } else {
                document.append(node, to: stack[lastTable - 1])
            }
        }

        /// Adds the attributes a later html or body tag sets that the element lacks.
        private mutating func mergeAttributes(_ tag: Tag, into node: Int) {
            for (name, value) in tag.attributes where document.nodes[node].attributes[name] == nil {
                document.nodes[node].attributes[name] = value
                if tag.unknownReferences.contains(name) { document.nodes[node].unknownReferences.insert(name) }
            }
            document.nodes[node].classes = Node.classes(document.nodes[node].attributes["class"])
            document.nodes[node].lowercaseClasses = document.nodes[node].classes.map { $0.lowercased() }
        }

        private mutating func noteStyleSheet(_ tag: Tag) {
            guard tag.name == "link", let relation = tag.attributes["rel"] else { return }
            if relation.lowercased().split(whereSeparator: \.isWhitespace).contains("stylesheet") { document.loadsStyles = true }
        }

        // MARK: Formatting elements

        private func lastFormatting(named name: String) -> Int? {
            for index in active.indices.reversed() {
                let entry = active[index]
                if entry == Self.marker { return nil }
                if document.nodes[entry].name == name { return index }
            }
            return nil
        }

        /// Opens a formatting element and lists it, at most three alike after the last marker.
        private mutating func insertFormatting(_ tag: Tag) {
            guard let node = insertElement(tag) else { return }
            var alike: [Int] = []
            for index in active.indices.reversed() {
                let entry = active[index]
                if entry == Self.marker { break }
                if document.nodes[entry].name == tag.name, document.nodes[entry].attributes == tag.attributes { alike.append(index) }
            }
            if alike.count >= 3, let earliest = alike.last { active.remove(at: earliest) }
            active.append(node)
            if active.count > limits.maximumDepth { cut() }
        }

        /// Opens again the formatting elements that an end tag closed before their time, as
        /// in <p><b>bold</p>still bold.
        private mutating func reconstructFormatting() {
            guard let last = active.last, last != Self.marker, !document.nodes[last].isOpen else { return }
            var index = active.count - 1
            while index > 0 {
                let previous = active[index - 1]
                if previous == Self.marker || document.nodes[previous].isOpen { break }
                index -= 1
            }
            while index < active.count {
                guard budget.spend(), let clone = insertElement(document.nodes[active[index]].tag) else { return }
                active[index] = clone
                index += 1
            }
        }

        private mutating func clearFormattingToMarker() {
            while let entry = active.popLast(), entry != Self.marker {}
        }

        /// The adoption agency algorithm of the HTML standard for the end tag of a
        /// formatting element. False when the end tag is to be read as any other end tag.
        private mutating func adoptionAgency(_ name: String) -> Bool {
            if let current, document.isElement(current, name), !active.contains(current) {
                pop()
                return true
            }
            for _ in 0..<8 {
                guard budget.spend(stack.count + active.count) else {
                    cut()
                    return true
                }
                guard let formattingIndex = lastFormatting(named: name) else { return false }
                let formatting = active[formattingIndex]
                guard let formattingOpen = stack.lastIndex(of: formatting) else {
                    active.remove(at: formattingIndex)
                    return true
                }
                guard inScope(element: formatting) else { return true }
                guard let furthestOpen = stack.indices.first(where: { $0 > formattingOpen && isSpecial(stack[$0]) }) else {
                    while stack.count > formattingOpen { pop() }
                    active.remove(at: formattingIndex)
                    return true
                }
                let furthestBlock = stack[furthestOpen]
                let commonAncestor = stack[formattingOpen - 1]
                var bookmark = formattingIndex
                var lastNode = furthestBlock
                var nodeOpen = furthestOpen
                var inner = 0
                while true {
                    inner += 1
                    nodeOpen -= 1
                    let node = stack[nodeOpen]
                    if node == formatting { break }
                    var listed = active.firstIndex(of: node)
                    if inner > 3, let index = listed {
                        active.remove(at: index)
                        if index < bookmark { bookmark -= 1 }
                        listed = nil
                    }
                    guard let index = listed else {
                        removeFromStack(at: nodeOpen)
                        continue
                    }
                    let clone = document.add(Node(element: document.nodes[node].tag, isForeign: document.nodes[node].isForeign))
                    active[index] = clone
                    document.nodes[node].isOpen = false
                    stack[nodeOpen] = clone
                    document.nodes[clone].isOpen = true
                    if lastNode == furthestBlock { bookmark = index + 1 }
                    document.append(lastNode, to: clone)
                    lastNode = clone
                }
                document.detach(lastNode)
                insertAtAppropriatePlace(lastNode, in: commonAncestor)
                let replacement = document.add(Node(element: document.nodes[formatting].tag))
                guard budget.spend(document.moveChildren(of: furthestBlock, to: replacement)) else {
                    cut()
                    return true
                }
                document.append(replacement, to: furthestBlock)
                if let index = active.firstIndex(of: formatting) {
                    active.remove(at: index)
                    if index < bookmark { bookmark -= 1 }
                }
                active.insert(replacement, at: min(max(bookmark, 0), active.count))
                if let index = stack.firstIndex(of: formatting) { removeFromStack(at: index) }
                // The new element goes right after the furthest block. The next round pops
                // it, so the furthest block ends up as the current node.
                if let index = stack.firstIndex(of: furthestBlock) {
                    stack.insert(replacement, at: index + 1)
                    document.nodes[replacement].isOpen = true
                }
            }
            return true
        }

        // MARK: Doctypes

        /// Whether a doctype puts the page in quirks mode. A page in limited quirks mode
        /// counts as not in quirks mode, which only matters for a table in a paragraph.
        private static func isQuirks(_ content: ArraySlice<UInt8>) -> Bool {
            var words: [String] = []
            var quoted: String?
            var quote: Character?
            var word = ""
            for character in String(decoding: content, as: UTF8.self) {
                if let open = quote {
                    if character == open {
                        words.append(quoted ?? "")
                        quoted = nil
                        quote = nil
                    } else {
                        quoted = (quoted ?? "") + String(character)
                    }
                } else if character == "\"" || character == "'" {
                    if !word.isEmpty { words.append(word) }
                    word = ""
                    quote = character
                    quoted = ""
                } else if character.isWhitespace {
                    if !word.isEmpty { words.append(word) }
                    word = ""
                } else {
                    word.append(character)
                }
            }
            if quote != nil { return true }
            if !word.isEmpty { words.append(word) }
            guard words.first?.lowercased() == "html" else { return true }
            var publicID = ""
            var systemID = ""
            if words.count >= 3, words[1].lowercased() == "public" {
                publicID = words[2].lowercased()
                if words.count >= 4 { systemID = words[3].lowercased() }
            } else if words.count >= 3, words[1].lowercased() == "system" {
                systemID = words[2].lowercased()
            } else if words.count > 1 {
                return true
            }
            if systemID == "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd" { return true }
            if publicID.isEmpty || publicID.hasPrefix("-//w3c//dtd xhtml 1.") { return false }
            if publicID.hasPrefix("-//w3c//dtd html 4.01") {
                let loose = publicID.hasPrefix("-//w3c//dtd html 4.01 transitional//") || publicID.hasPrefix("-//w3c//dtd html 4.01 frameset//")
                return loose && systemID.isEmpty
            }
            return true
        }

        // MARK: Element sets

        private static let formatting: Set<String> = ["b", "big", "code", "em", "font", "i", "s", "small", "strike", "strong", "tt", "u"]
        private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
        private static let impliedEndTags: Set<String> = ["dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc"]
        private static let scopeBoundaries: Set<String> = ["applet", "caption", "html", "table", "td", "th", "marquee", "object", "template"]
        private static let closesParagraph: Set<String> = [
            "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset",
            "figcaption", "figure", "footer", "header", "hgroup", "main", "menu", "nav", "ol", "p", "search", "section",
            "summary", "ul",
        ]
        private static let blockEnds: Set<String> = [
            "address", "article", "aside", "blockquote", "button", "center", "details", "dialog", "dir", "div", "dl",
            "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "listing", "main", "menu", "nav", "ol", "pre",
            "search", "section", "summary", "ul",
        ]
        private static let special: Set<String> = [
            "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br",
            "button", "caption", "center", "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed", "fieldset",
            "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head",
            "header", "hgroup", "hr", "html", "iframe", "img", "input", "keygen", "li", "link", "listing", "main",
            "marquee", "menu", "meta", "nav", "noembed", "noframes", "noscript", "object", "ol", "p", "param", "plaintext",
            "pre", "script", "search", "section", "select", "source", "style", "summary", "table", "tbody", "td",
            "template", "textarea", "tfoot", "th", "thead", "title", "tr", "track", "ul", "wbr", "xmp",
        ]
        /// Start tags that end SVG and MathML content.
        private static let breakout: Set<String> = [
            "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl", "dt", "em", "embed", "h1", "h2",
            "h3", "h4", "h5", "h6", "head", "hr", "i", "img", "li", "listing", "menu", "meta", "nobr", "ol", "p", "pre",
            "ruby", "s", "small", "span", "strong", "strike", "sub", "sup", "table", "tt", "u", "ul", "var",
        ]

        /// SVG and MathML elements whose content is HTML.
        static func holdsHTML(_ name: String) -> Bool {
            ["foreignobject", "desc", "title", "mi", "mo", "mn", "ms", "mtext", "annotation-xml"].contains(name)
        }
    }
}

// MARK: Style sheets

nonisolated extension VisibleText {
    /// The structure of CSS text, read from its UTF-8 bytes.
    private enum CSS {
        enum Item {
            case declaration(ArraySlice<UInt8>)
            case rule(prelude: ArraySlice<UInt8>, block: ArraySlice<UInt8>)
        }

        /// The text without comments, outside strings.
        static func withoutComments(_ bytes: [UInt8]) -> [UInt8] {
            guard bytes.contains(0x2A) else { return bytes }
            var result: [UInt8] = []
            result.reserveCapacity(bytes.count)
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 || byte == 0x27 {
                    let end = stringEnd(bytes[...], from: index)
                    result += bytes[index..<end]
                    index = end
                } else if byte == 0x5C {
                    result += bytes[index..<min(index + 2, bytes.count)]
                    index += 2
                } else if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                    var close = index + 2
                    while close + 1 < bytes.count, !(bytes[close] == 0x2A && bytes[close + 1] == 0x2F) { close += 1 }
                    index = close + 2
                    result.append(0x20)
                } else {
                    result.append(byte)
                    index += 1
                }
            }
            return result
        }

        /// The index after a string that starts with the quote at `start`. A string also
        /// ends before a line break it does not escape.
        static func stringEnd(_ bytes: ArraySlice<UInt8>, from start: Int) -> Int {
            let quote = bytes[start]
            var index = start + 1
            while index < bytes.endIndex {
                switch bytes[index] {
                case quote: return index + 1
                case 0x5C: index += 2
                case 0x0A, 0x0C, 0x0D: return index
                default: index += 1
                }
            }
            return bytes.endIndex
        }

        /// The index of the } that closes the block whose content starts at `start`.
        static func blockEnd(_ bytes: ArraySlice<UInt8>, from start: Int) -> Int {
            var depth = 1
            var index = start
            while index < bytes.endIndex {
                switch bytes[index] {
                case 0x22, 0x27:
                    index = stringEnd(bytes, from: index)
                    continue
                case 0x5C:
                    index += 2
                    continue
                case 0x7B: depth += 1
                case 0x7D:
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
                index += 1
            }
            return bytes.endIndex
        }

        /// The declarations and rules of a block or a style sheet, in order.
        static func items(_ bytes: ArraySlice<UInt8>) -> [Item] {
            var items: [Item] = []
            var start = bytes.startIndex
            var index = start
            var depth = 0
            while index < bytes.endIndex {
                switch bytes[index] {
                case 0x22, 0x27:
                    index = stringEnd(bytes, from: index)
                    continue
                case 0x5C:
                    index += 2
                    continue
                case 0x28, 0x5B: depth += 1
                case 0x29, 0x5D: depth = max(0, depth - 1)
                case 0x3B where depth == 0:
                    items.append(.declaration(bytes[start..<index]))
                    start = index + 1
                case 0x7B where depth == 0:
                    let end = blockEnd(bytes, from: index + 1)
                    let prelude = bytes[start..<index]
                    if isCustomProperty(prelude) {
                        // A custom property may hold a block. It runs to the next ";".
                        index = end + 1
                        continue
                    }
                    items.append(.rule(prelude: prelude, block: bytes[(index + 1)..<end]))
                    index = min(end + 1, bytes.endIndex)
                    start = index
                    continue
                case 0x7D where depth == 0:
                    start = index + 1
                default: break
                }
                index += 1
            }
            if start < bytes.endIndex { items.append(.declaration(bytes[start..<bytes.endIndex])) }
            return items
        }

        private static func isCustomProperty(_ prelude: ArraySlice<UInt8>) -> Bool {
            let trimmed = prelude.drop { Tokenizer.isSpace($0) }
            return trimmed.starts(with: [0x2D, 0x2D]) && trimmed.contains(0x3A)
        }

        static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
            var slice = bytes
            while let first = slice.first, Tokenizer.isSpace(first) { slice = slice.dropFirst() }
            while let last = slice.last, Tokenizer.isSpace(last) { slice = slice.dropLast() }
            return slice
        }

        /// The text with CSS escapes replaced by the characters they stand for, as \6e for n.
        static func unescaped(_ bytes: ArraySlice<UInt8>) -> String {
            guard bytes.contains(0x5C) else { return String(decoding: bytes, as: UTF8.self) }
            var result: [UInt8] = []
            var index = bytes.startIndex
            while index < bytes.endIndex {
                guard bytes[index] == 0x5C else {
                    result.append(bytes[index])
                    index += 1
                    continue
                }
                index += 1
                guard index < bytes.endIndex else {
                    result += "\u{FFFD}".utf8
                    break
                }
                var value: UInt32 = 0
                var digits = 0
                while index < bytes.endIndex, digits < 6, let digit = hexDigit(bytes[index]) {
                    value = value * 16 + digit
                    digits += 1
                    index += 1
                }
                if digits > 0 {
                    if index < bytes.endIndex, Tokenizer.isSpace(bytes[index]) { index += 1 }
                    let scalar = value == 0 ? nil : Unicode.Scalar(value)
                    result += String(scalar ?? "\u{FFFD}").utf8
                } else if bytes[index] == 0x0A {
                    index += 1
                } else {
                    result.append(bytes[index])
                    index += 1
                }
            }
            return String(decoding: result, as: UTF8.self)
        }

        static func hexDigit(_ byte: UInt8) -> UInt32? {
            switch byte {
            case 0x30...0x39: UInt32(byte - 0x30)
            case 0x41...0x46: UInt32(byte - 0x41 + 10)
            case 0x61...0x66: UInt32(byte - 0x61 + 10)
            default: nil
            }
        }

        /// Pieces of the text split at the separator outside parentheses, brackets and
        /// strings.
        static func split(_ text: Substring, at separator: Character) -> [Substring] {
            var pieces: [Substring] = []
            var depth = 0
            var quote: Character?
            var escaped = false
            var start = text.startIndex
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "(" || character == "[" {
                    depth += 1
                } else if character == ")" || character == "]" {
                    depth = max(0, depth - 1)
                } else if character == separator, depth == 0 {
                    pieces.append(text[start..<index])
                    start = text.index(after: index)
                }
                index = text.index(after: index)
            }
            pieces.append(text[start...])
            return pieces
        }

        /// The words of a value split at white space outside parentheses and strings.
        static func words(_ text: String) -> [Substring] {
            var words: [Substring] = []
            var depth = 0
            var quote: UInt8?
            var start: String.Index?
            let utf8 = text.utf8
            var index = utf8.startIndex
            while index < utf8.endIndex {
                let byte = utf8[index]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == 0x22 || byte == 0x27 {
                    quote = byte
                } else if byte == 0x28 {
                    depth += 1
                } else if byte == 0x29 {
                    depth = max(0, depth - 1)
                }
                if depth == 0, quote == nil, Tokenizer.isSpace(byte) {
                    if let begin = start { words.append(text[begin..<index]) }
                    start = nil
                } else if start == nil {
                    start = index
                }
                index = utf8.index(after: index)
            }
            if let begin = start { words.append(text[begin...]) }
            return words
        }

        /// The arguments of the function call that starts at `name(` in the text, or nil.
        static func arguments(of name: String, in text: Substring) -> Substring? {
            guard text.hasPrefix(name + "("), let close = closingParenthesis(text, from: text.index(text.startIndex, offsetBy: name.count)) else {
                return nil
            }
            return text[text.index(text.startIndex, offsetBy: name.count + 1)..<close]
        }

        /// The ) that closes the ( at `open`.
        static func closingParenthesis(_ text: Substring, from open: Substring.Index) -> Substring.Index? {
            var depth = 0
            var index = open
            while index < text.endIndex {
                switch text[index] {
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
                index = text.index(after: index)
            }
            return nil
        }
    }

    /// Whether rules under a media query apply in Mail on a Mac.
    private enum MediaQuery {
        enum Applies: Int {
            case never, sometimes, always

            /// Both conditions together.
            func and(_ other: Applies) -> Applies {
                Applies(rawValue: min(rawValue, other.rawValue)) ?? .never
            }
        }

        /// Always for a query with no condition on the screen or for screen and all,
        /// sometimes for one with a feature such as a width or dark mode, which Mail may
        /// meet, and never for print and other media.
        static func applies(_ query: String) -> Applies {
            let text = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .always }
            var result = Applies.never
            for part in CSS.split(Substring(text), at: ",") {
                let applies = one(part.trimmingCharacters(in: .whitespacesAndNewlines))
                if applies.rawValue > result.rawValue { result = applies }
            }
            return result
        }

        private static func one(_ query: String) -> Applies {
            guard !query.isEmpty else { return .always }
            var outside = ""
            var depth = 0
            for character in query {
                if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) } else if depth == 0 { outside.append(character) }
            }
            var words = outside.split(whereSeparator: \.isWhitespace).map(String.init)
            let hasFeatures = query.contains("(")
            var negated = false
            if words.first == "not" {
                negated = true
                words.removeFirst()
            } else if words.first == "only" {
                words.removeFirst()
            }
            let type = words.first.flatMap { $0 == "and" || $0 == "or" ? nil : $0 } ?? "all"
            let matchesType: Bool
            switch type {
            case "all", "screen": matchesType = true
            case "print", "speech", "aural", "braille", "embossed", "handheld", "projection", "tty", "tv": matchesType = false
            default: return .never
            }
            if hasFeatures { return matchesType || negated ? .sometimes : .never }
            return matchesType != negated ? .always : .never
        }
    }

    private enum Combinator {
        case descendant, child, adjacent, sibling
    }

    private struct AttributeTest {
        enum Match {
            case exists, equals, word, dash, prefix, suffix, contains
        }

        var name: String
        var match: Match
        var value: String
        var ignoresCase: Bool
    }

    private indirect enum PseudoClass {
        case root, empty, link, checked, disabled, enabled
        /// :nth-child and its kin: the elements at a·n + b, counted among the siblings, of
        /// the same type or matching a selector, from the start or the end.
        case nth(a: Int, b: Int, ofType: Bool, fromEnd: Bool, of: [StyleSelector]?)
        case not([StyleSelector])
        case anyOf([StyleSelector])
        /// A state no element has at rest, such as :hover, or a pseudo element that styles
        /// generated content, such as ::before.
        case never
        /// A part this reader does not check, such as :has() or ::first-line. It counts as
        /// matching, so a rule with it only adds hiding.
        case unknown
    }

    /// One compound of a selector, such as `td.note[title]:first-child`.
    private struct SelectorPart {
        var tag: String?
        var id: String?
        var classes: [String] = []
        /// The id and classes in lowercase, as quirks mode compares them.
        var lowercaseID: String?
        var lowercaseClasses: [String] = []
        var attributes: [AttributeTest] = []
        var pseudoClasses: [PseudoClass] = []
    }

    /// A complex selector, its parts from right to left: `parts[0]` is the element the rule
    /// styles, and `combinators[i]` joins `parts[i]` to `parts[i + 1]`.
    private struct StyleSelector {
        var parts: [SelectorPart]
        var combinators: [Combinator]
        var specificity: Int
        /// False when the selector holds a part this reader does not check.
        var isExact: Bool
        /// Whether it styles the first line or letter, so only part of the element's text.
        var stylesPart: Bool
    }

    /// Reads a selector list, as in a rule's prelude or in :is().
    private struct SelectorReader {
        /// The characters of the outermost list, which the readers of lists inside it share,
        /// so each reads its part without a copy.
        private let characters: [Character]
        private var index: Int
        /// Where this reader's list ends in `characters`.
        private let end: Int
        private let parents: [StyleSelector]?
        /// How many selector lists, as in :is() or :not(), this one is inside.
        private let depth: Int

        init(_ text: String, parents: [StyleSelector]?) {
            let characters = Array(text)
            self.init(characters, in: 0..<characters.count, parents: parents, depth: 0)
        }

        private init(_ characters: [Character], in range: Range<Int>, parents: [StyleSelector]?, depth: Int) {
            self.characters = characters
            index = range.lowerBound
            end = range.upperBound
            self.parents = parents
            self.depth = depth
        }

        /// A selector list nested deeper than this, such as :is() inside eight others, is not
        /// read. It may match, so the rule only hides. This keeps the stack and the work of a
        /// rule bounded, about this many times the length of its selector, with one copy of
        /// its characters.
        static let maximumDepth = 8

        /// The selectors, or nil when one cannot be read, which drops the rule, as in a
        /// browser. In a forgiving list, as in :is(), a selector that cannot be read is
        /// left out instead.
        mutating func list(forgiving: Bool = false, nested: Bool = false) -> [StyleSelector]? {
            var selectors: [StyleSelector] = []
            while true {
                skipSpace()
                if let selector = complex(nested: nested) {
                    selectors.append(selector)
                } else if !forgiving {
                    return nil
                } else {
                    skipTo(",")
                }
                skipSpace()
                guard index < end, characters[index] == "," else { break }
                index += 1
            }
            if index < end, !forgiving { return nil }
            guard !selectors.isEmpty else { return forgiving ? [] : nil }
            return selectors
        }

        private mutating func skipSpace() {
            while index < end, characters[index].isWhitespace { index += 1 }
        }

        private mutating func skipTo(_ stop: Character) {
            var depth = 0
            while index < end {
                let character = characters[index]
                if character == "(" { depth += 1 } else if character == ")" {
                    if depth == 0 { return }
                    depth -= 1
                } else if character == stop, depth == 0 { return }
                index += 1
            }
        }

        private mutating func complex(nested: Bool) -> StyleSelector? {
            var parts: [SelectorPart] = []
            var combinators: [Combinator] = []
            var exact = true
            var stylesPart = false
            var specificity = 0
            var usesParent = false
            skipSpace()
            // A nested selector may start with a combinator, relative to its parent.
            if nested, index < end, let combinator = Self.combinator(characters[index]) {
                index += 1
                parts.append(parentPart())
                combinators.append(combinator)
                usesParent = true
                skipSpace()
            }
            while true {
                guard let part = compound(exact: &exact, stylesPart: &stylesPart, specificity: &specificity, usesParent: &usesParent) else {
                    return nil
                }
                parts.append(part)
                let before = index
                skipSpace()
                guard index < end else { break }
                let character = characters[index]
                if character == "," || character == ")" { break }
                if let combinator = Self.combinator(character) {
                    index += 1
                    skipSpace()
                    combinators.append(combinator)
                } else if index > before {
                    combinators.append(.descendant)
                } else {
                    return nil
                }
            }
            guard combinators.count == parts.count - 1 else { return nil }
            if nested, !usesParent, let parents {
                parts.insert(SelectorPart(pseudoClasses: [.anyOf(parents)]), at: 0)
                combinators.insert(.descendant, at: 0)
                specificity += parents.map(\.specificity).max() ?? 0
                usesParent = true
            }
            if usesParent, parents?.contains(where: { !$0.isExact }) == true { exact = false }
            // Past the limit, the parts on the left are dropped, so the rule matches more
            // elements and only hides.
            if parts.count > Self.maximumParts {
                parts.removeFirst(parts.count - Self.maximumParts)
                combinators.removeFirst(combinators.count - (Self.maximumParts - 1))
                exact = false
            }
            return StyleSelector(parts: parts.reversed(), combinators: combinators.reversed(), specificity: specificity, isExact: exact, stylesPart: stylesPart)
        }

        private func parentPart() -> SelectorPart {
            SelectorPart(pseudoClasses: [parents.map { .anyOf($0) } ?? .root])
        }

        private static func combinator(_ character: Character) -> Combinator? {
            switch character {
            case ">": .child
            case "+": .adjacent
            case "~": .sibling
            default: nil
            }
        }

        private static let maximumParts = 32

        private mutating func compound(exact: inout Bool, stylesPart: inout Bool, specificity: inout Int, usesParent: inout Bool) -> SelectorPart? {
            var part = SelectorPart()
            var any = false
            while index < end {
                let character = characters[index]
                switch character {
                case "*":
                    index += 1
                    if index < end, characters[index] == "|" { index += 1 }
                case "&":
                    index += 1
                    usesParent = true
                    part.pseudoClasses.append(parents.map { .anyOf($0) } ?? .root)
                    specificity += parents?.map(\.specificity).max() ?? 0
                case "#":
                    index += 1
                    guard let name = identifier() else { return nil }
                    part.id = name
                    part.lowercaseID = name.lowercased()
                    specificity += 10_000
                case ".":
                    index += 1
                    guard let name = identifier() else { return nil }
                    part.classes.append(name)
                    part.lowercaseClasses.append(name.lowercased())
                    specificity += 100
                case "[":
                    index += 1
                    guard let test = attribute() else { return nil }
                    part.attributes.append(test)
                    specificity += 100
                case ":":
                    index += 1
                    guard let pseudo = pseudoClass(exact: &exact, stylesPart: &stylesPart, specificity: &specificity) else { return nil }
                    part.pseudoClasses.append(pseudo)
                default:
                    guard Self.startsIdentifier(character) else { return any ? part : nil }
                    guard let name = identifier() else { return nil }
                    if index < end, characters[index] == "|", index + 1 < end, characters[index + 1] != "=" {
                        index += 1
                        if index < end, characters[index] == "*" {
                            index += 1
                            break
                        }
                        guard let local = identifier() else { return nil }
                        part.tag = local.lowercased()
                    } else {
                        part.tag = name.lowercased()
                    }
                    specificity += 1
                }
                any = true
            }
            return any ? part : nil
        }

        private static func startsIdentifier(_ character: Character) -> Bool {
            character.isLetter || character == "_" || character == "-" || character == "\\" || !character.isASCII
        }

        /// An identifier with its escapes decoded.
        private mutating func identifier() -> String? {
            var bytes: [UInt8] = []
            while index < end {
                let character = characters[index]
                if character == "\\" {
                    bytes += "\\".utf8
                    index += 1
                    guard index < end else { break }
                    // A hex escape runs over up to six digits and may end in a space.
                    guard characters[index].isHexDigit else {
                        bytes += String(characters[index]).utf8
                        index += 1
                        continue
                    }
                    var digits = 0
                    while index < end, characters[index].isHexDigit, digits < 6 {
                        bytes += String(characters[index]).utf8
                        index += 1
                        digits += 1
                    }
                    if index < end, characters[index].isWhitespace {
                        bytes += " ".utf8
                        index += 1
                    }
                    continue
                }
                guard character.isLetter || character.isNumber || character == "-" || character == "_" || !character.isASCII else { break }
                bytes += String(character).utf8
                index += 1
            }
            guard !bytes.isEmpty else { return nil }
            return CSS.unescaped(bytes[...])
        }

        private mutating func attribute() -> AttributeTest? {
            skipSpace()
            if index < end, characters[index] == "*" || characters[index] == "|" {
                while index < end, characters[index] != "|" { index += 1 }
                index += 1
            }
            guard let rawName = identifier() else { return nil }
            var name = rawName.lowercased()
            if index < end, characters[index] == "|", index + 1 < end, characters[index + 1] != "=" {
                index += 1
                guard let local = identifier() else { return nil }
                name = local.lowercased()
            }
            skipSpace()
            guard index < end else { return nil }
            if characters[index] == "]" {
                index += 1
                return AttributeTest(name: name, match: .exists, value: "", ignoresCase: false)
            }
            let match: AttributeTest.Match
            switch characters[index] {
            case "=": match = .equals
            case "~": match = .word
            case "|": match = .dash
            case "^": match = .prefix
            case "$": match = .suffix
            case "*": match = .contains
            default: return nil
            }
            index += match == .equals ? 1 : 2
            skipSpace()
            guard index < end else { return nil }
            var value: String
            if characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]
                index += 1
                var bytes: [UInt8] = []
                while index < end, characters[index] != quote {
                    if characters[index] == "\\", index + 1 < end {
                        bytes += "\\".utf8
                        index += 1
                    }
                    bytes += String(characters[index]).utf8
                    index += 1
                }
                guard index < end else { return nil }
                index += 1
                value = CSS.unescaped(bytes[...])
            } else {
                guard let word = identifier() else { return nil }
                value = word
            }
            skipSpace()
            var ignoresCase = Self.caseInsensitiveAttributes.contains(name)
            if index < end, characters[index] == "i" || characters[index] == "I" {
                ignoresCase = true
                index += 1
                skipSpace()
            } else if index < end, characters[index] == "s" || characters[index] == "S" {
                ignoresCase = false
                index += 1
                skipSpace()
            }
            guard index < end, characters[index] == "]" else { return nil }
            index += 1
            if ignoresCase { value = value.lowercased() }
            return AttributeTest(name: name, match: match, value: value, ignoresCase: ignoresCase)
        }

        /// Attributes whose values HTML compares without case in selectors.
        private static let caseInsensitiveAttributes: Set<String> = [
            "align", "bgcolor", "charset", "checked", "clear", "color", "compact", "declare", "defer", "dir", "direction",
            "disabled", "face", "frame", "hreflang", "http-equiv", "lang", "language", "link", "media", "method",
            "multiple", "nohref", "noresize", "noshade", "nowrap", "readonly", "rel", "rev", "rules", "scope",
            "scrolling", "selected", "shape", "target", "text", "type", "valign", "valuetype", "vlink",
        ]

        private mutating func pseudoClass(exact: inout Bool, stylesPart: inout Bool, specificity: inout Int) -> PseudoClass? {
            var isElement = false
            if index < end, characters[index] == ":" {
                isElement = true
                index += 1
            }
            guard let rawName = identifier() else { return nil }
            let name = rawName.lowercased()
            var argument: Range<Int>?
            if index < end, characters[index] == "(" {
                let start = index + 1
                var depth = 0
                while index < end {
                    if characters[index] == "(" { depth += 1 } else if characters[index] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    index += 1
                }
                guard index < end else { return nil }
                argument = start..<index
                index += 1
            }
            if isElement || Self.legacyPseudoElements.contains(name) {
                specificity += 1
                if name == "first-line" || name == "first-letter" {
                    exact = false
                    stylesPart = true
                    return .unknown
                }
                return .never
            }
            specificity += 100
            switch name {
            case "root": return .root
            case "empty": return .empty
            case "link", "any-link", "-webkit-any-link": return .link
            case "checked": return .checked
            case "disabled": return .disabled
            case "enabled": return .enabled
            case "first-child": return .nth(a: 0, b: 1, ofType: false, fromEnd: false, of: nil)
            case "last-child": return .nth(a: 0, b: 1, ofType: false, fromEnd: true, of: nil)
            case "first-of-type": return .nth(a: 0, b: 1, ofType: true, fromEnd: false, of: nil)
            case "last-of-type": return .nth(a: 0, b: 1, ofType: true, fromEnd: true, of: nil)
            case "only-child":
                return .anyOf([StyleSelector(
                    parts: [SelectorPart(pseudoClasses: [
                        .nth(a: 0, b: 1, ofType: false, fromEnd: false, of: nil), .nth(a: 0, b: 1, ofType: false, fromEnd: true, of: nil),
                    ])],
                    combinators: [], specificity: 0, isExact: true, stylesPart: false)])
            case "only-of-type":
                return .anyOf([StyleSelector(
                    parts: [SelectorPart(pseudoClasses: [
                        .nth(a: 0, b: 1, ofType: true, fromEnd: false, of: nil), .nth(a: 0, b: 1, ofType: true, fromEnd: true, of: nil),
                    ])],
                    combinators: [], specificity: 0, isExact: true, stylesPart: false)])
            case "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type":
                guard let argument else { return nil }
                var formula = argument
                var of: [StyleSelector]?
                if !name.hasSuffix("of-type"), let separator = self.separator(" of ", in: argument) {
                    formula = argument.lowerBound..<separator.lowerBound
                    guard depth < Self.maximumDepth else {
                        exact = false
                        return .unknown
                    }
                    var reader = SelectorReader(characters, in: separator.upperBound..<argument.upperBound, parents: parents, depth: depth + 1)
                    guard let selectors = reader.list() else { return nil }
                    if selectors.contains(where: { !$0.isExact }) { exact = false }
                    specificity += selectors.map(\.specificity).max() ?? 0
                    of = selectors
                }
                guard let (a, b) = Self.formula(String(characters[formula])[...]) else { return nil }
                return .nth(a: a, b: b, ofType: name.hasSuffix("of-type"), fromEnd: name.contains("last"), of: of)
            case "not", "is", "where", "matches", "-webkit-any":
                guard let argument else { return nil }
                guard depth < Self.maximumDepth else {
                    exact = false
                    return .unknown
                }
                var reader = SelectorReader(characters, in: argument, parents: parents, depth: depth + 1)
                guard let selectors = reader.list(forgiving: name != "not") else { return nil }
                if selectors.contains(where: { !$0.isExact }) { exact = false }
                specificity -= 100
                if name != "where" { specificity += selectors.map(\.specificity).max() ?? 0 }
                return name == "not" ? .not(selectors) : .anyOf(selectors)
            case "hover", "active", "focus", "focus-visible", "focus-within", "target", "target-within", "-webkit-drag",
                 "autofill", "-webkit-autofill", "popover-open", "modal", "fullscreen", "-webkit-full-screen", "playing",
                 "paused", "picture-in-picture", "user-invalid", "user-valid":
                return .never
            default:
                exact = false
                return .unknown
            }
        }

        /// Where `text` first is in `range` of the characters.
        private func separator(_ text: String, in range: Range<Int>) -> Range<Int>? {
            let text = Array(text)
            guard range.count >= text.count else { return nil }
            return (range.lowerBound...(range.upperBound - text.count)).lazy
                .map { $0..<($0 + text.count) }
                .first { characters[$0].elementsEqual(text) }
        }

        /// Pseudo elements written with one colon.
        private static let legacyPseudoElements: Set<String> = ["before", "after", "first-line", "first-letter"]

        /// a and b of "an+b", "odd", "even" or a number. Each is clamped to 32 bits, as
        /// WebKit clamps them, so matching never overflows.
        private static func formula(_ text: Substring) -> (Int, Int)? {
            func clamped(_ number: Int) -> Int { min(max(number, Int(Int32.min)), Int(Int32.max)) }
            let value = text.lowercased().filter { !$0.isWhitespace }
            switch value {
            case "odd": return (2, 1)
            case "even": return (2, 0)
            default: break
            }
            guard let n = value.firstIndex(of: "n") else { return Int(value).map { (0, clamped($0)) } }
            let before = value[..<n]
            let after = value[value.index(after: n)...]
            let a: Int?
            switch before {
            case "", "+": a = 1
            case "-": a = -1
            default: a = Int(before)
            }
            guard let a else { return nil }
            guard !after.isEmpty else { return (clamped(a), 0) }
            guard let b = Int(after.hasPrefix("+") ? String(after.dropFirst()) : String(after)) else { return nil }
            return (clamped(a), clamped(b))
        }
    }

    /// One property of a style.
    private struct Declaration {
        /// Nil for a custom property.
        var property: Property?
        /// The custom property's name, such as --brand.
        var name: String
        /// In lowercase, with escapes decoded. A custom property's value keeps its case.
        var value: String
        var important: Bool
        var hasVariable: Bool
        /// The words of the value, split once, since a rule may apply to many elements.
        var words: [String]

        /// The declarations of a style attribute or block. Nested rules are skipped.
        static func list(_ bytes: ArraySlice<UInt8>) -> [Declaration] {
            var result: [Declaration] = []
            for case .declaration(let text) in CSS.items(bytes) where result.count < maximumPerBlock {
                if let declaration = Declaration(text) { result.append(declaration) }
            }
            return result
        }

        static let maximumPerBlock = 256

        init?(_ text: ArraySlice<UInt8>) {
            guard let colon = text.firstIndex(of: 0x3A) else { return nil }
            let name = CSS.unescaped(CSS.trimmed(text[..<colon]))
            var value = CSS.unescaped(CSS.trimmed(text[(colon + 1)...]))
            if name.hasPrefix("--") {
                property = nil
                self.name = name
            } else {
                guard let known = Property(rawValue: name.lowercased()) else { return nil }
                property = known
                self.name = known.rawValue
                value = value.lowercased()
            }
            important = false
            if let bang = value.lastIndex(of: "!"),
               value[value.index(after: bang)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "important" {
                important = true
                value = value[..<bang].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            self.value = value
            hasVariable = value.lowercased().contains("var(")
            words = property == nil ? [] : CSS.words(value).map(String.init)
        }
    }

    /// The properties that can hide text, or show text a parent hides. Others are skipped.
    private enum Property: String {
        case display, visibility, opacity, filter, zoom, color, background, position, left, top, right, bottom, inset, float
        case margin, clip, mask, width, height, overflow, transform, translate, scale, rotate, animation, font
        case contentVisibility = "content-visibility"
        case webkitFilter = "-webkit-filter"
        case fontSize = "font-size"
        case letterSpacing = "letter-spacing"
        case whiteSpace = "white-space"
        case whiteSpaceCollapse = "white-space-collapse"
        case textFillColor = "-webkit-text-fill-color"
        case backgroundColor = "background-color"
        case backgroundImage = "background-image"
        case textIndent = "text-indent"
        case marginLeft = "margin-left"
        case marginRight = "margin-right"
        case marginTop = "margin-top"
        case clipPath = "clip-path"
        case webkitClipPath = "-webkit-clip-path"
        case maskImage = "mask-image"
        case webkitMask = "-webkit-mask"
        case webkitMaskImage = "-webkit-mask-image"
        case maxWidth = "max-width"
        case maxHeight = "max-height"
        case overflowX = "overflow-x"
        case overflowY = "overflow-y"
        case webkitTransform = "-webkit-transform"
        case animationName = "animation-name"
        case webkitAnimation = "-webkit-animation"
        case webkitAnimationName = "-webkit-animation-name"
    }

    private struct Rule {
        var selector: StyleSelector
        var order: Int
        var declarations: [Declaration]
        /// Whether the rule only adds hiding: it applies under a condition, or this reader
        /// cannot match its selector exactly.
        var onlyHides: Bool
        /// Whether its colors count too, as for ::first-line, which always applies but only
        /// to part of the text.
        var checksColors: Bool
    }

    /// The rules of the email's style elements, found by the id, class or tag of the
    /// element they style.
    private struct StyleSheet {
        let limits: Limits
        let quirks: Bool
        private(set) var rules: [Rule] = []
        private(set) var declarationCount = 0
        private(set) var isCut = false
        /// A web font or an @import, which Orra never loads but Mail may.
        private(set) var loadsStyles = false
        /// The declarations of each animation, by name.
        private(set) var keyframes: [String: [Declaration]] = [:]
        private var byID: [String: [Int]] = [:]
        private var byClass: [String: [Int]] = [:]
        private var byTag: [String: [Int]] = [:]
        private var universal: [Int] = []

        init(limits: Limits, quirks: Bool) {
            self.limits = limits
            self.quirks = quirks
        }

        var isEmpty: Bool { rules.isEmpty && keyframes.isEmpty }

        mutating func add(_ css: String, when applies: MediaQuery.Applies) {
            guard applies != .never, !isCut else { return }
            let bytes = CSS.withoutComments(Array(css.utf8))
            readItems(bytes[...], applies: applies, depth: 0)
        }

        /// The rules that may style the element, in the order they apply: by specificity,
        /// then by their order in the sheets.
        func candidates(id: String?, classes: [String], tag: String) -> [Int] {
            var found: [Int] = []
            if let id { found += byID[id.lowercased()] ?? [] }
            for name in classes { found += byClass[name.lowercased()] ?? [] }
            found += byTag[tag] ?? []
            found += universal
            return found
        }

        private mutating func readItems(_ bytes: ArraySlice<UInt8>, applies: MediaQuery.Applies, depth: Int) {
            for item in CSS.items(bytes) {
                guard !isCut else { return }
                switch item {
                case .declaration(let text):
                    let statement = CSS.unescaped(CSS.trimmed(text)).lowercased()
                    if statement.hasPrefix("@import") { loadsStyles = true }
                case .rule(let prelude, let block):
                    let head = CSS.unescaped(CSS.trimmed(prelude))
                    if head.hasPrefix("@") {
                        atRule(head, block: block, applies: applies, depth: depth, parents: nil)
                    } else {
                        styleRule(head, block: block, applies: applies, parents: nil, depth: depth)
                    }
                }
            }
        }

        private mutating func atRule(_ head: String, block: ArraySlice<UInt8>, applies: MediaQuery.Applies, depth: Int, parents: [StyleSelector]?) {
            guard depth < Self.maximumNesting else { return }
            let lowered = head.lowercased()
            let name = String(lowered.prefix { !$0.isWhitespace && $0 != "(" })
            let condition = lowered.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
            let inner: MediaQuery.Applies
            switch name {
            case "@media": inner = applies.and(MediaQuery.applies(condition))
            case "@supports": inner = applies.and(condition.hasPrefix("not") ? .sometimes : .always)
            case "@layer": inner = applies
            case "@font-face":
                loadsStyles = true
                return
            case "@keyframes", "@-webkit-keyframes":
                let animation = String(head.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines))
                var declarations: [Declaration] = []
                for case .rule(_, let frame) in CSS.items(block) {
                    declarations += Declaration.list(frame)
                }
                guard declarationCount + declarations.count <= limits.maximumDeclarations else {
                    isCut = true
                    return
                }
                declarationCount += declarations.count
                keyframes[animation, default: []] += declarations
                return
            case "@page", "@counter-style", "@property", "@font-feature-values", "@font-palette-values", "@namespace",
                 "@charset", "@view-transition", "@position-try", "@starting-style", "@document", "@-moz-document":
                return
            default:
                // @container, @scope and rules this reader does not know may apply.
                inner = applies.and(.sometimes)
            }
            guard inner != .never else { return }
            if let parents {
                // Declarations in a rule nested in a style rule style its parent.
                styleBlock(block, selectors: parents, applies: inner, depth: depth + 1)
            } else {
                readItems(block, applies: inner, depth: depth + 1)
            }
        }

        private mutating func styleRule(_ prelude: String, block: ArraySlice<UInt8>, applies: MediaQuery.Applies, parents: [StyleSelector]?, depth: Int) {
            guard depth < Self.maximumNesting else { return }
            var reader = SelectorReader(prelude, parents: parents)
            guard let selectors = reader.list(nested: parents != nil) else { return }
            styleBlock(block, selectors: selectors, applies: applies, depth: depth)
        }

        private mutating func styleBlock(_ block: ArraySlice<UInt8>, selectors: [StyleSelector], applies: MediaQuery.Applies, depth: Int) {
            var declarations: [Declaration] = []
            var nested: [(prelude: String, block: ArraySlice<UInt8>)] = []
            for item in CSS.items(block) {
                switch item {
                case .declaration(let text):
                    if declarations.count < Declaration.maximumPerBlock, let declaration = Declaration(text) { declarations.append(declaration) }
                case .rule(let prelude, let inner):
                    nested.append((CSS.unescaped(CSS.trimmed(prelude)), inner))
                }
            }
            if !declarations.isEmpty {
                for selector in selectors {
                    guard rules.count < limits.maximumRules, declarationCount + declarations.count <= limits.maximumDeclarations else {
                        isCut = true
                        return
                    }
                    let rule = Rule(
                        selector: selector, order: rules.count, declarations: declarations,
                        onlyHides: applies != .always || !selector.isExact, checksColors: applies == .always && selector.stylesPart)
                    let index = rules.count
                    rules.append(rule)
                    declarationCount += declarations.count
                    let subject = selector.parts[0]
                    if let id = subject.id {
                        byID[id.lowercased(), default: []].append(index)
                    } else if let name = subject.classes.first {
                        byClass[name.lowercased(), default: []].append(index)
                    } else if let tag = subject.tag {
                        byTag[tag, default: []].append(index)
                    } else {
                        universal.append(index)
                    }
                }
            }
            for rule in nested {
                guard !isCut else { return }
                if rule.prelude.hasPrefix("@") {
                    atRule(rule.prelude, block: rule.block, applies: applies, depth: depth + 1, parents: selectors)
                } else {
                    styleRule(rule.prelude, block: rule.block, applies: applies, parents: selectors, depth: depth + 1)
                }
            }
        }

        private static let maximumNesting = 8
    }
}

// MARK: Values

nonisolated extension VisibleText {
    /// A color in sRGB, from 0 to 1.
    private struct Color: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        static let black = Color(red: 0, green: 0, blue: 0, alpha: 1)
        static let white = Color(red: 1, green: 1, blue: 1, alpha: 1)
        static let clear = Color(red: 0, green: 0, blue: 0, alpha: 0)
        /// The color of a link before it is visited.
        static let link = Color(red: 0, green: 0, blue: 238.0 / 255, alpha: 1)
        static let mark = Color(red: 1, green: 1, blue: 0, alpha: 1)

        /// This color painted over an opaque one.
        func over(_ below: Color) -> Color {
            Color(
                red: red * alpha + below.red * (1 - alpha),
                green: green * alpha + below.green * (1 - alpha),
                blue: blue * alpha + below.blue * (1 - alpha),
                alpha: 1)
        }

        /// The largest difference of one channel, as FileTextExtractor measures it.
        func distance(to other: Color) -> Double {
            max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
        }

        init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = min(max(red, 0), 1)
            self.green = min(max(green, 0), 1)
            self.blue = min(max(blue, 0), 1)
            self.alpha = min(max(alpha, 0), 1)
        }

        /// Hex digits, as in #rgb, #rgba, #rrggbb or #rrggbbaa.
        init?(hex: Substring) {
            guard [3, 4, 6, 8].contains(hex.count), let value = UInt64(hex, radix: 16) else { return nil }
            let short = hex.count <= 4
            let channels = short ? hex.count : hex.count / 2
            var parts: [Double] = []
            for channel in 0..<channels {
                let shift = UInt64((channels - 1 - channel) * (short ? 4 : 8))
                let raw = Double((value >> shift) & (short ? 0xF : 0xFF))
                parts.append(raw / (short ? 15 : 255))
            }
            self.init(red: parts[0], green: parts[1], blue: parts[2], alpha: parts.count == 4 ? parts[3] : 1)
        }

        init(hue: Double, saturation: Double, lightness: Double, alpha: Double) {
            let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
            let s = min(max(saturation, 0), 1)
            let l = min(max(lightness, 0), 1)
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            func channel(_ t: Double) -> Double {
                let t = (t + 1).truncatingRemainder(dividingBy: 1)
                if t < 1.0 / 6 { return p + (q - p) * 6 * t }
                if t < 0.5 { return q }
                if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
                return p
            }
            self.init(red: channel(h + 1.0 / 3), green: channel(h), blue: channel(h - 1.0 / 3), alpha: alpha)
        }

        /// The CSS named colors.
        static let named: [String: String] = {
            let pairs = """
                aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 \
                black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 \
                cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc \
                crimson dc143c cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 \
                darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f \
                darkorange ff8c00 darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f \
                darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 \
                deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 \
                floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 \
                goldenrod daa520 gray 808080 green 008000 greenyellow adff2f grey 808080 honeydew f0fff0 hotpink ff69b4 \
                indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5 \
                lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff \
                lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 \
                lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 \
                lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff \
                maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db \
                mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc \
                mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 \
                navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 \
                orangered ff4500 orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee \
                palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd \
                powderblue b0e0e6 purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 \
                saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d \
                silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 snow fffafa \
                springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 \
                turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 \
                yellowgreen 9acd32 \
                canvas ffffff canvastext 000000 linktext 0000ee visitedtext 551a8b activetext ff0000 buttonface efefef \
                buttontext 000000 buttonborder 767676 field ffffff fieldtext 000000 graytext 808080 highlight b5d5ff \
                highlighttext 000000 mark ffff00 marktext 000000 selecteditem 0063e1 selecteditemtext ffffff \
                accentcolor 0063e1 accentcolortext ffffff -webkit-link 0000ee -webkit-activelink ff0000 \
                -apple-system-label 000000 -apple-system-background ffffff -apple-system-blue 007aff
                """.split(separator: " ")
            var table: [String: String] = [:]
            for pair in stride(from: 0, to: pairs.count - 1, by: 2) {
                table[String(pairs[pair])] = String(pairs[pair + 1])
            }
            return table
        }()
    }

    /// What a color property sets.
    private enum Paint {
        case color(Color)
        /// currentcolor: the color of the text.
        case current
        /// A color this reader cannot read, such as one from lab() or color-mix().
        case unknown

        /// A CSS color value, or nil for one that sets nothing, such as inherit or a value
        /// a browser drops. With `bare`, also hex digits without the #, which old
        /// attributes such as bgcolor take.
        init?(css text: String, bare: Bool = false) {
            let value = text.trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case "": return nil
            case "inherit", "unset", "revert", "revert-layer": return nil
            case "transparent": self = .color(.clear)
            case "currentcolor": self = .current
            case "initial": self = .color(.black)
            default:
                if value.hasPrefix("#") {
                    guard let color = Color(hex: value.dropFirst()) else { return nil }
                    self = .color(color)
                } else if let hex = Color.named[value] {
                    self = .color(Color(hex: Substring(hex)) ?? .black)
                } else if let open = value.firstIndex(of: "("), value.hasSuffix(")") {
                    let function = String(value[..<open])
                    let inner = value[value.index(after: open)..<value.index(before: value.endIndex)]
                    switch function {
                    case "rgb", "rgba", "hsl", "hsla", "hwb":
                        guard let color = Self.function(function, inner) else { return nil }
                        self = .color(color)
                    case "light-dark":
                        // The light one, as Mail shows mail in light mode by default.
                        guard let first = CSS.split(inner, at: ",").first, let paint = Paint(css: String(first)) else { return nil }
                        self = paint
                    default:
                        self = .unknown
                    }
                } else if bare, let color = Color(hex: Substring(value)) {
                    self = .color(color)
                } else {
                    return nil
                }
            }
        }

        private static func function(_ name: String, _ inner: Substring) -> Color? {
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            guard parts.count >= 3 else { return nil }
            func number(_ part: Substring, scale: Double) -> Double? {
                let text = part.trimmingCharacters(in: .whitespaces)
                if text == "none" { return 0 }
                let value: Double?
                if text.hasSuffix("%") {
                    value = Double(text.dropFirst(0).dropLast()).map { $0 / 100 }
                } else if text.hasSuffix("deg") {
                    value = Double(text.dropLast(3)).map { $0 / scale }
                } else if text.hasSuffix("turn") {
                    value = Double(text.dropLast(4))
                } else {
                    value = Double(text).map { $0 / scale }
                }
                return value.flatMap { $0.isFinite ? $0 : nil }
            }
            guard let alpha = parts.count >= 4 ? number(parts[3], scale: 1) : 1 else { return nil }
            switch name {
            case "rgb", "rgba":
                guard let red = number(parts[0], scale: 255), let green = number(parts[1], scale: 255),
                      let blue = number(parts[2], scale: 255) else { return nil }
                return Color(red: red, green: green, blue: blue, alpha: alpha)
            case "hwb":
                guard let hue = number(parts[0], scale: 360), let white = number(parts[1], scale: 100),
                      let black = number(parts[2], scale: 100) else { return nil }
                if white + black >= 1 {
                    let gray = white / (white + black)
                    return Color(red: gray, green: gray, blue: gray, alpha: alpha)
                }
                let pure = Color(hue: hue, saturation: 1, lightness: 0.5, alpha: 1)
                func mix(_ channel: Double) -> Double { channel * (1 - white - black) + white }
                return Color(red: mix(pure.red), green: mix(pure.green), blue: mix(pure.blue), alpha: alpha)
            default:
                guard let hue = number(parts[0], scale: 360), let saturation = number(parts[1], scale: 100),
                      let lightness = number(parts[2], scale: 100) else { return nil }
                return Color(hue: hue, saturation: saturation, lightness: lightness, alpha: alpha)
            }
        }
    }

    /// Lengths and numbers, with calc(), min(), max() and clamp().
    private struct Measure {
        /// The font size of the element, for em, ex and ch.
        var fontSize: Double
        /// The viewport width and height assumed for vw and vh. Checks for small text and
        /// boxes take a narrow window, checks for text moved away a wide one, so either way
        /// a viewport size never hides less than it would in Mail.
        var viewport: Double
        /// What 100% is, or nil when a percentage is unknown.
        var percentBase: Double?

        /// A length in CSS pixels, or nil for a value this reader cannot read. A number
        /// without a unit counts as pixels, as in quirks mode.
        func pixels(_ text: some StringProtocol) -> Double? {
            var reader = MathReader(text: Array(text.utf8), measure: self)
            guard let value = reader.sum(), reader.isAtEnd, value.isFinite else { return nil }
            return value
        }

        /// A number or a percentage, as an opacity or a scale takes.
        static func number(_ text: some StringProtocol) -> Double? {
            let measure = Measure(fontSize: 16, viewport: 320, percentBase: 1)
            var reader = MathReader(text: Array(text.utf8), measure: measure, unitless: true)
            guard let value = reader.sum(), reader.isAtEnd, value.isFinite else { return nil }
            return value
        }

        /// An angle in degrees.
        static func degrees(_ text: some StringProtocol) -> Double? {
            let value = String(text)
            for (unit, scale) in [("deg", 1.0), ("grad", 0.9), ("rad", 180 / Double.pi), ("turn", 360.0)] where value.hasSuffix(unit) {
                return Double(value.dropLast(unit.count)).map { $0 * scale }
            }
            return value == "0" ? 0 : nil
        }

        private struct MathReader {
            let text: [UInt8]
            let measure: Measure
            var unitless = false
            var index = 0
            var depth = 0

            init(text: [UInt8], measure: Measure, unitless: Bool = false) {
                self.text = text
                self.measure = measure
                self.unitless = unitless
            }

            var isAtEnd: Bool {
                var rest = index
                while rest < text.count, Tokenizer.isSpace(text[rest]) { rest += 1 }
                return rest == text.count
            }

            private mutating func skipSpace() {
                while index < text.count, Tokenizer.isSpace(text[index]) { index += 1 }
            }

            mutating func sum() -> Double? {
                guard var value = product() else { return nil }
                while true {
                    skipSpace()
                    guard index < text.count, text[index] == 0x2B || text[index] == 0x2D else { return value }
                    let sign: Double = text[index] == 0x2B ? 1 : -1
                    index += 1
                    guard let next = product() else { return nil }
                    value += sign * next
                }
            }

            private mutating func product() -> Double? {
                guard var value = unary() else { return nil }
                while true {
                    skipSpace()
                    guard index < text.count, text[index] == 0x2A || text[index] == 0x2F else { return value }
                    let divides = text[index] == 0x2F
                    index += 1
                    guard let next = unary() else { return nil }
                    if divides {
                        guard next != 0 else { return nil }
                        value /= next
                    } else {
                        value *= next
                    }
                }
            }

            private mutating func unary() -> Double? {
                skipSpace()
                guard index < text.count, depth < 16 else { return nil }
                let byte = text[index]
                if byte == 0x28 {
                    index += 1
                    depth += 1
                    defer { depth -= 1 }
                    guard let value = sum() else { return nil }
                    skipSpace()
                    guard index < text.count, text[index] == 0x29 else { return nil }
                    index += 1
                    return value
                }
                if Tokenizer.isLetter(byte) || byte == 0x2D && index + 1 < text.count && Tokenizer.isLetter(text[index + 1]) {
                    var end = index
                    while end < text.count, Tokenizer.isLetter(text[end]) || text[end] == 0x2D { end += 1 }
                    let name = String(decoding: text[index..<end], as: UTF8.self)
                    guard end < text.count, text[end] == 0x28 else { return nil }
                    index = end + 1
                    depth += 1
                    defer { depth -= 1 }
                    var arguments: [Double] = []
                    while true {
                        guard let value = sum() else { return nil }
                        arguments.append(value)
                        skipSpace()
                        guard index < text.count else { return nil }
                        if text[index] == 0x2C {
                            index += 1
                            continue
                        }
                        guard text[index] == 0x29 else { return nil }
                        index += 1
                        break
                    }
                    switch name {
                    case "calc", "-webkit-calc": return arguments.count == 1 ? arguments[0] : nil
                    case "min": return arguments.min()
                    case "max": return arguments.max()
                    case "clamp": return arguments.count == 3 ? max(arguments[0], min(arguments[1], arguments[2])) : nil
                    case "abs": return arguments.count == 1 ? abs(arguments[0]) : nil
                    default: return nil
                    }
                }
                return dimension()
            }

            /// A number with its unit, in pixels.
            private mutating func dimension() -> Double? {
                let start = index
                if index < text.count, text[index] == 0x2B || text[index] == 0x2D { index += 1 }
                while index < text.count, (0x30...0x39).contains(text[index]) || text[index] == 0x2E { index += 1 }
                if index < text.count, text[index] | 0x20 == 0x65, index + 1 < text.count,
                   (0x30...0x39).contains(text[index + 1]) || ((text[index + 1] == 0x2D || text[index + 1] == 0x2B) && index + 2 < text.count && (0x30...0x39).contains(text[index + 2])) {
                    index += 2
                    while index < text.count, (0x30...0x39).contains(text[index]) { index += 1 }
                }
                guard index > start, let number = Double(String(decoding: text[start..<index], as: UTF8.self)), number.isFinite else { return nil }
                let unitStart = index
                while index < text.count, Tokenizer.isLetter(text[index]) || text[index] == 0x25 { index += 1 }
                let unit = String(decoding: text[unitStart..<index], as: UTF8.self).lowercased()
                switch unit {
                case "": return number
                case "px": return number
                case "pt": return number * 4 / 3
                case "pc": return number * 16
                case "in": return number * 96
                case "cm": return number * 96 / 2.54
                case "mm": return number * 96 / 25.4
                case "q": return number * 96 / 101.6
                case "em", "lh", "cap", "ic": return number * measure.fontSize
                case "rem", "rlh": return number * 16
                case "ex", "ch": return number * measure.fontSize / 2
                case "vw", "vh", "vmin", "vmax", "vi", "vb", "svw", "svh", "lvw", "lvh", "dvw", "dvh", "svmin", "svmax",
                     "lvmin", "lvmax", "dvmin", "dvmax", "cqw", "cqh", "cqi", "cqb", "cqmin", "cqmax":
                    return number * measure.viewport / 100
                case "%": return measure.percentBase.map { number * $0 / 100 } ?? (number == 0 ? 0 : nil)
                default: return unitless && number == 0 ? 0 : nil
                }
            }
        }
    }
}

// MARK: Boxes

nonisolated extension VisibleText {
    /// What one element sets for itself, the last value of each property winning. Nil
    /// leaves a property as the parent has it, or as it starts.
    private struct Box {
        var display: String?
        var visibility: String?
        var contentHidden: Bool?
        var opacity: Double?
        var filter: (opacity: Double, hides: Bool)?
        var fontSize: Double?
        var zoom: Double?
        var letterSpacing: Double?
        var preformatted: Bool?
        var color: Paint?
        var textFill: Paint?
        var background: Paint?
        var backgroundImage: Bool?
        /// The colors of a background gradient, which hides text only when it holds the
        /// text's color alone.
        var gradient: [Color]?
        var position: String?
        var floats: Bool?
        var left: Double?
        var top: Double?
        var right: Double?
        var bottom: Double?
        var textIndent: Double?
        var marginLeft: Double?
        var marginRight: Double?
        var marginTop: Double?
        var width: Double?
        var height: Double?
        var maxWidth: Double?
        var maxHeight: Double?
        var overflowHidden: Bool?
        var clip: Bool?
        var clipPath: Bool?
        var mask: Bool?
        var transform: Transform?
        var translateProperty: Transform?
        var scaleProperty: Transform?
        var rotateProperty: Transform?
        var animations: [String]?

        /// What a transform does to text: hides it, or scales it.
        struct Transform {
            var hides = false
            var scale = 1.0
        }

        /// How the element lays out: block, inline or a part of a table, from its display,
        /// its tag, and whether it floats or is positioned, which makes it a block.
        func layout(of name: String) -> Layout {
            let value = display ?? Layout.defaultDisplay(name)
            let isTaken = position == "absolute" || position == "fixed" || floats == true
            if value == "inline" || value == "contents" { return isTaken ? .block : .inline }
            if value.hasPrefix("table") && value != "table-caption" { return value == "table-cell" ? .cell : .tablePart }
            return value.hasPrefix("inline") ? .inlineBlock : .block
        }

        enum Layout {
            case block, inlineBlock, inline, cell, tablePart

            static func defaultDisplay(_ name: String) -> String {
                switch name {
                case "table": "table"
                case "tr": "table-row"
                case "td", "th": "table-cell"
                case "tbody", "thead", "tfoot": "table-row-group"
                case "col": "table-column"
                case "colgroup": "table-column-group"
                case "caption": "table-caption"
                case "button", "select", "textarea", "input", "img", "marquee", "video", "canvas", "iframe", "embed", "object":
                    "inline-block"
                default: blocks.contains(name) ? "block" : "inline"
                }
            }

            private static let blocks: Set<String> = [
                "html", "body", "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd",
                "blockquote", "pre", "section", "article", "header", "footer", "nav", "aside", "main", "figure",
                "figcaption", "address", "center", "form", "fieldset", "details", "summary", "hr", "legend", "dialog",
                "search", "hgroup", "menu", "dir", "listing", "xmp", "plaintext", "optgroup", "option", "frameset",
            ]
        }

        /// Whether the element's own box moves its content away or hides it, for the
        /// properties that apply to its layout: an inline box has no size, transform or
        /// clip of its own, and a table cell no margins.
        func isOffScreen(_ layout: Layout) -> Bool {
            let positioned = position.map { $0 != "static" } ?? false
            if positioned, (left ?? 0) <= -500 || (top ?? 0) <= -500 || (right ?? 0) >= 1_000 || (bottom ?? 0) >= 1_000 { return true }
            if positioned, (left ?? 0) >= 5_000 { return true }
            if layout == .block || layout == .inlineBlock, (marginLeft ?? 0) <= -500 || (marginTop ?? 0) <= -500 { return true }
            if layout == .block || layout == .inlineBlock, overflowHidden == true,
               [width, height, maxWidth, maxHeight].contains(where: { ($0 ?? 2) <= 1 }) { return true }
            guard layout != .inline else { return false }
            return [transform, translateProperty, scaleProperty, rotateProperty].contains { $0?.hides == true }
        }

        func isClipped(_ layout: Layout) -> Bool {
            let isAbsolute = position == "absolute" || position == "fixed"
            return (clip == true && isAbsolute) || clipPath == true || mask == true
        }

        func scale(_ layout: Layout) -> Double {
            let transforms = layout == .inline ? [] : [transform, translateProperty, scaleProperty, rotateProperty]
            return transforms.reduce(zoom ?? 1) { $0 * ($1?.scale ?? 1) }
        }

        /// Applies a declaration, with its value after var() is replaced when it has one.
        mutating func apply(_ declaration: Declaration, resolved: String?, parentFontSize: Double) {
            guard let property = declaration.property else { return }
            let value = resolved ?? declaration.value
            let words = resolved.map { CSS.words($0).map(String.init) } ?? declaration.words
            let first = words.first ?? value
            let font = Measure(fontSize: fontSize ?? parentFontSize, viewport: 320, percentBase: nil)
            // Text moved away counts with a wide window and percentages of 500 pixels.
            let offset = Measure(fontSize: fontSize ?? parentFontSize, viewport: 2_000, percentBase: 500)
            let size = Measure(fontSize: fontSize ?? parentFontSize, viewport: 320, percentBase: nil)
            if words.count == 1, first == "inherit" || Self.resets(first) {
                reset(property, to: first, parentFontSize: parentFontSize)
                return
            }
            switch property {
            case .display: display = first
            case .visibility: visibility = first
            case .contentVisibility: contentHidden = first == "hidden"
            case .opacity:
                if let number = Measure.number(first) { opacity = min(max(number, 0), 1) } else if Self.resets(first) { opacity = 1 }
            case .filter, .webkitFilter: filter = Self.filter(value)
            case .fontSize:
                if let size = Self.fontSize(first, parent: parentFontSize) { fontSize = size }
            case .font: if let size = Self.fontSizeInShorthand(value, parent: parentFontSize) { fontSize = size }
            case .zoom:
                if let number = Measure.number(first), number > 0 { zoom = number } else if first == "normal" || first == "0" || Self.resets(first) { zoom = 1 }
            case .letterSpacing: letterSpacing = first == "normal" ? 0 : font.pixels(first)
            case .whiteSpace, .whiteSpaceCollapse:
                preformatted = ["pre", "pre-wrap", "pre-line", "break-spaces", "preserve", "preserve-breaks", "preserve-spaces"].contains(first)
            case .color: if let paint = Paint(css: value) { color = paint }
            case .textFillColor: if let paint = Paint(css: value) { textFill = paint }
            case .backgroundColor: if let paint = Paint(css: value) { background = paint }
            case .background, .backgroundImage:
                // The color is in the last layer of the shorthand.
                let layers = CSS.split(Substring(value), at: ",")
                let images = layers.contains { $0.contains("url(") || $0.contains("gradient(") || $0.contains("image(") || $0.contains("element(") }
                backgroundImage = images
                gradient = images ? Self.gradientColors(value) : nil
                if property == .background {
                    background = .color(.clear)
                    for word in CSS.words(String(layers.last ?? "")) {
                        if let paint = Paint(css: String(word)) {
                            background = paint
                            break
                        }
                    }
                }
            case .position: position = first
            case .float: floats = first == "left" || first == "right" || first == "inline-start" || first == "inline-end"
            case .left: left = Self.offset(first, offset) ?? left
            case .top: top = Self.offset(first, offset) ?? top
            case .right: right = Self.offset(first, offset) ?? right
            case .bottom: bottom = Self.offset(first, offset) ?? bottom
            case .inset:
                let sides = Self.sides(words, offset)
                top = sides[0] ?? top
                right = sides[1] ?? right
                bottom = sides[2] ?? bottom
                left = sides[3] ?? left
            case .textIndent: textIndent = Self.offset(first, offset) ?? textIndent
            case .margin:
                let sides = Self.sides(words, offset)
                marginTop = sides[0] ?? marginTop
                marginRight = sides[1] ?? marginRight
                marginLeft = sides[3] ?? marginLeft
            case .marginLeft: marginLeft = Self.offset(first, offset) ?? marginLeft
            case .marginRight: marginRight = Self.offset(first, offset) ?? marginRight
            case .marginTop: marginTop = Self.offset(first, offset) ?? marginTop
            case .width: width = size.pixels(first) ?? width
            case .height: height = size.pixels(first) ?? height
            case .maxWidth: maxWidth = first == "none" ? nil : size.pixels(first) ?? maxWidth
            case .maxHeight: maxHeight = first == "none" ? nil : size.pixels(first) ?? maxHeight
            case .overflow, .overflowX, .overflowY:
                // A box of a pixel that scrolls shows no more than one that clips.
                let clips = words.contains { $0 == "hidden" || $0 == "clip" || $0 == "scroll" || $0 == "auto" }
                if clips || property == .overflow { overflowHidden = clips }
            case .clip: clip = Self.isEmptyRect(value)
            case .clipPath, .webkitClipPath: clipPath = Self.clipPathHides(value)
            case .mask, .maskImage, .webkitMask, .webkitMaskImage:
                mask = !(first == "none" || Self.resets(first)) && (value.contains("url(") || value.contains("gradient(") || value.contains("image("))
            case .transform, .webkitTransform: transform = Self.transform(value)
            case .translate: translateProperty = Self.translate(words, offset)
            case .scale: scaleProperty = Self.scale(words)
            case .rotate: rotateProperty = Self.rotate(words)
            case .animation, .animationName, .webkitAnimation, .webkitAnimationName:
                animations = (animations ?? []) + CSS.split(Substring(value), at: ",").flatMap { CSS.words(String($0)).map(String.init) }
            }
        }

        /// The hiding value of a property whose value this reader cannot work out.
        mutating func hide(by declaration: Declaration) {
            guard let property = declaration.property else { return }
            switch property {
            case .display: display = "none"
            case .visibility: visibility = "hidden"
            case .contentVisibility: contentHidden = true
            case .opacity: opacity = 0
            case .filter, .webkitFilter: filter = (0, true)
            case .fontSize, .font: fontSize = 0
            case .zoom: zoom = 0.01
            case .color: color = .unknown
            case .textFillColor: textFill = .unknown
            case .background, .backgroundColor: background = .unknown
            case .clip: clip = true
            case .clipPath, .webkitClipPath: clipPath = true
            case .mask, .maskImage, .webkitMask, .webkitMaskImage: mask = true
            case .transform, .webkitTransform: transform = Transform(hides: true)
            case .translate: translateProperty = Transform(hides: true)
            case .scale: scaleProperty = Transform(hides: true)
            case .rotate: rotateProperty = Transform(hides: true)
            case .position: position = "absolute"
            case .left, .textIndent, .marginLeft, .margin, .inset: (left, textIndent, marginLeft) = (-10_000, -10_000, -10_000)
            case .top, .marginTop: (top, marginTop) = (-10_000, -10_000)
            case .letterSpacing: letterSpacing = -10_000
            default: break
            }
        }

        /// A keyword such as inherit or initial: the property as the parent has it, or as it
        /// starts. For display, initial and unset are inline, and revert is the tag's own.
        private mutating func reset(_ property: Property, to keyword: String, parentFontSize: Double) {
            let inherits = keyword != "initial"
            switch property {
            case .display: display = keyword == "initial" || keyword == "unset" ? "inline" : nil
            case .visibility: visibility = inherits ? nil : "visible"
            case .contentVisibility: contentHidden = false
            case .opacity: opacity = nil
            case .filter, .webkitFilter: filter = nil
            case .fontSize, .font: fontSize = inherits ? parentFontSize : 16
            case .zoom: zoom = nil
            case .letterSpacing: letterSpacing = inherits ? nil : 0
            case .whiteSpace, .whiteSpaceCollapse: preformatted = inherits ? nil : false
            case .color: color = inherits ? .current : .color(.black)
            case .textFillColor: textFill = inherits ? nil : .current
            case .background:
                background = .color(.clear)
                backgroundImage = false
                gradient = nil
            case .backgroundColor: background = .color(.clear)
            case .backgroundImage:
                backgroundImage = false
                gradient = nil
            case .position: position = nil
            case .float: floats = nil
            case .left: left = nil
            case .top: top = nil
            case .right: right = nil
            case .bottom: bottom = nil
            case .inset: (left, top, right, bottom) = (nil, nil, nil, nil)
            case .textIndent: textIndent = nil
            case .margin: (marginLeft, marginRight, marginTop) = (nil, nil, nil)
            case .marginLeft: marginLeft = nil
            case .marginRight: marginRight = nil
            case .marginTop: marginTop = nil
            case .width: width = nil
            case .height: height = nil
            case .maxWidth: maxWidth = nil
            case .maxHeight: maxHeight = nil
            case .overflow, .overflowX, .overflowY: overflowHidden = false
            case .clip: clip = false
            case .clipPath, .webkitClipPath: clipPath = false
            case .mask, .maskImage, .webkitMask, .webkitMaskImage: mask = false
            case .transform, .webkitTransform: transform = nil
            case .translate: translateProperty = nil
            case .scale: scaleProperty = nil
            case .rotate: rotateProperty = nil
            case .animation, .animationName, .webkitAnimation, .webkitAnimationName: animations = nil
            }
        }

        private static func resets(_ value: String) -> Bool {
            ["initial", "unset", "revert", "revert-layer"].contains(value)
        }

        /// An offset, or nil for one this reader cannot read.
        private static func offset(_ text: String, _ measure: Measure) -> Double? {
            text == "auto" || resets(text) ? 0 : measure.pixels(text)
        }

        /// The four sides of a shorthand such as margin: top, right, bottom and left.
        private static func sides(_ words: [String], _ measure: Measure) -> [Double?] {
            let values = words.prefix(4).map { offset($0, measure) }
            switch values.count {
            case 1: return [values[0], values[0], values[0], values[0]]
            case 2: return [values[0], values[1], values[0], values[1]]
            case 3: return [values[0], values[1], values[2], values[1]]
            case 4: return values
            default: return [nil, nil, nil, nil]
            }
        }

        /// A font size in CSS pixels: a length, a percentage of the parent's or a keyword.
        static func fontSize(_ text: String, parent: Double) -> Double? {
            let named: [String: Double] = [
                "xx-small": 9, "x-small": 10, "small": 13, "medium": 16, "large": 18, "x-large": 24, "xx-large": 32, "xxx-large": 48,
                "initial": 16,
            ]
            if let size = named[text] { return size }
            if text == "smaller" { return parent / 1.2 }
            if text == "larger" { return parent * 1.2 }
            if text == "inherit" || text == "unset" || text == "revert" { return parent }
            return Measure(fontSize: parent, viewport: 320, percentBase: parent).pixels(text).map { max($0, 0) }
        }

        /// The size in the font shorthand, as in "font: 0/0 a" or "bold 12px/1.5 Arial". A
        /// number without a unit other than 0 is a weight, as in "700 12px Arial".
        private static func fontSizeInShorthand(_ value: String, parent: Double) -> Double? {
            for word in CSS.words(value) {
                let size = word.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if size != "0", size.allSatisfy(\.isNumber) { continue }
                if let pixels = fontSize(size, parent: parent) { return pixels }
            }
            return nil
        }

        /// opacity() multiplies the opacity, a strong blur() hides text, and brightness(),
        /// contrast(), invert() and filters from a URL may turn text into its background.
        private static func filter(_ value: String) -> (opacity: Double, hides: Bool)? {
            guard value != "none", !resets(value) else { return nil }
            var opacity = 1.0
            var hides = false
            for word in CSS.words(value) {
                guard let open = word.firstIndex(of: "("), word.hasSuffix(")") else {
                    hides = true
                    continue
                }
                let name = word[..<open]
                let argument = String(word[word.index(after: open)..<word.index(before: word.endIndex)]).trimmingCharacters(in: .whitespaces)
                let number = argument.isEmpty ? 1 : Measure.number(argument)
                switch name {
                case "opacity": opacity *= min(max(number ?? 0, 0), 1)
                case "blur": hides = hides || (Measure(fontSize: 16, viewport: 320, percentBase: nil).pixels(argument.isEmpty ? "0" : argument) ?? 99) >= 4
                case "brightness", "contrast": hides = hides || number != 1
                case "invert": hides = hides || number != 0
                case "drop-shadow", "grayscale", "sepia", "saturate", "hue-rotate": break
                default: hides = true
                }
            }
            return (opacity, hides)
        }

        /// rect(top, right, bottom, left) that leaves a pixel or less. auto is the edge of
        /// the box: 0 for top and left, the far side for bottom and right.
        private static func isEmptyRect(_ value: String) -> Bool {
            guard value.hasPrefix("rect(") else { return false }
            let parts = value.dropFirst(5).split(whereSeparator: { $0 == "," || $0 == " " || $0 == ")" })
            guard parts.count == 4 else { return false }
            let measure = Measure(fontSize: 16, viewport: 320, percentBase: nil)
            let edges = parts.enumerated().map { side, part in
                part == "auto" ? (side == 0 || side == 3 ? 0 : 100_000) : (measure.pixels(part) ?? 100_000)
            }
            return edges[2] - edges[0] <= 1 || edges[1] - edges[3] <= 1
        }

        /// Whether a clip path leaves nothing: an inset that meets itself, a circle or
        /// ellipse of no size, a polygon of no area, or a shape this reader cannot measure,
        /// such as one from a URL.
        private static func clipPathHides(_ value: String) -> Bool {
            let shape = Substring(value.trimmingCharacters(in: .whitespaces))
            guard shape != "none", !resets(String(shape)) else { return false }
            let boxes = ["margin-box", "border-box", "padding-box", "content-box", "fill-box", "stroke-box", "view-box"]
            if boxes.contains(String(shape)) { return false }
            let percent = Measure(fontSize: 16, viewport: 320, percentBase: 100)
            if let inner = CSS.arguments(of: "inset", in: shape) {
                let words = CSS.words(String(inner.split(separator: "r").first ?? inner)).prefix(4)
                let values = words.map { percent.pixels($0) }
                guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return true }
                let sides = values.compactMap { $0 }
                let all: [Double]
                switch sides.count {
                case 1: all = [sides[0], sides[0], sides[0], sides[0]]
                case 2: all = [sides[0], sides[1], sides[0], sides[1]]
                case 3: all = [sides[0], sides[1], sides[2], sides[1]]
                default: all = Array(sides.prefix(4))
                }
                return all[0] + all[2] >= 99 || all[1] + all[3] >= 99
            }
            if let inner = CSS.arguments(of: "circle", in: shape) ?? CSS.arguments(of: "ellipse", in: shape) {
                let radii = CSS.words(String(inner.components(separatedBy: " at ").first ?? String(inner)))
                guard !radii.isEmpty else { return false }
                return radii.contains { (percent.pixels($0) ?? 1) <= 0.5 }
            }
            if let inner = CSS.arguments(of: "polygon", in: shape) {
                var points: [(Double, Double)] = []
                for piece in CSS.split(inner, at: ",") {
                    let coordinates = CSS.words(String(piece)).compactMap { percent.pixels($0) }
                    guard coordinates.count == 2 else { continue }
                    points.append((coordinates[0], coordinates[1]))
                }
                guard points.count >= 3 else { return true }
                var area = 0.0
                for index in points.indices {
                    let (x1, y1) = points[index]
                    let (x2, y2) = points[(index + 1) % points.count]
                    area += x1 * y2 - x2 * y1
                }
                return abs(area) / 2 <= 1
            }
            return true
        }

        /// What a transform does: scales to nothing, turns edge on, moves off screen, or
        /// scales text smaller.
        private static func transform(_ value: String) -> Transform? {
            guard value != "none", !resets(value) else { return nil }
            var result = Transform()
            let offset = Measure(fontSize: 16, viewport: 2_000, percentBase: 500)
            var rest = Substring(value)
            while let open = rest.firstIndex(of: "("), let close = CSS.closingParenthesis(rest, from: open) {
                let name = rest[..<open].trimmingCharacters(in: .whitespaces)
                let arguments = CSS.split(rest[rest.index(after: open)..<close], at: ",")
                    .flatMap { CSS.words(String($0)) }
                    .map { String($0) }
                rest = rest[rest.index(after: close)...]
                let numbers = arguments.map { Measure.number($0) }
                switch name {
                case "scale", "scalex", "scaley", "scale3d":
                    for number in numbers.prefix(name == "scale3d" ? 2 : 2) {
                        let factor = abs(number ?? 1)
                        if factor <= 0.01 { result.hides = true }
                        result.scale *= min(factor, 1)
                    }
                case "translate", "translatex", "translatey", "translate3d":
                    if arguments.prefix(2).contains(where: { (offset.pixels($0) ?? 0) <= -500 }) { result.hides = true }
                case "matrix", "matrix3d":
                    let m = numbers.map { $0 ?? 1 }
                    let is3d = name == "matrix3d"
                    guard m.count == (is3d ? 16 : 6) else { continue }
                    let (a, b, c, d) = is3d ? (m[0], m[1], m[4], m[5]) : (m[0], m[1], m[2], m[3])
                    let (e, f) = is3d ? (m[12], m[13]) : (m[4], m[5])
                    let scaleX = (a * a + b * b).squareRoot()
                    let scaleY = (c * c + d * d).squareRoot()
                    if scaleX <= 0.01 || scaleY <= 0.01 || abs(a * d - b * c) <= 0.0001 || e <= -500 || f <= -500 { result.hides = true }
                    result.scale *= min(scaleX, scaleY, 1)
                case "rotatex", "rotatey", "skew", "skewx", "skewy":
                    for argument in arguments.prefix(2) where abs(cos((Measure.degrees(argument) ?? 0) * .pi / 180)) <= 0.02 {
                        result.hides = true
                    }
                case "rotate3d":
                    if arguments.count == 4, let angle = Measure.degrees(arguments[3]),
                       (numbers[0] ?? 0) != 0 || (numbers[1] ?? 0) != 0, abs(cos(angle * .pi / 180)) <= 0.02 {
                        result.hides = true
                    }
                case "rotate", "rotatez", "perspective":
                    break
                default:
                    result.hides = true
                }
            }
            return result
        }

        private static func translate(_ words: [String], _ offset: Measure) -> Transform? {
            guard let first = words.first, first != "none" else { return nil }
            var result = Transform()
            if words.prefix(2).contains(where: { (offset.pixels($0) ?? 0) <= -500 }) { result.hides = true }
            return result
        }

        private static func scale(_ words: [String]) -> Transform? {
            guard let first = words.first, first != "none" else { return nil }
            var result = Transform()
            for word in words.prefix(2) {
                let factor = abs(Measure.number(word) ?? 1)
                if factor <= 0.01 { result.hides = true }
                result.scale *= min(factor, 1)
            }
            return result
        }

        private static func rotate(_ words: [String]) -> Transform? {
            guard let angle = words.last.flatMap({ Measure.degrees($0) }), words.count > 1 else { return nil }
            let axis = words.first ?? ""
            var result = Transform()
            if axis == "x" || axis == "y" || words.count == 4, abs(cos(angle * .pi / 180)) <= 0.02 { result.hides = true }
            return result
        }

        /// The colors a background gradient holds.
        private static func gradientColors(_ value: String) -> [Color]? {
            guard value.contains("gradient(") else { return nil }
            var colors: [Color] = []
            var rest = Substring(value)
            while let open = rest.firstIndex(of: "("), let close = CSS.closingParenthesis(rest, from: open) {
                let name = rest[..<open].split(whereSeparator: { $0 == " " || $0 == "," }).last ?? ""
                if name.hasSuffix("gradient") {
                    for stop in CSS.split(rest[rest.index(after: open)..<close], at: ",") {
                        for word in CSS.words(String(stop)) {
                            switch Paint(css: String(word)) {
                            case .color(let color): colors.append(color)
                            case .current, .unknown: return nil
                            case nil: break
                            }
                        }
                    }
                } else if name.hasSuffix("url") || name.hasSuffix("image") {
                    return nil
                }
                rest = rest[rest.index(after: close)...]
            }
            return colors.isEmpty ? nil : colors
        }
    }

    /// The styles an element and its ancestors give its text.
    private struct Look {
        /// Inside the head, a script, an SVG image or another element whose text no reader
        /// sees as text. Such text is neither shown nor reported.
        var notRendered = false
        var displayNone = false
        var invisible = false
        var contentHidden = false
        var offScreen = false
        var clipped = false
        var opacity = 1.0
        var fontSize = 16.0
        /// What transforms and zoom scale the text by.
        var scale = 1.0
        var letterSpacing = 0.0
        var color = Color.black
        var colorUnknown = false
        var textFill: Color?
        var textFillUnknown = false
        /// The color behind the text, opaque.
        var background = Color.white
        /// False under a background image, which may hide or show any color.
        var backgroundKnown = true
        var gradient: [Color]?
        var preformatted = false
        var quoteDepth = 0
        /// The indent of the first line of a block, which a large negative one moves off
        /// screen.
        var textIndent = 0.0
        /// The custom properties the element inherits and sets.
        var custom: [String: String] = [:]
        /// The custom properties with those the rules that only add hiding set too.
        var conditionalCustom: [String: String] = [:]
        /// How a rule that only adds hiding hides the text.
        var conditionallyHidden: ProjectsHiddenText?
        /// Inside a select, but not in the option it shows.
        var unselected = false

        var hiddenKind: ProjectsHiddenText? {
            if displayNone || invisible || contentHidden || offScreen || clipped || unselected { return .hiddenStyle }
            let text = textFill ?? color
            if opacity < 0.1 || text.alpha < 0.1 { return .transparent }
            // Under 3 points, as FileTextExtractor counts a tiny font, or letters drawn on
            // top of each other.
            if fontSize * scale < 4 || letterSpacing <= -fontSize / 2 { return .tinyFont }
            if textFill == nil ? colorUnknown : textFillUnknown { return .sameColor }
            if backgroundKnown, text.over(background).distance(to: background) < 0.1 { return .sameColor }
            if let gradient, gradient.allSatisfy({ text.over($0.over(background)).distance(to: $0.over(background)) < 0.1 }) { return .sameColor }
            return conditionallyHidden
        }
    }
}

// MARK: Rendering

nonisolated extension VisibleText {
    /// Walks the tree in document order, works out the styles of each element and writes
    /// the text the reader sees, or reports it as hidden.
    private struct Renderer {
        let document: Document
        let sheet: StyleSheet
        private(set) var budget: Budget
        private(set) var isCut = false
        /// Whether the rest of the current line is off screen, after a first line indent
        /// or an inline margin of -500 pixels or less.
        private var lineShifted = false
        /// The body's text color, which a table takes in quirks mode.
        private var bodyColor = Look().color

        private struct Frame {
            var node: Int
            var look: Look
            var next: Int32
            var isShown: Bool
            var layout = Box.Layout.inline
            var shiftsAfter = false
            /// For an inline block, whether the line it sits on was shifted.
            var outerShift = false
            /// Whether the element has boxes, so it may end or shift a line.
            var hasBoxes = true
            /// A details element without open shows its first summary only.
            var isClosedDetails = false
            var summarySeen = false
            var isSelect = false
            var inSelect = false
            /// Inside a select, the option it shows.
            var shownOption: Int?
        }

        init(document: Document, sheet: StyleSheet, budget: Budget) {
            self.document = document
            self.sheet = sheet
            self.budget = budget
        }

        mutating func render(into output: inout Output, hiddenText: inout HiddenText) {
            var frames: [Frame] = []
            enter(Document.root, context: Look(), inSelect: false, shownOption: nil, frames: &frames, output: &output, hiddenText: &hiddenText)
            while let top = frames.indices.last {
                guard budget.spend() else {
                    isCut = true
                    return
                }
                let child = frames[top].next
                guard child >= 0 else {
                    let frame = frames.removeLast()
                    if frame.isShown, let breaks = Self.blockBreaks[document.nodes[frame.node].name] { output.breakLines(breaks) }
                    // A line after a block is no first line, an inline block goes on with
                    // the line it sits on, and a negative right margin pulls what follows
                    // on its line along.
                    if frame.hasBoxes {
                        switch frame.layout {
                        case .inline: break
                        case .inlineBlock: lineShifted = frame.outerShift
                        case .block, .cell, .tablePart: lineShifted = false
                        }
                        if frame.shiftsAfter { lineShifted = true }
                    }
                    continue
                }
                frames[top].next = document.nodes[Int(child)].next
                visit(Int(child), parent: top, frames: &frames, output: &output, hiddenText: &hiddenText)
            }
        }

        private mutating func visit(_ node: Int, parent: Int, frames: inout [Frame], output: inout Output, hiddenText: inout HiddenText) {
            var context = frames[parent].look
            if frames[parent].isClosedDetails {
                if document.isElement(node, "summary"), !frames[parent].summarySeen {
                    frames[parent].summarySeen = true
                } else {
                    context.contentHidden = true
                }
            }
            // A select shows one option, and an option outside a select shows nowhere.
            let shownOption = frames[parent].shownOption
            let inSelect = frames[parent].isSelect || frames[parent].inSelect
            if inSelect {
                if node == shownOption {
                    context.unselected = false
                } else if frames[parent].isSelect {
                    context.unselected = true
                }
            } else if document.isElement(node, "option") || document.isElement(node, "optgroup") {
                context.contentHidden = true
            }
            switch document.nodes[node].kind {
            case .text:
                // Only text takes the shift of its line. An element on it starts lines of
                // its own.
                if lineShifted { context.offScreen = true }
                show(document.text(of: node), look: context, output: &output, hiddenText: &hiddenText)
            case .rawText:
                if lineShifted { context.offScreen = true }
                switch document.nodes[frames[parent].node].name {
                case "textarea": show(document.text(of: node, decodingRaw: true), look: context, output: &output, hiddenText: &hiddenText)
                case "xmp", "plaintext": show(document.text(of: node), look: context, output: &output, hiddenText: &hiddenText)
                default: break
                }
            case .comment:
                let content = document.text(of: node)
                // Outlook's conditional comments, in nearly every newsletter and in mail
                // Outlook writes, hold its own copy of the layout. They are dropped too,
                // but reporting them would mark most mail as hiding text.
                guard !content.hasPrefix("[if") else { return }
                hiddenText.report(.htmlComment, Self.withoutTags(content), minimumWords: 4)
            case .element:
                enter(node, context: context, inSelect: inSelect, shownOption: shownOption, frames: &frames, output: &output, hiddenText: &hiddenText)
            }
        }

        private mutating func enter(_ node: Int, context: Look, inSelect: Bool, shownOption: Int?, frames: inout [Frame], output: inout Output, hiddenText: inout HiddenText) {
            let element = document.nodes[node]
            let name = element.name
            var (look, box) = style(node, parent: context)
            // Styles cut short at the limit may show what they would hide.
            guard !budget.isSpent else {
                isCut = true
                return
            }
            // A box out of the flow, positioned or floating, leaves the line it sits on
            // as it is, as an inline block does.
            let isOutOfFlow = box.position == "absolute" || box.position == "fixed" || box.floats == true
            let layout = isOutOfFlow ? .inlineBlock : box.layout(of: name)
            if node == Document.body { bodyColor = look.color }
            // The first line of a block starts with its indent. An inline box with a
            // negative left margin moves itself and the rest of its line, and an inline
            // block moves with its line.
            let outerShift = lineShifted || (layout != .block && layout != .cell && layout != .tablePart && Self.inlineMargin(box.marginLeft))
            // An element without boxes, as under display none, starts no line.
            let hasBoxes = !(look.displayNone || look.notRendered || look.contentHidden || look.unselected)
            switch hasBoxes ? layout : .inline {
            case .inline:
                guard hasBoxes else { break }
                if !element.isForeign, Self.inlineMargin(box.marginLeft) { lineShifted = true }
            case .inlineBlock:
                if outerShift { look.offScreen = true }
                lineShifted = look.textIndent <= -500
            case .block, .cell:
                lineShifted = look.textIndent <= -500
            case .tablePart:
                lineShifted = false
            }
            let isShown = !look.notRendered && look.hiddenKind == nil
            switch name {
            case "img":
                if !look.notRendered { image(element, box: box, hiddenText: &hiddenText) }
                return
            case "br":
                if isShown { output.lineBreak() }
                if hasBoxes { lineShifted = false }
                return
            case "li":
                if isShown {
                    output.breakLines(1)
                    output.addCollapsing("- ", quoteDepth: look.quoteDepth)
                }
            case "td", "th":
                if isShown { output.space() }
            default:
                if isShown, let breaks = Self.blockBreaks[name] { output.breakLines(breaks) }
            }
            guard !Self.voidElements.contains(name) else { return }
            var frame = Frame(node: node, look: look, next: element.first, isShown: isShown, shownOption: shownOption)
            frame.layout = layout
            frame.outerShift = outerShift
            frame.hasBoxes = hasBoxes
            frame.inSelect = inSelect
            frame.shiftsAfter = layout == .inline && Self.inlineMargin(box.marginRight)
            if !element.isForeign {
                frame.isClosedDetails = name == "details" && element.attributes["open"] == nil
                if name == "select" {
                    frame.isSelect = true
                    frame.shownOption = self.shownOption(of: node)
                }
                // An option with a label shows the label, not its text.
                if node == shownOption, name == "option", let label = element.attributes["label"], !label.isEmpty {
                    show(label, look: look, output: &output, hiddenText: &hiddenText)
                    frame.look.unselected = true
                }
            }
            frames.append(frame)
        }

        /// The option a select shows: the last one selected, or else the first one that is
        /// not disabled.
        private mutating func shownOption(of select: Int) -> Int? {
            var selected: Int?
            var first: Int?
            var firstEnabled: Int?
            var pending = [select]
            while let node = pending.popLast() {
                guard budget.spend() else { break }
                var child = document.nodes[node].last
                while child >= 0 {
                    let index = Int(child)
                    if document.isElement(index, "option") {
                        if document.nodes[index].attributes["selected"] != nil, selected == nil || index > selected! { selected = index }
                        if first == nil || index < first! { first = index }
                        if document.nodes[index].attributes["disabled"] == nil, firstEnabled == nil || index < firstEnabled! { firstEnabled = index }
                    } else if document.nodes[index].kind == .element {
                        pending.append(index)
                    }
                    child = document.nodes[index].previous
                }
            }
            return selected ?? firstEnabled ?? first
        }

        private mutating func show(_ text: String, look: Look, output: inout Output, hiddenText: inout HiddenText) {
            guard !look.notRendered else { return }
            if let kind = look.hiddenKind {
                hiddenText.add(kind, text)
                return
            }
            if text.unicodeScalars.contains(where: { !Output.isCollapsible($0) }) { hiddenText.finish() }
            if look.preformatted {
                output.addPreformatted(text, quoteDepth: look.quoteDepth)
            } else {
                output.addCollapsing(text, quoteDepth: look.quoteDepth)
            }
        }

        /// The alt and title text of an image, which the reader does not see while the
        /// image shows.
        private func image(_ element: Node, box: Box, hiddenText: inout HiddenText) {
            let text = [element.attributes["alt"], element.attributes["title"]].compactMap { $0 }.joined(separator: " ")
            let tiny = [element.attributes["width"], element.attributes["height"]].contains { value in
                value.flatMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: "")) }.map { $0 <= 2 } ?? false
            } || [box.width, box.height].contains { ($0 ?? 3) <= 2 }
            hiddenText.report(.imageText, text, minimumWords: tiny ? 1 : 4)
        }

        /// The text of a comment without markup.
        private static func withoutTags(_ text: String) -> String {
            var result = ""
            var inTag = false
            for character in text {
                switch character {
                case "<": inTag = true
                case ">" where inTag: inTag = false
                case _ where !inTag: result.append(character)
                default: break
                }
            }
            return result
        }

        // MARK: Styles

        /// The look of an element: its parent's, with what its tag, its attributes, the
        /// style sheets and its style attribute set. The box is what the element set for
        /// itself.
        private mutating func style(_ node: Int, parent: Look) -> (Look, Box) {
            let element = document.nodes[node]
            let name = element.name
            var box = Box()
            // Browser defaults and old attributes first, since every style overrides them.
            if element.attributes["hidden"] != nil { box.display = "none" }
            if !element.isForeign {
                switch name {
                case "dialog":
                    if element.attributes["open"] == nil { box.display = "none" }
                case "rp":
                    box.display = "none"
                case "mark":
                    box.background = .color(.mark)
                    box.color = .color(.black)
                case "button", "select":
                    box.background = .color(Color(red: 239.0 / 255, green: 239.0 / 255, blue: 239.0 / 255, alpha: 1))
                    box.color = .color(.black)
                case "textarea", "input":
                    box.background = .color(.white)
                    box.color = .color(.black)
                case "a", "area":
                    if element.attributes["href"] != nil { box.color = .color(.link) }
                case "font":
                    if let value = element.attributes["color"], let paint = Paint(css: value, bare: true) { box.color = paint }
                    if let value = element.attributes["size"] { box.fontSize = Self.fontSize(attribute: value) }
                case "body":
                    if let value = element.attributes["text"], let paint = Paint(css: value, bare: true) { box.color = paint }
                default:
                    break
                }
                if Self.backgroundElements.contains(name) {
                    if let value = element.attributes["bgcolor"], let paint = Paint(css: value, bare: true) { box.background = paint }
                    if element.attributes["background"] != nil { box.backgroundImage = true }
                }
            }

            var ordered: [Declaration] = []
            var onlyHiding: [(declarations: [Declaration], checksColors: Bool)] = []
            let conditional = element.unknownReferences.contains("style")
                || (!sheet.isEmpty && (element.unknownReferences.contains("class") || element.unknownReferences.contains("id")))
            if !sheet.isEmpty {
                let candidates = sheet.candidates(id: element.attributes["id"], classes: element.lowercaseClasses, tag: name)
                if !budget.spend(candidates.count * Self.candidateSteps) { isCut = true }
                var matched: [Rule] = []
                for index in candidates where !budget.isSpent {
                    let rule = sheet.rules[index]
                    if matches(rule.selector, part: 0, node) { matched.append(rule) }
                }
                matched.sort { ($0.selector.specificity, $0.order) < ($1.selector.specificity, $1.order) }
                var important: [Declaration] = []
                for rule in matched {
                    if rule.onlyHides {
                        onlyHiding.append((rule.declarations, rule.checksColors))
                    } else {
                        ordered += rule.declarations.filter { !$0.important }
                        important += rule.declarations.filter(\.important)
                    }
                }
                let inline = element.attributes["style"].map { Declaration.list(CSS.withoutComments(Array($0.utf8))[...]) } ?? []
                ordered += inline.filter { !$0.important }
                ordered += important
                ordered += inline.filter(\.important)
            } else if let style = element.attributes["style"] {
                let inline = Declaration.list(CSS.withoutComments(Array(style.utf8))[...])
                ordered = inline.filter { !$0.important } + inline.filter(\.important)
            }

            var custom = parent.custom
            var conditionalCustom = parent.conditionalCustom
            for declaration in ordered where declaration.property == nil {
                custom[declaration.name] = declaration.value
                conditionalCustom[declaration.name] = declaration.value
            }
            for trial in onlyHiding {
                for declaration in trial.declarations where declaration.property == nil { conditionalCustom[declaration.name] = declaration.value }
            }

            var usesVariables = false
            for declaration in ordered where declaration.property != nil {
                usesVariables = usesVariables || declaration.hasVariable
                apply(declaration, to: &box, custom: custom, parentFontSize: parent.fontSize)
            }
            var look = compose(parent, box, element: element)
            look.custom = custom
            look.conditionalCustom = conditionalCustom

            // Rules that only add hiding, animations and the variables those rules set:
            // each may hide the text, but may not show it.
            if look.hiddenKind == nil {
                var trials = onlyHiding
                if let animations = box.animations {
                    for animation in animations { if let frames = sheet.keyframes[animation] { trials.append((frames, false)) } }
                }
                if usesVariables, conditionalCustom != custom {
                    trials.append((ordered.filter { $0.hasVariable }, false))
                }
                for (declarations, checksColors) in trials {
                    var trial = box
                    for declaration in declarations {
                        guard let property = declaration.property, checksColors || !Self.colorProperties.contains(property) else { continue }
                        apply(declaration, to: &trial, custom: conditionalCustom, parentFontSize: parent.fontSize)
                    }
                    if let kind = compose(parent, trial, element: element).hiddenKind {
                        look.conditionallyHidden = kind
                        break
                    }
                }
                if conditional, look.conditionallyHidden == nil { look.conditionallyHidden = .hiddenStyle }
            }
            return (look, box)
        }

        private static let colorProperties: Set<Property> = [.color, .textFillColor, .background, .backgroundColor, .backgroundImage]
        /// The steps a candidate rule and an applied declaration count for, near what they
        /// cost next to a byte of markup, so the step limit also limits the time.
        private static let candidateSteps = 4
        private static let declarationSteps = 8

        private mutating func apply(_ declaration: Declaration, to box: inout Box, custom: [String: String], parentFontSize: Double) {
            // Applying a declaration takes far longer than reading a byte of markup.
            guard budget.spend(Self.declarationSteps) else { return }
            var value: String?
            if declaration.hasVariable {
                var work = 0
                let resolution = Self.resolved(declaration.value, custom, resolving: [], work: &work)
                _ = budget.spend(work)
                switch resolution {
                case .value(let text):
                    value = text.lowercased()
                case .missing:
                    // A variable that is missing makes the declaration count as unset.
                    value = "unset"
                case .tooLarge:
                    // Past the limits a browser still resolves it, so the declaration may hide.
                    box.hide(by: declaration)
                    return
                }
            }
            box.apply(declaration, resolved: value, parentFontSize: parentFontSize)
        }

        private enum Resolution {
            case value(String)
            /// A variable that is not set or refers to itself, without a fallback.
            case missing
            /// Variables nested or repeated past the limits of this reader.
            case tooLarge
        }

        /// The value with every var() replaced by the custom property it names, or else by
        /// its fallback.
        private static func resolved(_ value: String, _ custom: [String: String], resolving: [String], work: inout Int) -> Resolution {
            guard resolving.count < Self.maximumVariableDepth else { return .tooLarge }
            var result = ""
            var rest = Substring(value)
            while let range = rest.range(of: "var(", options: .caseInsensitive) {
                work += 1 + range.lowerBound.utf16Offset(in: rest) / 64
                guard work <= Self.maximumVariableWork else { return .tooLarge }
                let open = rest.index(before: range.upperBound)
                guard let close = CSS.closingParenthesis(rest, from: open) else { return .missing }
                result += rest[..<range.lowerBound]
                let inside = rest[range.upperBound..<close]
                let parts = CSS.split(inside, at: ",")
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                var replacement = Resolution.missing
                if !resolving.contains(name), let defined = custom[name] {
                    replacement = resolved(defined, custom, resolving: resolving + [name], work: &work)
                }
                if case .missing = replacement, parts.count > 1 {
                    let fallback = inside[inside.index(after: parts[0].endIndex)...]
                    replacement = resolved(fallback.trimmingCharacters(in: .whitespaces), custom, resolving: resolving, work: &work)
                }
                guard case .value(let text) = replacement else { return replacement }
                result += text
                guard result.utf8.count <= Self.maximumVariableBytes else { return .tooLarge }
                rest = rest[rest.index(after: close)...]
            }
            return .value(result + rest)
        }

        private static let maximumVariableDepth = 64
        private static let maximumVariableWork = 1_000
        private static let maximumVariableBytes = 16_384

        private static func inlineMargin(_ margin: Double?) -> Bool {
            (margin ?? 0) <= -500
        }

        /// The look of an element from its parent's and its box.
        private func compose(_ parent: Look, _ box: Box, element: Node) -> Look {
            let name = element.name
            let layout = box.layout(of: name)
            var look = parent
            // In quirks mode a table takes the body's text color and a medium font, not
            // its parent's.
            if sheet.quirks, name == "table", !element.isForeign {
                if box.color == nil {
                    look.color = bodyColor
                    look.colorUnknown = false
                }
                if box.fontSize == nil { look.fontSize = 16 }
            }
            look.notRendered = parent.notRendered || element.isForeign || Self.notRenderedElements.contains(name)
            look.preformatted = box.preformatted ?? (Self.preformattedElements.contains(name) || parent.preformatted)
            if name == "blockquote" { look.quoteDepth += 1 }
            look.displayNone = parent.displayNone || box.display == "none"
            switch box.visibility {
            case "hidden", "collapse": look.invisible = true
            case "visible", "initial": look.invisible = false
            default: break
            }
            look.contentHidden = parent.contentHidden || (box.contentHidden == true && layout != .inline)
            look.offScreen = parent.offScreen || box.isOffScreen(layout)
            look.clipped = parent.clipped || box.isClipped(layout) || box.filter?.hides == true
            look.opacity = parent.opacity * (box.opacity ?? 1) * (box.filter?.opacity ?? 1)
            look.scale = parent.scale * box.scale(layout)
            if let indent = box.textIndent { look.textIndent = indent }
            if let size = box.fontSize { look.fontSize = size }
            if let spacing = box.letterSpacing { look.letterSpacing = spacing }
            switch box.color {
            case .color(let color):
                look.color = color
                look.colorUnknown = false
            case .unknown:
                look.colorUnknown = true
            case .current, nil:
                break
            }
            switch box.textFill {
            case .color(let color):
                look.textFill = color
                look.textFillUnknown = false
            case .unknown:
                look.textFill = look.color
                look.textFillUnknown = true
            case .current:
                look.textFill = nil
                look.textFillUnknown = false
            case nil:
                break
            }
            switch box.background {
            case .color(let color) where color.alpha >= 0.1:
                look.background = color.over(parent.background)
                if color.alpha >= 0.9 {
                    look.backgroundKnown = true
                    look.gradient = nil
                }
            case .current:
                look.background = (look.textFill ?? look.color).over(parent.background)
                look.backgroundKnown = true
                look.gradient = nil
            case .unknown:
                look.backgroundKnown = false
            default:
                break
            }
            if box.backgroundImage == true {
                if let gradient = box.gradient { look.gradient = gradient } else { look.backgroundKnown = false }
            }
            return look
        }

        /// The size of <font size>, 1 to 7, or relative as +1 or -2. A number past 7 counts
        /// as 7 before the sign applies, which gives the same size and never overflows.
        private static func fontSize(attribute: String) -> Double? {
            let value = attribute.trimmingCharacters(in: .whitespaces)
            guard var size = Int(value.drop { $0 == "+" || $0 == "-" }).map({ min($0, 7) }) else { return nil }
            if value.hasPrefix("+") { size = 3 + size } else if value.hasPrefix("-") { size = 3 - size }
            let sizes: [Double] = [10, 13, 16, 18, 24, 32, 48]
            return sizes[min(max(size, 1), 7) - 1]
        }

        // MARK: Selectors

        /// Whether the element matches the selector from `part` leftward.
        private mutating func matches(_ selector: StyleSelector, part index: Int, _ element: Int) -> Bool {
            guard budget.spend(), matches(selector.parts[index], element) else { return false }
            guard index + 1 < selector.parts.count else { return true }
            switch selector.combinators[index] {
            case .child:
                guard let parent = document.parentElement(element) else { return false }
                return matches(selector, part: index + 1, parent)
            case .descendant:
                var ancestor = document.parentElement(element)
                while let candidate = ancestor, !budget.isSpent {
                    if matches(selector, part: index + 1, candidate) { return true }
                    ancestor = document.parentElement(candidate)
                }
                return false
            case .adjacent:
                guard let sibling = document.previousElement(element) else { return false }
                return matches(selector, part: index + 1, sibling)
            case .sibling:
                var sibling = document.previousElement(element)
                while let candidate = sibling, !budget.isSpent {
                    if matches(selector, part: index + 1, candidate) { return true }
                    sibling = document.previousElement(candidate)
                }
                return false
            }
        }

        private mutating func matches(_ part: SelectorPart, _ element: Int) -> Bool {
            let node = document.nodes[element]
            guard node.kind == .element else { return false }
            if let tag = part.tag, tag != node.name { return false }
            if let id = part.id {
                guard let own = node.attributes["id"], sheet.quirks ? own.lowercased() == part.lowercaseID : own == id else { return false }
            }
            if sheet.quirks {
                for name in part.lowercaseClasses where !node.lowercaseClasses.contains(name) { return false }
            } else {
                for name in part.classes where !node.classes.contains(name) { return false }
            }
            for test in part.attributes where !Self.matches(test, node) { return false }
            for pseudo in part.pseudoClasses {
                guard matches(pseudo, element) else { return false }
            }
            return true
        }

        // Classes and ids compare without case in quirks mode, as in Mail.

        private static func matches(_ test: AttributeTest, _ node: Node) -> Bool {
            guard var value = node.attributes[test.name] else { return false }
            if test.ignoresCase { value = value.lowercased() }
            switch test.match {
            case .exists: return true
            case .equals: return value == test.value
            case .word: return !test.value.isEmpty && Node.classes(value).contains(test.value)
            case .dash: return value == test.value || value.hasPrefix(test.value + "-")
            case .prefix: return !test.value.isEmpty && value.hasPrefix(test.value)
            case .suffix: return !test.value.isEmpty && value.hasSuffix(test.value)
            case .contains: return !test.value.isEmpty && value.contains(test.value)
            }
        }

        private mutating func matches(_ pseudo: PseudoClass, _ element: Int) -> Bool {
            let node = document.nodes[element]
            switch pseudo {
            case .root:
                return element == Document.root
            case .empty:
                var child = node.first
                while child >= 0 {
                    if document.nodes[Int(child)].kind != .comment { return false }
                    child = document.nodes[Int(child)].next
                }
                return true
            case .link:
                return (node.name == "a" || node.name == "area") && node.attributes["href"] != nil
            case .checked:
                return (node.name == "input" && node.attributes["checked"] != nil) || (node.name == "option" && node.attributes["selected"] != nil)
            case .disabled:
                return Self.formControls.contains(node.name) && node.attributes["disabled"] != nil
            case .enabled:
                return Self.formControls.contains(node.name) && node.attributes["disabled"] == nil
            case .nth(let a, let b, let ofType, let fromEnd, let of):
                var position = 1
                var sibling = fromEnd ? document.nextElement(element) : document.previousElement(element)
                while let candidate = sibling, budget.spend() {
                    let counts: Bool
                    if ofType {
                        counts = document.nodes[candidate].name == node.name
                    } else if let of {
                        counts = of.contains { matches($0, part: 0, candidate) }
                    } else {
                        counts = true
                    }
                    if counts { position += 1 }
                    sibling = fromEnd ? document.nextElement(candidate) : document.previousElement(candidate)
                }
                if let of, !of.contains(where: { matches($0, part: 0, element) }) { return false }
                if a == 0 { return position == b }
                // a and b fit in 32 bits, see SelectorReader.formula, so this never overflows.
                let steps = position - b
                return steps % a == 0 && steps / a >= 0
            case .not(let selectors):
                // A part this reader does not check might match, so the rule only hides.
                if selectors.contains(where: { !$0.isExact }) { return true }
                return !selectors.contains { matches($0, part: 0, element) }
            case .anyOf(let selectors):
                return selectors.contains { matches($0, part: 0, element) }
            case .never:
                return false
            case .unknown:
                return true
            }
        }

        // MARK: Element sets

        private static let formControls: Set<String> = ["button", "input", "select", "textarea", "option", "optgroup", "fieldset"]
        private static let voidElements: Set<String> = [
            "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input", "keygen", "link",
            "meta", "param", "source", "track", "wbr",
        ]
        /// Blank lines after the block, as plain text mail sets paragraphs apart.
        private static let blockBreaks: [String: Int] = {
            var breaks: [String: Int] = [:]
            for name in ["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "ul", "ol", "dl", "table", "hr", "xmp", "listing"] {
                breaks[name] = 2
            }
            for name in [
                "div", "li", "tr", "dt", "dd", "section", "article", "header", "footer", "nav", "aside", "main", "figure",
                "figcaption", "address", "center", "form", "fieldset", "details", "summary", "caption", "legend", "textarea",
                "body", "html", "option", "dialog", "search", "hgroup", "menu", "dir", "plaintext",
            ] {
                breaks[name] = 1
            }
            return breaks
        }()
        private static let notRenderedElements: Set<String> = [
            "head", "title", "script", "style", "template", "svg", "math", "iframe", "object", "noembed", "noframes",
            "applet", "audio", "video", "canvas", "datalist", "meta", "link", "base", "frameset", "frame",
        ]
        private static let preformattedElements: Set<String> = ["pre", "textarea", "xmp", "listing", "plaintext"]
        private static let backgroundElements: Set<String> = ["body", "table", "tr", "td", "th"]
    }
}
