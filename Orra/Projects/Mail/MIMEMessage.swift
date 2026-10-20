import Foundation

/// An email's raw source, as Mail gives it, parsed into its headers, the text parts a reader
/// sees and the names and types of its attachments.
///
/// - Multipart parts are split by their boundaries. Of the parts of multipart/alternative,
///   the last one with text counts, as RFC 2046 orders them from plainest to richest and as
///   Mail shows them. Of multipart/related only the first part is text, the rest are inline
///   resources. multipart/signed gives its first part, and multipart/encrypted nothing.
///   Every other multipart gives its text parts in order, as Mail shows them one after the
///   other.
/// - Quoted printable, base64 and the charsets of `MailHeaders.text(_:charset:)` are
///   decoded, and format=flowed text is joined back into its lines.
/// - A text part named as an attachment, every other type and attached emails
///   (message/rfc822) are attachments, listed by name and type and never decoded. Signatures
///   of signed mail are not listed.
/// - Parsing never fails. Broken structure reads as far as it can, and the limits cap the
///   size, the parts, the depth, the text and the steps, so a hostile message costs a
///   bounded amount of work. One step is one line looked at or one byte decoded.
nonisolated struct MIMEMessage: Sendable, Equatable {
    /// A text part the reader sees.
    nonisolated struct Body: Sendable, Equatable {
        nonisolated enum Format: String, Sendable {
            /// text/plain.
            case plain
            /// text/html, which VisibleText reads.
            case markup
        }

        var format: Format
        var text: String
    }

    nonisolated struct Attachment: Sendable, Equatable {
        /// The file name from Content-Disposition or Content-Type, decoded, or nil.
        var name: String?
        /// The MIME type in lowercase, such as application/pdf.
        var mimeType: String
        /// Whether the part asks to show inline, as an image in the text does.
        var isInline: Bool
    }

    nonisolated struct Limits: Sendable, Equatable {
        /// Bytes past this many are not read.
        var maximumSourceBytes = 32 << 20
        /// Parts past this many, counted over the whole message, are not read.
        var maximumParts = 256
        /// Multiparts nested deeper than this are not read.
        var maximumDepth = 12
        /// Text past this many bytes, over all bodies, is cut.
        var maximumTextBytes = 2 << 20
        /// A header block past this many bytes is cut.
        var maximumHeaderBytes = 256 << 10
        /// Parsing stops after this many steps.
        var maximumSteps = 64 << 20
    }

    var headers: MailHeaders
    var bodies: [Body]
    var attachments: [Attachment]
    /// Whether anything was left out at a limit.
    var isCut: Bool
    /// The work parsing took, in steps, see `Limits.maximumSteps`.
    var steps: Int

    /// Parses the bytes of a raw source.
    init(source: Data, limits: Limits = Limits()) {
        self.init(bytes: [UInt8](source), sourceIsText: false, limits: limits)
    }

    /// Parses a raw source that came as text. A source whose characters all fit in one byte
    /// is read as those bytes, so 8 bit parts keep their charset. A source with wider
    /// characters was decoded already, so its 8 bit parts read as UTF-8 first. How Mail
    /// turns an 8 bit source into text is unverified.
    init(source: String, limits: Limits = Limits()) {
        let fitsInBytes = source.unicodeScalars.allSatisfy { $0.value <= 0xFF }
        let bytes = fitsInBytes ? source.unicodeScalars.map { UInt8($0.value) } : Array(source.utf8)
        self.init(bytes: bytes, sourceIsText: !fitsInBytes, limits: limits)
    }

    /// Parses off the main actor, since a large message takes a while and the keyboard tap
    /// runs on the main thread.
    @concurrent
    static func parsed(_ source: Data, limits: Limits = Limits()) async -> MIMEMessage {
        MIMEMessage(source: source, limits: limits)
    }

    @concurrent
    static func parsed(_ source: String, limits: Limits = Limits()) async -> MIMEMessage {
        MIMEMessage(source: source, limits: limits)
    }

    private init(bytes: [UInt8], sourceIsText: Bool, limits: Limits) {
        var parser = Parser(bytes: bytes, sourceIsText: sourceIsText, limits: limits)
        let end = min(bytes.count, max(0, limits.maximumSourceBytes))
        if end < bytes.count { parser.isCut = true }
        let entity = parser.entity(0..<end, depth: 0)
        headers = entity.headers
        bodies = entity.bodies
        attachments = parser.attachments
        isCut = parser.isCut
        steps = parser.steps
    }
}

nonisolated extension MIMEMessage {
    /// A Content-Type or Content-Disposition value: its main value in lowercase and its
    /// parameters by lowercase name, with RFC 2231 sections joined and decoded and RFC 2047
    /// words decoded, which many senders use in file names.
    struct HeaderValue: Sendable, Equatable {
        var value: String
        var parameters: [String: String]

        init(_ text: String) {
            var pieces: [String] = []
            var current = ""
            var quoted = false
            var escaped = false
            for character in text {
                if escaped {
                    current.append(character)
                    escaped = false
                    continue
                }
                switch character {
                case "\\" where quoted:
                    current.append(character)
                    escaped = true
                case "\"":
                    quoted.toggle()
                    current.append(character)
                case ";" where !quoted:
                    pieces.append(current)
                    current = ""
                default:
                    current.append(character)
                }
                if pieces.count > Self.maximumParameters { break }
            }
            pieces.append(current)
            value = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()

            var plain: [String: String] = [:]
            var sections: [String: [Int: (text: String, extended: Bool)]] = [:]
            for piece in pieces.dropFirst().prefix(Self.maximumParameters) {
                guard let equals = piece.firstIndex(of: "=") else { continue }
                var name = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let raw = Self.unquoted(piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces))
                var extended = false
                if name.hasSuffix("*") {
                    extended = true
                    name.removeLast()
                }
                if let star = name.firstIndex(of: "*"), let number = Int(name[name.index(after: star)...]), number < 100 {
                    sections[String(name[..<star]), default: [:]][number] = (raw, extended)
                } else if extended {
                    sections[name, default: [:]][0] = (raw, true)
                } else if !name.isEmpty {
                    plain[name] = raw
                }
            }
            for (name, parts) in sections {
                guard let first = parts[0] else { continue }
                var charset: String?
                var bytes: [UInt8] = []
                for number in parts.keys.sorted() {
                    guard let part = parts[number] else { continue }
                    var text = Substring(part.text)
                    if number == 0, first.extended {
                        // charset'language'value
                        let quotes = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if quotes.count == 3 {
                            charset = String(quotes[0])
                            text = quotes[2]
                        }
                    }
                    bytes += part.extended ? Self.percentDecoded(text) : Array(text.utf8)
                }
                plain[name] = MailHeaders.text(bytes, charset: charset)
            }
            parameters = plain.mapValues { MailHeaders.decodedWords($0) }
        }

        private static let maximumParameters = 64

        private static func unquoted(_ text: String) -> String {
            guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
            var result = ""
            var escaped = false
            for character in text.dropFirst().dropLast() {
                if escaped || character != "\\" {
                    result.append(character)
                    escaped = false
                } else {
                    escaped = true
                }
            }
            return result
        }

        private static func percentDecoded(_ text: Substring) -> [UInt8] {
            let bytes = Array(text.utf8)
            var result: [UInt8] = []
            var index = 0
            while index < bytes.count {
                if bytes[index] == 0x25, index + 2 < bytes.count,
                   let value = UInt8(String(decoding: bytes[index + 1...index + 2], as: UTF8.self), radix: 16) {
                    result.append(value)
                    index += 3
                } else {
                    result.append(bytes[index])
                    index += 1
                }
            }
            return result
        }
    }
}

nonisolated extension MIMEMessage {
    private struct Entity {
        var headers = MailHeaders()
        var bodies: [Body] = []
    }

    private struct Parser {
        let bytes: [UInt8]
        let sourceIsText: Bool
        let limits: Limits
        var steps = 0
        var parts = 0
        var textBytes = 0
        var isCut = false
        var attachments: [Attachment] = []

        init(bytes: [UInt8], sourceIsText: Bool, limits: Limits) {
            self.bytes = bytes
            self.sourceIsText = sourceIsText
            self.limits = limits
        }

        /// Counts steps, and says false once there are too many.
        mutating func step(_ count: Int = 1) -> Bool {
            steps += count
            if steps > limits.maximumSteps {
                isCut = true
                return false
            }
            return true
        }

        /// The end of the line that starts at `start` without its line break, and the start
        /// of the next line.
        func line(at start: Int, in range: Range<Int>) -> (end: Int, next: Int) {
            let newline = bytes[start..<range.upperBound].firstIndex(of: 0x0A) ?? range.upperBound
            var end = newline
            if end > start, bytes[end - 1] == 0x0D { end -= 1 }
            return (end, min(newline + 1, range.upperBound))
        }

        mutating func entity(_ range: Range<Int>, depth: Int, defaultType: String = "text/plain") -> Entity {
            var entity = Entity()
            // The header block ends at the first empty line. A part that starts with a line
            // that is no field has no headers.
            var bodyStart = range.lowerBound
            var start = range.lowerBound
            var headerEnd = range.lowerBound
            var firstLine = true
            while start < range.upperBound {
                guard step() else { return entity }
                let (end, next) = line(at: start, in: range)
                if end == start {
                    headerEnd = start
                    bodyStart = next
                    break
                }
                // An mbox export starts with a "From " line, which is no field.
                let isMboxLine = depth == 0 && bytes[start..<end].starts(with: Self.mboxFrom)
                if firstLine, !isMboxLine, !Self.isField(bytes[start..<end]) {
                    headerEnd = range.lowerBound
                    bodyStart = range.lowerBound
                    break
                }
                firstLine = false
                if next - range.lowerBound > limits.maximumHeaderBytes {
                    isCut = true
                    headerEnd = start
                    bodyStart = range.upperBound
                    break
                }
                start = next
                headerEnd = next
                bodyStart = next
            }
            guard step(headerEnd - range.lowerBound) else { return entity }
            entity.headers = MailHeaders(bytes: bytes[range.lowerBound..<headerEnd])
            if entity.headers.isCut { isCut = true }
            let body = bodyStart..<max(bodyStart, range.upperBound)

            let type = HeaderValue(entity.headers["Content-Type"] ?? defaultType)
            var mimeType = type.value.contains("/") ? type.value : defaultType
            if mimeType.contains(where: \.isWhitespace) { mimeType = defaultType }
            let disposition = entity.headers["Content-Disposition"].map(HeaderValue.init)
            let transfer = (entity.headers["Content-Transfer-Encoding"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let name = disposition?.parameters["filename"] ?? type.parameters["name"]

            if mimeType.hasPrefix("multipart/") {
                if let boundary = type.parameters["boundary"], !boundary.isEmpty {
                    guard depth < limits.maximumDepth else {
                        isCut = true
                        return entity
                    }
                    entity.bodies = multipart(body, subtype: String(mimeType.dropFirst("multipart/".count)), boundary: boundary, depth: depth)
                    return entity
                }
                // A multipart without a boundary reads as plain text.
                mimeType = "text/plain"
            }
            switch mimeType {
            case "application/pkcs7-signature", "application/x-pkcs7-signature", "application/pgp-signature":
                return entity
            case "text/plain", "text/html":
                let isAttachment = disposition?.value == "attachment" || (name != nil && disposition?.value != "inline")
                if !isAttachment {
                    if let text = decodedText(body, transfer: transfer, charset: type.parameters["charset"]) {
                        let isFlowed = mimeType == "text/plain" && type.parameters["format"]?.lowercased() == "flowed"
                        let delsp = type.parameters["delsp"]?.lowercased() == "yes"
                        entity.bodies = [Body(
                            format: mimeType == "text/html" ? .markup : .plain,
                            text: isFlowed ? Self.unflowed(text, deleteSpace: delsp) : text)]
                    }
                    return entity
                }
            default:
                break
            }
            attachments.append(Attachment(
                name: name.map(MailHeaders.oneLine).flatMap { $0.isEmpty ? nil : $0 },
                mimeType: mimeType,
                isInline: disposition?.value == "inline"))
            return entity
        }

        /// The parts of a multipart body and the bodies they give.
        mutating func multipart(_ body: Range<Int>, subtype: String, boundary: String, depth: Int) -> [Body] {
            let delimiter = Array("--\(boundary)".utf8)
            var ranges: [Range<Int>] = []
            var partStart: Int?
            var start = body.lowerBound
            var closed = false
            while start < body.upperBound {
                guard step() else { break }
                let (end, next) = line(at: start, in: body)
                if end - start >= delimiter.count, bytes[start] == 0x2D, bytes[start..<start + delimiter.count].elementsEqual(delimiter) {
                    var rest = bytes[start + delimiter.count..<end]
                    let isClose = rest.starts(with: [0x2D, 0x2D])
                    if isClose { rest = rest.dropFirst(2) }
                    if rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                        if let partStart {
                            // The line break before a delimiter belongs to the delimiter.
                            var partEnd = start
                            if partEnd > partStart, bytes[partEnd - 1] == 0x0A { partEnd -= 1 }
                            if partEnd > partStart, bytes[partEnd - 1] == 0x0D { partEnd -= 1 }
                            ranges.append(partStart..<max(partStart, partEnd))
                        }
                        if isClose {
                            closed = true
                            partStart = nil
                            break
                        }
                        partStart = next
                    }
                }
                start = next
            }
            if !closed, let partStart, partStart < body.upperBound {
                ranges.append(partStart..<body.upperBound)
            }
            // A multipart without one delimiter reads as plain text.
            if ranges.isEmpty, !closed {
                if let text = decodedText(body, transfer: "", charset: nil), !text.isEmpty {
                    return [Body(format: .plain, text: text)]
                }
                return []
            }

            var children: [[Body]] = []
            for (number, range) in ranges.enumerated() {
                guard parts < limits.maximumParts else {
                    isCut = true
                    break
                }
                parts += 1
                if subtype == "encrypted" { break }
                if subtype == "signed", number > 0 { break }
                let defaultType = subtype == "digest" ? "message/rfc822" : "text/plain"
                let attachmentsBefore = attachments.count
                let child = entity(range, depth: depth + 1, defaultType: defaultType)
                if subtype == "related", number > 0 {
                    // Resources of the first part, such as its images, show inline.
                    for index in attachmentsBefore..<attachments.count { attachments[index].isInline = true }
                    continue
                }
                children.append(child.bodies)
            }
            if subtype == "alternative" {
                return children.last { !$0.isEmpty } ?? []
            }
            return children.flatMap { $0 }
        }

        /// A text part decoded, cut at the text limit, or nil once the limit is reached.
        mutating func decodedText(_ range: Range<Int>, transfer: String, charset: String?) -> String? {
            let budget = limits.maximumTextBytes - textBytes
            guard budget > 0 else {
                isCut = true
                return nil
            }
            guard step(range.count) else { return nil }
            var decoded: [UInt8]
            var isRaw = false
            switch transfer {
            case "base64":
                decoded = MailHeaders.base64(bytes[range])
            case "quoted-printable":
                decoded = MailHeaders.quotedPrintable(bytes[range])
            default:
                decoded = Array(bytes[range])
                isRaw = true
            }
            let readsAsUTF8 = isRaw && sourceIsText
            if decoded.count > budget {
                decoded.removeSubrange(budget...)
                isCut = true
                // Drop a character cut in half, which is up to three bytes in any charset.
                let encoding = readsAsUTF8 ? .utf8 : charset.flatMap(MailHeaders.encoding) ?? .utf8
                for _ in 0..<3 where !decoded.isEmpty && String(bytes: decoded, encoding: encoding) == nil {
                    decoded.removeLast()
                }
            }
            textBytes += decoded.count
            let text: String
            if readsAsUTF8, let utf8 = String(bytes: decoded, encoding: .utf8) {
                text = utf8
            } else {
                text = MailHeaders.text(decoded, charset: charset)
            }
            return Self.unixLines(text)
        }

        private static let mboxFrom = Array("From ".utf8)

        /// Whether a line is a header field: a name of printable characters, then a colon.
        static func isField(_ line: ArraySlice<UInt8>) -> Bool {
            guard let colon = line.firstIndex(of: 0x3A), colon > line.startIndex else { return false }
            return line[line.startIndex..<colon].allSatisfy { (0x21...0x7E).contains($0) }
        }

        /// Line breaks as "\n". "\r\n" is one Character, so the check looks at bytes.
        static func unixLines(_ text: String) -> String {
            guard text.utf8.contains(0x0D) else { return text }
            return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }

        /// format=flowed text (RFC 3676) with its soft line breaks joined: a line that ends in
        /// a space goes on in the next line of the same quote depth. Space stuffing is
        /// removed, and with delsp=yes the space at the break too. The signature line "-- "
        /// is never joined.
        static func unflowed(_ text: String, deleteSpace: Bool) -> String {
            var lines: [String] = []
            var flowing = false
            var flowingDepth = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let depth = line.prefix(while: { $0 == ">" }).count
                var content = line.dropFirst(depth)
                if content.hasPrefix(" ") { content = content.dropFirst() }
                let isSignature = content == "-- "
                let isFlowed = content.hasSuffix(" ") && !isSignature
                if isFlowed, deleteSpace { content = content.dropLast() }
                if flowing, depth == flowingDepth, !lines.isEmpty {
                    lines[lines.count - 1] += content
                } else {
                    let prefix = depth > 0 ? String(repeating: ">", count: depth) + " " : ""
                    lines.append(prefix + content)
                }
                flowing = isFlowed
                flowingDepth = depth
            }
            return lines.joined(separator: "\n")
        }
    }
}
