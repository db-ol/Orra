import Darwin
import Foundation

/// The voice sample on disk, for Remember my voice in Settings, which is off until the user
/// turns it on (approved by the maintainer on 2026-10-15). It holds the audio only, never
/// what is said in it or anything a voice model derived from it, so the speech model
/// writes the words down again when Orra loads it.
///
/// ~/Library/Application Support/io.github.db-ol.Orra/Voice/voice-sample.dat in the app.
/// Only the user can open the folder (0700) and read the file (0600). The folder is left
/// out of Time Machine backups, and the file is written in full under another name and
/// then renamed, so a crash never leaves half a sample behind.
///
/// The format: the 4 bytes "ORVS", then the version, the sample rate and the number of
/// samples, each a little endian UInt32, then the mono samples as little endian Float32.
nonisolated struct VoiceSampleFile: Sendable {
    /// The folder of the file. Tests pass a temporary one.
    let folder: URL

    static let name = "voice-sample.dat"
    static let magic: [UInt8] = Array("ORVS".utf8)
    static let version: UInt32 = 1
    static let headerSize = 16
    /// The sample rates a voice sample can have, wider than any microphone's.
    static let sampleRates = 8_000...384_000

    var url: URL {
        folder.appendingPathComponent(Self.name, isDirectory: false)
    }

    /// The app's file. Computing it touches nothing on disk.
    static var live: VoiceSampleFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VoiceSampleFile(folder: support.appendingPathComponent("io.github.db-ol.Orra/Voice", isDirectory: true))
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes the audio of `sample` in place of the file before it. Off the main actor,
    /// since a sample holds up to a few MB.
    @concurrent
    func save(_ sample: VoiceSample) async throws {
        try write(Self.encoded(sample))
    }

    /// Reads the file, nil when there is none. Throws `VoiceSample.ReadError.unreadable`
    /// for a file that is not a voice sample Orra wrote, and `.tooShort` for one under
    /// VoiceSample.minimumSeconds.
    @concurrent
    func load() async throws -> VoiceSample? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw VoiceSample.ReadError.unreadable
        }
        return try Self.decoded(data)
    }

    /// Deletes the file, with the folder and anything a write left behind in it.
    @concurrent
    func remove() async {
        try? FileManager.default.removeItem(at: folder)
    }

    static func encoded(_ sample: VoiceSample) -> Data {
        var data = Data(capacity: headerSize + sample.samples.count * 4)
        data.append(contentsOf: magic)
        for value in [version, UInt32(clamping: sample.sampleRate), UInt32(clamping: sample.samples.count)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        for value in sample.samples {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decoded(_ data: Data) throws -> VoiceSample {
        let read: (samples: [Float], rate: Int)? = data.withUnsafeBytes { raw in
            func word(at offset: Int) -> UInt32 {
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            guard raw.count >= headerSize, Array(raw.prefix(4)) == magic, word(at: 4) == version else { return nil }
            let rate = Int(word(at: 8))
            let count = Int(word(at: 12))
            guard sampleRates.contains(rate),
                  raw.count == headerSize + count * 4,
                  Double(count) <= VoiceSample.maximumSeconds * Double(rate) + 1
            else { return nil }
            var samples = [Float]()
            samples.reserveCapacity(count)
            for index in 0..<count {
                let value = Float(bitPattern: word(at: headerSize + index * 4))
                guard value.isFinite else { return nil }
                samples.append(value)
            }
            return (samples, rate)
        }
        guard let read else { throw VoiceSample.ReadError.unreadable }
        let sample = VoiceSample(samples: read.samples, sampleRate: read.rate)
        guard sample.seconds >= VoiceSample.minimumSeconds else { throw VoiceSample.ReadError.tooShort }
        return sample
    }

    /// Creates the folder for the user alone and out of backups, writes a new file only the
    /// user can read next to the old one, and renames it over the old one.
    private func write(_ data: Data) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The folder may be older than this rule.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try ModelDisk.excludeFromBackup(folder)
        let temporary = folder.appendingPathComponent(".\(Self.name)-\(UUID().uuidString)", isDirectory: false)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
