import Foundation

/// The text a reader sees in an email, as plain text, and the text the email hides from
/// them.
///
/// HTML is read by a parser of its own, never by WebKit and never as an NSAttributedString,
/// so nothing loads and nothing runs. It drops scripts, styles, comments and images, and
/// text that a style hides: display none, visibility hidden, a position off screen or
/// clipped to nothing, a font under 3 points, an opacity or color alpha under 0.1, and text
/// in the color of what lies behind it, the page white unless a color is set. Classes and
/// tags styled in the email's style sheets count like inline styles. Rules for small
/// screens, print and dark mode do not, since Mail on a Mac shows none of them. Links
/// become their text, and quoted mail in a blockquote gets "> " in front of its lines, as
/// in plain text mail.
///
/// Each piece of hidden text is kept as a `Hidden` of its kind, so the window can show the
/// user what the email hides. Hidden text never goes into `text`. Comments and the alt or
/// title text of images are reported only when they hold at least four words, or for an
/// image of two pixels or less, since most emails carry short ones such as "Logo". Plain
/// text bodies pass as they are. PromptHygiene finds what plain text hides.
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
        /// Text past this many bytes is cut.
        var maximumTextBytes = 1 << 20
        /// Hidden pieces past this many are counted in `findings` but not kept.
        var maximumHiddenPieces = 20
        var maximumHiddenLength = 300
        /// Reading stops after this many steps: one per byte of markup, per token, per
        /// open element looked at and per style rule tried.
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
        steps = reader.steps
    }
}

// MARK: Reading

nonisolated extension VisibleText {
    private struct Frame {
        var name: String
        var look: Look
    }

    private struct Reader {
        let limits: Limits
        var output: Output
        var hiddenText: HiddenText
        var steps = 0
        var isCut = false
        var stopped = false

        init(limits: Limits) {
            self.limits = limits
            output = Output(maximumBytes: limits.maximumTextBytes)
            hiddenText = HiddenText(maximumPieces: limits.maximumHiddenPieces, maximumLength: limits.maximumHiddenLength)
        }

        mutating func step(_ count: Int = 1) -> Bool {
            steps += count
            if steps > limits.maximumSteps {
                isCut = true
                stopped = true
            }
            return !stopped
        }

        mutating func read(_ markup: String) {
            var bytes = Array(markup.utf8)
            if bytes.count > limits.maximumMarkupBytes {
                bytes.removeSubrange(limits.maximumMarkupBytes...)
                isCut = true
            }
            guard step(bytes.count) else { return }
            let tokens = Tokenizer.tokens(bytes)
            guard step(tokens.count) else { return }
            var sheet = StyleSheet(maximumRules: limits.maximumRules)
            for case .raw("style", let range) in tokens {
                sheet.add(String(decoding: bytes[range], as: UTF8.self))
            }
            if sheet.isCut { isCut = true }
            guard step(sheet.count) else { return }
            render(tokens, bytes: bytes, sheet: sheet)
        }

        mutating func render(_ tokens: [Token], bytes: [UInt8], sheet: StyleSheet) {
            var stack: [Frame] = []
            let root = Look()
            for token in tokens {
                guard !stopped, step() else { break }
                switch token {
                case .text(let range):
                    if stack.last?.name == "head", bytes[range].contains(where: { !Tokenizer.isSpace($0) }) {
                        // Text in the head starts the body, as in a browser.
                        stack.removeLast()
                    }
                    let look = stack.last?.look ?? root
                    guard !look.notRendered else { continue }
                    show(Entities.decoded(bytes[range]), look: look)
                case .raw(let name, let range):
                    let look = stack.last?.look ?? root
                    guard !look.notRendered else { continue }
                    switch name {
                    case "textarea": show(Entities.decoded(bytes[range]), look: look)
                    case "xmp", "plaintext": show(String(decoding: bytes[range], as: UTF8.self), look: look)
                    default: break
                    }
                case .comment(let range):
                    let content = String(decoding: bytes[range], as: UTF8.self)
                    // Outlook's conditional comments, in nearly every newsletter and in mail
                    // Outlook writes, hold its own copy of the layout. They are dropped too,
                    // but reporting them would mark most mail as hiding text.
                    guard !content.hasPrefix("[if") else { continue }
                    hiddenText.report(.htmlComment, Self.withoutTags(content), minimumWords: 4)
                case .start(let tag):
                    start(tag, stack: &stack, sheet: sheet, root: root)
                case .end(let name):
                    end(name, stack: &stack)
                }
            }
            hiddenText.finish()
        }

        mutating func show(_ text: String, look: Look) {
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

        mutating func start(_ tag: Tag, stack: inout [Frame], sheet: StyleSheet, root: Look) {
            let name = tag.name
            if stack.last?.name == "head", !Self.headElements.contains(name) { stack.removeLast() }
            if name == "body" { stack.removeAll { $0.name == "head" } }
            closeImplicitly(before: name, stack: &stack)
            let parent = stack.last?.look ?? root
            var tried = 0
            let (look, box) = Look.of(tag, parent: parent, sheet: sheet, tried: &tried)
            guard step(tried) else { return }
            let isShown = !look.notRendered && look.hiddenKind == nil
            switch name {
            case "img":
                if !look.notRendered { image(tag, box: box) }
                return
            case "br":
                if isShown { output.lineBreak() }
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
            guard stack.count < limits.maximumDepth else {
                // Deeper markup is left out, so no style below this depth can be missed.
                isCut = true
                stopped = true
                return
            }
            stack.append(Frame(name: name, look: look))
        }

        mutating func end(_ name: String, stack: inout [Frame]) {
            switch name {
            case "br":
                // </br> reads as <br>, as in a browser.
                if let look = stack.last?.look, look.notRendered || look.hiddenKind != nil { return }
                output.lineBreak()
                return
            case "html", "body":
                return
            default:
                break
            }
            guard let index = stack.lastIndex(where: { $0.name == name }) else {
                _ = step(stack.count)
                return
            }
            guard step(stack.count - index) else { return }
            close(from: index, stack: &stack)
        }

        mutating func close(from index: Int, stack: inout [Frame]) {
            for frame in stack[index...].reversed() {
                if !frame.look.notRendered, frame.look.hiddenKind == nil, let breaks = Self.blockBreaks[frame.name] {
                    output.breakLines(breaks)
                }
            }
            stack.removeSubrange(index...)
        }

        /// Closes the elements that a new element ends without an end tag, as a browser
        /// does: a paragraph before a block, a list item before the next and a cell before
        /// the next cell or row.
        mutating func closeImplicitly(before name: String, stack: inout [Frame]) {
            guard let top = stack.last?.name else { return }
            let closes: Bool
            switch name {
            case "li": closes = top == "li"
            case "dt", "dd": closes = top == "dt" || top == "dd"
            case "td", "th": closes = top == "td" || top == "th"
            case "tr": closes = top == "td" || top == "th" || top == "tr"
            case "option": closes = top == "option"
            default: closes = top == "p" && Self.closesParagraph.contains(name)
            }
            guard closes else { return }
            close(from: stack.count - 1, stack: &stack)
            if name == "tr", stack.last?.name == "tr" { close(from: stack.count - 1, stack: &stack) }
        }

        /// The alt and title text of an image, which the reader does not see while the
        /// image shows.
        mutating func image(_ tag: Tag, box: Box) {
            let text = [tag.attributes["alt"], tag.attributes["title"]].compactMap { $0 }.joined(separator: " ")
            let tiny = [tag.attributes["width"], tag.attributes["height"]].contains { value in
                value.flatMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: "")) }.map { $0 <= 2 } ?? false
            } || [box.width, box.height].contains { ($0 ?? 3) <= 2 }
            hiddenText.report(.imageText, text, minimumWords: tiny ? 1 : 4)
        }

        /// The text of a comment without markup.
        static func withoutTags(_ text: String) -> String {
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

        static let voidElements: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr", "keygen",
        ]
        /// Blank lines after the block, as plain text mail sets paragraphs apart.
        static let blockBreaks: [String: Int] = {
            var breaks: [String: Int] = [:]
            for name in ["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "ul", "ol", "dl", "table", "hr", "xmp", "listing"] {
                breaks[name] = 2
            }
            for name in [
                "div", "li", "tr", "dt", "dd", "section", "article", "header", "footer", "nav", "aside", "main", "figure",
                "figcaption", "address", "center", "form", "fieldset", "details", "summary", "caption", "legend", "textarea",
                "body", "html", "option",
            ] {
                breaks[name] = 1
            }
            return breaks
        }()
        static let closesParagraph: Set<String> = [
            "address", "article", "aside", "blockquote", "center", "details", "div", "dl", "fieldset", "figcaption", "figure",
            "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "menu", "nav", "ol", "p", "pre",
            "section", "table", "ul", "li", "dd", "dt",
        ]
        static let headElements: Set<String> = ["head", "title", "style", "script", "meta", "link", "base", "noscript", "template"]
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

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        /// The text with spaces at the ends of lines and blank lines at its ends removed.
        var finished: String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    var line = line
                    while line.last == " " { line.removeLast() }
                    return line
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
        }

        static func isCollapsible(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case " ", "\t", "\n", "\r", "\u{0C}", "\u{A0}": true
            default: false
            }
        }

        /// At least `count` line breaks before the next text.
        mutating func breakLines(_ count: Int) {
            guard !text.isEmpty else { return }
            pendingBreaks = max(pendingBreaks, count)
            pendingSpace = false
        }

        /// A <br>: it ends a line with text, and makes an empty line after one without.
        mutating func lineBreak() {
            guard !text.isEmpty else { return }
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
            pendingBreaks = min(pendingBreaks + 1, Self.maximumBreaks)
            pendingSpace = false
        }

        private mutating func add(_ segment: String, quoteDepth: Int) {
            guard !segment.isEmpty, !isFull else { return }
            var piece = ""
            if pendingBreaks > 0 {
                piece += String(repeating: "\n", count: pendingBreaks)
                pendingBreaks = 0
                lineHasText = false
            } else if pendingSpace, lineHasText {
                piece += " "
            }
            if !lineHasText, quoteDepth > 0 { piece += String(repeating: "> ", count: min(quoteDepth, 20)) }
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
        var attributes: [String: String]
    }

    private enum Token {
        case text(Range<Int>)
        case start(Tag)
        case end(String)
        case comment(Range<Int>)
        /// The content of an element whose text is not markup, such as script or style.
        case raw(String, Range<Int>)
    }

    /// Splits markup into tokens as a browser's tokenizer does, leniently: anything that is
    /// not a tag, a comment or a declaration is text, and a tag cut off by the end of the
    /// input is dropped.
    private enum Tokenizer {
        static let rawElements: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"]

        static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
        }

        static func isLetter(_ byte: UInt8) -> Bool {
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }

        static func lowercased(_ bytes: ArraySlice<UInt8>) -> String {
            String(decoding: bytes.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
        }

        static func tokens(_ bytes: [UInt8]) -> [Token] {
            var tokens: [Token] = []
            var textStart = 0
            var index = 0
            let count = bytes.count

            func endText(at end: Int) {
                if end > textStart { tokens.append(.text(textStart..<end)) }
            }
            func after(_ byte: UInt8, from start: Int) -> Int {
                guard start < count, let found = bytes[start...].firstIndex(of: byte) else { return count }
                return found + 1
            }

            while index < count {
                guard let open = bytes[index...].firstIndex(of: 0x3C) else { break }
                index = open
                guard index + 1 < count else { break }
                let next = bytes[index + 1]
                if next == 0x21 {
                    endText(at: index)
                    if bytes[index...].starts(with: [0x3C, 0x21, 0x2D, 0x2D]) {
                        let contentStart = index + 4
                        if bytes[contentStart...].starts(with: [0x3E]) {
                            index = contentStart + 1
                        } else if bytes[contentStart...].starts(with: [0x2D, 0x3E]) {
                            index = contentStart + 2
                        } else if let close = find([0x2D, 0x2D, 0x3E], in: bytes, from: contentStart) {
                            tokens.append(.comment(contentStart..<close))
                            index = close + 3
                        } else {
                            tokens.append(.comment(contentStart..<count))
                            index = count
                        }
                    } else {
                        // A doctype, CDATA or a conditional marker: a declaration up to >.
                        index = after(0x3E, from: index + 2)
                    }
                    textStart = index
                    continue
                }
                if next == 0x3F {
                    endText(at: index)
                    index = after(0x3E, from: index + 2)
                    textStart = index
                    continue
                }
                if next == 0x2F {
                    guard index + 2 < count else { break }
                    endText(at: index)
                    if isLetter(bytes[index + 2]) {
                        var end = index + 2
                        while end < count, !isSpace(bytes[end]), bytes[end] != 0x2F, bytes[end] != 0x3E { end += 1 }
                        tokens.append(.end(lowercased(bytes[(index + 2)..<end])))
                        index = after(0x3E, from: end)
                    } else {
                        index = after(0x3E, from: index + 2)
                    }
                    textStart = index
                    continue
                }
                if isLetter(next) {
                    endText(at: index)
                    guard let found = startTag(bytes, at: index) else {
                        textStart = count
                        index = count
                        break
                    }
                    let tag = found.tag
                    tokens.append(.start(tag))
                    index = found.end
                    if rawElements.contains(tag.name) {
                        let (contentEnd, resume) = rawEnd(bytes, name: tag.name, from: index)
                        tokens.append(.raw(tag.name, index..<contentEnd))
                        tokens.append(.end(tag.name))
                        index = resume
                    } else if tag.name == "plaintext" {
                        tokens.append(.raw(tag.name, index..<count))
                        index = count
                    }
                    textStart = index
                    continue
                }
                // A < that starts no tag is text.
                index += 1
            }
            endText(at: count)
            return tokens
        }

        /// The tag that starts at `start`, and the index after it, or nil when the input ends
        /// inside it.
        static func startTag(_ bytes: [UInt8], at start: Int) -> (tag: Tag, end: Int)? {
            let count = bytes.count
            var index = start + 1
            while index < count, !isSpace(bytes[index]), bytes[index] != 0x2F, bytes[index] != 0x3E { index += 1 }
            var tag = Tag(name: lowercased(bytes[(start + 1)..<index]), attributes: [:])
            while true {
                while index < count, isSpace(bytes[index]) || bytes[index] == 0x2F { index += 1 }
                guard index < count else { return nil }
                if bytes[index] == 0x3E { return (tag, index + 1) }
                let nameStart = index
                index += 1
                while index < count, !isSpace(bytes[index]), bytes[index] != 0x2F, bytes[index] != 0x3E, bytes[index] != 0x3D { index += 1 }
                let name = lowercased(bytes[nameStart..<index])
                while index < count, isSpace(bytes[index]) { index += 1 }
                var value = ""
                if index < count, bytes[index] == 0x3D {
                    index += 1
                    while index < count, isSpace(bytes[index]) { index += 1 }
                    guard index < count else { return nil }
                    let quote = bytes[index]
                    if quote == 0x22 || quote == 0x27 {
                        guard let close = bytes[(index + 1)...].firstIndex(of: quote) else { return nil }
                        value = Entities.decoded(bytes[(index + 1)..<min(close, index + 1 + maximumValueBytes)])
                        index = close + 1
                    } else {
                        let valueStart = index
                        while index < count, !isSpace(bytes[index]), bytes[index] != 0x3E { index += 1 }
                        value = Entities.decoded(bytes[valueStart..<min(index, valueStart + maximumValueBytes)])
                    }
                }
                if tag.attributes[name] == nil, tag.attributes.count < maximumAttributes {
                    tag.attributes[name] = value
                }
            }
        }

        private static let maximumAttributes = 64
        private static let maximumValueBytes = 64 << 10

        /// Where the content of a raw element ends, at its end tag, and the index after that
        /// tag. Without an end tag the content runs to the end.
        static func rawEnd(_ bytes: [UInt8], name: String, from start: Int) -> (contentEnd: Int, resume: Int) {
            let nameBytes = Array(name.utf8)
            var index = start
            while index < bytes.count, let open = bytes[index...].firstIndex(of: 0x3C) {
                let nameStart = open + 2
                let nameEnd = nameStart + nameBytes.count
                if nameEnd <= bytes.count, bytes[open + 1] == 0x2F,
                   bytes[nameStart..<nameEnd].map({ (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }) == nameBytes,
                   nameEnd == bytes.count || isSpace(bytes[nameEnd]) || bytes[nameEnd] == 0x2F || bytes[nameEnd] == 0x3E {
                    let close = nameEnd < bytes.count ? (bytes[nameEnd...].firstIndex(of: 0x3E) ?? bytes.count) : bytes.count
                    return (open, min(close + 1, bytes.count))
                }
                index = open + 1
            }
            return (bytes.count, bytes.count)
        }

        static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
            var index = start
            while index + pattern.count <= bytes.count, let first = bytes[index...].firstIndex(of: pattern[0]) {
                if first + pattern.count <= bytes.count, bytes[first..<first + pattern.count].elementsEqual(pattern) { return first }
                index = first + 1
            }
            return nil
        }
    }

    /// HTML character references: numeric ones, the Latin-1 names and the common
    /// typographic ones.
    private enum Entities {
        static func decoded(_ bytes: ArraySlice<UInt8>) -> String {
            guard bytes.contains(0x26) else { return String(decoding: bytes, as: UTF8.self) }
            var result: [UInt8] = []
            result.reserveCapacity(bytes.count)
            var index = bytes.startIndex
            while index < bytes.endIndex {
                guard bytes[index] == 0x26, let found = reference(bytes, at: index) else {
                    result.append(bytes[index])
                    index += 1
                    continue
                }
                result += found.text.utf8
                index = found.end
            }
            return String(decoding: result, as: UTF8.self)
        }

        private static func reference(_ bytes: ArraySlice<UInt8>, at start: Int) -> (text: String, end: Int)? {
            var index = start + 1
            guard index < bytes.endIndex else { return nil }
            if bytes[index] == 0x23 {
                index += 1
                let hex = index < bytes.endIndex && bytes[index] | 0x20 == 0x78
                if hex { index += 1 }
                var value: UInt32 = 0
                var digits = 0
                while index < bytes.endIndex, digits < 8 {
                    let byte = bytes[index]
                    let digit: UInt32
                    switch byte {
                    case 0x30...0x39: digit = UInt32(byte - 0x30)
                    case 0x61...0x66 where hex: digit = UInt32(byte - 0x61 + 10)
                    case 0x41...0x46 where hex: digit = UInt32(byte - 0x41 + 10)
                    default: digit = 99
                    }
                    guard digit != 99 else { break }
                    value = value * (hex ? 16 : 10) + digit
                    digits += 1
                    index += 1
                }
                guard digits > 0 else { return nil }
                if index < bytes.endIndex, bytes[index] == 0x3B { index += 1 }
                let scalar = value == 0 ? nil : Unicode.Scalar(value)
                return (String(scalar ?? "\u{FFFD}"), index)
            }
            let nameStart = index
            while index < bytes.endIndex, index - nameStart < 32,
                  Tokenizer.isLetter(bytes[index]) || (0x30...0x39).contains(bytes[index]) { index += 1 }
            guard index > nameStart else { return nil }
            let name = String(decoding: bytes[nameStart..<index], as: UTF8.self)
            if index < bytes.endIndex, bytes[index] == 0x3B, let value = named[name] {
                return (value, index + 1)
            }
            if legacy.contains(name), let value = named[name] { return (value, index) }
            return nil
        }

        /// Names a browser reads without the semicolon too.
        private static let legacy: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

        private static let named: [String: String] = {
            var table: [String: String] = [:]
            // U+00A0 to U+00FF in order.
            let latin1 = """
                nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 \
                acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde \
                Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc \
                Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml \
                aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute ocirc \
                otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
                """
            for (offset, name) in latin1.split(separator: " ").enumerated() {
                table[String(name)] = String(Unicode.Scalar(UInt8(0xA0 + offset)))
            }
            let others = """
                quot 34 amp 38 apos 39 lt 60 gt 62 OElig 338 oelig 339 Scaron 352 scaron 353 Yuml 376 fnof 402 circ 710 \
                tilde 732 ensp 8194 emsp 8195 thinsp 8201 zwnj 8204 zwj 8205 lrm 8206 rlm 8207 ndash 8211 mdash 8212 \
                lsquo 8216 rsquo 8217 sbquo 8218 ldquo 8220 rdquo 8221 bdquo 8222 dagger 8224 Dagger 8225 bull 8226 \
                hellip 8230 permil 8240 prime 8242 Prime 8243 lsaquo 8249 rsaquo 8250 oline 8254 frasl 8260 euro 8364 \
                trade 8482 larr 8592 uarr 8593 rarr 8594 darr 8595 harr 8596 minus 8722 infin 8734 ne 8800 le 8804 \
                ge 8805 hearts 9829 check 10003
                """.split(separator: " ")
            for pair in stride(from: 0, to: others.count - 1, by: 2) {
                if let value = UInt32(others[pair + 1]), let scalar = Unicode.Scalar(value) {
                    table[String(others[pair])] = String(scalar)
                }
            }
            return table
        }()
    }
}

// MARK: Styles

nonisolated extension VisibleText {
    /// A color in sRGB, from 0 to 1.
    private struct Color: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        static let black = Color(red: 0, green: 0, blue: 0, alpha: 1)
        static let white = Color(red: 1, green: 1, blue: 1, alpha: 1)

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

        /// A CSS color: #rgb, #rgba, #rrggbb, #rrggbbaa, rgb(), rgba(), hsl(), hsla(),
        /// transparent or a named color. With `bare`, also hex digits without the #, which
        /// old attributes such as bgcolor take.
        init?(css text: String, bare: Bool = false) {
            let value = text.trimmingCharacters(in: .whitespaces).lowercased()
            if value == "transparent" {
                self.init(red: 0, green: 0, blue: 0, alpha: 0)
            } else if value.hasPrefix("#") {
                self.init(hex: value.dropFirst())
            } else if value.hasPrefix("rgb") || value.hasPrefix("hsl") {
                guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else { return nil }
                let parts = value[value.index(after: open)..<close]
                    .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                guard parts.count >= 3 else { return nil }
                func number(_ part: Substring, scale: Double) -> Double? {
                    let value = part.hasSuffix("%") ? Double(part.dropLast()).map { $0 / 100 } : Double(part.replacingOccurrences(of: "deg", with: "")).map { $0 / scale }
                    return value.flatMap { $0.isFinite ? $0 : nil }
                }
                let alpha = parts.count >= 4 ? number(parts[3], scale: 1) : 1
                if value.hasPrefix("rgb") {
                    guard let red = number(parts[0], scale: 255), let green = number(parts[1], scale: 255),
                          let blue = number(parts[2], scale: 255), let alpha else { return nil }
                    self.init(red: red, green: green, blue: blue, alpha: alpha)
                } else {
                    guard let hue = number(parts[0], scale: 360), let saturation = number(parts[1], scale: 100),
                          let lightness = number(parts[2], scale: 100), let alpha else { return nil }
                    self.init(hue: hue, saturation: saturation, lightness: lightness, alpha: alpha)
                }
            } else if let hex = Self.named[value] {
                self.init(hex: Substring(hex))
            } else if bare {
                self.init(hex: Substring(value))
            } else {
                return nil
            }
            red = min(max(red, 0), 1)
            green = min(max(green, 0), 1)
            blue = min(max(blue, 0), 1)
            alpha = min(max(alpha, 0), 1)
        }

        init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        private init?(hex: Substring) {
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

        private init(hue: Double, saturation: Double, lightness: Double, alpha: Double) {
            let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
            let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
            let p = 2 * lightness - q
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
        private static let named: [String: String] = {
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
                yellowgreen 9acd32
                """.split(separator: " ")
            var table: [String: String] = [:]
            for pair in stride(from: 0, to: pairs.count - 1, by: 2) {
                table[String(pairs[pair])] = String(pairs[pair + 1])
            }
            return table
        }()
    }

    /// One property of a style, in lowercase.
    private struct Declaration {
        var property: String
        var value: String
        var important: Bool

        /// The properties that can hide text. Others are skipped.
        static let read: Set<String> = [
            "display", "visibility", "opacity", "font-size", "font", "color", "background", "background-color",
            "background-image", "position", "left", "top", "text-indent", "margin-left", "margin-top", "clip",
            "clip-path", "width", "height", "max-width", "max-height", "overflow", "overflow-x", "overflow-y",
            "transform",
        ]

        static func list(_ text: some StringProtocol) -> [Declaration] {
            var result: [Declaration] = []
            for piece in topLevel(text, separatedBy: ";") where result.count < 64 {
                guard let colon = piece.firstIndex(of: ":") else { continue }
                let property = piece[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard read.contains(property) else { continue }
                var value = piece[piece.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var important = false
                if let bang = value.lastIndex(of: "!"),
                   value[value.index(after: bang)...].trimmingCharacters(in: .whitespaces) == "important" {
                    important = true
                    value = value[..<bang].trimmingCharacters(in: .whitespaces)
                }
                result.append(Declaration(property: property, value: value, important: important))
            }
            return result
        }

        /// Pieces of the text split at the separator outside parentheses and quotes.
        static func topLevel(_ text: some StringProtocol, separatedBy separator: Character) -> [Substring] {
            let text = Substring(text)
            var pieces: [Substring] = []
            var depth = 0
            var quote: Character?
            var start = text.startIndex
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
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
    }

    /// The last compound of a selector, such as `span.note` in `td > span.note`. The parts
    /// before it are not checked, so a rule may hide more than it would in Mail, never less.
    private struct StyleSelector {
        var tag: String?
        var id: String?
        var classes: [String] = []
        var attributes: [String] = []
        var specificity = 0

        /// Nil for a selector that never matches a message at rest, such as one for a
        /// pseudo element or for :hover, or one this reader cannot read.
        init?(_ text: Substring) {
            let selector = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selector.isEmpty else { return nil }
            var depth = 0
            var start = selector.startIndex
            for index in selector.indices {
                switch selector[index] {
                case "[", "(": depth += 1
                case "]", ")": depth = max(0, depth - 1)
                case " ", "\t", "\n", ">", "+", "~":
                    if depth == 0 { start = selector.index(after: index) }
                default: break
                }
            }
            let compound = selector[start...]
            guard !compound.isEmpty else { return nil }
            var index = compound.startIndex
            func identifier() -> String {
                let begin = index
                while index < compound.endIndex {
                    let character = compound[index]
                    guard character.isLetter || character.isNumber || character == "-" || character == "_" || character == "\\" else { break }
                    index = compound.index(after: index)
                }
                return String(compound[begin..<index])
            }
            var ids = 0, classCount = 0, tags = 0
            if compound[index] == "*" {
                index = compound.index(after: index)
            } else if compound[index].isLetter {
                tag = identifier().lowercased()
                tags += 1
            }
            while index < compound.endIndex {
                let character = compound[index]
                index = compound.index(after: index)
                switch character {
                case ".":
                    let name = identifier().lowercased()
                    guard !name.isEmpty else { return nil }
                    classes.append(name)
                    classCount += 1
                case "#":
                    let name = identifier().lowercased()
                    guard !name.isEmpty else { return nil }
                    id = name
                    ids += 1
                case "[":
                    let close = compound[index...].firstIndex(of: "]") ?? compound.endIndex
                    let inside = compound[index..<close]
                    let name = inside.prefix { !"=~|^$*".contains($0) }.trimmingCharacters(in: .whitespaces).lowercased()
                    guard !name.isEmpty else { return nil }
                    attributes.append(name)
                    classCount += 1
                    index = close < compound.endIndex ? compound.index(after: close) : close
                case ":":
                    guard index < compound.endIndex, compound[index] != ":" else { return nil }
                    let name = identifier().lowercased()
                    guard !Self.dynamic.contains(name), !Self.pseudoElements.contains(name) else { return nil }
                    if index < compound.endIndex, compound[index] == "(" {
                        let close = compound[index...].firstIndex(of: ")") ?? compound.endIndex
                        index = close < compound.endIndex ? compound.index(after: close) : close
                    }
                    classCount += 1
                default:
                    return nil
                }
            }
            specificity = ids * 10_000 + classCount * 100 + tags
        }

        /// Pseudo classes that match only while the reader acts, never at rest.
        private static let dynamic: Set<String> = [
            "hover", "focus", "active", "visited", "focus-within", "focus-visible", "target", "checked",
        ]
        /// Pseudo elements written with one colon, as in the common clearfix rule
        /// `.clearfix:after { visibility: hidden }`, which styles generated content and not
        /// the element.
        private static let pseudoElements: Set<String> = [
            "before", "after", "first-line", "first-letter", "selection", "placeholder", "marker", "backdrop",
        ]

        func matches(_ tag: Tag, name: String, id elementID: String?, classes elementClasses: Set<String>) -> Bool {
            if let required = self.tag, required != name { return false }
            if let id, id != elementID { return false }
            if !classes.allSatisfy(elementClasses.contains) { return false }
            return attributes.allSatisfy { tag.attributes[$0] != nil }
        }
    }

    private struct Rule {
        var selector: StyleSelector
        var order: Int
        var declarations: [Declaration]
    }

    /// The rules of the email's style elements that can hide text, found by id, class or
    /// tag.
    private struct StyleSheet {
        let maximumRules: Int
        private(set) var count = 0
        private(set) var isCut = false
        private var byID: [String: [Rule]] = [:]
        private var byClass: [String: [Rule]] = [:]
        private var byTag: [String: [Rule]] = [:]
        private var universal: [Rule] = []

        init(maximumRules: Int) {
            self.maximumRules = maximumRules
        }

        mutating func add(_ css: String) {
            parse(Substring(Self.withoutComments(css)), depth: 0)
        }

        /// The rules that match the element, in the order they apply: by specificity, then
        /// by their order in the sheets.
        func rules(for tag: Tag, id: String?, classes: Set<String>, tried: inout Int) -> [Rule] {
            var candidates: [Rule] = []
            if let id { candidates += byID[id] ?? [] }
            for name in classes { candidates += byClass[name] ?? [] }
            candidates += byTag[tag.name] ?? []
            candidates += universal
            tried += candidates.count
            return candidates
                .filter { $0.selector.matches(tag, name: tag.name, id: id, classes: classes) }
                .sorted { ($0.selector.specificity, $0.order) < ($1.selector.specificity, $1.order) }
        }

        private mutating func parse(_ css: Substring, depth: Int) {
            var index = css.startIndex
            while index < css.endIndex {
                guard let stop = css[index...].firstIndex(where: { $0 == "{" || $0 == ";" || $0 == "}" }) else { return }
                let prelude = css[index..<stop].trimmingCharacters(in: .whitespacesAndNewlines)
                guard css[stop] == "{" else {
                    index = css.index(after: stop)
                    continue
                }
                let blockStart = css.index(after: stop)
                let blockEnd = Self.blockEnd(css, from: blockStart)
                let block = css[blockStart..<blockEnd]
                index = blockEnd < css.endIndex ? css.index(after: blockEnd) : blockEnd
                if prelude.hasPrefix("@") {
                    let rule = prelude.lowercased()
                    guard depth < 4 else { continue }
                    if rule.hasPrefix("@media"), Self.appliesOnAMac(rule) {
                        parse(block, depth: depth + 1)
                    } else if rule.hasPrefix("@supports") {
                        parse(block, depth: depth + 1)
                    }
                    continue
                }
                let declarations = Declaration.list(block)
                guard !declarations.isEmpty else { continue }
                for text in Declaration.topLevel(prelude, separatedBy: ",") {
                    guard let selector = StyleSelector(text) else { continue }
                    guard count < maximumRules else {
                        isCut = true
                        return
                    }
                    let rule = Rule(selector: selector, order: count, declarations: declarations)
                    count += 1
                    if let id = selector.id {
                        byID[id, default: []].append(rule)
                    } else if let name = selector.classes.first {
                        byClass[name, default: []].append(rule)
                    } else if let tag = selector.tag {
                        byTag[tag, default: []].append(rule)
                    } else {
                        universal.append(rule)
                    }
                }
            }
        }

        /// Whether rules in an @media block apply in Mail on a Mac: not those for small
        /// screens, print, speech or dark mode.
        private static func appliesOnAMac(_ rule: String) -> Bool {
            let compact = rule.filter { !$0.isWhitespace }
            return !["max-width", "max-device-width", "print", "speech", "prefers-color-scheme:dark"].contains { compact.contains($0) }
        }

        private static func blockEnd(_ css: Substring, from start: Substring.Index) -> Substring.Index {
            var depth = 1
            var index = start
            while index < css.endIndex {
                switch css[index] {
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
                index = css.index(after: index)
            }
            return css.endIndex
        }

        private static func withoutComments(_ css: String) -> String {
            guard css.contains("/*") else { return css }
            var result = ""
            var rest = Substring(css)
            while let open = rest.range(of: "/*") {
                result += rest[..<open.lowerBound]
                guard let close = rest[open.upperBound...].range(of: "*/") else { return result }
                rest = rest[close.upperBound...]
            }
            return result + rest
        }
    }

    /// What one element sets for itself, the last value of each property winning.
    private struct Box {
        var display: String?
        var visibility: String?
        var opacity: Double?
        var fontSize: Double?
        var color: Color?
        var background: Color?
        var backgroundImage = false
        var position: String?
        var left: Double?
        var top: Double?
        var textIndent: Double?
        var marginLeft: Double?
        var marginTop: Double?
        var width: Double?
        var height: Double?
        var maxWidth: Double?
        var maxHeight: Double?
        var overflowHidden = false
        var clipped = false
        var scaledAway = false

        /// Moved off screen, clipped to nothing, scaled to nothing or moved away, or a box of
        /// a pixel or less that hides what overflows it.
        var isOffScreen: Bool {
            if clipped || scaledAway { return true }
            if let position, position != "static", (left ?? 0) <= -500 || (top ?? 0) <= -500 { return true }
            if (textIndent ?? 0) <= -500 || (marginLeft ?? 0) <= -500 || (marginTop ?? 0) <= -500 { return true }
            return overflowHidden && [width, height, maxWidth, maxHeight].contains { ($0 ?? 2) <= 1 }
        }

        mutating func apply(_ declaration: Declaration, parentFontSize: Double) {
            let value = declaration.value
            let first = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? value
            switch declaration.property {
            case "display": display = first
            case "visibility": visibility = first
            case "opacity":
                if let number = Self.number(first) { opacity = min(max(number, 0), 1) }
            case "font-size":
                if let size = Self.fontSize(first, parent: parentFontSize) { fontSize = size }
            case "font":
                // The size in the shorthand, as in "font: 0/0 a" or "bold 12px/1.5 Arial". A
                // number without a unit other than 0 is a weight, as in "700 12px Arial".
                for word in value.split(whereSeparator: \.isWhitespace) {
                    let size = word.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    if size != "0", size.allSatisfy(\.isNumber) { continue }
                    if let pixels = Self.fontSize(size, parent: parentFontSize) {
                        fontSize = pixels
                        break
                    }
                }
            case "color":
                if let parsed = Color(css: value) { color = parsed }
            case "background", "background-color":
                if value.contains("url(") || value.contains("gradient(") { backgroundImage = true }
                for word in Declaration.topLevel(value, separatedBy: " ") {
                    if let parsed = Color(css: String(word)) {
                        background = parsed
                        break
                    }
                }
            case "background-image":
                if value.contains("url(") || value.contains("gradient(") { backgroundImage = true }
            case "position": position = first
            case "left": left = Self.length(first)
            case "top": top = Self.length(first)
            case "text-indent": textIndent = Self.length(first)
            case "margin-left": marginLeft = Self.length(first)
            case "margin-top": marginTop = Self.length(first)
            case "width": width = Self.length(first)
            case "height": height = Self.length(first)
            case "max-width": maxWidth = Self.length(first)
            case "max-height": maxHeight = Self.length(first)
            case "overflow", "overflow-x", "overflow-y":
                if first == "hidden" || first == "clip" { overflowHidden = true }
            case "clip":
                clipped = Self.isEmptyRect(value)
            case "clip-path":
                clipped = Self.clipsEverything(value)
            case "transform":
                scaledAway = Self.transformHides(value)
            default:
                break
            }
        }

        /// A number or a percentage, or nil for anything else, such as nan, which a browser
        /// ignores as it ignores the declaration.
        static func number(_ text: String) -> Double? {
            let value = text.hasSuffix("%") ? Double(text.dropLast()).map { $0 / 100 } : Double(text)
            return value.flatMap { $0.isFinite ? $0 : nil }
        }

        /// A length in CSS pixels. Percentages and viewport units are unknown, except zero.
        static func length(_ text: some StringProtocol, fontSize: Double = 16) -> Double? {
            let text = String(text)
            let numberEnd = text.firstIndex { !($0.isNumber || $0 == "." || $0 == "-" || $0 == "+") } ?? text.endIndex
            guard let number = Double(text[..<numberEnd]), number.isFinite else { return nil }
            switch text[numberEnd...] {
            case "", "px": return number
            case "pt": return number * 4 / 3
            case "pc": return number * 16
            case "in": return number * 96
            case "cm": return number * 96 / 2.54
            case "mm": return number * 96 / 25.4
            case "em": return number * fontSize
            case "rem": return number * 16
            case "ex", "ch": return number * fontSize / 2
            default: return number == 0 ? 0 : nil
            }
        }

        /// A font size in CSS pixels: a length, a percentage of the parent's or a keyword.
        static func fontSize(_ text: String, parent: Double) -> Double? {
            let named: [String: Double] = [
                "xx-small": 9, "x-small": 10, "small": 13, "medium": 16, "large": 18, "x-large": 24, "xx-large": 32, "xxx-large": 48,
            ]
            if let size = named[text] { return size }
            if text == "smaller" { return parent / 1.2 }
            if text == "larger" { return parent * 1.2 }
            if text.hasSuffix("%") { return number(text).map { $0 * parent } }
            guard text.first?.isNumber == true || text.first == "." else { return nil }
            return length(text, fontSize: parent)
        }

        /// rect(top, right, bottom, left) that leaves a pixel or less. auto is the edge of
        /// the box: 0 for top and left, the far side for bottom and right.
        private static func isEmptyRect(_ value: String) -> Bool {
            guard value.hasPrefix("rect(") else { return false }
            let parts = value.dropFirst(5).split(whereSeparator: { $0 == "," || $0 == " " || $0 == ")" })
            guard parts.count == 4 else { return false }
            let edges = parts.enumerated().map { side, part in
                part == "auto" ? (side == 0 || side == 3 ? 0 : 100_000) : (length(part) ?? 100_000)
            }
            return edges[2] - edges[0] <= 1 || edges[1] - edges[3] <= 1
        }

        private static func clipsEverything(_ value: String) -> Bool {
            if value.hasPrefix("inset("), let first = value.dropFirst(6).split(whereSeparator: { $0 == " " || $0 == ")" }).first {
                return first.hasSuffix("%") && (Double(first.dropLast()) ?? 0) >= 50
            }
            if value.hasPrefix("circle("), let first = value.dropFirst(7).split(whereSeparator: { $0 == " " || $0 == ")" }).first {
                return (length(first) ?? 1) == 0 || first == "0%"
            }
            return false
        }

        /// Whether a transform scales the box to nothing, as scale(0), or moves it off
        /// screen, as translateX(-9999px).
        private static func transformHides(_ value: String) -> Bool {
            for function in ["scale", "translate"] {
                var rest = Substring(value)
                while let range = rest.range(of: function) {
                    rest = rest[range.upperBound...]
                    guard let open = rest.firstIndex(of: "("), rest[..<open].count <= 1,
                          let close = rest.firstIndex(of: ")") else { continue }
                    let arguments = rest[rest.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " })
                    let hides = function == "scale"
                        ? arguments.contains { abs(Double($0) ?? 1) <= 0.01 }
                        : arguments.contains { (length($0) ?? 0) <= -500 }
                    if hides { return true }
                }
            }
            return false
        }
    }

    /// The styles an element and its ancestors give its text.
    private struct Look {
        /// Inside the head, a script, an SVG image or another element whose text no reader
        /// sees as text. Such text is neither shown nor reported.
        var notRendered = false
        var displayNone = false
        var invisible = false
        var offScreen = false
        var opacity = 1.0
        var fontSize = 16.0
        var color: Color?
        /// The color behind the text, opaque.
        var background = Color.white
        /// False under a background image, which may hide or show any color.
        var backgroundKnown = true
        var preformatted = false
        var quoteDepth = 0

        var hiddenKind: ProjectsHiddenText? {
            if displayNone || invisible || offScreen { return .hiddenStyle }
            let text = color ?? .black
            if opacity < 0.1 || text.alpha < 0.1 { return .transparent }
            // Under 3 points, as FileTextExtractor counts a tiny font.
            if fontSize < 4 { return .tinyFont }
            if backgroundKnown, text.over(background).distance(to: background) < 0.1 { return .sameColor }
            return nil
        }

        static let notRenderedElements: Set<String> = [
            "head", "title", "script", "style", "template", "svg", "math", "iframe", "object", "noembed", "noframes",
            "applet", "audio", "video", "canvas", "datalist",
        ]
        static let preformattedElements: Set<String> = ["pre", "textarea", "xmp", "listing", "plaintext"]
        static let backgroundElements: Set<String> = ["body", "table", "tr", "td", "th"]

        /// The look of an element: its parent's, with what its tag, its attributes, the
        /// style sheets and its style attribute set. The box is what the element set for
        /// itself.
        static func of(_ tag: Tag, parent: Look, sheet: StyleSheet, tried: inout Int) -> (Look, Box) {
            let name = tag.name
            var box = Box()
            // Attributes first, since every style overrides them.
            if tag.attributes["hidden"] != nil { box.display = "none" }
            if name == "font" {
                if let value = tag.attributes["color"], let color = Color(css: value, bare: true) { box.color = color }
                if let value = tag.attributes["size"] { box.fontSize = fontSize(attribute: value) }
            }
            if name == "body", let value = tag.attributes["text"], let color = Color(css: value, bare: true) { box.color = color }
            if backgroundElements.contains(name) {
                if let value = tag.attributes["bgcolor"], let color = Color(css: value, bare: true) { box.background = color }
                if tag.attributes["background"] != nil { box.backgroundImage = true }
            }
            // Without case, as in the quirks mode most email HTML is in, so a rule never
            // misses an element it styles in Mail.
            let id = tag.attributes["id"]?.lowercased()
            let classes = Set(tag.attributes["class"].map { $0.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) } ?? [])
            let rules = sheet.rules(for: tag, id: id, classes: classes, tried: &tried)
            let inline = tag.attributes["style"].map { Declaration.list($0) } ?? []
            let fromRules: [Declaration] = rules.flatMap(\.declarations)
            var ordered: [Declaration] = fromRules.filter { !$0.important }
            ordered += inline.filter { !$0.important }
            ordered += fromRules.filter(\.important)
            ordered += inline.filter(\.important)
            for declaration in ordered { box.apply(declaration, parentFontSize: parent.fontSize) }

            var look = parent
            look.notRendered = parent.notRendered || notRenderedElements.contains(name)
            look.preformatted = parent.preformatted || preformattedElements.contains(name)
            if name == "blockquote" { look.quoteDepth += 1 }
            look.displayNone = parent.displayNone || box.display == "none"
            switch box.visibility {
            case "hidden", "collapse": look.invisible = true
            case "visible", "initial", "revert": look.invisible = false
            default: break
            }
            look.offScreen = parent.offScreen || box.isOffScreen
            look.opacity = parent.opacity * (box.opacity ?? 1)
            if let size = box.fontSize { look.fontSize = size }
            if let color = box.color { look.color = color }
            if let background = box.background, background.alpha >= 0.1 {
                look.background = background.over(parent.background)
                if background.alpha >= 0.9 { look.backgroundKnown = true }
            }
            if box.backgroundImage { look.backgroundKnown = false }
            return (look, box)
        }

        /// The size of <font size>, 1 to 7, or relative as +1 or -2.
        private static func fontSize(attribute: String) -> Double? {
            let value = attribute.trimmingCharacters(in: .whitespaces)
            guard var size = Int(value.drop { $0 == "+" || $0 == "-" }) else { return nil }
            if value.hasPrefix("+") { size = 3 + size } else if value.hasPrefix("-") { size = 3 - size }
            let sizes: [Double] = [10, 13, 16, 18, 24, 32, 48]
            return sizes[min(max(size, 1), 7) - 1]
        }
    }
}
