import Compression
import Foundation

/// A read only view of the bytes of one ZIP file in memory, such as an xlsx, a pptx, a docx
/// or an odt. Nothing is written, so no part name ever becomes a path.
///
/// - An archive has one end record without ZIP64, on one disk, with its central directory
///   just before it, at most `maximumEntries` entries, and every entry unencrypted, stored
///   or deflated, with 32 bit sizes. Anything else is unreadable.
/// - A part is unpacked only into a buffer of the size its entry declares, after that size
///   was taken from a budget, and its CRC-32 is checked. So a part never unpacks past what
///   its entry says, whatever its bytes say.
/// - Deflated parts are decoded with Compression, whose COMPRESSION_ZLIB is the raw DEFLATE
///   format of RFC 1951 that ZIP uses.
nonisolated struct ZipArchive: Sendable {
    /// An entry of the central directory.
    nonisolated struct Entry: Sendable, Equatable {
        var name: String
        /// 0 for a stored part, 8 for a deflated one.
        var method: Int
        var packedSize: Int
        var size: Int
        var crc32: UInt32
        /// Where its local header starts.
        var offset: Int
    }

    /// The most entries an archive may have (a guess). An Office file has a few hundred.
    static let maximumEntries = 10_000

    let entries: [Entry]
    private let data: Data
    /// Where the central directory starts, so every part lies before it.
    private let directoryStart: Int

    /// The archive in `data`, or unreadable when it breaks one of the rules above.
    init(_ data: Data) throws(FileSkipReason) {
        switch data.withUnsafeBytes({ Self.directory(of: $0.bindMemory(to: UInt8.self)) }) {
        case .success(let directory):
            (entries, directoryStart) = directory
            self.data = data
        case .failure(let reason):
            throw reason
        }
    }

    /// The entries of the central directory and where it starts.
    private static func directory(of bytes: UnsafeBufferPointer<UInt8>) -> Result<([Entry], Int), FileSkipReason> {
        func number(_ offset: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        guard bytes.count >= 22 else { return .failure(.unreadable) }
        // The end of the central directory: 22 bytes, then a comment of up to 65,535 bytes
        // that runs to the end of the file.
        let lowest = max(0, bytes.count - 22 - 65_535)
        let ends = stride(from: bytes.count - 22, through: lowest, by: -1).filter { offset in
            number(offset, 4) == 0x0605_4B50 && offset + 22 + number(offset + 20, 2) == bytes.count
        }
        guard ends.count == 1, let end = ends.first else { return .failure(.unreadable) }
        let count = number(end + 10, 2), directorySize = number(end + 12, 4), directoryStart = number(end + 16, 4)
        // One disk, no ZIP64, and the directory just before its end.
        guard number(end + 4, 4) == 0, number(end + 8, 2) == count, count != 0xFFFF, count <= maximumEntries,
              directoryStart + directorySize == end else { return .failure(.unreadable) }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var offset = directoryStart
        for _ in 0..<count {
            guard offset + 46 <= end, number(offset, 4) == 0x0201_4B50 else { return .failure(.unreadable) }
            let flags = number(offset + 8, 2), method = number(offset + 10, 2)
            let packedSize = number(offset + 20, 4), size = number(offset + 24, 4), header = number(offset + 42, 4)
            guard flags & 1 == 0, method == 0 || method == 8, packedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF,
                  header != 0xFFFF_FFFF else { return .failure(.unreadable) }
            let nameLength = number(offset + 28, 2)
            let next = offset + 46 + nameLength + number(offset + 30, 2) + number(offset + 32, 2)
            guard next <= end else { return .failure(.unreadable) }
            entries.append(Entry(
                name: String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self),
                method: method, packedSize: packedSize, size: size, crc32: UInt32(number(offset + 16, 4)), offset: header))
            offset = next
        }
        guard offset == end else { return .failure(.unreadable) }
        return .success((entries, directoryStart))
    }

    /// The sizes of every part unpacked, added up.
    var unpackedSize: Int64 {
        entries.reduce(0) { $0 + Int64($1.size) }
    }

    /// Whether the archive holds a part of that name, compared without case, as Office
    /// compares part names.
    func contains(_ name: String) -> Bool {
        let name = Self.folded(name)
        return entries.contains { Self.folded($0.name) == name }
    }

    /// The unpacked bytes of the part of that name, compared without case. Its size is
    /// taken from `budget` first, and a part that does not fit is too large. A part that is
    /// missing or named twice, whose local header does not match its entry, that unpacks to
    /// another size or whose CRC-32 differs is unreadable.
    func data(of name: String, budget: inout Int64) -> Result<Data, FileSkipReason> {
        let name = Self.folded(name)
        let matching = entries.filter { Self.folded($0.name) == name }
        guard matching.count == 1, let entry = matching.first else { return .failure(.unreadable) }
        guard Int64(entry.size) <= budget else { return .failure(.tooLarge) }
        budget -= Int64(entry.size)
        guard let packed = packedBytes(of: entry) else { return .failure(.unreadable) }
        let unpacked: Data
        if entry.method == 0 {
            guard packed.count == entry.size else { return .failure(.unreadable) }
            unpacked = packed
        } else if entry.size == 0 {
            unpacked = Data()
        } else {
            guard !packed.isEmpty else { return .failure(.unreadable) }
            // One byte more than the part declares, so a part that holds more fills the
            // buffer and is refused. A failed decode writes nothing and returns 0.
            var buffer = Data(count: entry.size + 1)
            let written = buffer.withUnsafeMutableBytes { output in
                packed.withUnsafeBytes { input in
                    compression_decode_buffer(
                        output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                        input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { return .failure(.unreadable) }
            buffer.removeLast()
            unpacked = buffer
        }
        guard Self.crc32(unpacked) == entry.crc32 else { return .failure(.unreadable) }
        return .success(unpacked)
    }

    /// The packed bytes of an entry, after its local header, nil when the header does not
    /// match the entry or the bytes run into the central directory.
    private func packedBytes(of entry: Entry) -> Data? {
        data.withUnsafeBytes { raw -> Data? in
            let bytes = raw.bindMemory(to: UInt8.self)
            func number(_ offset: Int, _ size: Int) -> Int {
                (0..<size).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
            }
            let header = entry.offset
            guard header + 30 <= directoryStart, number(header, 4) == 0x0403_4B50 else { return nil }
            let nameLength = number(header + 26, 2)
            let start = header + 30 + nameLength + number(header + 28, 2)
            guard start <= directoryStart, entry.packedSize <= directoryStart - start,
                  bytes[(header + 30)..<(header + 30 + nameLength)].elementsEqual(entry.name.utf8) else { return nil }
            return Data(bytes[start..<(start + entry.packedSize)])
        }
    }

    /// A part name for comparing: in lowercase, and with no slash in front, which a
    /// relationship may write and an entry never has.
    private static func folded(_ name: String) -> String {
        String(name.drop { $0 == "/" }).lowercased()
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
        return crc
    }

    /// The CRC-32 of ZIP, with the polynomial of IEEE 802.3.
    static func crc32(_ data: Data) -> UInt32 {
        let table = crcTable
        return ~data.withUnsafeBytes { bytes in
            bytes.reduce(UInt32(0xFFFF_FFFF)) { crc, byte in
                table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
    }
}
