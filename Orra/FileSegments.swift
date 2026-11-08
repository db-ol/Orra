import Foundation

/// How Transcribe File cuts a file into the segments the speech model transcribes, each
/// with its start and end in the file, which become the times of the subtitles.
///
/// The cuts are those of meeting captions, CaptionSegmenter, which works on a stream,
/// gives each sentence its times and was tuned with the speech model on the speech corpus.
/// The cuts of a long dictation, RecordingPieces, need the whole recording in memory and
/// make pieces of up to a minute, too long for a subtitle. Segments aim at 2 to 15 s: a
/// stretch of speech that reaches 15 s without a pause is cut at its quietest frame after
/// its first 2 s, and a segment shorter than 2 s joins the next one when that follows
/// within a second, see FileSegmentJoiner. The pause that ends a sentence, the least
/// speech a segment needs and the audio kept around it are those of captions.
///
/// A file can be far quieter than what the Mac plays. Most English clips of FLEURS stay
/// below the levels captions start and go on at, 0.003 and 0.002 RMS, so on 10 minutes of
/// them joined with pauses the speech model missed 63% of the words. Speech still has to
/// stand 4 times above the noise of the pauses to start and 2 times to go on, so a file
/// lowers the two levels to 0.0004 and 0.0003, which only matter above digital silence.
/// The error rate on those 10 minutes fell to 4.3%, against 3.7% for the same clips each
/// transcribed whole, and on 10 minutes of Chinese clips it was 3.2% against 3.8%,
/// measured on 2026-11-05 with FileTranscriptionMeasurementTests.
nonisolated enum FileSegments {
    /// The shortest segment Transcribe File aims at.
    static let shortest = 2.0
    /// The longest segment.
    static let longest = 15.0
    /// The longest pause a short segment is joined across.
    static let joinedPause = 1.0

    /// The segmenter's settings for a file: those of captions, with a longer limit, a cut
    /// anywhere after the first `shortest` seconds of a long stretch, and lower levels for
    /// quiet files.
    static var settings: CaptionSegmenter.Settings {
        var settings = CaptionSegmenter.Settings()
        settings.maximumLength = longest
        settings.cutWindow = longest - shortest
        settings.startLevel = 0.0004
        settings.continueLevel = 0.0003
        return settings
    }
}

/// Joins a segment shorter than `FileSegments.shortest` with the one after it, when that
/// starts within `FileSegments.joinedPause` of its end and the two last no longer than
/// `FileSegments.longest` together, so the speech model hears a short answer such as “Yes,
/// that works.” with what follows it, and the subtitle stays up long enough to read. The
/// joined segment holds the samples of both without the pause between them, and spans
/// both in time. A short segment with nothing close after it stays as it is.
///
/// Pure work on values, so the tests feed it made up segments.
nonisolated struct FileSegmentJoiner: Sendable {
    /// A short segment that waits for the next one.
    private var held: CaptionSegment?

    /// Takes the next segment and returns those that are ready, in order.
    mutating func append(_ segment: CaptionSegment) -> [CaptionSegment] {
        guard let first = held else {
            return keepingShort(segment)
        }
        held = nil
        if segment.start - first.end <= FileSegments.joinedPause, segment.end - first.start <= FileSegments.longest {
            return keepingShort(CaptionSegment(samples: first.samples + segment.samples, start: first.start, end: segment.end))
        }
        return [first] + keepingShort(segment)
    }

    /// The end of the file: the short segment that waits, if any.
    mutating func finish() -> CaptionSegment? {
        defer { held = nil }
        return held
    }

    /// Holds a short segment for the next one and passes on any other.
    private mutating func keepingShort(_ segment: CaptionSegment) -> [CaptionSegment] {
        guard segment.duration < FileSegments.shortest else { return [segment] }
        held = segment
        return []
    }
}
