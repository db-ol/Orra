import AVFoundation
import Foundation
import Testing
@testable import Orra

/// Reading the audio of a file for Transcribe File, on files the tests make: WAV, AIFF,
/// CAF and M4A audio, an MP4 and a QuickTime movie with sound, a movie without sound, a
/// document and a folder. Times of the segments come out where the sound is, whatever
/// the file's rate and channels.
struct FileAudioSourceTests {
    /// Three stretches of sound with pauses between them, in a file of 12 s.
    static let bursts: [(start: Double, end: Double)] = [(1.0, 3.5), (5.0, 8.0), (9.5, 11.2)]

    /// Every segment of a file.
    private func segments(of url: URL) async throws -> (duration: Double, segments: [CaptionSegment]) {
        let opened = try await FileAudioSource.open(url)
        var segments: [CaptionSegment] = []
        while let segment = try await opened.next() {
            segments.append(segment)
        }
        await opened.cancel()
        return (opened.duration, segments)
    }

    /// The segments match the bursts: each starts at its burst less the preroll and ends
    /// after it with the tail, within 0.1 s, with 16 kHz samples.
    private func expectBursts(_ segments: [CaptionSegment], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(segments.count == Self.bursts.count, sourceLocation: sourceLocation)
        for (segment, burst) in zip(segments, Self.bursts) {
            #expect(abs(segment.start - (burst.start - 0.2)) < 0.1, "start \(segment.start) for \(burst.start)", sourceLocation: sourceLocation)
            #expect(abs(segment.end - (burst.end + 0.15)) < 0.1, "end \(segment.end) for \(burst.end)", sourceLocation: sourceLocation)
            let seconds = Double(segment.samples.count) / 16_000
            #expect(abs(seconds - segment.duration) < 0.05, sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: [("wav", 44_100.0, 2), ("aif", 48_000.0, 1), ("caf", 16_000.0, 1), ("m4a", 44_100.0, 1), ("m4a", 22_050.0, 2)])
    func audioFilesAreReadAs16kHzMonoWithTheirTimes(_ type: String, _ rate: Double, _ channels: Int) async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sound.\(type)")
        // With two channels the sound is on the left one only, and still heard.
        try TestMedia.writeAudio(TestMedia.bursts(Self.bursts, seconds: 12, rate: rate), rate: rate, channels: channels, to: url)
        let (duration, segments) = try await segments(of: url)
        #expect(abs(duration - 12) < 0.1)
        expectBursts(segments)
    }

    @Test(arguments: ["mp4", "mov"])
    func aMovieWithSoundIsReadFromItsAudioTrack(_ type: String) async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("movie.\(type)")
        try await Self.writeMovie(TestMedia.bursts(Self.bursts, seconds: 12, rate: 48_000), seconds: 12, to: url)
        let (duration, segments) = try await segments(of: url)
        #expect(abs(duration - 12) < 0.6)
        expectBursts(segments)
    }

    @Test func aMovieWithoutSoundHasNoAudio() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("silent movie.mp4")
        try await Self.writeMovie(nil, seconds: 3, to: url)
        await #expect(throws: FileAudioProblem.noAudio) {
            _ = try await FileAudioSource.open(url)
        }
    }

    /// Writes a movie with a picture, or ends the test as skipped in a virtual machine and
    /// on a Mac that cannot write H.264 video.
    private static func writeMovie(_ samples: [Float]?, seconds: Double, to url: URL) async throws {
        if TestMedia.isVirtualMachine {
            try Test.cancel("A virtual machine writes no H.264 movie for this test")
        }
        do {
            try await TestMedia.writeMovie(samples, rate: 48_000, seconds: seconds, video: true, to: url)
        } catch let error as TestMedia.MovieNotWritten {
            try Test.cancel("This Mac could not write an H.264 movie: \(String(describing: error.underlying))")
        }
    }

    @Test func aDocumentAFolderAndAMissingFileCannotBeRead() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("notes.m4a")
        try Data("These are notes, not sound.".utf8).write(to: document)
        await #expect(throws: FileAudioProblem.unreadable) {
            _ = try await FileAudioSource.open(document)
        }
        await #expect(throws: FileAudioProblem.unreadable) {
            _ = try await FileAudioSource.open(folder)
        }
        await #expect(throws: FileAudioProblem.unreadable) {
            _ = try await FileAudioSource.open(folder.appendingPathComponent("gone.wav"))
        }
    }

    /// What the asset says decides the problem: protected media first, then a file without
    /// sound, then one that cannot be read.
    @Test func theProblemFollowsWhatTheAssetSays() {
        #expect(FileAudioSource.problem(isReadable: true, isProtected: false, audioTracks: 1, otherTracks: 1) == nil)
        #expect(FileAudioSource.problem(isReadable: false, isProtected: true, audioTracks: 1, otherTracks: 1) == .protected)
        #expect(FileAudioSource.problem(isReadable: true, isProtected: true, audioTracks: 0, otherTracks: 1) == .protected)
        #expect(FileAudioSource.problem(isReadable: true, isProtected: false, audioTracks: 0, otherTracks: 1) == .noAudio)
        #expect(FileAudioSource.problem(isReadable: false, isProtected: false, audioTracks: 0, otherTracks: 0) == .unreadable)
        #expect(FileAudioSource.problem(isReadable: false, isProtected: false, audioTracks: 1, otherTracks: 0) == .unreadable)
    }

    @Test func anOrdinaryFileIsOnThisMac() throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sound.wav")
        try TestMedia.writeAudio([Float](repeating: 0, count: 1_600), rate: 16_000, to: url)
        #expect(FileAudioSource.problemBeforeOpening(url) == nil)
        #expect(FileAudioSource.problemBeforeOpening(folder) == .unreadable)
    }

    /// Each call decodes only up to the next segment, so a stop leaves the rest unread.
    @Test func readingStopsWhenCancelled() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sound.caf")
        try TestMedia.writeAudio(TestMedia.bursts(Self.bursts, seconds: 12, rate: 16_000), rate: 16_000, to: url)
        let opened = try await FileAudioSource.open(url)
        let first = try await opened.next()
        #expect(first != nil)
        await opened.cancel()
        #expect(try await opened.next() == nil)
    }

    /// A segment shorter than 2 s joins the one after it when that follows within a second.
    @Test func aShortStretchJoinsTheNextOne() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sound.wav")
        try TestMedia.writeAudio(TestMedia.bursts([(1.0, 1.8), (2.6, 6.0), (8.0, 10.0)], seconds: 11, rate: 16_000), rate: 16_000, to: url)
        let (_, segments) = try await segments(of: url)
        try #require(segments.count == 2)
        #expect(abs(segments[0].start - 0.8) < 0.1)
        #expect(abs(segments[0].end - 6.15) < 0.1)
    }

    /// A file of several hours is read segment by segment, with no more memory than a
    /// short one. It writes about 40 MB, so it runs only with
    /// TEST_RUNNER_ORRA_TRANSCRIBE_LONG=1, and then attaches the time it took and the
    /// memory as transcribe-file-long.txt. Run it on its own: memory that the speech model
    /// of an earlier test in the same run gives back and takes again shows as growth here.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORRA_TRANSCRIBE_LONG"] != nil))
    func aFileOfThreeHoursIsReadInBoundedMemory() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("long.m4a")
        let hours = 3.0
        let seconds = hours * 3_600
        let rate = 16_000.0
        // Written in pieces of 10 minutes, so the test itself never holds the whole file.
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let piece = 600.0
            // Sound for 3 s in every 5 s.
            let pattern = stride(from: 0.0, to: piece, by: 5).map { (start: $0 + 1, end: $0 + 4) }
            let samples = TestMedia.bursts(pattern, seconds: piece, rate: rate)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            for _ in 0..<Int(seconds / piece) {
                try file.write(from: buffer)
            }
        }
        let before = MemoryFootprint.current()
        let started = ContinuousClock.now
        let opened = try await FileAudioSource.open(url)
        var count = 0
        var last: CaptionSegment?
        var peak = before
        while let segment = try await opened.next() {
            count += 1
            last = segment
            if count % 200 == 0 {
                peak = max(peak, MemoryFootprint.current())
            }
        }
        await opened.cancel()
        let took = started.duration(to: .now)
        #expect(abs(opened.duration - seconds) < 1)
        #expect(count == Int(seconds / 5))
        #expect(abs((last?.end ?? 0) - (seconds - 1 + 0.15)) < 0.2)
        // Far less than the 690 MB of the samples of three hours.
        let grown = Int64(peak) - Int64(before)
        #expect(grown < 100_000_000, "grew \(grown / 1_000_000) MB")
        Attachment.record("Read \(count) segments of \(hours) h in \(took), memory grew \(grown / 1_000_000) MB at the most", named: "transcribe-file-long.txt")
    }
}
