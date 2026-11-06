import AVFoundation
import Foundation
import os

/// Why Transcribe File cannot read a file, or stopped reading one.
nonisolated enum FileAudioProblem: Error, Equatable, Sendable {
    /// Not a file AVFoundation reads, such as a document, a folder or a damaged file.
    case unreadable
    /// A file without an audio track, such as a video without sound.
    case noAudio
    /// Protected media, such as a movie bought in a store, whose audio no app may read.
    case protected
    /// A file in iCloud Drive or another cloud that is not on this Mac yet. Reading it
    /// would make macOS download it, so Orra leaves it alone.
    case notOnThisMac
    /// The audio stopped partway, such as in a damaged file or one that went away.
    case readFailed

    /// A short name for the log.
    var logName: String {
        switch self {
        case .unreadable: "unreadable"
        case .noAudio: "no audio"
        case .protected: "protected"
        case .notOnThisMac: "not on this Mac"
        case .readFailed: "read failed"
        }
    }
}

/// A file opened for Transcribe File: how long it is, and its speech segment by segment.
/// Closures, so tests pass made up segments.
nonisolated struct OpenedFile: Sendable {
    /// Seconds, as the file says, which can be a little off for some MP3 files.
    var duration: Double
    /// The next segment of speech, in order, nil after the last. Throws
    /// FileAudioProblem.readFailed when the audio stops partway.
    var next: @Sendable () async throws -> CaptionSegment?
    /// Stops reading and lets go of the file.
    var cancel: @Sendable () async -> Void
}

/// Reads the audio of one file the user dropped or picked for Transcribe File, and cuts it
/// into segments as it goes, see FileSegments.
///
/// AVAssetReader decodes the file's first audio track and converts it to 16 kHz mono, a
/// stereo track mixed down. The samples never go to disk, and only what a segment needs
/// stays in memory: each call of `next()` decodes until the next segment is cut, so a file
/// of several hours takes no more memory than a short one. The asset may follow no
/// reference to another file or a URL, so Orra reads the one file the user chose. A file
/// that is not on this Mac yet is refused before anything reads it, see
/// FileAudioProblem.notOnThisMac.
///
/// An actor, so decoding runs off the main actor, on a queue of its own: AVAssetReader
/// decodes in calls that block until the next buffer is ready, which must not hold a thread
/// of the shared pool of Swift concurrency that other work waits for.
actor FileAudioSource {
    private let queue = DispatchSerialQueue(label: "io.github.db-ol.Orra.file-audio", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private let url: URL
    private var segmenter: CaptionSegmenter
    private var joiner = FileSegmentJoiner()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// Segments cut and not taken yet. One chunk of audio can end more than one.
    private var ready: [CaptionSegment] = []
    private var isAtEnd = false
    /// The samples decoded so far. Internal for the tests that check that a file is read
    /// one segment at a time.
    private(set) var decodedSamples = 0
    /// Where the track's first sample plays in the file, in seconds, which segment times
    /// start from. A track that starts late in a video has its delay here.
    private var offset: Double?

    init(url: URL, settings: CaptionSegmenter.Settings = FileSegments.settings) {
        self.url = url
        segmenter = CaptionSegmenter(settings: settings)
    }

    /// What the reader turns the track into: 16 kHz mono 32 bit floats.
    static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: RecordingLimits.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// The file as a source for FileTranscription.
    static func open(_ url: URL) async throws -> OpenedFile {
        let source = FileAudioSource(url: url)
        let duration = try await source.open()
        return OpenedFile(
            duration: duration,
            next: { try await source.next() },
            cancel: { await source.cancel() }
        )
    }

    /// Opens the file and starts reading its audio. Returns its length in seconds, or
    /// throws a FileAudioProblem.
    func open() async throws -> Double {
        if let problem = Self.problemBeforeOpening(url) {
            throw problem
        }
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        let isReadable: Bool
        let isProtected: Bool
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            (isReadable, isProtected, duration, tracks) = try await asset.load(.isReadable, .hasProtectedContent, .duration, .tracks)
        } catch {
            Logger.fileTranscription.error("The file could not be opened: \(Self.code(of: error), privacy: .public)")
            throw FileAudioProblem.unreadable
        }
        let audio = tracks.filter { $0.mediaType == .audio }
        if let problem = Self.problem(isReadable: isReadable, isProtected: isProtected, audioTracks: audio.count, otherTracks: tracks.count - audio.count) {
            throw problem
        }
        // The first audio track that plays, such as the main language of a movie.
        var chosen = audio[0]
        for track in audio where (try? await track.load(.isEnabled)) == true {
            chosen = track
            break
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            Logger.fileTranscription.error("The file could not be read: \(Self.code(of: error), privacy: .public)")
            throw FileAudioProblem.unreadable
        }
        let output = AVAssetReaderTrackOutput(track: chosen, outputSettings: Self.outputSettings)
        // The samples are copied into the segment anyway.
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw FileAudioProblem.unreadable
        }
        reader.add(output)
        guard reader.startReading() else {
            Logger.fileTranscription.error("Reading the file did not start: \(reader.error.map(Self.code(of:)) ?? "no error", privacy: .public)")
            throw FileAudioProblem.unreadable
        }
        self.reader = reader
        self.output = output
        return duration.isNumeric ? max(duration.seconds, 0) : 0
    }

    /// The next segment, nil after the last one or once reading was cancelled. Throws
    /// FileAudioProblem.readFailed when the audio stops partway, and CancellationError when
    /// the task is cancelled.
    func next() throws -> CaptionSegment? {
        while ready.isEmpty, !isAtEnd {
            try Task.checkCancellation()
            guard let reader, let output else { return nil }
            guard let buffer = output.copyNextSampleBuffer() else {
                isAtEnd = true
                switch reader.status {
                case .failed:
                    Logger.fileTranscription.error("Reading the file stopped partway: \(reader.error.map(Self.code(of:)) ?? "no error", privacy: .public)")
                    throw FileAudioProblem.readFailed
                case .cancelled:
                    return nil
                default:
                    break
                }
                if let last = segmenter.finish() {
                    take(last)
                }
                if let held = joiner.finish() {
                    ready.append(shifted(held))
                }
                break
            }
            if offset == nil {
                let time = CMSampleBufferGetPresentationTimeStamp(buffer)
                offset = time.isNumeric ? max(time.seconds, 0) : 0
            }
            let samples = Self.samples(of: buffer)
            decodedSamples += samples.count
            for segment in segmenter.append(samples) {
                take(segment)
            }
        }
        return ready.isEmpty ? nil : ready.removeFirst()
    }

    /// Stops reading. Later calls of `next()` return nil.
    func cancel() {
        reader?.cancelReading()
        reader = nil
        output = nil
        ready = []
        isAtEnd = true
    }

    private func take(_ segment: CaptionSegment) {
        ready += joiner.append(segment).map(shifted)
    }

    /// The segment with its times in the file rather than in the track.
    private func shifted(_ segment: CaptionSegment) -> CaptionSegment {
        var segment = segment
        segment.start += offset ?? 0
        segment.end += offset ?? 0
        return segment
    }

    /// The samples of one buffer of the reader's output.
    private static func samples(of buffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? samples : []
    }

    /// What keeps a file from being read, from what the asset says about it.
    static func problem(isReadable: Bool, isProtected: Bool, audioTracks: Int, otherTracks: Int) -> FileAudioProblem? {
        if isProtected {
            return .protected
        }
        if audioTracks == 0 {
            // A movie without sound has tracks, a document has none.
            return otherTracks > 0 ? .noAudio : .unreadable
        }
        return isReadable ? nil : .unreadable
    }

    /// A folder or another thing that is no file, and a file that is not on this Mac yet,
    /// before anything reads it. Follows a symbolic link to the file it names, which is the
    /// file the user chose.
    static func problemBeforeOpening(_ url: URL) -> FileAudioProblem? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return .unreadable }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return problem(mode: info.st_mode, flags: info.st_flags, isUbiquitous: values?.isUbiquitousItem == true, downloadingStatus: values?.ubiquitousItemDownloadingStatus)
    }

    /// What `problemBeforeOpening(_:)` finds from what stat and the file's resource values
    /// say: no ordinary file, or one whose contents are not on this Mac, which a file
    /// provider such as iCloud Drive marks dataless, or an iCloud item not downloaded yet.
    static func problem(mode: mode_t, flags: UInt32, isUbiquitous: Bool, downloadingStatus: URLUbiquitousItemDownloadingStatus?) -> FileAudioProblem? {
        guard mode & S_IFMT == S_IFREG else { return .unreadable }
        if flags & UInt32(SF_DATALESS) != 0 {
            return .notOnThisMac
        }
        if isUbiquitous, downloadingStatus == .notDownloaded {
            return .notOnThisMac
        }
        return nil
    }

    /// The domain and code of an error, for the log, never its text, which may name the
    /// file.
    private static func code(of error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}

extension Logger {
    /// Transcribe File. Durations, counts, timings and error codes only, never the text,
    /// the audio or the name of a file.
    nonisolated static let fileTranscription = Logger(subsystem: ProblemReport.subsystem, category: "transcribe-file")
}
