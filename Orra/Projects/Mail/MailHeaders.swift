import Foundation

/// The header fields of an email or of one MIME part, unfolded, with the values Projects
/// reads decoded: RFC 2047 words in the subject and in names, the Message-ID lists that
/// threads come from, the addresses and the date.
///
/// Parsing never fails. A line that is not a field is skipped, and a value whose bytes are
/// not in the charset it names is read in the next one that fits.
nonisolated struct MailHeaders: Sendable, Equatable {
    /// One field as it came, unfolded, with its RFC 2047 words still encoded.
    nonisolated struct Field: Sendable, Equatable {
        var name: String
        var value: String
    }

    /// Caps on what one header block may hold.
    nonisolated struct Limits: Sendable, Equatable {
        /// Fields past this many are left out.
        var maximumFields = 1_000
        /// A value is cut to this many bytes.
        var maximumValueBytes = 64 << 10
    }

    var fields: [Field]
    /// Whether fields or bytes were left out at a limit.
    var isCut = false

    init(fields: [Field] = []) {
        self.fields = fields
    }

    /// Parses a header block, such as the text before the first blank line of an email, or
    /// what Mail gives for all headers. It stops at the first blank line.
    init(parsing text: String, limits: Limits = Limits()) {
        self.init(bytes: Array(text.utf8)[...], limits: limits)
    }

    /// Parses a header block in bytes. Each value is read as UTF-8 when its bytes are valid
    /// UTF-8, or else as GB18030, or else as Windows-1252, since mail that does not follow
    /// RFC 2047 often carries raw bytes in the subject or a name. With `readsCharacters`, the
    /// bytes are the characters of a source that came as text, one byte each, and a value
    /// that is not UTF-8 reads as those characters.
    init(bytes: ArraySlice<UInt8>, limits: Limits = Limits(), readsCharacters: Bool = false) {
        var fields: [Field] = []
        var name: String?
        var value: [UInt8] = []
        var isCut = false

        func finish() {
            guard let name else { return }
            guard fields.count < limits.maximumFields else {
                isCut = true
                return
            }
            if value.count > limits.maximumValueBytes {
                value.removeSubrange(limits.maximumValueBytes...)
                isCut = true
            }
            let text = readsCharacters ? String(bytes: value, encoding: .utf8) ?? String(bytes: value, encoding: .isoLatin1) : nil
            fields.append(Field(name: name, value: text ?? Self.headerText(value)))
        }

        var start = bytes.startIndex
        while start < bytes.endIndex {
            let newline = bytes[start...].firstIndex(of: 0x0A) ?? bytes.endIndex
            var end = newline
            if end > start, bytes[end - 1] == 0x0D { end -= 1 }
            let line = bytes[start..<end]
            start = newline == bytes.endIndex ? newline : newline + 1
            if line.isEmpty { break }
            if line.first == 0x20 || line.first == 0x09 {
                // A folded line continues the field before it, white space and all.
                if name != nil, value.count <= limits.maximumValueBytes { value.append(contentsOf: line) }
                continue
            }
            finish()
            name = nil
            value = []
            guard let colon = line.firstIndex(of: 0x3A) else { continue }
            var nameEnd = colon
            while nameEnd > line.startIndex, bytes[nameEnd - 1] == 0x20 || bytes[nameEnd - 1] == 0x09 { nameEnd -= 1 }
            let nameBytes = line[line.startIndex..<nameEnd]
            guard !nameBytes.isEmpty, nameBytes.allSatisfy({ (0x21...0x7E).contains($0) }) else { continue }
            name = String(decoding: nameBytes, as: UTF8.self)
            var valueStart = colon + 1
            while valueStart < line.endIndex, line[valueStart] == 0x20 || line[valueStart] == 0x09 { valueStart += 1 }
            value.append(contentsOf: line[valueStart...])
        }
        finish()
        self.fields = fields
        self.isCut = isCut
    }

    /// The values of every field with this name, in order. Names compare without case.
    func values(_ name: String) -> [String] {
        fields.lazy.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// The value of the first field with this name, or nil.
    subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The subject with its RFC 2047 words decoded, on one line.
    var subject: String? {
        self["Subject"].map(Self.decodedWords)
    }

    /// The Message-ID without its angle brackets.
    var messageID: String? {
        self["Message-ID"].flatMap { Self.messageIDs($0).first }
    }

    /// The Message-IDs In-Reply-To names, usually one.
    var inReplyTo: [String] {
        values("In-Reply-To").flatMap(Self.messageIDs)
    }

    /// The Message-IDs of References, the root of the thread first.
    var references: [String] {
        Self.cut(values("References").flatMap(Self.messageIDs))
    }

    var from: [MailAddressHeader] { addresses("From") }
    var to: [MailAddressHeader] { addresses("To") }
    var cc: [MailAddressHeader] { addresses("Cc") }
    var replyTo: [MailAddressHeader] { addresses("Reply-To") }

    /// The mailboxes of every field with this name.
    func addresses(_ name: String) -> [MailAddressHeader] {
        values(name).flatMap(MailAddressHeader.list)
    }

    /// The mailboxes of every field with this name, or nil when an entry was not read
    /// exactly, see `MailAddressHeader.read(_:)`. For a check that must see every address
    /// another reader such as Mail may take from the fields.
    func exactAddresses(_ name: String) -> [MailAddressHeader]? {
        var mailboxes: [MailAddressHeader] = []
        for value in values(name) {
            let read = MailAddressHeader.read(value)
            guard read.unclear == 0 else { return nil }
            mailboxes += read.mailboxes
        }
        return mailboxes
    }

    /// The date the sender's client wrote, or nil when the Date field is missing or cannot
    /// be read.
    var date: Date? {
        self["Date"].flatMap(Self.date)
    }

    // MARK: RFC 2047

    /// The value with its RFC 2047 words decoded, such as `=?UTF-8?B?6aG555uu?=` or
    /// `=?GB2312?Q?=CF=EE=C4=BF?=`, on one line. Words next to each other with only white
    /// space between them join without it. Words in one charset are decoded together, so a
    /// character split between two words comes out whole. Line breaks and other control
    /// characters become spaces, so a decoded value never spans lines.
    static func decodedWords(_ value: String) -> String {
        let bytes = Array(value.utf8)
        guard bytes.count > 1 else { return oneLine(value) }
        var result = ""
        var literalStart = 0
        var pending: (charset: String, bytes: [UInt8])?
        var index = 0
        var ends = WordEnds(bytes)

        func flushPending() {
            if let word = pending {
                result += text(word.bytes, charset: word.charset)
                pending = nil
            }
        }

        while index < bytes.count {
            guard bytes[index] == 0x3D, index + 1 < bytes.count, bytes[index + 1] == 0x3F,
                  let word = encodedWord(bytes, at: index, ends: &ends) else {
                index += 1
                continue
            }
            let gap = bytes[literalStart..<index]
            let onlySpace = gap.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
            if pending != nil, onlySpace, pending?.charset.caseInsensitiveCompare(word.charset) == .orderedSame {
                pending?.bytes += word.bytes
            } else if pending != nil, onlySpace {
                flushPending()
                pending = (word.charset, word.bytes)
            } else {
                flushPending()
                result += String(decoding: gap, as: UTF8.self)
                pending = (word.charset, word.bytes)
            }
            index = word.end
            literalStart = word.end
        }
        flushPending()
        result += String(decoding: bytes[literalStart...], as: UTF8.self)
        return oneLine(result)
    }

    /// Where the next "?=" and the next byte that may not stand in an encoded word are, from
    /// a position that only moves forward, so a value full of words that never end takes
    /// linear time.
    private struct WordEnds {
        let bytes: [UInt8]
        private var terminatorAt = 0
        private var breakerAt = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            terminatorAt = Self.find(in: bytes, from: 0) { $0 + 1 < bytes.count && bytes[$0] == 0x3F && bytes[$0 + 1] == 0x3D }
            breakerAt = Self.find(in: bytes, from: 0) { bytes[$0] <= 0x20 || bytes[$0] >= 0x7F }
        }

        private static func find(in bytes: [UInt8], from start: Int, where test: (Int) -> Bool) -> Int {
            var index = start
            while index < bytes.count, !test(index) { index += 1 }
            return index
        }

        /// The first "?=" at or after `start`.
        mutating func terminator(from start: Int) -> Int {
            if start > terminatorAt {
                let bytes = bytes
                terminatorAt = Self.find(in: bytes, from: start) { $0 + 1 < bytes.count && bytes[$0] == 0x3F && bytes[$0 + 1] == 0x3D }
            }
            return terminatorAt
        }

        /// The first byte at or after `start` that may not stand in a word.
        mutating func breaker(from start: Int) -> Int {
            if start > breakerAt {
                let bytes = bytes
                breakerAt = Self.find(in: bytes, from: start) { bytes[$0] <= 0x20 || bytes[$0] >= 0x7F }
            }
            return breakerAt
        }
    }

    /// The encoded word that starts at `start`, with its charset, its decoded bytes and the
    /// index after it, or nil when the text there is not one.
    private static func encodedWord(_ bytes: [UInt8], at start: Int, ends: inout WordEnds) -> (charset: String, bytes: [UInt8], end: Int)? {
        var index = start + 2
        let charsetStart = index
        while index < bytes.count, bytes[index] != 0x3F {
            if bytes[index] <= 0x20 || bytes[index] >= 0x7F || index - charsetStart > 64 { return nil }
            index += 1
        }
        guard index > charsetStart, index + 2 < bytes.count, bytes[index + 2] == 0x3F else { return nil }
        // RFC 2231 lets the charset carry a language, as in UTF-8*en.
        var charset = String(decoding: bytes[charsetStart..<index], as: UTF8.self)
        if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }
        let encoding = bytes[index + 1] | 0x20
        guard encoding == 0x62 || encoding == 0x71 else { return nil }
        // RFC 2047 caps a word at 75 characters. A longer cap stays lenient with senders,
        // and bounds the work on a value full of words that never end.
        let textStart = index + 3
        let textEnd = ends.terminator(from: textStart)
        guard textEnd + 1 < bytes.count, textEnd - textStart <= maximumWordBytes, ends.breaker(from: textStart) >= textEnd else { return nil }
        let encoded = bytes[textStart..<textEnd]
        let decoded = encoding == 0x62 ? base64(encoded) : quotedPrintable(encoded, underscoreIsSpace: true)
        return (charset, decoded, textEnd + 2)
    }

    private static let maximumWordBytes = 1_024

    /// Text with line breaks and other control characters, tab included, turned into
    /// spaces, and trimmed.
    static func oneLine(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F || $0 == 0xC2 }) else { return text.trimmingCharacters(in: .whitespaces) }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Message-IDs

    /// The Message-IDs in a value, without angle brackets, such as the one of Message-ID or
    /// the list of References. Comments in parentheses are skipped. A value without angle
    /// brackets gives its words that hold an @. A list of more than 200 keeps the first, the
    /// root of a thread in References, and the last 199, the newest.
    static func messageIDs(_ value: String) -> [String] {
        var ids: [String] = []
        var bare: [String] = []
        var word = ""
        var index = value.startIndex
        func endWord() {
            if word.contains("@") { bare.append(word) }
            word = ""
        }
        while index < value.endIndex {
            let character = value[index]
            switch character {
            case "(":
                endWord()
                index = commentEnd(value, from: index)
                continue
            case "<":
                endWord()
                guard let close = value[index...].firstIndex(of: ">") else {
                    index = value.endIndex
                    continue
                }
                let id = value[value.index(after: index)..<close]
                if !id.isEmpty, !id.contains(where: { $0.isWhitespace || $0 == "<" }) {
                    ids.append(String(id))
                }
                index = value.index(after: close)
                continue
            case _ where character.isWhitespace || character == ",":
                endWord()
            default:
                word.append(character)
            }
            index = value.index(after: index)
        }
        endWord()
        return cut(ids.isEmpty ? bare : ids)
    }

    private static func cut(_ ids: [String]) -> [String] {
        guard ids.count > maximumIDs else { return ids }
        return [ids[0]] + ids.suffix(maximumIDs - 1)
    }

    private static let maximumIDs = 200

    /// The index after the comment that opens at `start`, which may hold nested comments and
    /// escaped characters.
    static func commentEnd(_ value: String, from start: String.Index) -> String.Index {
        var depth = 0
        var index = start
        while index < value.endIndex {
            switch value[index] {
            case "\\":
                index = value.index(after: index)
                if index == value.endIndex { return index }
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return value.index(after: index) }
            default:
                break
            }
            index = value.index(after: index)
        }
        return index
    }

    // MARK: Date

    /// The moment an RFC 5322 date such as `Mon, 12 Oct 2026 09:30:00 +0800` names. The day
    /// of the week, the seconds and the zone may be missing, and a missing zone counts as
    /// UTC. Zone names follow RFC 5322, so CST is US Central time. Nil when the value is not
    /// such a date.
    static func date(_ value: String) -> Date? {
        var text = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "(" {
                index = commentEnd(value, from: index)
                text.append(" ")
                continue
            }
            text.append(value[index])
            index = value.index(after: index)
        }
        var words = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { $0.lowercased() }
        if let first = words.first, first.allSatisfy(\.isLetter), month(first) == nil { words.removeFirst() }
        guard words.count >= 4 else { return nil }
        var day: Int?
        var monthNumber: Int?
        // Day month year, or month day year, which a few clients write.
        if let number = Int(words[0]) {
            day = number
            monthNumber = month(words[1])
        } else if let number = Int(words[1]) {
            monthNumber = month(words[0])
            day = number
        }
        guard let day, let monthNumber, (1...31).contains(day), var year = Int(words[2]) else { return nil }
        if words[2].count <= 2 { year += year < 50 ? 2000 : 1900 }
        guard (1900...9999).contains(year) else { return nil }
        let time = words[3].split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard time.count == 2 || time.count == 3, time.allSatisfy({ $0 != nil }) else { return nil }
        let hour = time[0]!, minute = time[1]!, second = time.count == 3 ? time[2]! : 0
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        var offset = 0
        if words.count >= 5 {
            guard let zone = zoneOffset(words[4]) else { return nil }
            offset = zone
        }
        let days = daysSince1970(year: year, month: monthNumber, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func month(_ word: String) -> Int? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard word.count >= 3 else { return nil }
        return months.firstIndex(of: String(word.prefix(3))).map { $0 + 1 }
    }

    /// Seconds east of UTC for a zone such as +0800, -0500, GMT or EST.
    private static func zoneOffset(_ zone: String) -> Int? {
        if let sign = zone.first, sign == "+" || sign == "-" {
            let digits = zone.dropFirst()
            guard digits.count == 4, let number = Int(digits) else { return nil }
            let seconds = (number / 100) * 3_600 + (number % 100) * 60
            return sign == "-" ? -seconds : seconds
        }
        let names = ["ut": 0, "utc": 0, "gmt": 0, "z": 0, "est": -5, "edt": -4, "cst": -6, "cdt": -5, "mst": -7, "mdt": -6, "pst": -8, "pdt": -7]
        if let hours = names[zone] { return hours * 3_600 }
        // RFC 5322 reads every other zone name, military letters included, as UTC.
        return zone.allSatisfy(\.isLetter) ? 0 : nil
    }

    /// Days from 1970-01-01 to a date in the Gregorian calendar (Howard Hinnant's
    /// days_from_civil).
    private static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    // MARK: Charsets and transfer encodings

    /// Bytes as text in the charset a MIME label names. Chinese labels read as their largest
    /// form, as browsers do: GB2312 and GBK as GB18030, and Big5 as Big5-HKSCS, since mail
    /// labeled GB2312 often holds GBK characters. US-ASCII and Latin-1 read as
    /// Windows-1252. A single byte label on valid UTF-8 reads as UTF-8, a common mistake of
    /// senders. Broken UTF-8 keeps its valid characters. Bytes that are not valid in another
    /// charset, and a missing or unknown charset, fall back to UTF-8, then GB18030, then
    /// Windows-1252 and Latin-1, which reads any bytes.
    static func text(_ bytes: some Collection<UInt8>, charset: String?) -> String {
        let declared = charset.flatMap(encoding)
        if declared == nil || declared == .windowsCP1252, let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        if let declared {
            if let text = String(bytes: bytes, encoding: declared) { return text }
            if declared == .utf8 { return String(decoding: bytes, as: UTF8.self) }
        }
        for fallback in [String.Encoding.utf8, gb18030, .windowsCP1252] where fallback != declared {
            if let text = String(bytes: bytes, encoding: fallback) { return text }
        }
        return String(bytes: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Raw header bytes as text: UTF-8, else GB18030, else Windows-1252.
    private static func headerText(_ bytes: [UInt8]) -> String {
        text(bytes, charset: nil)
    }

    /// The encoding of a MIME charset label, or nil for a label macOS does not know.
    static func encoding(_ charset: String) -> String.Encoding? {
        let label = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")).lowercased()
        switch label {
        case "utf-8", "utf8", "unicode-1-1-utf-8":
            return .utf8
        case "us-ascii", "ascii", "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1", "windows-1252", "cp1252", "x-cp1252":
            return .windowsCP1252
        case "gb2312", "gbk", "gb18030", "euc-cn", "x-euc-cn", "x-gbk", "cp936", "ms936", "windows-936", "csgb2312", "chinese", "gb_2312-80", "iso-ir-58":
            return gb18030
        case "big5", "big5-hkscs", "cn-big5", "x-x-big5", "csbig5", "x-big5":
            return big5HKSCS
        default:
            guard !label.isEmpty, label.count <= 64 else { return nil }
            let encoding = CFStringConvertIANACharSetNameToEncoding(label as CFString)
            guard encoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        }
    }

    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    private static let big5HKSCS = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))

    /// Base64 decoded leniently: characters outside the alphabet are skipped, the text ends
    /// at the first =, and a short last group gives the bytes it holds.
    static func base64(_ encoded: some Collection<UInt8>) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(encoded.count * 3 / 4)
        var buffer: UInt32 = 0
        var count = 0
        for byte in encoded {
            let value: UInt32
            switch byte {
            case 0x41...0x5A: value = UInt32(byte - 0x41)
            case 0x61...0x7A: value = UInt32(byte - 0x61 + 26)
            case 0x30...0x39: value = UInt32(byte - 0x30 + 52)
            case 0x2B, 0x2D: value = 62
            case 0x2F, 0x5F: value = 63
            case 0x3D: return finishBase64(&result, buffer: buffer, count: count)
            default: continue
            }
            buffer = buffer << 6 | value
            count += 1
            if count == 4 {
                result.append(UInt8(buffer >> 16 & 0xFF))
                result.append(UInt8(buffer >> 8 & 0xFF))
                result.append(UInt8(buffer & 0xFF))
                buffer = 0
                count = 0
            }
        }
        return finishBase64(&result, buffer: buffer, count: count)
    }

    private static func finishBase64(_ result: inout [UInt8], buffer: UInt32, count: Int) -> [UInt8] {
        switch count {
        case 2:
            result.append(UInt8(buffer >> 4 & 0xFF))
        case 3:
            result.append(UInt8(buffer >> 10 & 0xFF))
            result.append(UInt8(buffer >> 2 & 0xFF))
        default:
            break
        }
        return result
    }

    /// Quoted printable decoded leniently: =XX gives the byte, = at the end of a line joins
    /// it to the next, and any other = stays as it is. In RFC 2047 words, _ is a space.
    static func quotedPrintable(_ encoded: some Collection<UInt8>, underscoreIsSpace: Bool = false) -> [UInt8] {
        let bytes = Array(encoded)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5F, underscoreIsSpace {
                result.append(0x20)
                index += 1
                continue
            }
            guard byte == 0x3D else {
                result.append(byte)
                index += 1
                continue
            }
            if let high = hexValue(bytes, index + 1), let low = hexValue(bytes, index + 2) {
                result.append(high << 4 | low)
                index += 3
                continue
            }
            // A soft line break: = with only spaces or tabs before the end of the line.
            var next = index + 1
            while next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x09 { next += 1 }
            if next < bytes.count, bytes[next] == 0x0D { next += 1 }
            if next < bytes.count, bytes[next] == 0x0A {
                index = next + 1
                continue
            }
            if next == bytes.count {
                index = next
                continue
            }
            result.append(byte)
            index += 1
        }
        return result
    }

    private static func hexValue(_ bytes: [UInt8], _ index: Int) -> UInt8? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case 0x30...0x39: return bytes[index] - 0x30
        case 0x41...0x46: return bytes[index] - 0x41 + 10
        case 0x61...0x66: return bytes[index] - 0x61 + 10
        default: return nil
        }
    }
}

/// One mailbox of an address field such as From, To or Cc: the display name, decoded, and
/// the address in the one form Projects compares, from `ProjectsAddress.normalized(_:)`.
nonisolated struct MailAddressHeader: Sendable, Hashable {
    var name: String
    var address: String

    /// Every mailbox in an address list such as
    /// `"Tan, Mei" <Mei.Tan@Orchard.example>, lu@orchard.example (Lu Wen)`.
    ///
    /// Quoted names may hold commas. A group such as `Team: a@x.example, b@x.example;`
    /// gives its members. A name in a comment after a bare address counts when there is no
    /// other. RFC 2047 words in names are decoded. An entry whose address
    /// `ProjectsAddress.normalized(_:)` does not take is left out, and so is every entry
    /// past the first 1,000.
    static func list(_ value: String) -> [MailAddressHeader] {
        read(value).mailboxes
    }

    /// The mailboxes of an address list, as `list(_:)` gives them, and how many entries were
    /// not read exactly: those left out, and those with a second address in angle brackets
    /// or text after the one, which another reader may take another address from. An empty
    /// entry, as after a last comma, does not count.
    static func read(_ value: String) -> (mailboxes: [MailAddressHeader], unclear: Int) {
        var result: [MailAddressHeader] = []
        var unclear = 0
        var phrase = ""
        var angle: String?
        var comment = ""
        // Whether the entry has more after its address in angle brackets.
        var moreAfterAngle = false
        var index = value.startIndex

        func finish() {
            defer {
                phrase = ""
                angle = nil
                comment = ""
                moreAfterAngle = false
            }
            let bare = phrase.trimmingCharacters(in: .whitespaces)
            let addressText = angle ?? bare
            guard result.count < maximumMailboxes, let address = ProjectsAddress.normalized(addressText) else {
                if angle != nil || !bare.isEmpty { unclear += 1 }
                return
            }
            if moreAfterAngle { unclear += 1 }
            var name = angle == nil ? "" : bare
            if name.isEmpty { name = comment }
            name = MailHeaders.decodedWords(name).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            result.append(MailAddressHeader(name: name, address: address))
        }

        while index < value.endIndex {
            let character = value[index]
            switch character {
            case "\"":
                if angle != nil { moreAfterAngle = true }
                var quoted = ""
                var cursor = value.index(after: index)
                while cursor < value.endIndex, value[cursor] != "\"" {
                    if value[cursor] == "\\" {
                        cursor = value.index(after: cursor)
                        if cursor == value.endIndex { break }
                    }
                    quoted.append(value[cursor])
                    cursor = value.index(after: cursor)
                }
                phrase += quoted
                index = cursor < value.endIndex ? value.index(after: cursor) : cursor
                continue
            case "(":
                let end = MailHeaders.commentEnd(value, from: index)
                let inside = value[value.index(after: index)..<end].dropLast(value[..<end].last == ")" ? 1 : 0)
                if comment.isEmpty { comment = String(inside).trimmingCharacters(in: .whitespaces) }
                index = end
                continue
            case "<":
                if angle != nil { moreAfterAngle = true }
                let close = value[index...].firstIndex(of: ">") ?? value.endIndex
                angle = String(value[value.index(after: index)..<close])
                index = close < value.endIndex ? value.index(after: close) : close
                continue
            case ",", ";":
                finish()
            case ":" where angle == nil && !phrase.contains("@"):
                // The name of a group. Its members follow.
                phrase = ""
                comment = ""
            default:
                if angle != nil, !character.isWhitespace { moreAfterAngle = true }
                phrase.append(character)
            }
            index = value.index(after: index)
        }
        finish()
        return (result, unclear)
    }

    private static let maximumMailboxes = 1_000
}
